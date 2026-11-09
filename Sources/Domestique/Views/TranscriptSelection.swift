import AppKit
import SwiftUI

/// One continuous text selection across a whole transcript. SwiftUI's `.textSelection` stops at the
/// edge of each `Text`, so user messages and answers render through `SpanText` and share this instead.
///
/// The selection is stored against the transcript model rather than the views: the stack is lazy, so
/// text scrolled out of view has no view but must still be highlighted on return and copied.
@MainActor
final class TranscriptSelection {
    struct Segment {
        let id: String
        let text: String
        /// Joins this segment to the one before it when copied.
        let lead: String
    }

    private struct Spot: Equatable {
        var id: String
        var offset: Int
    }

    /// Assigned on every transcript render; segments are only derived from it when a selection needs them.
    var turns: [Turn] = []

    private var segments: [Segment] = []
    private var order: [String: Int] = [:]
    private var live: [String: SpanTextView] = [:]
    private var anchor: Spot?
    private var focus: Spot?

    private var dragEvent: NSEvent?
    private var dragOrigin: Spot?
    private var dragMoved = false
    private var dragView: SpanTextView?
    private var scrollClip: NSClipView?
    private var autoscrollTimer: Timer?
    private var monitor: Any?

    // MARK: Lifecycle

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            // Local monitors always run on the main thread.
            nonisolated(unsafe) let mainEvent = event
            let passThrough = MainActor.assumeIsolated { self.handle(mainEvent) != nil }
            return passThrough ? event : nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endDrag()
    }

    func register(_ view: SpanTextView, id: String) {
        if view.spanID != id, live[view.spanID] === view { live[view.spanID] = nil }
        view.spanID = id
        live[id] = view
        view.showSelection(range(for: id, length: view.string.utf16.count))
    }

    func unregister(_ view: SpanTextView) {
        if live[view.spanID] === view { live[view.spanID] = nil }
    }

    // MARK: Events

    private var window: NSWindow? { live.values.first?.window }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // Runs before the view's own mouseDown, which starts a new selection if the click hit text.
            if event.window === window { clear() }
        case .leftMouseDragged:
            if dragView != nil {
                dragEvent = event
                dragMoved = true
                updateFocus(event)
            }
        case .leftMouseUp:
            if dragView != nil {
                if !dragMoved, let view = dragView, let url = view.link(at: event.locationInWindow) {
                    NSWorkspace.shared.open(url)
                }
                endDrag()
            }
        case .keyDown:
            return handleKey(event)
        default:
            break
        }
        return event
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return event
        }
        let responder = event.window?.firstResponder
        switch event.charactersIgnoringModifiers {
        case "c":
            // Don't take Copy from the composer or a search field.
            guard hasSelection, responder is SpanTextView || !(responder is NSText) else { return event }
            copySelection()
            return nil
        case "a":
            guard responder is SpanTextView else { return event }
            selectAll()
            return nil
        default:
            return event
        }
    }

    func mouseDown(on view: SpanTextView, event: NSEvent) {
        rebuild()
        view.window?.makeFirstResponder(view)
        let index = view.characterIndex(at: event.locationInWindow)
        dragView = view
        dragEvent = event
        dragMoved = false
        scrollClip = view.outermostScrollView?.contentView

        if event.clickCount > 1 {
            let granularity: NSSelectionGranularity = event.clickCount == 2 ? .selectByWord : .selectByParagraph
            let span = view.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: granularity)
            anchor = Spot(id: view.spanID, offset: span.location)
            focus = Spot(id: view.spanID, offset: span.location + span.length)
            dragMoved = true
        } else {
            anchor = Spot(id: view.spanID, offset: index)
            focus = anchor
        }
        applyToLiveViews()

        // Keep scrolling while the pointer rests past the edge, when no drag events arrive.
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
    }

    private func autoscrollTick() {
        guard let event = dragEvent, dragMoved, let clip = scrollClip else { return }
        if clip.autoscroll(with: event) { updateFocus(event) }
    }

    private func endDrag() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        dragView = nil
        dragEvent = nil
        scrollClip = nil
    }

    private func updateFocus(_ event: NSEvent) {
        guard let view = nearestView(to: event.locationInWindow) else { return }
        let spot = Spot(id: view.spanID, offset: view.characterIndex(at: event.locationInWindow))
        guard spot != focus else { return }
        focus = spot
        applyToLiveViews()
    }

    /// The text under the pointer, or the closest to it when dragging through the gaps between blocks.
    private func nearestView(to point: NSPoint) -> SpanTextView? {
        var best: (view: SpanTextView, distance: CGFloat, across: CGFloat)?
        for view in live.values where view.window != nil {
            let frame = view.convert(view.bounds, to: nil)
            let distance = point.y < frame.minY ? frame.minY - point.y : point.y > frame.maxY ? point.y - frame.maxY : 0
            let across = point.x < frame.minX ? frame.minX - point.x : point.x > frame.maxX ? point.x - frame.maxX : 0
            if best == nil || distance < best!.distance || (distance == best!.distance && across < best!.across) {
                best = (view, distance, across)
            }
        }
        return best?.view
    }

    // MARK: Selection

    var hasSelection: Bool {
        guard let bounds = orderedBounds else { return false }
        return bounds.lower != bounds.upper
    }

    func clear() {
        anchor = nil
        focus = nil
        applyToLiveViews()
    }

    func selectAll() {
        rebuild()
        guard let first = segments.first, let last = segments.last else { return }
        anchor = Spot(id: first.id, offset: 0)
        focus = Spot(id: last.id, offset: last.text.utf16.count)
        applyToLiveViews()
    }

    func copySelection() {
        rebuild()
        guard let bounds = orderedBounds else { return }
        var out = ""
        for index in bounds.lower.index...bounds.upper.index {
            let segment = segments[index]
            let text = segment.text as NSString
            let start = index == bounds.lower.index ? min(bounds.lower.offset, text.length) : 0
            let end = index == bounds.upper.index ? min(bounds.upper.offset, text.length) : text.length
            if index != bounds.lower.index { out += segment.lead }
            out += text.substring(with: NSRange(location: start, length: max(0, end - start)))
        }
        copy(out)
    }

    private struct Bound: Equatable {
        var index: Int
        var offset: Int
    }

    private var orderedBounds: (lower: Bound, upper: Bound)? {
        guard let anchor, let focus, let a = order[anchor.id], let f = order[focus.id] else { return nil }
        let first = Bound(index: a, offset: anchor.offset)
        let second = Bound(index: f, offset: focus.offset)
        return (a, anchor.offset) <= (f, focus.offset) ? (first, second) : (second, first)
    }

    private func range(for id: String, length: Int) -> NSRange? {
        guard let bounds = orderedBounds, let index = order[id], index >= bounds.lower.index, index <= bounds.upper.index
        else { return nil }
        let start = index == bounds.lower.index ? min(bounds.lower.offset, length) : 0
        let end = index == bounds.upper.index ? min(bounds.upper.offset, length) : length
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private func applyToLiveViews() {
        for (id, view) in live { view.showSelection(range(for: id, length: view.string.utf16.count)) }
    }

    private func rebuild() {
        segments = turns.flatMap(Self.segments(of:))
        order = Dictionary(segments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func segments(of turn: Turn) -> [Segment] {
        var out: [Segment] = []
        if let user = turn.user, case .user(let text) = user.kind {
            out.append(Segment(id: user.id, text: text, lead: "\n\n"))
        }
        if let answer = turn.answer, case .assistant(let text) = answer.kind, !text.isEmpty {
            out += MarkdownParser.segments(MarkdownParser.parse(text), prefix: answer.id)
        }
        return out
    }
}

extension EnvironmentValues {
    @Entry var transcriptSelection: TranscriptSelection? = nil
}

extension MarkdownParser {
    /// The selectable pieces of a message, one per text view `BlockView` renders, with matching IDs.
    static func segments(_ blocks: [MarkdownBlock], prefix: String) -> [TranscriptSelection.Segment] {
        typealias Segment = TranscriptSelection.Segment
        func plain(_ s: String) -> String { String(inline(s).characters) }
        var out: [Segment] = []
        for (b, block) in blocks.enumerated() {
            let id = "\(prefix)#\(b)"
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                out.append(Segment(id: id, text: plain(text), lead: "\n\n"))
            case .code(_, let code):
                out.append(Segment(id: id, text: code, lead: "\n\n"))
            case .list(let ordered, let items):
                for (i, item) in items.enumerated() {
                    let indent = String(repeating: "  ", count: item.indent)
                    let marker = item.checked.map { $0 ? "[x] " : "[ ] " } ?? (ordered ? "\(i + 1). " : "- ")
                    out.append(Segment(id: "\(id).\(i)", text: plain(item.text), lead: (i == 0 ? "\n\n" : "\n") + indent + marker))
                }
            case .table(let rows):
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        let lead = c > 0 ? "\t" : r == 0 ? "\n\n" : "\n"
                        out.append(Segment(id: "\(id).\(r).\(c)", text: plain(cell), lead: lead))
                    }
                }
            case .rule:
                break
            }
        }
        return out
    }
}

// MARK: - Text view

/// Text that takes part in a `TranscriptSelection`.
struct SpanText: NSViewRepresentable {
    let id: String
    let text: NSAttributedString
    var wraps = true
    @Environment(\.transcriptSelection) private var selection

    func makeNSView(context: Context) -> SpanTextView {
        SpanTextView(usingTextLayoutManager: false).configured()
    }

    func updateNSView(_ view: SpanTextView, context: Context) {
        view.selection = selection
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
        selection?.register(view, id: id)
    }

    static func dismantleNSView(_ view: SpanTextView, coordinator: ()) {
        view.selection?.unregister(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SpanTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let unbounded = CGFloat.greatestFiniteMagnitude
        container.size = NSSize(width: wraps ? (proposal.width ?? unbounded) : unbounded, height: unbounded)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

final class SpanTextView: NSTextView {
    var spanID = ""
    weak var selection: TranscriptSelection?

    func configured() -> SpanTextView {
        isEditable = false
        isSelectable = false  // Selection is drawn and tracked by TranscriptSelection.
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        return self
    }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { selection?.mouseDown(on: self, event: event) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    // A tracking area rather than cursor rects, which don't take effect inside SwiftUI's hosting view.
    private var cursorArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        cursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    override func mouseExited(with event: NSEvent) {
        // Keep the I-beam while a drag passes over the gaps between blocks.
        if NSEvent.pressedMouseButtons == 0 { NSCursor.arrow.set() }
    }

    private func updateCursor(_ event: NSEvent) {
        (link(at: event.locationInWindow) != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }


    override func menu(for event: NSEvent) -> NSMenu? {
        guard selection?.hasSelection == true else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copySpan), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copySpan() { selection?.copySelection() }

    /// Temporary attributes rather than the native selection, which greys out in every view but the
    /// first responder and so can't look like one selection.
    func showSelection(_ range: NSRange?) {
        guard let layout = layoutManager else { return }
        let all = NSRange(location: 0, length: string.utf16.count)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard let range else { return }
        layout.addTemporaryAttributes(
            [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor],
            forCharacterRange: range)
    }

    /// The insertion point nearest a window location, clamped to the start or end above or below the text.
    func characterIndex(at windowPoint: NSPoint) -> Int {
        guard let layout = layoutManager, let container = textContainer else { return 0 }
        let point = convert(windowPoint, from: nil)
        let length = string.utf16.count
        if point.y < 0 { return 0 }
        if point.y > bounds.maxY { return length }
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(length, index + (fraction > 0.5 ? 1 : 0))
    }

    func link(at windowPoint: NSPoint) -> URL? {
        let index = characterIndex(at: windowPoint)
        guard index < string.utf16.count, let storage = textStorage else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    /// The transcript's own scroll view, skipping any horizontal one around a code block or table.
    var outermostScrollView: NSScrollView? {
        var found = enclosingScrollView
        while let outer = found?.superview?.enclosingScrollView { found = outer }
        return found
    }
}

// MARK: - Styling

enum SpanStyle {
    /// Renders inline markdown or highlighted code the way SwiftUI's `Text` would.
    static func attributed(
        _ source: AttributedString, font: NSFont, color: NSColor, lineSpacing: CGFloat = 0
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let out = NSMutableAttributedString()
        for run in source.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont(base: font, intent: run.inlinePresentationIntent),
                .foregroundColor: run.swiftUI.foregroundColor.map { NSColor($0) } ?? color,
                .paragraphStyle: paragraph,
            ]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.controlAccentColor
            }
            out.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return out
    }

    private static func runFont(base: NSFont, intent: InlinePresentationIntent?) -> NSFont {
        guard let intent else { return base }
        if intent.contains(.code) { return .monospacedSystemFont(ofSize: base.pointSize - 0.5, weight: .regular) }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
    }
}

import AppKit
import SwiftUI

/// Design tokens. Light-first (Codex-like: white canvas, soft grey chrome), with dark variants.
enum Theme {
    // MARK: Surfaces
    static let canvas = dyn(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let sidebar = dyn(light: 0xF2F2F4, dark: 0x232325)
    static let panel = dyn(light: 0xFAFAFA, dark: 0x202022)
    static let raised = dyn(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let sunken = dyn(light: 0xF3F3F3, dark: 0x2A2A2C)
    /// Inset text fields and editors on raised cards (darker than the card in dark mode, where
    /// `sunken` and `raised` are nearly the same).
    static let field = dyn(light: 0xF3F3F3, dark: 0x1E1E20)
    static let hover = dyn(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.07)
    static let selected = dyn(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.11)
    static let hairline = dyn(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.085, darkAlpha: 0.10)
    static let border = dyn(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.11, darkAlpha: 0.13)

    // MARK: Text
    // Charcoal rather than near-black (and off-white in dark mode): calmer on long transcripts.
    static let text = dyn(light: 0x34343A, dark: 0xD8D8DC)
    static let text2 = dyn(light: 0x7A7A80, dark: 0x9C9CA2)
    static let text3 = dyn(light: 0xA8A8AE, dark: 0x6C6C72)
    /// Unselected sidebar titles: a step down from `text` so the selected and unread rows lead.
    static let textSoft = dyn(light: 0x55555B, dark: 0xB4B4BA)

    // MARK: Accents
    static let accent = Color.accentColor
    static let userBubble = dyn(light: 0xF2F2F4, dark: 0x2E2E31)
    static let userBubbleText = text
    /// The composer's round send button.
    static let sendButton = dyn(light: 0x2C2C30, dark: 0x4A4A4E)
    static let added = dyn(light: 0x3E8E58, dark: 0x5DBB74)
    static let removed = dyn(light: 0xC9575E, dark: 0xF07A7F)
    static let addedBG = dyn(light: 0x1A7F37, dark: 0x3FB950, lightAlpha: 0.09, darkAlpha: 0.14)
    static let removedBG = dyn(light: 0xCF222E, dark: 0xF85149, lightAlpha: 0.08, darkAlpha: 0.14)
    static let warning = dyn(light: 0xD9480F, dark: 0xFF8A4C)
    static let running = dyn(light: 0x2F80ED, dark: 0x58A6FF)
    static let merged = dyn(light: 0x8250DF, dark: 0xA371F7)
    /// Filled "go" buttons (Merge). Darker than `added` in dark mode so white text stays legible.
    static let go = dyn(light: 0x1F883D, dark: 0x238636)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = dyn(light: 0x111111, dark: 0xECECEE)

    // Tools and thinking stay neutral: colour is kept for status you act on (PRs, checks, needs-you, errors).
    static let toolIcon = dyn(light: 0x8E8E93, dark: 0x8E8E93)
    static let toolWash = dyn(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.06)

    // MARK: Syntax (Codex/GitHub-light-ish)
    static let synKeyword = dyn(light: 0xCF222E, dark: 0xFF7B72)
    static let synString = dyn(light: 0x0A3069, dark: 0xA5D6FF)
    static let synComment = dyn(light: 0x6E7781, dark: 0x8B949E)
    static let synNumber = dyn(light: 0x0550AE, dark: 0x79C0FF)
    static let synType = dyn(light: 0x8250DF, dark: 0xD2A8FF)
    static let synFunction = dyn(light: 0x6639BA, dark: 0xD2A8FF)
    static let synAttr = dyn(light: 0x0550AE, dark: 0x79C0FF)

    // MARK: Type
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let ui = Font.system(size: 13)
    static let uiMedium = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let tiny = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoDigits = Font.system(size: 11.5).monospacedDigit()

    // MARK: Metrics
    static let headerHeight: CGFloat = 46
    static let rowRadius: CGFloat = 7
    static let cardRadius: CGFloat = 12
    static let contentWidth: CGFloat = 760
    /// Max width of the chat column (transcript, composer, trays). It shrinks with the window below this.
    static let chatWidth: CGFloat = 900

    /// Extra space between lines so text of `size` sits on a `lineHeight` grid, like CSS line-height
    /// (13pt on 21pt for transcript prose).
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return max(0, lineHeight - (font.ascender - font.descender + font.leading))
    }

    private static func dyn(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

// MARK: - Components

/// Small borderless icon button with a rounded hover background.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(active ? Theme.text : Theme.text2)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(active ? Theme.selected : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Subtle bordered button (Codex "View changes", "Undo", Conductor "Open :port").
struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    /// Red label, for actions that remove or delete something.
    var destructive = false
    /// Fill for prominent buttons; defaults to the near-black `userBubble`.
    var fill: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SoftButtonBody(
            configuration: configuration, prominent: prominent, compact: compact, destructive: destructive,
            fill: fill ?? Theme.userBubble)
    }

    private struct SoftButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let compact: Bool
        let destructive: Bool
        let fill: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .lineLimit(1)
                .fixedSize()  // buttons keep their label; the row's text wraps instead
                .font(compact ? Theme.small : Theme.ui)
                .foregroundStyle(prominent ? Color.white : destructive ? Theme.removed : Theme.text)
                .padding(.horizontal, compact ? 8 : 11)
                .frame(height: compact ? 24 : 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(prominent ? AnyShapeStyle(fill) : AnyShapeStyle(hovering ? Theme.hover : Theme.raised))
                )
                .overlay {
                    if prominent && hovering {
                        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? .clear : Theme.border, lineWidth: 0.5)
                )
                .opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var softCompact: SoftButtonStyle { SoftButtonStyle(compact: true) }
    static var softProminent: SoftButtonStyle { SoftButtonStyle(prominent: true) }
    static var softDestructive: SoftButtonStyle { SoftButtonStyle(compact: true, destructive: true) }
    /// Filled green, for the moment a PR is ready to land.
    static var softGo: SoftButtonStyle { SoftButtonStyle(prominent: true, fill: Theme.go) }
}

/// Pill-style tab (Conductor "Changes 56" / "Checks").
struct PillTab: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text(verbatim: "\(count)").foregroundStyle(Theme.text3)
                }
            }
            .font(selected ? Theme.uiMedium : Theme.ui)
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Underlined tab (Conductor chat tabs / dock tabs).
struct UnderlineTab<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(Theme.ui)
                .foregroundStyle(selected ? Theme.text : hovering ? Theme.text : Theme.text2)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.text : .clear).frame(height: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "+12 −3" in monospaced digits.
struct DiffCount: View {
    let additions: Int
    let deletions: Int
    var font: Font = Theme.monoDigits

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(Self.short(additions))").foregroundStyle(Theme.added)
            Text(verbatim: "-\(Self.short(deletions))").foregroundStyle(Theme.removed)
        }
        .font(font)
    }

    static func short(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.0fk", Double(n) / 1000) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Row with rounded hover/selected background used in lists.
struct HoverRow<Content: View>: View {
    var selected = false
    var height: CGFloat? = nil
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rowRadius)
                        .fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
    }
}

/// Dashed empty-state box (Conductor dock "Run tests or a development server…").
struct DashedEmptyState<Actions: View>: View {
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Text(message)
                .font(Theme.ui)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            actions
        }
        .padding(28)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

/// Draggable divider between columns/rows. Hit area is wider than the 1pt line.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// Called with the drag translation since the last call.
    let onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    @State private var last: CGFloat = 0

    var body: some View {
        ZStack {
            Hairline(vertical: axis == .horizontal)
        }
        .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
        .overlay {
            Color.clear
                .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                .contentShape(Rectangle())
                // pointerStyle is scoped to the view: no push/pop stack to unbalance.
                .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let t = axis == .horizontal ? v.translation.width : v.translation.height
                            onDrag(t - last)
                            last = t
                        }
                        .onEnded { _ in
                            last = 0
                            onEnd()
                        }
                )
        }
    }
}

extension View {
    /// Standard header bar background: draggable window area.
    func headerBar() -> some View {
        self
            .frame(height: Theme.headerHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}

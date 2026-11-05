import AgentKit
import DQCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let chat: ChatModel
    let workspaceModel: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(chat: chat)
            AgentsTray(chat: chat)
                .padding(.bottom, 6)
                .animation(.snappy(duration: 0.2), value: chat.trayTaskIDs)
            ComposerView(chat: chat)
        }
        .onAppear { chat.loadIfNeeded() }
    }
}

struct EmptyChatHint: View {
    let chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tab = chat.tab, let ws = chat.workspace.workspace {
                HStack(spacing: 8) {
                    ProviderIcon(provider: tab.provider, size: 14)
                    Text("What should we build?")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Text(verbatim: "\(chat.workspace.repo?.title ?? "") · \(ws.branch) · ports \(ws.portBase)–\(ws.portBase + 9)")
                    .font(Theme.ui)
                    .foregroundStyle(Theme.text2)
            }
        }
        .padding(.top, 80)
    }
}

struct WorkingIndicator: View {
    let status: String?
    let since: Date?

    var body: some View {
        HStack(spacing: 8) {
            Spinner(size: 11)
            if let since {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(status ?? "Working for \(formatDuration(Int(ctx.date.timeIntervalSince(since) * 1000)))")
                        .monospacedDigit()
                }
            } else {
                Text(status ?? "Working…")
            }
        }
        .font(Theme.ui)
        .foregroundStyle(Theme.text2)
        .shimmering()
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(chat.attachments.enumerated()), id: \.offset) { i, a in
                        AttachmentChip(name: a.filename) { chat.attachments.remove(at: i) }
                    }
                }
            }
            TextField(placeholder, text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...14)
                .focused($focused)
                .onSubmit { chat.send() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    chat.draft += "\n"
                    return .handled
                }
                .padding(.top, 4)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                // The whole text region (not just the glyphs) is the text target: I-beam on hover,
                // click anywhere in it to focus. Leaving it restores the normal arrow. The tap lives on
                // a background layer so clicks on text still reach the field (caret, drag-select).
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .pointerStyle(.horizontalText)
                        .onTapGesture { focused = true }
                }
            HStack(spacing: 6) {
                Menu {
                    Button("Attach images…") { pickImages() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                PermissionMenu(chat: chat)
                Spacer(minLength: 8)
                ModelMenu(chat: chat)
                EffortMenu(chat: chat)
                SendButton(chat: chat)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .padding(.top, 2)
        .frame(maxWidth: Theme.contentWidth)
        .frame(maxWidth: .infinity)
        .onAppear { focusSoon() }
        .onChange(of: app.composerFocusRequest) { focusSoon() }
        .dropDestination(for: URL.self) { urls, _ in
            addImages(urls)
            return true
        }
    }

    /// Setting focus in the same pass the field is inserted is dropped by AppKit; defer a runloop turn.
    private func focusSoon() {
        DispatchQueue.main.async { focused = true }
    }

    private var placeholder: String {
        if chat.isRunning { return "Steer or queue a follow-up…" }
        switch chat.tab?.provider {
        case .codex: return "Work with Codex"
        default: return "Work with Claude"
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addImages(panel.urls)
    }

    private func addImages(_ urls: [URL]) {
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                let data = try? Data(contentsOf: url)
            else { continue }
            chat.attachments.append(
                AgentAttachment(data: data, mediaType: type.preferredMIMEType ?? "image/png", filename: url.lastPathComponent))
        }
    }
}

private struct AttachmentChip: View {
    let name: String
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo").foregroundStyle(Theme.text2)
            Text(name).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
        }
        .font(Theme.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PermissionMenu: View {
    let chat: ChatModel

    var body: some View {
        if let tab = chat.tab {
            Menu {
                ForEach(AgentPermissionMode.allCases) { m in
                    Button {
                        chat.setPermissionMode(m)
                    } label: {
                        if tab.permissionMode == m { Label(m.displayName, systemImage: "checkmark") } else { Text(m.displayName) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: symbol(tab.permissionMode)).font(.system(size: 11))
                    Text(tab.permissionMode.displayName)
                }
                .font(Theme.ui)
                .foregroundStyle(tab.permissionMode == .bypass ? Theme.warning : Theme.text2)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Full access never asks · Auto lets the provider's reviewer decide · Ask shows approvals here")
        }
    }

    private func symbol(_ m: AgentPermissionMode) -> String {
        switch m {
        case .bypass: "exclamationmark.circle"
        case .auto: "wand.and.stars"
        case .ask: "hand.raised"
        }
    }
}

/// Provider + model picker with search. Switching provider is only possible before the first message.
private struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    @State private var open = false

    var body: some View {
        if let tab = chat.tab {
            Button {
                open.toggle()
            } label: {
                ComposerChip {
                    ProviderIcon(provider: tab.provider, size: 10)
                    Text(app.modelLabel(tab.provider, tab.model)).foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.text3)
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Model")
            .popover(isPresented: $open, arrowEdge: .top) {
                ModelPickerList(chat: chat, tab: tab) { open = false }
            }
        }
    }
}

private struct ModelPickerList: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    let tab: ChatTab
    let done: () -> Void
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    struct Entry: Identifiable {
        var provider: ProviderKind
        var modelID: String?  // nil = provider default
        var name: String
        var detail: String?
        var tag: String
        var id: String { "\(provider.rawValue):\(modelID ?? "")" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text3)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui)
                    .focused($searchFocused)
                    .onSubmit { if let e = highlightedEntry { pick(e) } }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 7))
            .padding(8)
            Hairline()
            let groups = grouped
            if groups.isEmpty {
                Text("No models match “\(query)”")
                    .font(Theme.ui).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(groups, id: \.0) { provider, entries in
                                HStack(spacing: 5) {
                                    ProviderIcon(provider: provider, size: 9)
                                    Text(provider.displayName)
                                }
                                .font(Theme.smallMedium).foregroundStyle(Theme.text3)
                                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
                                ForEach(entries) { e in
                                    row(e).id(e.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { searchFocused = true }
        .onChange(of: query) { highlighted = nil }
    }

    private func row(_ e: Entry) -> some View {
        let selected = e.provider == tab.provider && e.modelID == tab.model
        let isHighlighted = highlightedEntry?.id == e.id
        return Button {
            pick(e)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(e.name).font(Theme.ui).foregroundStyle(Theme.text)
                        Text(e.tag).font(Theme.monoSmall).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    if let d = e.detail, !d.isEmpty {
                        Text(d).font(Theme.small).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = e.id } }
    }

    // MARK: data

    private var entries: [Entry] {
        ProviderKind.allCases.filter { $0 == tab.provider || !chat.hasMessages }.flatMap { p -> [Entry] in
            let def = app.models(for: p).first(where: \.isDefault)
            var list = [
                Entry(
                    provider: p, modelID: nil, name: app.modelLabel(p, nil),
                    detail: def?.description, tag: "default")
            ]
            list += app.pickableModels(for: p).map {
                Entry(provider: p, modelID: $0.id, name: $0.displayName, detail: $0.description, tag: $0.id)
            }
            return list
        }
    }

    private var filtered: [Entry] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { e in
            let hay = [e.name, e.tag, e.detail ?? "", e.provider.displayName].joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private var grouped: [(ProviderKind, [Entry])] {
        let list = filtered
        return ProviderKind.allCases.compactMap { p in
            let es = list.filter { $0.provider == p }
            return es.isEmpty ? nil : (p, es)
        }
    }

    private var highlightedEntry: Entry? {
        let list = filtered
        if let highlighted, let e = list.first(where: { $0.id == highlighted }) { return e }
        if query.isEmpty { return list.first { $0.provider == tab.provider && $0.modelID == tab.model } ?? list.first }
        return list.first
    }

    private func moveHighlight(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == highlightedEntry?.id } ?? 0
        highlighted = list[max(0, min(list.count - 1, i + delta))].id
    }

    private func pick(_ e: Entry) {
        if e.provider != tab.provider { chat.setProvider(e.provider) }
        chat.setModel(e.modelID)
        done()
    }
}

/// Thinking level for the chosen model (hidden when the model doesn't support it).
private struct EffortMenu: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel

    var body: some View {
        if let tab = chat.tab, let model = app.resolvedModel(tab.provider, tab.model), !model.efforts.isEmpty {
            let current = tab.effort ?? model.defaultEffort
            Menu {
                Section("Thinking") {
                    ForEach(model.efforts, id: \.self) { e in
                        Button {
                            chat.setEffort(e)
                        } label: {
                            check(current == e, Self.label(e) + (e == model.defaultEffort ? "  (default)" : ""))
                        }
                    }
                }
            } label: {
                ComposerChip {
                    Image(systemName: "brain").font(.system(size: 10)).foregroundStyle(Theme.text3)
                    Text(current.map(Self.label) ?? "Default").foregroundStyle(Theme.text2)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.text3)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Thinking level")
        }
    }

    static func label(_ e: String) -> String {
        switch e {
        case "xhigh": "Extra high"
        case "max": "Max"
        case "minimal": "Minimal"
        default: e.prefix(1).uppercased() + e.dropFirst()
        }
    }
}

private struct ComposerChip<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) { content }
            .font(Theme.ui)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

@ViewBuilder
private func check(_ on: Bool, _ title: String) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}

private struct SendButton: View {
    let chat: ChatModel

    var body: some View {
        let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty
        let stop = chat.isRunning && empty
        Button {
            if stop { chat.interrupt() } else { chat.send() }
        } label: {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(.system(size: stop ? 10 : 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.userBubble))
                .opacity(!stop && empty ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!stop && empty)
        .help(stop ? "Stop (⌘.)" : "Send (↩) · newline (⇧↩)")
    }
}

// MARK: - Shimmer

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Theme.canvas.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width * 1.5)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

import AgentKit
import DQCore
import ServerKit
import SwiftUI

/// One session: the transcript, live status, and the composer.
struct ChatView: View {
    @Bindable var chat: SessionChat
    let canWrite: Bool
    /// Swaps this (still empty) chat for one with another agent.
    let switchProvider: (ProviderKind, String) -> Void
    @FocusState private var composerFocused: Bool
    /// How many of the latest items are rendered; older ones are behind "Show earlier".
    @State private var limit = Self.pageSize

    private static let pageSize = 50

    var body: some View {
        ScrollView {
            // Deliberately not lazy: a bottom-anchored LazyVStack anchors to estimated row heights, and when
            // those are wrong it opens on blank space until a scroll forces layout. The window keeps this cheap.
            VStack(alignment: .leading, spacing: 14) {
                if !chat.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if chat.items.isEmpty && chat.queuedPrompt == nil {
                    EmptyChatHint(chat: chat)
                }
                if let err = chat.loadError {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(Palette.text2)
                }
                if chat.items.count > limit {
                    Button("Show earlier messages") { limit += Self.pageSize }
                        .font(.footnote)
                        .foregroundStyle(Palette.text2)
                        .frame(maxWidth: .infinity)
                }
                ForEach(chat.items.suffix(limit)) { item in
                    TranscriptRow(item: item, chat: chat, canWrite: canWrite)
                }
                if let prompt = chat.queuedPrompt {
                    UserBubble(text: prompt)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                LiveStrip(chat: chat)
                if canWrite { Composer(chat: chat, focused: $composerFocused, switchProvider: switchProvider) }
            }
            .background(Palette.canvas)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .task(id: chat.loaded) {
            // A new chat opens ready to type. Wait out the navigation push, which would drop the focus.
            guard chat.loaded, chat.items.isEmpty, canWrite else { return }
            try? await Task.sleep(for: .milliseconds(500))
            composerFocused = true
        }
    }
}

private struct EmptyChatHint: View {
    let chat: SessionChat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What should we build?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.text)
            if let ws = chat.workspace {
                let repo = chat.server.repositories[ws.repositoryID]?.title
                Text(verbatim: [repo, ws.branch].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the agent is doing right now: elapsed time, status line, running subagents.
private struct LiveStrip: View {
    let chat: SessionChat

    private var statusText: String {
        if chat.queuedPrompt != nil { return chat.workspace?.stateLabel ?? "Setting up…" }
        return chat.status ?? (chat.pendingApprovals.isEmpty ? "Working…" : "Waiting for you")
    }

    var body: some View {
        if chat.isRunning || !chat.runningTasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if chat.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(statusText).lineLimit(1)
                        Spacer()
                        if let start = chat.turnStartedAt {
                            Text(start, style: .timer).monospacedDigit()
                        }
                    }
                }
                ForEach(chat.runningTasks) { task in
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").foregroundStyle(Palette.warning)
                        Text(task.description).lineLimit(1)
                        if let a = task.activity { Text("· \(a)").foregroundStyle(Palette.text3).lineLimit(1) }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Composer

/// The Mac composer on a phone: the prompt on top; permissions, model, thinking and send underneath.
private struct Composer: View {
    @Bindable var chat: SessionChat
    var focused: FocusState<Bool>.Binding
    let switchProvider: (ProviderKind, String) -> Void

    private var isEmpty: Bool { chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(chat.isRunning ? "Steer or queue a follow-up" : "Prompt", text: $chat.draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(focused)
                .foregroundStyle(Palette.text)
                .padding(.top, 4)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(spacing: 2) {
                PermissionMenu(chat: chat)
                Spacer(minLength: 6)
                ModelMenu(chat: chat, switchProvider: switchProvider)
                EffortMenu(chat: chat)
                sendButton.padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var sendButton: some View {
        let stop = chat.isRunning && isEmpty
        let disabled = !stop && (isEmpty || chat.queuedPrompt != nil)
        return Button {
            if stop { chat.interrupt() } else { chat.send() }
        } label: {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(.system(size: stop ? 12 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.userBubble))
                .opacity(disabled ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(stop ? "Stop" : "Send")
    }
}

private struct ComposerChip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
    }
}

private struct ChipChevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.text3)
    }
}

@ViewBuilder
private func checked(_ on: Bool, _ title: String) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}

private struct PermissionMenu: View {
    let chat: SessionChat

    private var current: AgentPermissionMode { AgentPermissionMode(proto: chat.session?.permissionMode ?? .bypass) }

    var body: some View {
        Menu {
            ForEach(AgentPermissionMode.allCases, id: \.self) { m in
                Button { chat.update(permission: m) } label: { checked(current == m, m.displayName) }
            }
        } label: {
            ComposerChip {
                Image(systemName: symbol(current))
                    .foregroundStyle(current == .bypass ? Palette.warning : Palette.text2)
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Permissions: \(current.displayName)")
    }

    private func symbol(_ m: AgentPermissionMode) -> String {
        switch m {
        case .bypass: "exclamationmark.circle"
        case .auto: "wand.and.stars"
        case .ask: "hand.raised"
        }
    }
}

/// Model, grouped by agent. Like the Mac, the agent can only change before the first message.
private struct ModelMenu: View {
    let chat: SessionChat
    let switchProvider: (ProviderKind, String) -> Void

    private var providers: [ProviderKind] {
        chat.items.isEmpty && chat.queuedPrompt == nil ? chat.server.providers : [chat.provider]
    }

    var body: some View {
        Menu {
            ForEach(providers) { p in
                Section(p.displayName) {
                    ForEach(chat.server.models[p] ?? []) { m in
                        Button {
                            if p == chat.provider { chat.update(model: m.id) } else { switchProvider(p, m.id) }
                        } label: {
                            checked(p == chat.provider && m.id == chat.currentModel?.id, m.displayName)
                        }
                    }
                }
            }
        } label: {
            ComposerChip {
                ProviderBadge(provider: chat.provider, size: 10)
                Text(chat.currentModel?.displayName ?? "Default").foregroundStyle(Palette.text)
                ChipChevron()
            }
        }
        .menuOrder(.fixed)
        .task {
            for p in chat.server.providers { await chat.server.loadModels(p) }
        }
        .accessibilityLabel("Model")
    }
}

/// Thinking level for the chosen model (hidden when the model doesn't support it).
private struct EffortMenu: View {
    let chat: SessionChat

    var body: some View {
        if let model = chat.currentModel, !model.efforts.isEmpty {
            let effort = chat.session?.effort ?? ""
            let current = effort.isEmpty ? model.defaultEffort : effort
            Menu {
                Section("Thinking") {
                    ForEach(model.efforts, id: \.self) { e in
                        Button { chat.update(effort: e) } label: {
                            checked(current == e, Self.label(e) + (e == model.defaultEffort ? "  (default)" : ""))
                        }
                    }
                }
            } label: {
                ComposerChip {
                    Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(Palette.text3)
                    Text(current.map(Self.label) ?? "Default").foregroundStyle(Palette.text2)
                    ChipChevron()
                }
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Thinking level")
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

extension ModelOption: @retroactive Identifiable {}

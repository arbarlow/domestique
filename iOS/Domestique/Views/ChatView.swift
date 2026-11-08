import AgentKit
import DQCore
import ServerKit
import SwiftUI

/// One session: the transcript, live status, and the composer.
struct ChatView: View {
    @Bindable var chat: SessionChat
    let canWrite: Bool
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !chat.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if chat.items.isEmpty {
                    Text("Send a message to start.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                if let err = chat.loadError {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(chat.items) { item in
                    TranscriptRow(item: item, chat: chat, canWrite: canWrite)
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
                if canWrite { Composer(chat: chat, focused: $composerFocused) }
            }
        }
    }
}

/// What the agent is doing right now: elapsed time, status line, running subagents.
private struct LiveStrip: View {
    let chat: SessionChat

    var body: some View {
        if chat.isRunning || !chat.runningTasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if chat.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(chat.status ?? (chat.pendingApprovals.isEmpty ? "Working…" : "Waiting for you"))
                            .lineLimit(1)
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
                        if let a = task.activity { Text("· \(a)").foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Composer: View {
    @Bindable var chat: SessionChat
    var focused: FocusState<Bool>.Binding

    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            SessionOptionsMenu(chat: chat)
            TextField(chat.isRunning ? "Steer or queue a follow-up" : "Message \(chat.provider.displayName)",
                      text: $chat.draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            if chat.isRunning && !canSend {
                Button {
                    chat.interrupt()
                } label: {
                    Image(systemName: "stop.fill").font(.body.weight(.bold)).frame(width: 38, height: 38)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel("Stop")
            } else {
                Button {
                    chat.send()
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 38, height: 38)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// Model, effort and permission mode for this session.
private struct SessionOptionsMenu: View {
    let chat: SessionChat

    private var models: [ModelOption] { chat.server.models[chat.provider] ?? [] }
    private var session: Proto_Session? { chat.session }
    private var currentModel: ModelOption? {
        models.first { $0.id == session?.model } ?? models.first(where: \.isDefault)
    }

    var body: some View {
        Menu {
            if !models.isEmpty {
                Picker("Model", selection: Binding(get: { session?.model ?? "" }, set: { chat.update(model: $0) })) {
                    ForEach(models) { m in Text(m.displayName).tag(m.id) }
                }
                .pickerStyle(.menu)
            }
            if let efforts = currentModel?.efforts, !efforts.isEmpty {
                Picker("Effort", selection: Binding(get: { session?.effort ?? "" }, set: { chat.update(effort: $0) })) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Picker("Permissions", selection: Binding(
                get: { AgentPermissionMode(proto: session?.permissionMode ?? .bypass) },
                set: { chat.update(permission: $0) })
            ) {
                ForEach(AgentPermissionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            ProviderBadge(provider: chat.provider, size: 16)
                .frame(width: 38, height: 38)
                .glassEffect(.regular, in: .circle)
        }
        .task { await chat.server.loadModels(chat.provider) }
        .accessibilityLabel("Agent options")
    }
}

extension ModelOption: @retroactive Identifiable {}

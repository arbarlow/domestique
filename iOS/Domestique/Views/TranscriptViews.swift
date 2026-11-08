import DQCore
import ServerKit
import SwiftUI

struct TranscriptRow: View {
    let item: TranscriptItem
    let chat: SessionChat
    let canWrite: Bool

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text)
        case .assistant(let text):
            MarkdownView(text: text)
        case .reasoning(let text):
            ReasoningRow(text: text)
        case .tool(let call):
            ToolRow(call: call)
        case .approval(let req):
            ApprovalCard(request: req, chat: chat, canWrite: canWrite)
        case .notice(let text):
            Label(text, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Palette.removed)
                .textSelection(.enabled)
        case .turnSummary(let s):
            TurnSummaryRow(summary: s)
        case .trigger(let text):
            Label(text, systemImage: "bolt.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 18))
                .textSelection(.enabled)
        }
    }
}

private struct ReasoningRow: View {
    let text: String
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.footnote)
                .foregroundStyle(Palette.toolThought)
        }
    }
}

struct ToolRow: View {
    let call: ToolCall
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.description ?? call.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                        if !call.summary.isEmpty {
                            Text(call.summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(open ? nil : 1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    statusIcon
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(call.fileChanges, id: \.path) { change in
                    PatchView(path: change.path, patch: change.diff)
                }
                if call.fileChanges.isEmpty, !call.input.isEmpty, call.input != call.summary {
                    CodeBlock(language: "", code: String(call.input.prefix(4000)))
                }
                if !call.output.isEmpty {
                    CodeBlock(language: "", code: String(call.output.suffix(8000)))
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var statusIcon: some View {
        switch call.status {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.removed)
        case .declined: Image(systemName: "nosign").foregroundStyle(.secondary)
        case .completed: EmptyView()
        }
    }

    private var icon: String {
        switch call.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebSearch", "WebFetch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    private var tint: Color {
        switch call.name {
        case "Bash": Palette.running
        case "Read": Palette.toolRead
        case "Edit", "MultiEdit", "Write": Palette.added
        case "Grep", "Glob": Palette.toolSearch
        case "WebSearch", "WebFetch": Palette.toolWeb
        case "Task", "Agent": Palette.warning
        default: .secondary
        }
    }
}

private struct TurnSummaryRow: View {
    let summary: TurnSummary

    var body: some View {
        let parts = [
            summary.durationMs.map { Duration.milliseconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)) },
        ].compactMap { $0 }
        HStack(spacing: 6) {
            Rectangle().fill(.quaternary).frame(height: 0.5)
            if summary.isError {
                Text(summary.message ?? "Turn failed").foregroundStyle(Palette.removed)
            } else if !parts.isEmpty {
                Text("Worked for " + parts.joined(separator: " · ")).fixedSize()
            }
            Rectangle().fill(.quaternary).frame(height: 0.5)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Approvals and questions

struct ApprovalCard: View {
    let request: ApprovalRequest
    let chat: SessionChat
    let canWrite: Bool
    @State private var denyReason = ""
    @State private var showDeny = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: request.isQuestion ? "questionmark.bubble.fill" : "hand.raised.fill")
                    .foregroundStyle(pending ? Palette.warning : .secondary)
                Text(request.title).font(.subheadline.weight(.semibold))
            }
            if request.isQuestion {
                QuestionForm(request: request, enabled: pending && canWrite) { answers in
                    chat.answer(request.requestID, answers)
                }
            } else {
                if !request.detail.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(request.detail)
                            .font(.caption.monospaced())
                            .fixedSize()
                    }
                    .frame(maxHeight: 220)
                }
                if pending && canWrite {
                    HStack(spacing: 8) {
                        Button("Approve") { chat.respond(request.requestID, .approve) }
                            .buttonStyle(.glassProminent)
                        Button("Always") { chat.respond(request.requestID, .approveForSession) }
                            .buttonStyle(.glass)
                        Spacer()
                        Button("Deny", role: .destructive) { showDeny = true }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.regular)
                }
            }
            if !pending {
                Text(resolutionLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if pending { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.warning.opacity(0.6), lineWidth: 1) }
        }
        .alert("Deny", isPresented: $showDeny) {
            TextField("Tell the agent why (optional)", text: $denyReason)
            Button("Deny", role: .destructive) {
                chat.respond(request.requestID, .deny(message: denyReason.isEmpty ? nil : denyReason))
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var pending: Bool { request.resolution == .pending }

    private var resolutionLabel: String {
        switch request.resolution {
        case .approved: "Approved"
        case .approvedForSession: "Approved for this session"
        case .denied: "Denied"
        case .answered: request.answers.values.joined(separator: ", ").isEmpty ? "Answered" : "Answered: " + request.answers.values.joined(separator: ", ")
        case .cancelled: "Cancelled"
        case .pending: ""
        }
    }
}

private struct QuestionForm: View {
    let request: ApprovalRequest
    let enabled: Bool
    let submit: ([String: String]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(request.questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    if !q.header.isEmpty {
                        Text(q.header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(q.question).font(.subheadline)
                    ForEach(q.options, id: \.label) { opt in
                        Button {
                            toggle(q, opt.label)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: isPicked(q, opt.label)
                                      ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                      : (q.multiSelect ? "square" : "circle"))
                                    .foregroundStyle(isPicked(q, opt.label) ? Palette.text : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(opt.label).foregroundStyle(.primary)
                                    if let d = opt.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Other…", text: Binding(get: { other[q.id] ?? "" }, set: { other[q.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                }
            }
            if enabled {
                Button("Submit", action: send)
                    .buttonStyle(.glassProminent)
                    .disabled(!complete)
            }
        }
        .disabled(!enabled)
    }

    private func isPicked(_ q: AgentQuestion, _ label: String) -> Bool { picked[q.id]?.contains(label) ?? false }

    private func toggle(_ q: AgentQuestion, _ label: String) {
        var set = picked[q.id] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
            other[q.id] = ""
        }
        picked[q.id] = set
    }

    private func answer(_ q: AgentQuestion) -> String {
        let typed = (other[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = q.options.map(\.label).filter { picked[q.id]?.contains($0) ?? false }
        return (chosen + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }

    private var complete: Bool { request.questions.allSatisfy { !answer($0).isEmpty } }

    private func send() {
        submit(Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, answer($0)) }))
    }
}

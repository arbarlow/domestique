import DQCore
import GitKit
import SwiftUI

// MARK: - Turn grouping

/// A user message and everything the agent did in response. The work (tools, thinking, commentary)
/// collapses behind "Worked for 12s"; the final answer and an edited-files card stay visible.
struct Turn: Identifiable {
    let id: String
    var user: TranscriptItem?
    /// Why the agent started this turn on its own (no user message).
    var triggers: [String] = []
    var work: [TranscriptItem] = []
    /// Subagents spawned this turn: always visible as cards, never folded into "Worked for".
    var agents: [TranscriptItem] = []
    var answer: TranscriptItem?
    /// Items that must never hide inside the collapsed work (pending approvals, errors).
    var pinned: [TranscriptItem] = []
    var summary: TurnSummary?
    var finished: Bool { summary != nil }

    static func build(_ items: [TranscriptItem], running: Bool) -> [Turn] {
        var turns: [Turn] = []
        var current = Turn(id: "start")
        func flush() {
            if current.user != nil || !current.triggers.isEmpty || !current.work.isEmpty || !current.agents.isEmpty
                || current.summary != nil || !current.pinned.isEmpty
            {
                // The last agent message is the answer; earlier ones are commentary.
                if let i = current.work.lastIndex(where: { if case .assistant = $0.kind { true } else { false } }),
                    current.finished || i == current.work.count - 1
                {
                    current.answer = current.work.remove(at: i)
                }
                turns.append(current)
            }
        }
        for item in items {
            switch item.kind {
            case .user:
                flush()
                current = Turn(id: item.id, user: item)
            case .trigger(let text):
                // Several notifications before the agent responds read as one automatic turn.
                if current.user == nil && current.work.isEmpty && current.agents.isEmpty && current.summary == nil {
                    current.triggers.append(text)
                } else {
                    flush()
                    current = Turn(id: item.id, triggers: [text])
                }
            case .tool(let call) where call.name == "Agent":
                current.agents.append(item)
            case .turnSummary(let s):
                current.summary = s
                flush()
                current = Turn(id: "after-\(item.id)")
            case .approval(let r) where r.resolution == .pending:
                current.pinned.append(item)
            case .error:
                current.pinned.append(item)
            default:
                current.work.append(item)
            }
        }
        flush()
        // Old transcripts interrupted mid-turn have no summary: treat everything but the last as finished.
        if !running, var last = turns.popLast() {
            if last.summary == nil && (last.answer != nil || !last.work.isEmpty) { last.summary = TurnSummary() }
            turns.append(last)
        }
        return turns
    }

    /// Summary-only turns (nothing said, nothing done) render nothing.
    var hasContent: Bool {
        user != nil || !triggers.isEmpty || !work.isEmpty || !agents.isEmpty || answer != nil || !pinned.isEmpty
    }

    var fileChanges: [FileChange] {
        work.flatMap { item -> [FileChange] in
            if case .tool(let call) = item.kind { return call.fileChanges }
            return []
        }
    }

    var toolCount: Int {
        work.reduce(0) { n, item in
            if case .tool = item.kind { return n + 1 }
            return n
        }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let chat: ChatModel
    @State private var selection = TranscriptSelection()

    var body: some View {
        let turns = Turn.build(chat.items, running: chat.isRunning).filter(\.hasContent)
        let _ = selection.turns = turns
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if chat.items.isEmpty {
                    EmptyChatHint(chat: chat)
                }
                ForEach(Array(turns.enumerated()), id: \.element.id) { idx, turn in
                    // A finished turn is never live: after a send, isRunning flips before the server echoes
                    // the new message, and treating the old turn as live would briefly expand its whole work
                    // log. That height spike leaves the bottom-anchored lazy stack showing blank space.
                    TurnView(
                        turn: turn, chat: chat,
                        isLive: chat.isRunning && idx == turns.count - 1 && !turn.finished)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollContentBackground(.hidden)
        .environment(\.transcriptSelection, selection)
        .onAppear { selection.start() }
        .onDisappear { selection.stop() }
    }
}

private struct TurnView: View {
    let turn: Turn
    let chat: ChatModel
    let isLive: Bool
    @State private var expanded = false

    private var basePath: String? { chat.workspace.workspace?.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let user = turn.user, case .user(let text) = user.kind {
                UserBubble(id: user.id, text: text, date: user.timestamp)
            } else if !turn.triggers.isEmpty {
                TriggerPill(texts: turn.triggers)
            }

            if isLive {
                // While working, show the steps as they happen.
                if !turn.work.isEmpty {
                    WorkLog(items: turn.work, chat: chat, basePath: basePath)
                }
            } else if !turn.work.isEmpty {
                WorkedForLine(summary: turn.summary, steps: turn.toolCount, expanded: $expanded)
                if expanded {
                    WorkLog(items: turn.work, chat: chat, basePath: basePath)
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
            }

            ForEach(turn.agents) { item in
                if case .tool(let call) = item.kind {
                    AgentCard(call: call, task: chat.task(forToolUse: item.id), basePath: basePath)
                }
            }

            ForEach(turn.pinned) { item in
                PinnedItemView(item: item, chat: chat)
            }

            if let answer = turn.answer, case .assistant(let text) = answer.kind, !text.isEmpty {
                MarkdownView(text: text, spanID: answer.id)
            }

            if isLive {
                WorkingIndicator(status: chat.status, since: chat.turnStartedAt)
            }

            if turn.finished {
                let changes = EditedFile.aggregate(turn.fileChanges, basePath: basePath)
                if !changes.isEmpty {
                    EditedFilesCard(files: changes, model: chat.workspace)
                }
                TurnFooter(turn: turn)
            }
        }
        .animation(.snappy(duration: 0.18), value: expanded)
    }
}

// MARK: - Pieces

private struct UserBubble: View {
    let id: String
    let text: String
    let date: Date
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            SpanText(
                id: id,
                text: SpanStyle.attributed(
                    AttributedString(text), font: .systemFont(ofSize: 13.5), color: NSColor(Theme.userBubbleText), lineSpacing: 3)
            )
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 6) {
                Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                IconButton(symbol: "doc.on.doc", help: "Copy", size: 11) { copy(text) }
            }
            .opacity(hovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
        .onHover { hovering = $0 }
    }
}

private struct WorkedForLine: View {
    let summary: TurnSummary?
    let steps: Int
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text(label)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(Theme.ui)
                .foregroundStyle(hovering ? Theme.text : Theme.text2)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var label: String {
        var s = "Worked"
        if let ms = summary?.durationMs { s += " for \(formatDuration(ms))" }
        if steps > 0 { s += " · \(steps) step\(steps == 1 ? "" : "s")" }
        return s
    }
}

/// The detailed steps of a turn: tool calls as compact lines, thinking, commentary.
private struct WorkLog: View {
    let items: [TranscriptItem]
    let chat: ChatModel
    let basePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                switch item.kind {
                case .tool(let call):
                    ToolLine(call: call, basePath: basePath, model: chat.workspace)
                case .reasoning(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ReasoningLine(text: text) }
                case .assistant(let text):
                    if !text.isEmpty {
                        MarkdownView(text: text, compact: true)
                            .foregroundStyle(Theme.text2)
                    }
                case .approval(let req):
                    ApprovalCard(request: req, chat: chat)
                case .notice(let text):
                    Label(text, systemImage: "info.circle").font(Theme.small).foregroundStyle(Theme.text3)
                default:
                    EmptyView()
                }
            }
        }
    }
}

private struct PinnedItemView: View {
    let item: TranscriptItem
    let chat: ChatModel

    var body: some View {
        switch item.kind {
        case .approval(let req):
            ApprovalCard(request: req, chat: chat)
        case .error(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.removed)
                Text(text).font(Theme.ui).foregroundStyle(Theme.text).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.removedBG, in: RoundedRectangle(cornerRadius: 10))
        default:
            EmptyView()
        }
    }
}

/// One tool call as a single quiet line ("Ran npm test", "Edited row.tsx +12 −3"), expandable.
struct ToolLine: View {
    let call: ToolCall
    var basePath: String?
    var model: WorkspaceModel?
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    icon.frame(width: 14)
                    if let description {
                        // The agent said what it's doing: lead with that, the command trails as a quiet chip.
                        Text(description)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                    } else {
                        Text(verb).foregroundStyle(Theme.text2)
                    }
                    if isCommand {
                        Text(detail)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        Text(detail)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let stat = diffStat {
                        DiffCount(additions: stat.0, deletions: stat.1)
                    }
                    Spacer(minLength: 0)
                    if hovering {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(Theme.ui)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded { ToolDetail(call: call, basePath: basePath) }
        }
    }

    private var isCommand: Bool { call.name == "Bash" }

    private var description: String? {
        guard let d = call.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        return d
    }

    private var verb: String {
        let running = call.status == .running
        switch call.name {
        case "Bash": return running ? "Running" : "Ran"
        case "Read": return running ? "Reading" : "Read"
        case "Edit", "MultiEdit", "NotebookEdit": return running ? "Editing" : "Edited"
        case "Write": return running ? "Writing" : "Wrote"
        case "Grep", "Glob": return running ? "Searching" : "Searched"
        case "WebSearch": return "Searched the web"
        case "WebFetch": return "Fetched"
        case "Agent": return "Delegated"
        case "Todos": return "Updated todos"
        case "MCP": return "Called"
        case "Skill": return "Used skill"
        default: return call.name
        }
    }

    private var detail: String {
        if call.name == "Todos" {
            let lines = call.summary.split(separator: "\n")
            let done = lines.filter { $0.hasPrefix("✓") }.count
            return "\(done)/\(lines.count) done"
        }
        return relativize(call.summary.split(separator: "\n").first.map(String.init) ?? "", basePath: basePath)
    }

    private var diffStat: (Int, Int)? {
        guard !call.fileChanges.isEmpty else { return nil }
        return call.fileChanges.reduce((0, 0)) { acc, c in
            let s = EditedFile.count(c.diff)
            return (acc.0 + s.0, acc.1 + s.1)
        }
    }

    @ViewBuilder private var icon: some View {
        switch call.status {
        case .running: Spinner(size: 10)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(Theme.removed).font(.system(size: 11))
        case .declined: Image(systemName: "nosign").foregroundStyle(Theme.warning).font(.system(size: 11))
        case .completed: Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 11))
        }
    }

    private var tint: Color {
        switch call.name {
        case "Bash": Theme.toolCommand
        case "Read": Theme.toolRead
        case "Edit", "Write", "MultiEdit", "NotebookEdit": Theme.toolEdit
        case "Grep", "Glob": Theme.toolSearch
        case "WebFetch", "WebSearch": Theme.toolWeb
        case "Agent": Theme.toolAgent
        default: Theme.text3
        }
    }

    private var symbol: String {
        switch call.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write", "MultiEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent": "person.2"
        case "Todos": "checklist"
        case "MCP": "puzzlepiece.extension"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct ToolDetail: View {
    let call: ToolCall
    let basePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if call.name == "Todos" {
                Text(call.summary).font(Theme.ui).padding(12)
            } else if !call.fileChanges.isEmpty {
                ForEach(call.fileChanges, id: \.path) { change in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(relativize(change.path, basePath: basePath))
                            .font(Theme.smallMedium)
                            .foregroundStyle(Theme.text2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        Hairline()
                        CompactDiff(diff: change.diff)
                    }
                }
            } else {
                if !call.input.isEmpty, call.name != "Read" {
                    Text(call.input)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .lineLimit(30)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !call.output.isEmpty {
                    Hairline()
                    ScrollView {
                        Text(call.output.count > 20_000 ? String(call.output.suffix(20_000)) : call.output)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
        .background(Theme.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }
}

/// Unified diff hunk text rendered with line tints.
struct CompactDiff: View {
    let diff: String

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(400)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(Theme.monoSmall)
                        .foregroundStyle(line.hasPrefix("@@") ? Theme.text3 : Theme.text)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? Theme.addedBG : line.hasPrefix("-") ? Theme.removedBG : .clear)
                }
            }
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxHeight: 340)
    }
}

private struct ReasoningLine: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(Theme.toolThought)
                        .frame(width: 14)
                    Text("Thought").foregroundStyle(Theme.text2)
                    if !expanded {
                        Text(text.replacingOccurrences(of: "\n", with: " "))
                            .font(Theme.small)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.toolThought.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .font(Theme.ui)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(Theme.ui)
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.leading, 21)
            }
        }
    }
}

// MARK: - Edited files card (Codex)

struct EditedFile: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var additions: Int
    var deletions: Int

    static func count(_ diff: String) -> (Int, Int) {
        var a = 0
        var d = 0
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { a += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { d += 1 }
        }
        return (a, d)
    }

    static func aggregate(_ changes: [FileChange], basePath: String?) -> [EditedFile] {
        var order: [String] = []
        var map: [String: EditedFile] = [:]
        for c in changes {
            let path = relativize(c.path, basePath: basePath)
            let (a, d) = count(c.diff)
            if map[path] == nil {
                order.append(path)
                map[path] = EditedFile(path: path, additions: 0, deletions: 0)
            }
            map[path]!.additions += a
            map[path]!.deletions += d
        }
        return order.compactMap { map[$0] }
    }
}

private struct EditedFilesCard: View {
    let files: [EditedFile]
    let model: WorkspaceModel

    var body: some View {
        let add = files.reduce(0) { $0 + $1.additions }
        let del = files.reduce(0) { $0 + $1.deletions }
        HStack(spacing: 12) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 1) {
                Text("Edited \(files.count) file\(files.count == 1 ? "" : "s")").font(Theme.uiMedium)
                DiffCount(additions: add, deletions: del)
            }
            Spacer()
            Button("View changes") { model.showChanges() }
                .buttonStyle(.soft)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// Only speaks up when a turn ended abnormally ("Interrupted", an error). No copy / cost chrome:
/// the text is selectable like any other Mac text.
private struct TurnFooter: View {
    let turn: Turn

    var body: some View {
        if let s = turn.summary, let message = s.message {
            Text(message)
                .font(Theme.small)
                .foregroundStyle(s.isError ? Theme.removed : Theme.text3)
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(.top, -4)
        }
    }
}

// MARK: - Approvals & questions

struct ApprovalCard: View {
    let request: ApprovalRequest
    let chat: ChatModel
    @State private var answers: [String: String] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        let pending = request.resolution == .pending
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: request.isQuestion ? "questionmark.bubble" : "hand.raised")
                    .foregroundStyle(Theme.warning)
                Text(request.title).font(Theme.uiMedium)
                Spacer()
                if !pending {
                    Text(resolutionText).font(Theme.small).foregroundStyle(Theme.text3)
                }
            }
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8))
            }
            if request.isQuestion {
                ForEach(request.questions) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q.question).font(Theme.ui)
                        FlowLayout(spacing: 6) {
                            ForEach(q.options, id: \.label) { o in
                                let selected = (answers[q.id] ?? request.answers[q.id]) == o.label
                                Button(o.label) { answers[q.id] = o.label }
                                    .buttonStyle(SoftButtonStyle(prominent: selected, compact: true))
                                    .help(o.description ?? "")
                            }
                        }
                        .disabled(!pending)
                        if pending {
                            TextField("Something else…", text: Binding(
                                get: { custom[q.id] ?? "" },
                                set: {
                                    custom[q.id] = $0
                                    answers[q.id] = $0
                                }
                            ))
                            .textFieldStyle(.plain)
                            .font(Theme.ui)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                if pending {
                    HStack {
                        Button("Submit") { chat.answer(request, answers: answers) }
                            .buttonStyle(.softProminent)
                            .disabled(answers.count < request.questions.count)
                        Button("Skip") { chat.respond(request, decision: .deny(message: "The user skipped the question.")) }
                            .buttonStyle(.soft)
                    }
                }
            } else if pending {
                HStack(spacing: 8) {
                    Button("Allow") { chat.respond(request, decision: .approve) }
                        .buttonStyle(.softProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Allow for session") { chat.respond(request, decision: .approveForSession) }
                        .buttonStyle(.soft)
                    Button("Deny") { chat.respond(request, decision: .deny(message: nil)) }
                        .buttonStyle(.soft)
                }
            }
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(pending ? Theme.warning.opacity(0.55) : Theme.border, lineWidth: pending ? 1 : 0.5))
    }

    private var resolutionText: String {
        switch request.resolution {
        case .pending: ""
        case .approved: "Allowed"
        case .approvedForSession: "Allowed for session"
        case .denied: "Denied"
        case .answered: "Answered"
        case .cancelled: "Cancelled"
        }
    }
}

/// Wrapping HStack for option chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Helpers

func formatDuration(_ ms: Int) -> String {
    let s = ms / 1000
    if s < 60 { return "\(max(1, s))s" }
    return "\(s / 60)m \(s % 60)s"
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Paths inside the worktree shown relative to it (handles /tmp vs /private/tmp).
func relativize(_ path: String, basePath: String?) -> String {
    guard let base = basePath else { return path }
    var out = path
    for prefix in [base + "/", "/private" + base + "/", base.replacingOccurrences(of: "/private/", with: "/") + "/"] {
        out = out.replacingOccurrences(of: prefix, with: "")
    }
    return out
}

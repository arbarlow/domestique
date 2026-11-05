import AgentKit
import DQCore
import SwiftUI

// MARK: - Inline card (in the transcript)

/// A subagent spawned by the Agent tool: live status, what it's doing, and what it returned.
struct AgentCard: View {
    let call: ToolCall
    let task: AgentTask?
    var basePath: String?
    @State private var expanded = false
    @State private var showPrompt = false

    private var status: AgentTask.Status {
        if let task { return task.status }
        switch call.status {
        case .running: return .running
        case .failed: return .failed
        case .declined: return .stopped
        case .completed: return .completed
        }
    }

    private var title: String { task?.description ?? call.summary }
    private var result: String? {
        if let s = task?.summary, !s.isEmpty { return s }
        if let o = task?.output, !o.isEmpty { return o }
        // Background launches return a bookkeeping line, not a result.
        if call.output.hasPrefix("Async agent launched") { return nil }
        return call.output.isEmpty ? nil : call.output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    AgentStatusIcon(status: status)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(Theme.uiMedium).foregroundStyle(Theme.text).lineLimit(1)
                            if let type = task?.subagentType, type != "general-purpose" {
                                Text(type).font(Theme.tiny).foregroundStyle(Theme.text2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.hover, in: Capsule())
                            }
                            if task?.isBackground == true {
                                Text("background").font(Theme.tiny).foregroundStyle(Theme.text3)
                            }
                        }
                        if status == .running, let activity = task?.activity ?? task?.steps.last.map({ "\($0.name) \($0.summary)" }) {
                            Text(activity).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                        } else if status != .running, let result {
                            Text(result.replacingOccurrences(of: "\n", with: " "))
                                .font(Theme.small).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    AgentMeta(task: task)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Hairline()
                VStack(alignment: .leading, spacing: 12) {
                    if let prompt = task?.prompt ?? promptFromInput, !prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                showPrompt.toggle()
                            } label: {
                                Label(showPrompt ? "Hide prompt" : "Show prompt", systemImage: "text.quote")
                                    .font(Theme.small).foregroundStyle(Theme.text2)
                            }
                            .buttonStyle(.plain)
                            if showPrompt {
                                Text(prompt).font(Theme.small).foregroundStyle(Theme.text2).textSelection(.enabled)
                            }
                        }
                    }
                    if let steps = task?.steps, !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(steps.suffix(12).enumerated()), id: \.offset) { _, step in
                                HStack(spacing: 6) {
                                    Text(step.name).font(Theme.small).foregroundStyle(Theme.text2)
                                    Text(relativize(step.summary.split(separator: "\n").first.map(String.init) ?? "", basePath: basePath))
                                        .font(Theme.monoSmall).foregroundStyle(Theme.text)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            if steps.count > 12 {
                                Text("+ \(steps.count - 12) earlier steps").font(Theme.tiny).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                    if let result {
                        MarkdownView(text: result, compact: true)
                    } else if status == .running {
                        Text("Working…").font(Theme.small).foregroundStyle(Theme.text3)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(status == .running ? Theme.running.opacity(0.35) : Theme.border, lineWidth: status == .running ? 1 : 0.5))
    }

    private var promptFromInput: String? {
        (try? JSONValue.parse(call.input))?["prompt"]?.string
    }
}

struct AgentStatusIcon: View {
    let status: AgentTask.Status
    var body: some View {
        Group {
            switch status {
            case .running: Spinner(size: 13)
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.added)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.removed)
            case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(Theme.text3)
            }
        }
        .font(.system(size: 14))
        .frame(width: 18, height: 18)
    }
}

/// "1m 12s · 14 tools" — live while running.
struct AgentMeta: View {
    let task: AgentTask?
    var body: some View {
        if let task {
            Group {
                if task.isRunning {
                    TimelineView(.periodic(from: task.startedAt, by: 1)) { ctx in
                        Text(label(until: ctx.date))
                    }
                } else {
                    Text(label(until: task.endedAt ?? .now))
                }
            }
            .font(Theme.small.monospacedDigit())
            .foregroundStyle(Theme.text3)
        }
    }

    private func label(until end: Date) -> String {
        let task = task!
        var parts = [formatDuration(Int(end.timeIntervalSince(task.startedAt) * 1000))]
        if task.toolUses > 0 { parts.append("\(task.toolUses) tool\(task.toolUses == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// A turn the agent started by itself, e.g. after a background subagent finished.
struct TriggerPill: View {
    let texts: [String]
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
            Text(texts.joined(separator: " · ")).lineLimit(2)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.hover, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }
}

// MARK: - Tray (above the composer)

/// Every subagent in this chat at a glance; persists while any is running, finished ones until dismissed.
struct AgentsTray: View {
    let chat: ChatModel
    @State private var showList = false

    var body: some View {
        let tasks = chat.trayTasks
        // One subagent is already obvious from its card in the chat; the tray is for juggling several.
        if tasks.count > 1 {
            let running = tasks.filter(\.isRunning).count
            HStack(spacing: 8) {
                Button {
                    showList.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if running > 0 { Spinner(size: 10) } else { Image(systemName: "checkmark.circle").foregroundStyle(Theme.added) }
                        Text(summary(tasks)).font(Theme.smallMedium).foregroundStyle(Theme.text)
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.text3)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showList, arrowEdge: .top) {
                    AgentsList(chat: chat)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tasks) { task in
                            AgentChip(task: task) { showList = true }
                        }
                    }
                }
                if running < tasks.count {
                    IconButton(symbol: "xmark", help: "Clear finished agents", size: 9) {
                        chat.clearFinishedFromTray()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
            .padding(.horizontal, 28)
            .frame(maxWidth: Theme.contentWidth)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func summary(_ tasks: [AgentTask]) -> String {
        let running = tasks.filter(\.isRunning).count
        let done = tasks.count - running
        switch (running, done) {
        case (0, _): return "\(done) agent\(done == 1 ? "" : "s") done"
        case (_, 0): return "\(running) agent\(running == 1 ? "" : "s") running"
        default: return "\(running) running · \(done) done"
        }
    }
}

private struct AgentChip: View {
    let task: AgentTask
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                AgentStatusIcon(status: task.status).scaleEffect(0.8).frame(width: 14, height: 14)
                Text(task.description).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Theme.hover, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(task.activity ?? task.description)
    }
}

/// Popover list with every subagent in the chat.
private struct AgentsList: View {
    let chat: ChatModel

    var body: some View {
        let all = chat.taskOrder.compactMap { chat.tasks[$0] }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents").font(Theme.uiMedium)
                Spacer()
                Text("\(all.filter(\.isRunning).count) running").font(Theme.small).foregroundStyle(Theme.text3)
            }
            .padding(12)
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(all.reversed()) { task in
                        HStack(alignment: .top, spacing: 10) {
                            AgentStatusIcon(status: task.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.description).font(Theme.ui).foregroundStyle(Theme.text)
                                if let line = task.isRunning ? task.activity : (task.summary ?? (task.output.isEmpty ? nil : task.output)) {
                                    Text(line.replacingOccurrences(of: "\n", with: " "))
                                        .font(Theme.small).foregroundStyle(Theme.text2).lineLimit(3)
                                }
                                AgentMeta(task: task)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        Hairline().padding(.leading, 40)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 380)
    }
}

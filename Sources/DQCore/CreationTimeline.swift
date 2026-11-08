import Foundation

/// The ordered stages of creating a workspace and when each ran, so the UI can show progress and
/// where the time went. Starting a stage ends the one before it.
public struct CreationTimeline: Sendable, Equatable {
    public struct Stage: Sendable, Equatable, Identifiable {
        public enum Status: Sendable, Equatable { case pending, running, done, failed }

        public let id: String
        public var title: String
        public var detail: String?
        public var startedAt: Date?
        public var finishedAt: Date?
        public var failed = false

        public var status: Status {
            if failed { return .failed }
            if finishedAt != nil { return .done }
            return startedAt == nil ? .pending : .running
        }

        /// How long it took, or has taken so far; nil until it starts.
        public func duration(now: Date = .now) -> TimeInterval? {
            startedAt.map { (finishedAt ?? now).timeIntervalSince($0) }
        }
    }

    public private(set) var stages: [Stage]

    public init(stages: [(id: String, title: String)]) {
        self.stages = stages.map { Stage(id: $0.id, title: $0.title) }
    }

    public var current: Stage? { stages.first { $0.status == .running } }
    public var hasFailed: Bool { stages.contains { $0.failed } }

    /// The longest stage that has finished.
    public var slowest: Stage? {
        stages.filter { $0.finishedAt != nil }.max { ($0.duration() ?? 0) < ($1.duration() ?? 0) }
    }

    /// From the first stage's start to the last one's end (or `now`, while one is still running).
    public func total(now: Date = .now) -> TimeInterval? {
        guard let start = stages.compactMap(\.startedAt).min() else { return nil }
        let end = current == nil ? stages.compactMap(\.finishedAt).max() ?? now : now
        return end.timeIntervalSince(start)
    }

    /// Ends the running stage and starts `id`. Planned stages before `id` that never started turned
    /// out not to be needed, so they're dropped. Does nothing if `id` is unknown or already started.
    public mutating func begin(_ id: String, detail: String? = nil, at now: Date = .now) {
        guard let target = stages.firstIndex(where: { $0.id == id }), stages[target].startedAt == nil else { return }
        closeRunning(at: now)
        stages[target].startedAt = now
        stages[target].detail = detail ?? stages[target].detail
        let skipped = stages[..<target].filter { $0.startedAt == nil }.map(\.id)
        stages.removeAll { skipped.contains($0.id) }
    }

    /// Updates the note on `id` while it's running; a late update for a finished stage is ignored.
    public mutating func setDetail(_ id: String, _ detail: String?) {
        guard let i = stages.firstIndex(where: { $0.id == id }), stages[i].status == .running else { return }
        stages[i].detail = detail
    }

    /// Everything's done: ends the running stage and drops any that were never needed.
    public mutating func finish(at now: Date = .now) {
        closeRunning(at: now)
        stages.removeAll { $0.startedAt == nil }
    }

    /// Marks the running stage as the one that failed.
    public mutating func fail(at now: Date = .now) {
        guard let i = stages.firstIndex(where: { $0.status == .running }) else { return }
        stages[i].finishedAt = now
        stages[i].failed = true
    }

    private mutating func closeRunning(at now: Date) {
        if let i = stages.firstIndex(where: { $0.status == .running }) { stages[i].finishedAt = now }
    }

    /// "<1s", "34s", "1m 42s".
    public static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        if whole < 1 { return "<1s" }
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}

import Foundation
import Synchronization

/// A live stream of events. Events are delivered in order and never dropped (unbounded buffer), so
/// drain `events` promptly.
///
/// The client resubscribes on its own after a reconnect or a server `Gap`:
/// - a server subscription receives a fresh `ServerSnapshot` (replace your state with it);
/// - a rider subscription replays items persisted after `lastSeq`, then `ReplayDone`, then goes live
///   again. Upserts are idempotent, so folding stays correct.
///
/// `events` ends when the subscription is cancelled, the client is closed, or the server refuses a
/// resubscription (e.g. the rider was closed).
public final class TeamCarSubscription: Sendable {
    enum Kind: Sendable {
        case server
        case rider(fromSeq: UInt64)
    }

    private struct State {
        var lastSeq: UInt64
        var serverID: UInt64?
        var done = false
    }

    /// Single consumer.
    public let events: AsyncStream<Radio_Event>
    private let continuation: AsyncStream<Radio_Event>.Continuation
    private let state: Mutex<State>
    private let target: Radio_Subscribe
    private let isRider: Bool
    private weak let client: TeamCarClient?

    init(client: TeamCarClient, target: Radio_Subscribe, kind: Kind) {
        (events, continuation) = AsyncStream<Radio_Event>.makeStream(bufferingPolicy: .unbounded)
        self.client = client
        self.target = target
        switch kind {
        case .server:
            isRider = false
            state = Mutex(State(lastSeq: 0))
        case .rider(let fromSeq):
            isRider = true
            state = Mutex(State(lastSeq: fromSeq))
        }
        // The consumer stopped iterating (its task was cancelled): treat it as cancel().
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.cancel() }
        }
    }

    /// Rider subscriptions: the highest event seq delivered (resubscribe from it to resume elsewhere).
    public var lastSeq: UInt64 { state.withLock { $0.lastSeq } }

    /// Ends the subscription and unsubscribes on the server.
    public func cancel() {
        let first = state.withLock { s -> Bool in
            defer { s.done = true }
            return !s.done
        }
        continuation.finish()
        guard first, let client else { return }
        Task { await client.remove(self) }
    }

    // MARK: Client side

    /// What to send on (re)subscribe: rider streams resume after the last delivered seq.
    var currentTarget: Radio_Subscribe {
        guard isRider, case .rider(var r) = target.target else { return target }
        r.fromSeq = lastSeq
        var t = Radio_Subscribe()
        t.rider = r
        return t
    }

    var serverID: UInt64? { state.withLock { $0.serverID } }

    func bind(serverID: UInt64) { state.withLock { $0.serverID = serverID } }
    func unbind() { state.withLock { $0.serverID = nil } }

    /// Called in order from the client's read loop.
    func deliver(_ event: Radio_Event) {
        let open = state.withLock { s -> Bool in
            guard !s.done else { return false }
            if isRider, event.seq > s.lastSeq { s.lastSeq = event.seq }
            return true
        }
        if open { continuation.yield(event) }
    }

    /// Ends the stream without unsubscribing (client closed, or the server refused).
    func finish() {
        state.withLock { $0.done = true }
        continuation.finish()
    }
}

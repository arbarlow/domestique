import CryptoKit
import Foundation
import Network
import Synchronization

/// One WebSocket connection carrying binary messages, built on Network.framework.
///
/// - `ws://` / `wss://` URLs use `NWProtocolWebSocket` directly (it sends Host, path and does the upgrade).
/// - Unix sockets: `NWProtocolWebSocket` builds its HTTP upgrade request from a URL endpoint, so over
///   `NWEndpoint.unix(path:)` it has no Host or path to send (and Go's net/http rejects a request without
///   Host). There we run the WebSocket protocol with `skipHandshake` on top of `HTTPUpgradeFramer`, a tiny
///   framer that performs the RFC 6455 opening handshake (`GET /domestique/v1`, `Host: localhost`), validates
///   `Sec-WebSocket-Accept`, then passes bytes through. Framing, client masking, ping/pong and close stay
///   native.
final class WebSocketTransport: Sendable {
    /// Big enough for any frame the server will send (its own read limit is 64 MB; transcripts can be large).
    static let maximumMessageSize = 256 << 20

    private let connection: NWConnection
    private let queue: DispatchQueue

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Opens the connection and completes the WebSocket handshake.
    static func open(_ endpoint: ServerEndpoint, timeout: Duration = .seconds(10)) async throws -> WebSocketTransport {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = maximumMessageSize

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.components.seconds)
        tcp.noDelay = true

        let nwEndpoint: NWEndpoint
        let params: NWParameters
        switch endpoint {
        case .unix(let path):
            params = NWParameters(tls: nil, tcp: tcp)
            ws.skipHandshake = true
            params.defaultProtocolStack.applicationProtocols.insert(
                NWProtocolFramer.Options(definition: HTTPUpgradeFramer.definition), at: 0)
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            nwEndpoint = .unix(path: path)
        case .url:
            guard let url = endpoint.webSocketURL else {
                throw ServerError(code: .invalidArgument, message: "Unsupported server URL \(endpoint)", local: true)
            }
            let tls: NWProtocolTLS.Options? = url.scheme == "wss" ? NWProtocolTLS.Options() : nil
            params = NWParameters(tls: tls, tcp: tcp)
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            nwEndpoint = .url(url)
        }

        let connection = NWConnection(to: nwEndpoint, using: params)
        let queue = DispatchQueue(label: "ServerKit.WebSocket")
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                once.set(cont)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(with: .success(()))
                    case .waiting(let error), .failed(let error):
                        // .waiting means NW would retry on its own; we have our own backoff.
                        once.resume(with: .failure(ServerError.disconnected("Can't connect to \(endpoint): \(error.localizedDescription)")))
                        connection.cancel()
                    case .cancelled:
                        once.resume(with: .failure(ServerError.disconnected("Connection to \(endpoint) cancelled")))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                    if once.resume(with: .failure(ServerError.disconnected("Timed out connecting to \(endpoint)"))) {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        // After the handshake, a failure just tears the connection down; receive()/send() report it.
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        return WebSocketTransport(connection: connection, queue: queue)
    }

    /// Queues one binary message. Messages go out in the order of these calls.
    func send(_ data: Data, completion: @escaping @Sendable (ServerError?) -> Void) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            completion(error.map { ServerError.disconnected("Send failed: \($0.localizedDescription)") })
        })
    }

    /// Sends one binary message.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            send(data) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    enum Message: Sendable {
        case binary(Data)
        /// Ping, pong or text: not a Domestique protocol frame, but proof the peer is alive.
        case other
    }

    /// Receives the next message. Throws when the connection closes. Call from one task at a time.
    /// `first` is sent once the read is queued; if that fails, the read reports the broken connection.
    func receive(thenSending first: Data? = nil) async throws -> Message {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Message, any Error>) in
            connection.receiveMessage { content, context, isComplete, error in
                if let error {
                    cont.resume(throwing: ServerError.disconnected("Connection lost: \(error.localizedDescription)"))
                    return
                }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                switch meta?.opcode {
                case .binary:
                    cont.resume(returning: .binary(content ?? Data()))
                case .close:
                    var reason = "Server closed the connection"
                    if let meta, case .protocolCode(let code) = meta.closeCode, code != .normalClosure {
                        reason += " (\(code))"
                    }
                    if let content, !content.isEmpty, let text = String(data: content, encoding: .utf8) {
                        reason += ": \(text)"
                    }
                    cont.resume(throwing: ServerError.disconnected(reason))
                case nil:
                    // No metadata and no data: the stream ended.
                    if let content, !content.isEmpty {
                        cont.resume(returning: .binary(content))
                    } else {
                        cont.resume(throwing: ServerError.disconnected("Connection closed"))
                    }
                default:
                    cont.resume(returning: .other)
                }
            }
            if let first { send(first) { _ in } }
        }
    }

    /// Sends a close frame (best effort) and tears the connection down.
    func close() {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        let connection = connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        // Don't wait forever on a wedged peer.
        queue.asyncAfter(deadline: .now() + .seconds(1)) { connection.cancel() }
    }

    /// Drops the connection at once.
    func cancel() { connection.cancel() }
}

/// Resumes a continuation at most once (state callbacks and timeouts race).
private final class ResumeOnce: Sendable {
    private let state = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    func set(_ cont: CheckedContinuation<Void, any Error>) { state.withLock { $0 = cont } }

    @discardableResult
    func resume(with result: Result<Void, any Error>) -> Bool {
        guard let cont = state.withLock({ s -> CheckedContinuation<Void, any Error>? in
            defer { s = nil }
            return s
        }) else { return false }
        cont.resume(with: result)
        return true
    }
}

// MARK: - HTTP upgrade over a Unix socket

/// Performs the client side of the RFC 6455 opening handshake, then gets out of the way. Sits below an
/// `NWProtocolWebSocket` configured with `skipHandshake`.
///
/// Framer instances are created and called only on their connection's queue, so the mutable state needs
/// no locking (Network.framework's contract for `NWProtocolFramerImplementation`).
final class HTTPUpgradeFramer: NWProtocolFramerImplementation {
    static let label = "ServerProtocol HTTP upgrade"
    static let definition = NWProtocolFramer.Definition(implementation: HTTPUpgradeFramer.self)
    /// Still the original path, so this build can reach servers that haven't been upgraded.
    static let path = "/radio/v1"
    static let host = "localhost"
    private static let maxHeaderBytes = 16 << 10

    private let key: String
    private var upgraded = false

    required init(framer: NWProtocolFramer.Instance) {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        key = Data(bytes).base64EncodedString()
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        let request = [
            "GET \(Self.path) HTTP/1.1",
            "Host: \(Self.host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "User-Agent: ServerKit",
            "", "",
        ].joined(separator: "\r\n")
        framer.writeOutput(data: Data(request.utf8))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard !upgraded else { return 0 }
        var head: Data?
        var needed = 1
        // Peek at what's buffered; consume exactly the response head so any bytes after it (the first
        // WebSocket frames) stay for the WebSocket protocol above us.
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { buffer, _ in
            guard let buffer else { return 0 }
            let terminator: [UInt8] = [13, 10, 13, 10]
            if buffer.count >= 4 {
                for i in 0...(buffer.count - 4)
                where buffer[i] == terminator[0] && buffer[i + 1] == terminator[1]
                    && buffer[i + 2] == terminator[2] && buffer[i + 3] == terminator[3] {
                    head = Data(buffer[0..<i])
                    return i + 4
                }
            }
            needed = buffer.count + 1
            return 0
        }
        guard let head else {
            if needed > Self.maxHeaderBytes {
                framer.markFailed(error: .posix(.EBADMSG))
            }
            return needed
        }
        guard validate(String(decoding: head, as: UTF8.self)) else {
            framer.markFailed(error: .posix(.ECONNREFUSED))
            return 0
        }
        upgraded = true
        framer.passThroughOutput()
        framer.passThroughInput()
        framer.markReady()
        return 0
    }

    private func validate(_ head: String) -> Bool {
        let lines = head.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else { return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return headers["sec-websocket-accept"] == Data(digest).base64EncodedString()
            && headers["upgrade"]?.lowercased() == "websocket"
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        // Only reached before passThroughOutput(), which can't happen: nothing above us is ready yet.
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

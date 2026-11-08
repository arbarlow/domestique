import Foundation
import Network
import ServerKit

/// Makes a port on the server reachable from this phone: listens on the phone's loopback and pipes each connection
/// through `nc` on the server, over the existing Domestique connection. Dev servers bound to 127.0.0.1 need no
/// changes, and this works wherever the app can reach the server.
@MainActor
final class PortTunnel {
    private let remotePort: UInt16
    private weak var server: ServerConnection?
    private var listener: NWListener?

    init(remotePort: UInt16, server: ServerConnection) {
        self.remotePort = remotePort
        self.server = server
    }

    /// Starts listening if needed and returns the phone's port: the server's port, unless something here already
    /// has it (a simulator shares the Mac's loopback with the server).
    func open() async throws -> UInt16 {
        if let listener, listener.state == .ready, let port = listener.port?.rawValue { return port }
        listener?.cancel()
        listener = nil
        if let port = NWEndpoint.Port(rawValue: remotePort), let bound = try? await listen(on: port) { return bound }
        return try await listen(on: .any)
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: once.resume(.success(listener?.port?.rawValue ?? port.rawValue))
                case .failed(let error):
                    once.resume(.failure(error))
                    listener?.cancel()
                    Task { @MainActor in if self?.listener === listener { self?.listener = nil } }
                case .cancelled: once.resume(.failure(ServerError(code: .unavailable, message: "The tunnel closed")))
                default: break
                }
            }
            listener.start(queue: .main)
        }
        self.listener = listener
        return bound
    }

    private func serve(_ connection: NWConnection) {
        guard let server else { return connection.cancel() }
        let port = remotePort
        connection.start(queue: .global())
        Task {
            do {
                let client = try await server.ready()
                var target = Proto_ProcessTarget()
                target.argv = ["nc", "127.0.0.1", String(port)]
                let sub = try await client.subscribeProcess(target)
                await Self.pump(connection, client: client, sub: sub)
            } catch {
                connection.cancel()
            }
        }
    }

    private nonisolated static func pump(_ connection: NWConnection, client: ServerClient, sub: ServerSubscription) async {
        var upload: Task<Void, Never>?
        loop: for await event in sub.events {
            switch event.payload {
            case .processStarted(let started):
                upload = Task { await send(connection, to: client, processID: started.processID, sub: sub) }
            case .processOutput(let output) where output.stream == .stdout:
                guard await write(output.data, to: connection) else { break loop }
            case .processExited:
                break loop
            default: break
            }
        }
        upload?.cancel()
        sub.cancel()
        connection.cancel()
    }

    /// Browser to server. A browser's FIN means it's done with the connection, so that ends the process too.
    private nonisolated static func send(_ connection: NWConnection, to client: ServerClient, processID: String, sub: ServerSubscription) async {
        while !Task.isCancelled {
            let (data, done) = await read(from: connection)
            if let data, !data.isEmpty {
                do {
                    try await client.processInput(processID: processID, data: data)
                } catch {
                    break
                }
            }
            if done { break }
        }
        sub.cancel()
    }

    private nonisolated static func read(from connection: NWConnection) async -> (Data?, Bool) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete || error != nil))
            }
        }
    }

    private nonisolated static func write(_ data: Data, to connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
        }
    }

    /// Resumes a continuation at most once. Only touched on the main queue.
    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<UInt16, any Error>?
        init(_ continuation: CheckedContinuation<UInt16, any Error>) { self.continuation = continuation }
        func resume(_ result: Result<UInt16, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

extension ServerConnection {
    func tunnel(to port: UInt16) -> PortTunnel {
        if let existing = tunnels[port] { return existing }
        let tunnel = PortTunnel(remotePort: port, server: self)
        tunnels[port] = tunnel
        return tunnel
    }

    /// A URL for this phone to visit `port` on the server, after checking something answers there.
    func previewURL(port: UInt16, path: String = "", in workspaceID: String) async throws -> URL {
        let check = try await run(in: workspaceID, "command -v nc >/dev/null || exit 3; (exec 3<>/dev/tcp/127.0.0.1/\(port)) 2>/dev/null || exit 4")
        switch check.status {
        case 0: break
        case 3: throw ServerError(code: .failedPrecondition, message: "\(name) needs nc (netcat) installed to open ports on this phone.")
        case 4: throw ServerError(code: .failedPrecondition, message: "Nothing is listening on port \(port) yet.")
        default: throw ServerError(code: .failedPrecondition, message: "Couldn't check port \(port).")
        }
        let local = try await tunnel(to: port).open()
        guard let url = URL(string: "http://localhost:\(local)\(path)") else {
            throw ServerError(code: .invalidArgument, message: "Bad path: \(path)")
        }
        return url
    }
}

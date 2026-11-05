import DQCore
import Foundation

/// A long-lived child process speaking newline-delimited JSON on stdin/stdout.
/// Lines are delivered in order on `lines`; writes are serialised by the owner (an actor).
final class LineProcess: @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = Data()
    private var exited = false
    private var onExit: (@Sendable (Int32, String) -> Void)?

    init(executable: String, arguments: [String], cwd: String, environment: [String: String]) {
        (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { lock.withLock { !exited } && process.isRunning }

    func start(onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        self.onExit = onExit
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.flushRemainder()
                return
            }
            self.ingest(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.stderrTail.append(chunk)
                if self.stderrTail.count > 16_384 { self.stderrTail = self.stderrTail.suffix(8_192) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // Give the stdout reader a moment to drain.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                let tail = self.lock.withLock { () -> String in
                    self.exited = true
                    return String(decoding: self.stderrTail, as: UTF8.self)
                }
                self.flushRemainder()
                self.continuation.finish()
                self.onExit?(proc.terminationStatus, tail)
            }
        }
        try process.run()
    }

    private func ingest(_ chunk: Data) {
        var out: [Data] = []
        lock.withLock {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                if !line.isEmpty { out.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        for line in out { continuation.yield(line) }
    }

    private func flushRemainder() {
        let rest: Data = lock.withLock {
            let r = buffer
            buffer.removeAll()
            return r
        }
        if !rest.isEmpty { continuation.yield(rest) }
    }

    func write(_ value: JSONValue) {
        var data = value.encoded()
        data.append(UInt8(ascii: "\n"))
        write(data)
    }

    func write(_ data: Data) {
        guard lock.withLock({ !exited }) else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            // Broken pipe: the termination handler will report the exit.
        }
    }

    func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    func terminate() {
        guard process.isRunning else { return }
        process.interrupt()  // SIGINT ends the turn cleanly
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

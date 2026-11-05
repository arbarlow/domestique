import Darwin
import Foundation

/// Output from a PTY as line edits, delivered in coalesced batches.
struct LogBatch: Sendable {
    /// New lines, or existing lines (same id) that were redrawn in place.
    var upserts: [LogLine]
    /// Lines erased by the program (e.g. `ESC[J` under a spinner).
    var removed: [Int]
}

/// Spawns a command under a pseudo-terminal in its own session / process group and streams output.
/// Not main-actor bound: all reading happens on a private serial queue.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let masterFD: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    // Terminal-ish line model (queue-confined).
    private var screen = LogScreen()
    private var flushScheduled = false
    private var nextID: Int
    private var exited = false
    private var eof = false
    private var finished = false
    private var exitCode: Int32 = 0

    private let onBatch: @Sendable (LogBatch) -> Void
    private let onExit: @Sendable (Int32) -> Void

    static let maxLineLength = 8_000

    struct SpawnError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// - Parameters:
    ///   - firstLineID: ids continue from here so a TaskRun's lines stay unique across restarts.
    init(
        shell: String, command: String, cwd: String, environment: [String: String], firstLineID: Int,
        onBatch: @escaping @Sendable (LogBatch) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.onBatch = onBatch
        self.onExit = onExit
        self.nextID = firstLineID

        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            throw SpawnError(message: "openpty failed: \(String(cString: strerror(errno)))")
        }
        // Don't echo anything we might write; output-only.
        var tio = termios()
        if tcgetattr(slave, &tio) == 0 {
            tio.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(slave, TCSANOW, &tio)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, slave, 0)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 1)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 2)
        posix_spawn_file_actions_addchdir(&fileActions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session => new process group with pgid == pid, so we can signal the whole tree.
        // CLOEXEC_DEFAULT => only fds 0-2 are inherited.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        let argv = [shell, "-c", command]
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var childPID: pid_t = 0
        let rc = withCStrings(argv) { argvPtr in
            withCStrings(envp) { envPtr in
                posix_spawn(&childPID, shell, &fileActions, &attr, argvPtr, envPtr)
            }
        }
        close(slave)
        guard rc == 0 else {
            close(master)
            throw SpawnError(message: "Failed to start \(shell): \(String(cString: strerror(rc)))")
        }
        pid = childPID
        masterFD = master
        queue = DispatchQueue(label: "domestique.pty.\(childPID)")
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { close(master) }
        readSource = rs

        let es = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        es.setEventHandler { [weak self] in self?.handleExit() }
        exitSource = es

        rs.resume()
        es.resume()
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
    }

    // MARK: signals

    /// Signals the whole process group.
    func signalGroup(_ sig: Int32) {
        if kill(-pid, sig) != 0 {
            // Group may already be gone; try the leader directly.
            kill(pid, sig)
        }
    }

    var groupAlive: Bool { kill(-pid, 0) == 0 }

    // MARK: reading (queue)

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
            if n > 0 {
                consume(buffer[0..<n])
                if n < buffer.count { break }
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                break
            } else {
                // 0 or EIO: every writer closed the slave side.
                eof = true
                readSource?.cancel()
                readSource = nil
                scheduleFlush(immediately: true)
                finishIfDone()
                break
            }
        }
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        screen.feed(bytes)
        scheduleFlush(immediately: false)
    }

    private func scheduleFlush(immediately: Bool) {
        if immediately {
            flush()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard screen.hasChanges else { return }
        let changes = screen.takeChanges()
        onBatch(LogBatch(upserts: changes.upserts, removed: changes.removed))
    }

    private func handleExit() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, 0)
        exitSource?.cancel()
        exitSource = nil
        if r == pid {
            let low = status & 0x7F
            exitCode = low == 0 ? (status >> 8) & 0xFF : 128 + low
        } else {
            exitCode = -1
        }
        exited = true
        // Give in-flight output a moment to arrive before reporting the exit; children that
        // inherited the PTY can keep it open forever, so don't wait for EOF.
        queue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self else { return }
            self.readAvailableIfOpen()
            self.finishIfDone(force: true)
        }
        finishIfDone()
    }

    private func readAvailableIfOpen() {
        if readSource != nil { readAvailable() }
    }

    private func finishIfDone(force: Bool = false) {
        guard exited, !finished, eof || force else { return }
        finished = true
        flush()
        onExit(exitCode)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeBufferPointer { body($0.baseAddress!) }
}

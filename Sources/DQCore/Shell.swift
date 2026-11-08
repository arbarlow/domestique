import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// Raw stdout bytes (for binary-safe reads, e.g. `cat` over SSH).
    public var stdoutData: Data = Data()
    public var succeeded: Bool { status == 0 }

    public init(status: Int32, stdout: String, stderr: String, stdoutData: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutData = stdoutData
    }
}

public struct ShellError: Error, LocalizedError, Sendable {
    public var command: String
    public var result: ShellResult
    public init(command: String, result: ShellResult) {
        self.command = command
        self.result = result
    }
    public var errorDescription: String? {
        let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command)` failed (\(result.status)): \(msg.isEmpty ? out : msg)"
    }
}

#if os(macOS)
/// Runs short-lived commands (git, gh, lsof...). Long-running processes live in ProcessKit / AgentKit.
/// macOS only: iOS has no child processes (the iPhone app does everything through a server).
public enum Shell {
    /// Run an executable found on the user's login PATH.
    @discardableResult
    public static func run(
        _ executable: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:],
        stdin: String? = nil, check: Bool = true
    ) async throws -> ShellResult {
        let exe = try await LoginEnvironment.shared.resolve(executable)
        let baseEnv = await LoginEnvironment.shared.environment()
        let result = try await runRaw(exe, args, cwd: cwd, env: baseEnv.merging(env) { $1 }, stdin: stdin)
        if check && !result.succeeded {
            throw ShellError(command: ([executable] + args).joined(separator: " "), result: result)
        }
        return result
    }

    /// Run with an absolute executable path and an explicit environment.
    public static func runRaw(
        _ executablePath: String, _ args: [String], cwd: String?, env: [String: String], stdin: String? = nil
    ) async throws -> ShellResult {
        try await runRaw(executablePath, args, cwd: cwd, env: env, stdinData: stdin.map { Data($0.utf8) })
    }

    /// Like `runRaw`, with binary stdin.
    public static func runRaw(
        _ executablePath: String, _ args: [String], cwd: String?, env: [String: String], stdinData: Data?
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdinData != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { cont in
            let group = DispatchGroup()
            nonisolated(unsafe) var outData = Data()
            nonisolated(unsafe) var errData = Data()
            group.enter()
            group.enter()
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                // Balance the termination enter and drain readers.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                group.leave()
                group.notify(queue: .global()) { cont.resume(throwing: error) }
                return
            }
            if let inPipe, let stdinData {
                DispatchQueue.global().async {
                    inPipe.fileHandleForWriting.write(stdinData)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            group.notify(queue: .global()) {
                cont.resume(
                    returning: ShellResult(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self),
                        stdoutData: outData
                    ))
            }
        }
    }
}

/// GUI apps launched from Finder/Dock don't inherit the user's shell PATH (nvm, homebrew, ~/.local/bin).
/// We capture the login shell's environment once and use it for every child process.
public actor LoginEnvironment {
    public static let shared = LoginEnvironment()

    private var cached: [String: String]?
    private var resolved: [String: String] = [:]

    public func environment() async -> [String: String] {
        if let cached { return cached }
        let env = await Self.capture()
        cached = env
        return env
    }

    /// Absolute path for a command name (or the path itself if already absolute).
    public func resolve(_ name: String) async throws -> String {
        if name.hasPrefix("/") { return name }
        if let hit = resolved[name] { return hit }
        let env = await environment()
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                resolved[name] = candidate
                return candidate
            }
        }
        throw NSError(
            domain: "Domestique", code: 127,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't find `\(name)` on your PATH."])
    }

    private static func capture() async -> [String: String] {
        var fallback = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        fallback["PATH"] = (extra + [(fallback["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")]).joined(separator: ":")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__DQ_ENV_\(UUID().uuidString.prefix(8))__"
        // -l login, -i interactive so .zshrc (nvm etc.) is sourced.
        let script = "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"
        let baseEnv = fallback
        guard
            let result = try? await withTimeout(seconds: 10, {
                try await Shell.runRaw(shell, ["-l", "-i", "-c", script], cwd: home, env: baseEnv)
            })
        else { return fallback }
        let parts = result.stdout.components(separatedBy: marker)
        guard parts.count >= 3 else { return fallback }
        var env: [String: String] = [:]
        for entry in parts[1].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        guard env["PATH"] != nil else { return fallback }
        // Never leak interactive-shell-only noise into children.
        for key in ["PS1", "PS2", "PROMPT", "RPROMPT", "SHLVL", "_", "OLDPWD", "PWD"] { env.removeValue(forKey: key) }
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        return env
    }
}

#endif

public struct TimeoutError: Error {}

public func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

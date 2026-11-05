import AppKit
import CryptoKit
import DQCore
import Foundation
import GitHubKit
import Observation

/// Self-updater fed by the GitHub Releases that CI publishes on every push to master.
///
/// Why not Sparkle/Squirrel: release builds are ad-hoc signed, so Squirrel's "same designated requirement" check can't
/// pass (an ad-hoc requirement is the cdhash, which changes every build), and Sparkle would need an appcast plus an
/// EdDSA key in CI. GitHub over HTTPS is already the trust root for the manual install, so we keep that and check
/// the published SHA-256 and the bundle's code signature before swapping. Files fetched with URLSession aren't
/// quarantined, so updated builds don't need the `xattr` step either.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        /// Downloaded, verified and unpacked; one click restarts into it.
        case ready(stagedApp: URL)
        case installing
        case failed(String)
    }

    static let repoSlug = "arbarlow/domestique"
    private static let checkInterval: Duration = .seconds(4 * 60 * 60)

    private(set) var phase: Phase = .idle
    /// Builds newer than the running one, newest first. Non-empty means an update is on offer.
    private(set) var available: [AppRelease] = []
    private(set) var lastChecked: Date?

    let currentBuild: Int
    /// Only CI builds (CFBundleVersion = run number > 1) running from an .app bundle update themselves. Local Xcode
    /// builds stay at 1 and `swift run` has no bundle, so neither would ever match a release.
    let isEnabled: Bool

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var stagedBuild: Int?

    var newest: AppRelease? { available.first }

    init(bundle: Bundle = .main) {
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let forced = ProcessInfo.processInfo.environment["DQ_UPDATE_FORCE"] == "1"
        isEnabled = bundle.bundleURL.pathExtension == "app" && (currentBuild > 1 || forced)
    }

    func start() {
        guard isEnabled, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))  // don't compete with launch work
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Checks GitHub and, when there's something newer, downloads it in the background so installing is instant.
    func check(userInitiated: Bool = false) async {
        guard isEnabled else { return }
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        let previous = phase
        phase = .checking
        do {
            let releases = try await GitHubClient.shared.appReleases(slug: Self.repoSlug)
            lastChecked = Date()
            available = AppRelease.newer(than: currentBuild, in: releases)
            Trace.log("updater: build \(currentBuild), \(releases.count) releases, \(available.count) newer")
            guard let newest else {
                phase = .idle
                return
            }
            if case .ready = previous, stagedBuild == newest.build {
                phase = previous
                return
            }
            await download(newest)
        } catch {
            Trace.log("updater: check failed: \(error)")
            // A failed background check (offline, rate limited) shouldn't nag, and shouldn't lose a staged update.
            if case .ready = previous {
                phase = previous
            } else {
                phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    /// Retry after a failed download.
    func downloadNewest() {
        guard let newest else { return }
        Task { await download(newest) }
    }

    private func download(_ release: AppRelease) async {
        phase = .downloading
        do {
            let staged = try await Self.fetchAndStage(release)
            stagedBuild = release.build
            phase = .ready(stagedApp: staged)
            Trace.log("updater: staged build \(release.build) at \(staged.path)")
        } catch {
            Trace.log("updater: download failed: \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Swaps the staged build into place once this process has exited, then relaunches it.
    func installAndRelaunch() {
        guard case .ready(let staged) = phase else { return }
        let app = Bundle.main.bundleURL
        if let problem = Self.installProblem(for: app) {
            phase = .failed(problem)
            return
        }
        phase = .installing
        // A detached helper does the swap so we never replace the bundle of a running process. It waits for our
        // PID to go away, moves the old bundle aside (restoring it if the move-in fails), and opens the new one.
        let script = """
            pid="$1"; app="$2"; new="$3"; old="$new.previous"
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            rm -rf "$old"
            if mv "$app" "$old"; then
              if ! mv "$new" "$app"; then mv "$old" "$app"; fi
            fi
            open "$app"
            rm -rf "$old"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "domestique-update", "\(ProcessInfo.processInfo.processIdentifier)", app.path, staged.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            phase = .failed("Couldn't start the installer: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Off-main work

    private static func installProblem(for app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running Domestique from a temporary location. Move it to Applications, run "
                + "`xattr -dr com.apple.quarantine` on it, and reopen it."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "Can't write to \(app.deletingLastPathComponent().path). Move Domestique somewhere you own."
        }
        return nil
    }

    /// Download → checksum → unzip → validate. Returns the unpacked .app, on the same volume as the running app so
    /// the final swap is a rename.
    private nonisolated static func fetchAndStage(_ release: AppRelease) async throws -> URL {
        let gh = GitHubClient.shared
        let zip = try await gh.downloadReleaseAsset(slug: repoSlug, id: release.zipAssetID)
        defer { try? FileManager.default.removeItem(at: zip) }

        if let checksumID = release.checksumAssetID {
            let file = try await gh.downloadReleaseAsset(slug: repoSlug, id: checksumID)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let expected = AppRelease.parseChecksum(try String(contentsOf: file, encoding: .utf8)) else {
                throw UpdateError("The release's checksum file is unreadable.")
            }
            guard try sha256(of: zip) == expected else { throw UpdateError("The download didn't match its checksum.") }
        }

        let fm = FileManager.default
        let staging = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
        let unzip = try await Shell.runRaw("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], cwd: nil, env: [:])
        guard unzip.succeeded else { throw UpdateError("Couldn't unpack the update: \(unzip.stderr)") }

        let app = staging.appendingPathComponent("Domestique.app")
        guard let info = Bundle(url: app)?.infoDictionary,
            info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
            info["CFBundleVersion"] as? String == String(release.build)
        else { throw UpdateError("The downloaded app isn't build \(release.build) of Domestique.") }

        // Apple silicon refuses to launch a bundle with a broken signature, so catch that before swapping.
        let sig = try await Shell.runRaw("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], cwd: nil, env: [:])
        guard sig.succeeded else { throw UpdateError("The update's code signature is invalid.") }
        return app
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

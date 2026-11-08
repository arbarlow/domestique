import DQCore
import Foundation
import GitKit
import HostKit

/// Creating, archiving and deleting workspaces that live on a cloud machine.
extension AppModel {
    /// Where new workspaces in `repo` run by default.
    func defaultLocation(for repo: Repository) -> WorkspaceLocation {
        // The pre-provider "boat.dev" choice means the first boat.dev provider.
        var loc = repo.defaultLocation
        if case .cloud = loc, let p = settings.provider(for: loc) { loc = .sandbox(p.id) }
        // A repository's own choice, unless it's gone or turned off; else the app-wide default.
        if let loc, workspaceLocations.contains(loc) { return loc }
        return appDefaultLocation
    }

    /// New boat.dev workspace: one sandbox per workspace, the repo cloned into /home/user/<repo>,
    /// on a new branch from a fresh origin/<default>. Mirrors the local worktree flow.
    func provisionBoatWorkspace(_ wsID: UUID, repo: Repository, provider: SandboxProviderConfig) async throws {
        guard let ws = workspace(wsID) else { return }
        let boat = provider.boat
        let client = BoatClient.client(account: provider.credentialAccount)
        guard BoatClient.isConfigured(account: provider.credentialAccount) else {
            if let home = provider.home, link(for: home)?.isConnected != true {
                throw HostError("\(serverName(for: home)) isn't connected, so it can't start a sandbox on \(provider.name).")
            }
            throw HostError("Sign \(provider.name) in first: add an API key in Settings → Servers, or run `boat login`.")
        }

        setCreationStep(wsID, "Starting a sandbox on \(provider.name)")
        let request = BoatCreateRequest(
            name: "\(repo.name) · \(ws.name)", type: boat.machineType,
            ttlSeconds: boat.autoStopMinutes.map { $0 * 60 }, disableAutoStop: boat.autoStopMinutes == nil,
            environment: boat.environment?.isEmpty == false ? boat.environment : nil,
            from: boat.fromSnapshot?.isEmpty == false ? boat.fromSnapshot : nil,
            labels: ["domestique": "1", "repo": repo.name, "workspace": ws.name])
        let machineID = try await client.create(request, idempotencyKey: wsID.uuidString)
        updateWorkspace(wsID) {
            var h = WorkspaceHost(provider: .boat, machineID: machineID, machineName: request.name, machineType: boat.machineType)
            h.accountID = provider.credentialAccount
            $0.host = h
        }
        let host = Hosts.boatHost(machineID, account: provider.credentialAccount)
        cloud.observe(host)

        setCreationStep(wsID, "Waiting for \(machineID) to boot")
        try await host.prepare()

        let path = "\(BoatHost.home)/\(repo.name)"
        updateWorkspace(wsID) { $0.path = path }
        setCreationStep(wsID, "Cloning \(repo.githubSlug ?? repo.name)")
        try await cloneRepo(repo, into: path, host: host, shareToken: boat.shareGitHubToken)

        setCreationStep(wsID, "Branching \(ws.branch) from origin/\(repo.defaultBranch)")
        let identity = await localGitIdentity(repo)
        let q = ShellQuote.quote
        var script = [
            "set -e",
            "git fetch -q origin \(q(repo.defaultBranch))",
            // --no-track: a plain `git push` must never land on the default branch.
            "git switch -q --no-track -c \(q(ws.branch)) \(q("origin/" + repo.defaultBranch))",
            "git config \(q("branch.\(ws.branch).gh-merge-base")) \(q(repo.defaultBranch))",
        ]
        if let name = identity.name { script.append("git config user.name \(q(name))") }
        if let email = identity.email { script.append("git config user.email \(q(email))") }
        script.append("git rev-parse HEAD")
        let r = try await host.runScript(script.joined(separator: "\n"), cwd: path, label: "git switch -c \(ws.branch)")
        let base = r.stdout.split(separator: "\n").last.map(String.init)
        updateWorkspace(wsID) {
            $0.baseCommit = base
            $0.state = .settingUp
        }
    }

    /// Clone with boat's own GitHub access first; fall back to the user's local `gh` token
    /// (stored 0600 on the sandbox, used by a credential helper for this clone and as GH_TOKEN).
    private func cloneRepo(_ repo: Repository, into path: String, host: BoatHost, shareToken: Bool) async throws {
        let url = Self.cloneURL(repo)
        let q = ShellQuote.quote
        let exists = try await host.runScript("test -d \(q(path + "/.git"))", cwd: BoatHost.home, check: false)
        if exists.succeeded { return }

        let first = try await host.runScript(
            "gh auth setup-git >/dev/null 2>&1 || true; GIT_TERMINAL_PROMPT=0 git clone -q \(q(url)) \(q(path))",
            cwd: BoatHost.home, check: false)
        if first.succeeded { return }

        guard shareToken, url.contains("github.com"),
            let token = try? await Shell.run("gh", ["auth", "token"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw HostError(
                "Couldn't clone \(url) on the sandbox: \(first.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n\nGive boat.dev's GitHub app access to this repository, or turn on “Share my GitHub login” in Settings → Cloud."
            )
        }
        // The token travels over stdin, never in argv / logs, into a file only the sandbox user can read.
        try await host.runScript(
            "umask 077 && mkdir -p \"$HOME/.config/domestique\" && cat > \"$HOME/.config/domestique/github-token\"",
            cwd: BoatHost.home, stdin: Data(token.utf8), label: "store GitHub token")
        let env = """
            # Written by Domestique: your local GitHub login, for repos boat.dev's GitHub app can't reach.
            if [ -r "$HOME/.config/domestique/github-token" ]; then export GH_TOKEN="$(cat "$HOME/.config/domestique/github-token")"; fi

            """
        try await host.writeFile("\(BoatHost.home)/.config/domestique/env.sh", data: Data(env.utf8))
        let helper = #"!f() { test "$1" = get && echo username=x-access-token && echo "password=$(cat "$HOME/.config/domestique/github-token")"; }; f"#
        let script = """
            set -e
            H=\(q(helper))
            GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c credential.https://github.com.helper= -c "credential.https://github.com.helper=$H" clone -q \(q(url)) \(q(path))
            cd \(q(path))
            git config --add credential.https://github.com.helper ""
            git config --add credential.https://github.com.helper "$H"
            """
        try await host.runScript(script, cwd: BoatHost.home, label: "git clone \(url)")
    }

    /// Puts the server's MCP servers on a sandbox and returns the `--mcp-config` path (nil = none).
    /// If the server can't be reached, the copy from last time is better than losing the servers.
    func syncMCPConfig(to host: BoatHost, server: SandboxProviderHome) async -> String? {
        do {
            let config = try await serverClient(for: server).resolveMcpConfig()
            guard config.serverCount > 0 else {
                try await host.removeMCPConfig()
                return nil
            }
            try await host.installMCPConfig(Data(config.json.utf8))
            return BoatHost.mcpConfigPath
        } catch {
            return await host.fileExists(BoatHost.mcpConfigPath) ? BoatHost.mcpConfigPath : nil
        }
    }

    /// GitHub remotes become https (the sandbox has no SSH key for GitHub); others are used as-is.
    static func cloneURL(_ repo: Repository) -> String {
        if let slug = repo.githubSlug { return "https://github.com/\(slug).git" }
        return repo.remoteURL ?? repo.path
    }

    private func localGitIdentity(_ repo: Repository) async -> (name: String?, email: String?) {
        func get(_ key: String) async -> String? {
            let r = try? await Shell.run("git", ["config", key], cwd: repo.path, check: false)
            let v = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? nil : v
        }
        return (await get("user.name"), await get("user.email"))
    }

    func setCreationStep(_ wsID: UUID?, _ step: String?) {
        guard let wsID else { return }
        creationSteps[wsID] = step
    }

    /// Archive: stop the sandbox (resumable for 14 days), or delete it if the user asked for that.
    func archiveRemote(_ ws: Workspace) async {
        guard let h = ws.host else { return }
        let host = cloud.host(h.machineID)
        let client = cloud.client(h.machineID)
        await host.disconnect()
        do {
            if settings.provider(for: h)?.boat.deleteOnArchive ?? false {
                try await client.delete(h.machineID)
            } else if cloud.status[h.machineID]?.phase != .stopped {
                try await client.stop(h.machineID)
            }
        } catch let e as BoatAPIError where e.status == 404 {
            // Already gone.
        } catch {
            alert = AppAlert(title: "Couldn't stop the boat.dev sandbox", message: error.localizedDescription)
        }
        await cloud.poll(h.machineID)
    }

    /// Delete permanently: the sandbox and its snapshots go too.
    func deleteRemote(_ ws: Workspace) async {
        guard let h = ws.host else { return }
        do {
            try await cloud.client(h.machineID).delete(h.machineID)
        } catch let e as BoatAPIError where e.status == 404 {
        } catch {
            alert = AppAlert(title: "Couldn't delete the boat.dev sandbox", message: error.localizedDescription)
        }
    }
}

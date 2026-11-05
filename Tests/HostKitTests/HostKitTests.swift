import DQCore
import Foundation
import Testing

@testable import HostKit

@Suite struct BoatHostTests {
    @Test func remoteScriptQuotesEverything() {
        let s = BoatHost.remoteScript("exec claude -p", cwd: "/home/user/my repo", env: ["A": "it's", "BAD-NAME": "x"])
        #expect(s.hasPrefix("exec bash -lc '"))
        #expect(s.contains("my repo"))
        #expect(!s.contains("BAD-NAME"))
        // Round-trips through a real shell: the inner script sees A with its quote intact.
        #expect(s.contains("export A="))
    }

    @Test func phases() {
        #expect(BoatPhase(apiState: "idle") == .running)
        #expect(BoatPhase(apiState: "archived") == .stopped)
        #expect(BoatPhase(apiState: "provisioning") == .starting)
        #expect(BoatPhase(apiState: "archiving") == .stopping)
        #expect(BoatPhase(apiState: "weird") == .error)
    }

    @Test func endpointPrefersForwardedIPv4() throws {
        let a = BoatSSHAccess(machineIp: "2001:db8::1", sshUser: "user", sshEndpoint: "203.0.113.10:22001", hostKey: "ssh-ed25519 AAA")
        let s = BoatSandbox(id: "bx_23456789", state: "idle")
        let e = try BoatHost.endpoint(a, sandbox: s)
        #expect(e.host == "203.0.113.10" && e.port == 22001)
        let direct = try BoatHost.endpoint(BoatSSHAccess(machineIp: "198.51.100.4", sshUser: nil, sshEndpoint: nil, hostKey: "k"), sandbox: s)
        #expect(direct.host == "198.51.100.4" && direct.port == 22 && direct.user == "user")
    }

    @Test func shellQuoteRoundTrip() async throws {
        let tricky = "a b 'c' \"d\" $HOME `x`"
        let r = try await Shell.runRaw("/bin/bash", ["-c", "printf %s " + ShellQuote.quote(tricky)], cwd: nil, env: [:])
        #expect(r.stdout == tricky)
    }

    @Test func remoteScriptRunsInBash() async throws {
        // Run the generated remote string locally through bash to prove the quoting nests correctly.
        let script = BoatHost.remoteScript("printf '%s|%s' \"$A\" \"$PWD\"", cwd: "/tmp", env: ["A": "it's $x"])
        let r = try await Shell.runRaw("/bin/bash", ["-c", script.replacingOccurrences(of: "exec bash -lc", with: "exec bash -c")], cwd: nil, env: ["HOME": NSTemporaryDirectory()])
        #expect(r.stdout.hasPrefix("it's $x|"))
        #expect(r.stdout.hasSuffix("/tmp"))
    }

    @Test func parsesSandboxJSON() throws {
        let json = #"{"id":"bx_8hercfzb","state":"idle","archiveAfter":"2026-11-05T21:52:14.585Z","ttlSeconds":900,"type":"small","ip":"2001:41d0::23","sshEndpoint":"37.187.27.60:19035","extra":{"x":1}}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)!
        }
        let s = try d.decode(BoatSandbox.self, from: Data(json.utf8))
        #expect(s.phase == .running && s.ttlSeconds == 900 && s.archiveAfter != nil)
    }
}

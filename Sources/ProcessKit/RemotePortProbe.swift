import DQCore
import Foundation

/// One round trip that answers "what is listening on the remote machine, and which run owns it".
///
/// Each remote TaskRun writes its session id to `/tmp/domestique/runs/<key>.sid`; `ss -ltnp` gives
/// the pids behind every listening socket, and `ps` maps pids to sessions.
public enum RemotePortProbe {
    public struct Result: Sendable, Hashable {
        /// Every listening TCP port.
        public var listening: Set<Int>
        /// TaskRun.remoteKey -> ports its process tree listens on.
        public var byRun: [String: Set<Int>]
    }

    static let script = #"""
        d=/tmp/domestique/runs
        {
          for f in "$d"/*.sid; do [ -e "$f" ] || continue; printf 'S %s %s\n' "$(basename "$f" .sid)" "$(cat "$f")"; done
          ps -e -o pid=,sid= | awk '{print "P", $1, $2}'
          ss -ltnpH 2>/dev/null | sed 's/^/L /'
        } | awk '
        $1=="S" { run[$3]=$2; next }
        $1=="P" { sid[$2]=$3; next }
        $1=="L" {
          n=split($5, a, ":"); port=a[n]; print "A", port
          line=$0
          while (match(line, /pid=[0-9]+/)) {
            p=substr(line, RSTART+4, RLENGTH-4); line=substr(line, RSTART+RLENGTH)
            s=sid[p]; if (s != "" && (s in run)) print "R", run[s], port
          }
        }'
        """#

    public static func probe(_ host: any ExecutionHost) async throws -> Result {
        let r = try await host.runScript(script, cwd: "/tmp", check: true, label: "port probe")
        return parse(r.stdout)
    }

    static func parse(_ out: String) -> Result {
        var listening = Set<Int>()
        var byRun: [String: Set<Int>] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 2, f[0] == "A", let p = Int(f[1]) {
                listening.insert(p)
            } else if f.count == 3, f[0] == "R", let p = Int(f[2]) {
                byRun[String(f[1]), default: []].insert(p)
            }
        }
        return Result(listening: listening, byRun: byRun)
    }
}

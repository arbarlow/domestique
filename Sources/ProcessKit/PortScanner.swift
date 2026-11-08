import Darwin
import Foundation

/// Finds TCP ports that a process tree is listening on, using libproc (no `lsof` spawn).
public enum PortScanner {
    /// Listening TCP ports of `rootPID`, its descendants, and anything still in its process group.
    public static func listeningPorts(rootPID: pid_t) -> [Int] {
        var pids = Set(descendants(of: rootPID))
        pids.insert(rootPID)
        pids.formUnion(processGroupMembers(rootPID))
        var ports = Set<Int>()
        for pid in pids { ports.formUnion(listeningPorts(pid: pid)) }
        return ports.sorted()
    }

    /// All descendants (children, grandchildren, ...) by parent pid.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [pid]
        var seen: Set<pid_t> = [pid]
        while let current = queue.popLast() {
            for child in children(of: current) where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// True if anything accepts TCP connections on localhost:port (IPv4 or IPv6).
    public static func isPortListening(_ port: Int) -> Bool {
        connects(port: port, ipv6: false) || connects(port: port, ipv6: true)
    }

    // MARK: - libproc

    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let bytes = buffer.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), raw.baseAddress, Int32(raw.count))
            }
            if bytes <= 0 { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            if count >= capacity {
                capacity *= 4
                if capacity > 65536 { return buffer.filter { $0 > 0 } }
                continue
            }
            return buffer.prefix(count).filter { $0 > 0 }
        }
    }

    /// Members of the process group whose id is `pgid` (we spawn tasks as group leaders).
    static func processGroupMembers(_ pgid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Headroom in case the group grows between the two calls.
        size += 8 * MemoryLayout<kinfo_proc>.stride
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(n).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    static func listeningPorts(pid: pid_t) -> Set<Int> {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 16)
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
            guard r == size else { continue }
            let si = info.psi
            guard si.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let raw = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            let port = Int(UInt16(bigEndian: raw))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }

    // MARK: - connect probe

    static func connects(port: Int, ipv6: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
    }
}

/// Picks a block of ports for a new workspace.
///
/// Each kind of workspace has its own range so blocks never collide, even though the ones on this Mac
/// are handed out by the server and the cloud ones by the app.
public enum PortAllocator {
    public static let blockSize = 10
    /// Local worktrees (allocated by the server; keep in step with domestique's DefaultPortStart/End).
    public static let localRange = 41000...50999
    /// boat.dev sandboxes (their ports are forwarded to this Mac).
    public static let cloudRange = 51000...60999

    /// Lowest base in `range` (stepping by the block size) not in `used` whose ports are all free here.
    public static func allocate(used: Set<Int>, in range: ClosedRange<Int> = localRange) -> Int {
        var base = range.lowerBound
        while base + blockSize - 1 <= range.upperBound {
            if !used.contains(base), !(base..<(base + blockSize)).contains(where: { PortScanner.isPortListening($0) }) {
                return base
            }
            base += blockSize
        }
        return range.lowerBound
    }
}

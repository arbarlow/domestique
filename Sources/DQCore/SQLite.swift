import Foundation
import SQLite3

/// Minimal thread-safe SQLite wrapper (system libsqlite3, no dependencies).
/// One connection per process; WAL so several app instances can share the file.
public final class SQLiteDB: @unchecked Sendable {
    public enum Value: Sendable, Hashable {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)

        public var data: Data? {
            switch self {
            case .blob(let d): d
            case .text(let s): Data(s.utf8)
            default: nil
            }
        }
        public var string: String? {
            switch self {
            case .text(let s): s
            case .blob(let d): String(decoding: d, as: UTF8.self)
            default: nil
            }
        }
        public var int: Int64? { if case .int(let i) = self { i } else { nil } }
    }

    public struct Error: Swift.Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw Error(message: "Couldn't open database at \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 5_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: execution

    public func exec(_ sql: String) throws {
        try locked {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw Error(message: "\(msg) — \(sql.prefix(120))")
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        try locked {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(sql) }
            return Int(sqlite3_changes(db))
        }
    }

    public func query(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
        try locked {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var rows: [[Value]] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw error(sql) }
                let n = sqlite3_column_count(stmt)
                var row: [Value] = []
                row.reserveCapacity(Int(n))
                for i in 0..<n { row.append(column(stmt, i)) }
                rows.append(row)
            }
            return rows
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try exec("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try exec("COMMIT")
                return result
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Changes when *another* connection (another app instance) commits. Cheap to poll.
    public var dataVersion: Int64 {
        (try? query("PRAGMA data_version").first?.first?.int) ?? 0
    }

    // MARK: helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error(sql) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), Self.transient) }
            }
        }
        return stmt
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> Value {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: p, count: n))
        default: return .null
        }
    }

    private func error(_ sql: String) -> Error {
        Error(message: "\(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(120))")
    }
}

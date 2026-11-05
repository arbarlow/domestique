import Foundation

/// A tiny line-oriented terminal model for task logs.
///
/// Dev servers (Vite, Next, cargo, docker…) assume an interactive terminal and redraw recent lines:
/// `\r` to rewrite the current line, `ESC[1A` + `ESC[2K` to replace the previous one ("hmr update … (x4)"),
/// `ESC[J` to wipe a spinner block. A plain newline splitter turns each redraw into junk/blank lines.
/// This keeps the last `liveRows` rows editable: a redraw republishes the affected row under its existing
/// id, so the log view updates in place. Rows that scroll out of the live window are final.
/// Colour (SGR) sequences stay in the text for ANSI.parse; everything else is interpreted or dropped.
/// Absolute positioning (`ESC[H`, `ESC[2J`) is ignored: in a log, history matters more than a screen.
struct LogScreen {
    static let liveRows = 200
    static let maxRowBytes = 8_000

    struct Row {
        let id: Int
        var bytes: [UInt8] = []
    }

    private(set) var rows: [Row] = []
    private var cursor = 0
    /// Set by CR / LF / "column 1": the next write replaces the row instead of appending.
    private var replaceOnWrite = false
    private var dirty: Set<Int> = []
    private var removed: [Int] = []
    /// Dirty rows that scrolled out of the live window before being flushed.
    private var scrolledOut: [LogLine] = []
    private var state: EscState = .ground
    private let nextID: () -> Int

    private enum EscState {
        case ground
        case escape
        case csi([UInt8])
        case osc
        case oscEscape
        case skipOne
    }

    init(nextID: @escaping () -> Int = { LogLineIDs.next() }) {
        self.nextID = nextID
    }

    var hasChanges: Bool { !dirty.isEmpty || !removed.isEmpty || !scrolledOut.isEmpty }

    // MARK: input

    mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { step(b) }
    }

    private mutating func step(_ b: UInt8) {
        switch state {
        case .ground:
            ground(b)
        case .escape:
            switch b {
            case UInt8(ascii: "["): state = .csi([])
            case UInt8(ascii: "]"): state = .osc
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"): state = .skipOne
            default: state = .ground  // ESC 7/8/=/> etc: ignore
            }
        case .skipOne:
            state = .ground
        case .csi(var params):
            if b >= 0x40 && b <= 0x7E {
                state = .ground
                csi(final: b, params: params)
            } else if params.count < 64 {
                params.append(b)
                state = .csi(params)
            }
        case .osc:
            if b == 0x07 { state = .ground } else if b == 0x1B { state = .oscEscape }
        case .oscEscape:
            state = b == UInt8(ascii: "\\") ? .ground : .osc
        }
    }

    private mutating func ground(_ b: UInt8) {
        switch b {
        case 0x1B:
            state = .escape
        case 0x0A:  // LF (the tty's onlcr turns \n into \r\n anyway)
            ensureRow()
            dirty.insert(rows[cursor].id)  // blank lines are real lines
            cursor += 1
            ensureRow()
            replaceOnWrite = true
        case 0x0D:
            replaceOnWrite = true
        case 0x08:  // backspace
            ensureRow()
            if !replaceOnWrite, !rows[cursor].bytes.isEmpty {
                rows[cursor].bytes.removeLast()
                dirty.insert(rows[cursor].id)
            }
        case 0x09:
            write([b])
        case 0x00..<0x20, 0x7F:
            break  // BEL and other C0 controls
        default:
            write([b])
        }
    }

    private mutating func csi(final: UInt8, params raw: [UInt8]) {
        // Private-mode sequences (ESC[?25l cursor hide, etc.) carry no log content.
        if raw.first == UInt8(ascii: "?") || raw.first == UInt8(ascii: ">") { return }
        let params = String(decoding: raw, as: UTF8.self)
        let first = Int(params.split(separator: ";").first ?? "") ?? 0
        let n = max(1, first)
        switch final {
        case UInt8(ascii: "m"):  // SGR: keep for colours
            write([0x1B, UInt8(ascii: "[")] + raw + [final])
        case UInt8(ascii: "A"):
            moveUp(n)
        case UInt8(ascii: "F"):
            moveUp(n)
            replaceOnWrite = true
        case UInt8(ascii: "B"):
            moveDown(n)
        case UInt8(ascii: "E"):
            moveDown(n)
            replaceOnWrite = true
        case UInt8(ascii: "G"):
            if first <= 1 { replaceOnWrite = true }
        case UInt8(ascii: "K"):
            // 0: to end of line (a no-op unless we're at column 1), 1/2: whole line (approx.).
            if first != 0 || replaceOnWrite { clearRow() }
        case UInt8(ascii: "J"):
            if first == 0 {
                // Erase below: drop rows under the cursor (spinner / progress blocks).
                if cursor + 1 < rows.count {
                    for row in rows[(cursor + 1)...] {
                        removed.append(row.id)
                        dirty.remove(row.id)
                    }
                    rows.removeSubrange((cursor + 1)...)
                }
                if replaceOnWrite { clearRow() }
            }
        // H/f/d (absolute position), S/T (scroll), 2J (clear screen): ignored on purpose.
        default:
            break
        }
    }

    // MARK: editing

    private mutating func ensureRow() {
        while rows.count <= cursor { rows.append(Row(id: nextID())) }
        trim()
    }

    private mutating func write(_ bytes: [UInt8]) {
        ensureRow()
        if replaceOnWrite {
            replaceOnWrite = false
            if !rows[cursor].bytes.isEmpty {
                rows[cursor].bytes.removeAll(keepingCapacity: true)
            }
        }
        if rows[cursor].bytes.count + bytes.count <= Self.maxRowBytes {
            rows[cursor].bytes.append(contentsOf: bytes)
        }
        dirty.insert(rows[cursor].id)
    }

    private mutating func clearRow() {
        ensureRow()
        rows[cursor].bytes.removeAll(keepingCapacity: true)
        dirty.insert(rows[cursor].id)
        replaceOnWrite = false
    }

    private mutating func moveUp(_ n: Int) {
        cursor = max(0, cursor - n)
    }

    private mutating func moveDown(_ n: Int) {
        cursor += n
        ensureRow()
    }

    private mutating func trim() {
        let excess = rows.count - Self.liveRows
        guard excess > 0 else { return }
        for row in rows.prefix(excess) where dirty.contains(row.id) {
            dirty.remove(row.id)
            scrolledOut.append(LogLine(id: row.id, raw: String(decoding: row.bytes, as: UTF8.self)))
        }
        rows.removeFirst(excess)
        cursor = max(0, cursor - excess)
    }

    // MARK: output

    /// Rows created or changed since the last call (in display order), and ids that were erased.
    mutating func takeChanges() -> (upserts: [LogLine], removed: [Int]) {
        var upserts = scrolledOut
        scrolledOut.removeAll()
        if !dirty.isEmpty {
            for row in rows where dirty.contains(row.id) {
                upserts.append(LogLine(id: row.id, raw: String(decoding: row.bytes, as: UTF8.self)))
            }
            dirty.removeAll(keepingCapacity: true)
        }
        let gone = removed
        removed.removeAll()
        return (upserts, gone)
    }
}

import Foundation

public enum ANSIColor: Int, Sendable, Hashable, CaseIterable {
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
}

public struct ANSISegment: Sendable, Hashable {
    public var text: String
    public var foreground: ANSIColor?
    public var bold: Bool
    public var dim: Bool

    public init(text: String, foreground: ANSIColor? = nil, bold: Bool = false, dim: Bool = false) {
        self.text = text
        self.foreground = foreground
        self.bold = bold
        self.dim = dim
    }
}

/// Minimal SGR parser for log rendering. Cursor movement / erase sequences and OSC are dropped.
public enum ANSI {
    public static func strip(_ s: String) -> String {
        // Fast path: no escapes or control characters.
        if !s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) { return s }
        return parse(s).map(\.text).joined()
    }

    public static func parse(_ line: String) -> [ANSISegment] {
        var segments: [ANSISegment] = []
        var style = Style()
        var text = String.UnicodeScalarView()
        let scalars = Array(line.unicodeScalars)
        var i = 0

        func flush() {
            guard !text.isEmpty else { return }
            let s = String(text)
            if let last = segments.last, last.foreground == style.fg, last.bold == style.bold, last.dim == style.dim {
                segments[segments.count - 1].text += s
            } else {
                segments.append(ANSISegment(text: s, foreground: style.fg, bold: style.bold, dim: style.dim))
            }
            text = String.UnicodeScalarView()
        }

        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" {
                guard i + 1 < scalars.count else { break }
                let next = scalars[i + 1]
                if next == "[" {
                    // CSI: params (0x30–0x3F), intermediates (0x20–0x2F), final (0x40–0x7E).
                    var j = i + 2
                    var params = ""
                    while j < scalars.count, (0x30...0x3F).contains(scalars[j].value) {
                        params.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    while j < scalars.count, (0x20...0x2F).contains(scalars[j].value) { j += 1 }
                    guard j < scalars.count else { i = scalars.count; break }
                    let final = scalars[j]
                    if final == "m" {
                        flush()
                        style.apply(sgr: params)
                    }
                    i = j + 1
                } else if next == "]" {
                    // OSC: terminated by BEL or ST (ESC \).
                    var j = i + 2
                    while j < scalars.count {
                        if scalars[j] == "\u{07}" { j += 1; break }
                        if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                        j += 1
                    }
                    i = j
                } else if next == "(" || next == ")" || next == "#" {
                    i += 3  // charset designation, e.g. ESC ( B
                } else {
                    i += 2  // two-char escape (ESC =, ESC >, ESC 7 ...)
                }
                continue
            }
            if c.value < 0x20 && c != "\t" || c.value == 0x7F {
                i += 1  // drop other control characters (\r, BEL, backspace...)
                continue
            }
            text.append(c)
            i += 1
        }
        flush()
        return segments
    }

    struct Style {
        var fg: ANSIColor?
        var bold = false
        var dim = false

        mutating func apply(sgr: String) {
            let codes = sgr.isEmpty ? [0] : sgr.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var k = 0
            while k < codes.count {
                let code = codes[k]
                switch code {
                case 0:
                    self = Style()
                case 1: bold = true
                case 2: dim = true
                case 22:
                    bold = false
                    dim = false
                case 30...37: fg = ANSIColor(rawValue: code - 30)
                case 90...97: fg = ANSIColor(rawValue: code - 90 + 8)
                case 39: fg = nil
                case 38, 48:
                    // Extended colour: 38;5;n or 38;2;r;g;b. Background (48) is consumed and ignored.
                    if k + 1 < codes.count, codes[k + 1] == 5, k + 2 < codes.count {
                        if code == 38 { fg = ANSI.color256(codes[k + 2]) }
                        k += 2
                    } else if k + 1 < codes.count, codes[k + 1] == 2, k + 4 < codes.count {
                        if code == 38 { fg = ANSI.colorRGB(codes[k + 2], codes[k + 3], codes[k + 4]) }
                        k += 4
                    }
                default: break
                }
                k += 1
            }
        }
    }

    static func color256(_ n: Int) -> ANSIColor? {
        switch n {
        case 0...15: return ANSIColor(rawValue: n)
        case 16...231:
            let v = n - 16
            let r = v / 36, g = (v / 6) % 6, b = v % 6
            let idx = (r >= 3 ? 1 : 0) + (g >= 3 ? 2 : 0) + (b >= 3 ? 4 : 0)
            let bright = max(r, g, b) >= 4
            if idx == 0 { return max(r, g, b) >= 2 ? .brightBlack : .black }
            return ANSIColor(rawValue: idx + (bright ? 8 : 0))
        case 232...255:
            return n < 244 ? .brightBlack : .white
        default: return nil
        }
    }

    static func colorRGB(_ r: Int, _ g: Int, _ b: Int) -> ANSIColor {
        let idx = (r >= 128 ? 1 : 0) + (g >= 128 ? 2 : 0) + (b >= 128 ? 4 : 0)
        let bright = max(r, g, b) >= 200
        if idx == 0 { return max(r, g, b) >= 64 ? .brightBlack : .black }
        return ANSIColor(rawValue: idx + (bright ? 8 : 0))!
    }
}

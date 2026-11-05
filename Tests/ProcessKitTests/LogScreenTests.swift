import Testing

@testable import ProcessKit

@Suite struct LogScreenTests {
    /// Feeds chunks, folds the published edits like TaskRun does, returns visible text lines.
    private func render(_ chunks: [String]) -> [String] {
        var counter = 0
        var screen = LogScreen(nextID: {
            counter += 1
            return counter
        })
        var lines: [LogLine] = []
        for chunk in chunks {
            screen.feed(Array(chunk.utf8))
            let changes = screen.takeChanges()
            for l in changes.upserts {
                if let i = lines.firstIndex(where: { $0.id == l.id }) { lines[i] = l } else { lines.append(l) }
            }
            lines.removeAll { changes.removed.contains($0.id) }
        }
        return lines.map(\.text)
    }

    @Test func plainLinesAndBlankLines() {
        #expect(render(["a\r\n", "\r\n", "b\r\n"]) == ["a", "", "b"])
    }

    @Test func viteRepeatCounterRewritesPreviousLine() {
        // Vite: on a repeated message it moves up one line, clears it, and reprints with "(xN)".
        let first = "\u{1B}[32m8:14:02 PM [vite]\u{1B}[39m hmr update /src/styles/globals.css\r\n"
        let again = "\u{1B}[1A\u{1B}[2K8:14:02 PM [vite] hmr update /src/styles/globals.css (x2)\r\n"
        let thrice = "\u{1B}[1A\u{1B}[2K\u{1B}[G8:14:02 PM [vite] hmr update /src/styles/globals.css (x3)\r\n"
        let out = render(["ready\r\n", first, again, thrice])
        #expect(out == ["ready", "8:14:02 PM [vite] hmr update /src/styles/globals.css (x3)"])
    }

    @Test func carriageReturnProgressBarKeepsOneLine() {
        #expect(render(["10%", "\r20%", "\r100%\r\n", "done\r\n"]) == ["100%", "done"])
    }

    @Test func eraseBelowRemovesSpinnerBlock() {
        let out = render(["start\r\n", "⠋ building\r\n⠋ step 2\r\n", "\u{1B}[2A\u{1B}[J", "built\r\n"])
        #expect(out == ["start", "built"])
    }

    @Test func coloursKeptControlSequencesDropped() {
        var screen = LogScreen(nextID: { 1 })
        screen.feed(Array("\u{1B}[?25l\u{1B}]0;title\u{07}\u{1B}[31merror\u{1B}[0m\r\n".utf8))
        let line = screen.takeChanges().upserts.first
        #expect(line?.text == "error")
        #expect(line?.segments.first?.foreground == .red)
    }

    @Test func clearScreenDoesNotEraseHistory() {
        #expect(render(["one\r\n", "\u{1B}[2J\u{1B}[3J\u{1B}[H", "two\r\n"]) == ["one", "two"])
    }
}

import Foundation
import Testing

@testable import DQCore

@Suite struct DotEnvTests {
    private func values(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: DotEnv.parse(text).map { ($0.key, $0.value) })
    }

    @Test func plainValuesCommentsAndExport() {
        let v = values("""
            # a comment
            A=1

            export B = two words  # trailing
            C=has#hash
            EMPTY=
            not an assignment
            BAD-NAME=x
            """)
        #expect(v == ["A": "1", "B": "two words", "C": "has#hash", "EMPTY": ""])
    }

    @Test func quotes() {
        let v = values(#"""
            S='lit\n $X # y'
            D="a\nb \"q\" \\ $X"
            B=`tick`
            T="x" # comment
            OPEN="never closed
            """#)
        #expect(v["S"] == #"lit\n $X # y"#)
        #expect(v["D"] == "a\nb \"q\" \\ $X")
        #expect(v["B"] == "tick")
        #expect(v["T"] == "x")
        #expect(v["OPEN"] == "\"never closed")
    }

    @Test func multilineAndWindowsLineEndings() {
        let v = values("KEY=\"line1\nline2\"\r\nNEXT=b\r\n")
        #expect(v == ["KEY": "line1\nline2", "NEXT": "b"])
    }

    @Test func lastDuplicateWinsInFirstPosition() {
        #expect(DotEnv.parse("A=1\nB=2\nA=3") == [EnvVariable(key: "A", value: "3"), EnvVariable(key: "B", value: "2")])
    }

    @Test func shellScriptRoundTripsThroughBash() async throws {
        let value = "it's $HOME `x`\nnext \"line\""
        let script = DotEnv.shellScript([EnvVariable(key: "A", value: value), EnvVariable(key: "B", value: "2")])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script + "\nprintf '%s|%s' \"$A\" \"$B\""]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(String(data: data, encoding: .utf8) == "\(value)|2")
    }
}

import Foundation
import Testing

@testable import DQCore

@Suite struct ShipPromptsTests {
    @Test func defaultsFillPlaceholders() {
        let ctx = ShipPromptContext(base: "main", branch: "alex/x", prNumber: 12, checks: ["make test"])
        let settings = AppSettings()
        for kind in ShipPromptKind.allCases {
            let text = settings.shipPrompt(kind, ctx)
            #expect(!text.contains("{"), "\(kind) left a placeholder: \(text)")
        }
        #expect(settings.shipPrompt(.push, ctx).contains("to update PR #12"))
        #expect(settings.shipPrompt(.trunk, ctx).contains("`make test`"))
        #expect(settings.shipPrompt(.trunk, ctx).contains("git push origin HEAD:main"))
    }

    @Test func emptyOptionalPlaceholders() {
        let ctx = ShipPromptContext(base: "main", branch: "b")
        #expect(ShipPrompts.render("push{pr}.{checks}", ctx) == "push.")
    }

    @Test func overridesAndReset() {
        var s = AppSettings()
        s.setShipPromptTemplate(.createPR, "Open a PR into {base}")
        #expect(s.isShipPromptCustomized(.createPR))
        #expect(s.shipPrompt(.createPR, ShipPromptContext(base: "trunk", branch: "b")) == "Open a PR into trunk")
        s.setShipPromptTemplate(.createPR, ShipPromptKind.createPR.defaultTemplate)
        #expect(!s.isShipPromptCustomized(.createPR))
        s.setShipPromptTemplate(.trunk, "x")
        s.setShipPromptTemplate(.trunk, "   ")
        #expect(s.shipPrompts == nil)
    }

    @Test func oldSettingsStillDecode() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "shipPrompts")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.shipPrompts == nil)
    }
}

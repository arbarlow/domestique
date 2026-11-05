import DQCore
import Foundation
import Testing

@testable import GitHubKit

@Suite struct AppReleaseTests {
    private func release(
        tag: String, name: String = "", draft: Bool = false, prerelease: Bool = false, assets: [String] = ["Domestique.zip", "Domestique.zip.sha256"]
    ) -> JSONValue {
        .object([
            "tag_name": .string(tag), "name": .string(name), "draft": .bool(draft), "prerelease": .bool(prerelease),
            "body": .string("notes"), "html_url": .string("https://github.com/o/r/releases/tag/\(tag)"),
            "published_at": .string("2026-11-05T21:27:21Z"),
            "assets": .array(assets.enumerated().map { i, n in .object(["id": .number(Double(100 + i)), "name": .string(n)]) }),
        ])
    }

    @Test func parsesBuildsNewestFirstAndSkipsUnusable() {
        let json: JSONValue = .array([
            release(tag: "build-3", name: "Add auto-updater"),
            release(tag: "build-10", name: "Fix sidebar"),
            release(tag: "build-11", draft: true),
            release(tag: "build-12", prerelease: true),
            release(tag: "v1.0"),
            release(tag: "build-9", assets: ["other.zip"]),
            release(tag: "build-4"),
        ])
        let releases = AppRelease.parse(json)
        #expect(releases.map(\.build) == [10, 4, 3])
        #expect(releases[0].title == "Fix sidebar")
        #expect(releases[1].title == "build-4")  // untitled falls back to the tag
        #expect(releases[0].zipAssetID == 100)
        #expect(releases[0].checksumAssetID == 101)
        #expect(releases[0].publishedAt != nil)
    }

    @Test func newerThanCurrent() {
        let all = [3, 10, 4].map { AppRelease(build: $0, tag: "build-\($0)", title: "", zipAssetID: $0) }
        #expect(AppRelease.newer(than: 4, in: all).map(\.build) == [10])
        #expect(AppRelease.newer(than: 10, in: all).isEmpty)
    }

    @Test func buildFromTag() {
        #expect(AppRelease.build(fromTag: "build-42") == 42)
        #expect(AppRelease.build(fromTag: "build-") == nil)
        #expect(AppRelease.build(fromTag: "v42") == nil)
    }

    @Test func checksumLine() {
        let hex = String(repeating: "ab", count: 32)
        #expect(AppRelease.parseChecksum("\(hex)  Domestique.zip\n") == hex)
        #expect(AppRelease.parseChecksum(hex.uppercased()) == hex)
        #expect(AppRelease.parseChecksum("nothex  Domestique.zip") == nil)
        #expect(AppRelease.parseChecksum("") == nil)
    }
}

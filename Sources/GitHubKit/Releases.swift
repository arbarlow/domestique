import DQCore
import Foundation

/// One CI build of Domestique, published as a GitHub Release tagged `build-<n>` (see .github/workflows/release.yml).
public struct AppRelease: Sendable, Hashable, Identifiable {
    public var id: Int { build }
    /// CI run number. Matches the app's CFBundleVersion.
    public var build: Int
    public var tag: String
    /// Release title: the subject of the commit that triggered the build (the squashed PR title).
    public var title: String
    public var notes: String
    public var htmlURL: URL?
    public var publishedAt: Date?
    public var zipAssetID: Int
    public var checksumAssetID: Int?

    public init(
        build: Int, tag: String, title: String, notes: String = "", htmlURL: URL? = nil, publishedAt: Date? = nil,
        zipAssetID: Int, checksumAssetID: Int? = nil
    ) {
        self.build = build
        self.tag = tag
        self.title = title
        self.notes = notes
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.zipAssetID = zipAssetID
        self.checksumAssetID = checksumAssetID
    }

    public static let zipName = "Domestique.zip"
    public static let checksumName = "Domestique.zip.sha256"

    /// `build-42` → 42.
    public static func build(fromTag tag: String) -> Int? {
        guard tag.hasPrefix("build-") else { return nil }
        return Int(tag.dropFirst("build-".count))
    }

    /// Parses the REST `GET /repos/{slug}/releases` array, keeping published builds that ship the app zip, newest first.
    public static func parse(_ json: JSONValue) -> [AppRelease] {
        let iso = ISO8601DateFormatter()
        let releases: [AppRelease] = (json.array ?? []).compactMap { r in
            guard r["draft"]?.bool != true, r["prerelease"]?.bool != true,
                let tag = r["tag_name"]?.string, let build = build(fromTag: tag)
            else { return nil }
            let assets = r["assets"]?.array ?? []
            func assetID(_ name: String) -> Int? { assets.first { $0["name"]?.string == name }?["id"]?.int }
            guard let zip = assetID(zipName) else { return nil }
            let name = r["name"]?.string ?? ""
            return AppRelease(
                build: build, tag: tag, title: name.isEmpty ? tag : name, notes: r["body"]?.string ?? "",
                htmlURL: r["html_url"]?.string.flatMap(URL.init(string:)),
                publishedAt: r["published_at"]?.string.flatMap(iso.date(from:)),
                zipAssetID: zip, checksumAssetID: assetID(checksumName))
        }
        return releases.sorted { $0.build > $1.build }
    }

    /// Builds newer than `current`, newest first.
    public static func newer(than current: Int, in releases: [AppRelease]) -> [AppRelease] {
        releases.filter { $0.build > current }.sorted { $0.build > $1.build }
    }

    /// First token of a `shasum -a 256` line ("<hex>  Domestique.zip").
    public static func parseChecksum(_ text: String) -> String? {
        let token = text.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() }
        guard let token, token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        return token
    }
}

extension GitHubClient {
    /// Release builds for `slug`, newest first. Uses the user's GitHub token when there is one (it lifts the
    /// 60/hour anonymous rate limit), otherwise asks anonymously.
    public func appReleases(slug: String) async throws -> [AppRelease] {
        let url = URL(string: "https://api.github.com/repos/\(slug)/releases?per_page=30")!
        let (data, http) = try await sendOptionallyAuthed(URLRequest(url: url))
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        return AppRelease.parse(try JSONValue.parse(data))
    }

    /// Downloads a release asset to a temporary file and returns its location (caller moves or deletes it).
    public func downloadReleaseAsset(slug: String, id: Int) async throws -> URL {
        // The API answers with a 302 to a pre-signed object-store URL. Our session doesn't follow redirects, which is
        // what we want here: the signed URL must be fetched *without* our Authorization header or it gets rejected.
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(slug)/releases/assets/\(id)")!)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, http) = try await sendOptionallyAuthed(req)
        if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
            let signed = URL(string: location)
        {
            let (file, response) = try await URLSession.shared.download(from: signed)
            guard let r = response as? HTTPURLResponse, (200..<300).contains(r.statusCode) else {
                try? FileManager.default.removeItem(at: file)
                throw GitHubError(message: "Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            return file
        }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return file
    }

    private func sendOptionallyAuthed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if let tok = try? await token() { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError(message: "Unexpected response") }
        return (data, http)
    }
}

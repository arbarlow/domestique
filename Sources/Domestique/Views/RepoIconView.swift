import AppKit
import DQCore
import SwiftUI

/// A repository's icon: monogram, SF Symbol, emoji or image, on a rounded tile.
struct RepoIconView: View {
    let repo: Repository
    var size: CGFloat = 18

    var body: some View {
        let icon = repo.icon ?? RepoIcon(kind: .monogram)
        let radius = size * 0.28
        Group {
            switch icon.kind {
            case .monogram:
                Text(String(repo.title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: radius).fill(RepoIconStyle.color(icon, name: repo.name)))
            case .symbol:
                Image(systemName: icon.symbol ?? "folder.fill")
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: radius).fill(RepoIconStyle.color(icon, name: repo.name)))
            case .emoji:
                Text(icon.emoji ?? "📁")
                    .font(.system(size: size * 0.72))
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: radius).fill(Theme.hover))
            case .image:
                if let file = icon.imageFile, let image = RepoIconStore.image(file) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: radius))
                        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline))
                } else {
                    RepoIconView(repo: withoutIcon, size: size)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var withoutIcon: Repository {
        var r = repo
        r.icon = nil
        return r
    }
}

enum RepoIconStyle {
    static let palette: [String] = [
        "#5E5CE6", "#0A84FF", "#30B0C7", "#34C759", "#A2845E", "#FF9F0A", "#FF6B3D", "#FF375F", "#BF5AF2", "#3A3A3C",
    ]

    static let symbols: [String] = [
        "bicycle", "figure.run", "bolt.fill", "flame.fill", "leaf.fill", "cube.fill", "shippingbox.fill", "globe",
        "server.rack", "cpu", "terminal.fill", "hammer.fill", "wrench.and.screwdriver.fill", "paintbrush.fill",
        "chart.bar.fill", "heart.fill", "star.fill", "sparkles", "cloud.fill", "lock.fill", "gamecontroller.fill",
        "music.note", "camera.fill", "book.fill", "graduationcap.fill", "cart.fill", "creditcard.fill",
        "envelope.fill", "map.fill", "house.fill", "airplane", "iphone",
    ]

    static func color(_ icon: RepoIcon, name: String) -> Color {
        if let hex = icon.colorHex, let c = Color(hex: hex) { return c }
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hex: palette[h % palette.count]) ?? .gray
    }
}

/// Icon images live in Application Support/Domestique/icons, normalised to 128px PNGs.
@MainActor
enum RepoIconStore {
    private static var cache: [String: NSImage] = [:]

    static func image(_ file: String) -> NSImage? {
        if let hit = cache[file] { return hit }
        guard let image = NSImage(contentsOf: Paths.icons.appendingPathComponent(file)) else { return nil }
        cache[file] = image
        return image
    }

    /// Resizes to 128×128 and stores it; returns the new file name.
    static func importImage(_ source: NSImage) -> String? {
        let side: CGFloat = 128
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Aspect-fill into the square.
        let s = source.size
        let scale = max(side / max(s.width, 1), side / max(s.height, 1))
        let w = s.width * scale
        let h = s.height * scale
        source.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let file = "\(UUID().uuidString).png"
        Paths.ensure(Paths.icons)
        do {
            try png.write(to: Paths.icons.appendingPathComponent(file))
            return file
        } catch {
            return nil
        }
    }

    static func importFile(_ url: URL) -> String? {
        NSImage(contentsOf: url).flatMap(importImage)
    }

    /// Owner avatar for GitHub remotes (org or user).
    static func githubAvatar(slug: String) async -> String? {
        let owner = slug.split(separator: "/").first.map(String.init) ?? slug
        guard let url = URL(string: "https://github.com/\(owner).png?size=256"),
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let image = NSImage(data: data)
        else { return nil }
        return importImage(image)
    }

    /// Likely app icons / logos tracked in the repo, best first.
    static func candidates(in repoPath: String) async -> [String] {
        guard let result = try? await Shell.run("git", ["ls-files"], cwd: repoPath) else { return [] }
        let names: Set<String> = [
            "favicon.png", "apple-touch-icon.png", "icon.png", "logo.png", "ic_launcher.png", "icon-512.png",
            "android-chrome-512x512.png", "icon-192.png", "logo-512.png", "app-icon.png", "appicon.png",
        ]
        var scored: [(String, Int)] = []
        for path in result.stdout.split(separator: "\n").map(String.init) {
            let lower = path.lowercased()
            let file = (lower as NSString).lastPathComponent
            guard lower.hasSuffix(".png") || lower.hasSuffix(".icns") else { continue }
            var score = 0
            if lower.contains("appicon.appiconset/") { score = 3 }
            else if names.contains(file) { score = 2 }
            else if file.contains("logo") || file.hasPrefix("icon") { score = 1 }
            guard score > 0 else { continue }
            if lower.contains("node_modules/") || lower.contains("/test") { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: repoPath + "/" + path)[.size] as? Int) ?? 0
            scored.append((path, score * 10_000_000 + size))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            .sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }
}

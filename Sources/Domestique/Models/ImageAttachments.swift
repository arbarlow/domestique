import AgentKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns dropped / picked images into attachments the agents accept.
///
/// Claude takes PNG, JPEG, GIF and WebP up to ~5 MB base64 and 8000 px a side (and downsamples
/// anything over ~1.5k px anyway), so TIFF/HEIC/etc. and full-screen retina captures get
/// re-encoded and scaled down here rather than failing the turn.
@MainActor
enum ImageAttachments {
    static let acceptedDropTypes: [UTType] = [.fileURL, .image]

    private static let passthrough: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    private static let maxBytes = 3_750_000  // ≈ 5 MB once base64-encoded
    private static let maxEdge = 2576

    static func load(_ providers: [NSItemProvider]) async -> [AgentAttachment] {
        var out: [AgentAttachment] = []
        for p in providers {
            if let a = await load(p) { out.append(a) }
        }
        return out
    }

    static func load(urls: [URL]) -> [AgentAttachment] {
        urls.compactMap(attachment(fileURL:))
    }

    // MARK: Providers

    private static func load(_ provider: NSItemProvider) async -> AgentAttachment? {
        // Finder / screenshot thumbnail / most apps: a file on disk.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            let url = await fileURL(from: provider),
            let a = attachment(fileURL: url)
        {
            return a
        }
        // Browsers, Preview, Photos etc.: raw image bytes, no file.
        let type = provider.registeredTypeIdentifiers.lazy.compactMap(UTType.init).first { $0.conforms(to: .image) }
        guard let type, let data = await data(from: provider, type: type) else { return nil }
        let base = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "image"
        return attachment(data: data, type: type, filename: base)
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                cont.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(for: type) { data, _ in cont.resume(returning: data) }
        }
    }

    // MARK: Normalising

    private static func attachment(fileURL url: URL) -> AgentAttachment? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return attachment(data: data, type: type, filename: url.deletingPathExtension().lastPathComponent)
    }

    private static func attachment(data: Data, type: UTType, filename base: String) -> AgentAttachment? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let mime = type.preferredMIMEType ?? ""
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        if passthrough.contains(mime), data.count <= maxBytes, max(w, h) <= maxEdge {
            return AgentAttachment(data: data, mediaType: mime, filename: base + "." + (type.preferredFilenameExtension ?? "png"))
        }

        // Re-encode: decode (honouring EXIF orientation), cap the long edge, PNG, else JPEG if still too big.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h, 1), maxEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if let png = encode(image, as: .png), png.count <= maxBytes {
            return AgentAttachment(data: png, mediaType: "image/png", filename: base + ".png")
        }
        guard let jpeg = encode(image, as: .jpeg, quality: 0.85) else { return nil }
        return AgentAttachment(data: jpeg, mediaType: "image/jpeg", filename: base + ".jpg")
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

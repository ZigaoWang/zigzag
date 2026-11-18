import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image file you chose as a tab's, pinned page's or favorite's icon (#303), kept as a square PNG in Zigzag's data
/// folder (`Page Icons`), so it stays when the original moves. The icon string is `image:<file name>`, kept where an
/// SF Symbol's name or an emoji is (`IconChoice`).
///
/// SVG and the web's own bitmap kinds are read by the sandboxed picture helper (`SafePictures`), which has no network
/// and no files, so an SVG's scripts never run and its links to other files are never followed. A PDF goes to the PDF
/// helper. HEIC and ICNS, which neither takes, are read here, as a space's background is.
nonisolated enum PageImageIcon {
    static let prefix = "image:"
    /// Larger files are turned away: an icon never needs more.
    static let maxBytes = 1024 * 1024
    /// Pixels across the kept PNG: 3x the largest place an icon shows (a favorite's tile, 18 pt at the largest text).
    static let side = 128

    /// What the open panel offers.
    static let types: [UTType] = [.svg, .png, .jpeg, .heic, .pdf, .icns]

    enum Failure: Error, Equatable {
        case tooLarge
        case unreadable
    }

    static var folder: URL { Paths.directory("Page Icons") }

    static func isImage(_ icon: String) -> Bool { name(of: icon) != nil }

    /// The kept file's name in an icon string, if it's one of these.
    static func name(of icon: String) -> String? {
        guard icon.hasPrefix(prefix) else { return nil }
        let name = String(icon.dropFirst(prefix.count))
        return isOwnName(name) ? name : nil
    }

    /// Copies the image at `source` into `folder` as a square PNG and gives its icon string.
    static func store(_ source: URL, in folder: URL = folder) async throws(Failure) -> String {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > maxBytes { throw .tooLarge }
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { throw .unreadable }
        return try await store(data, in: folder)
    }

    static func store(_ data: Data, in folder: URL = folder) async throws(Failure) -> String {
        guard data.count <= maxBytes else { throw .tooLarge }
        guard let picture = await read(data), let square = square(picture),
              let png = NSBitmapImageRep(cgImage: square).representation(using: .png, properties: [:]) else { throw .unreadable }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        guard (try? png.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { throw .unreadable }
        return prefix + name
    }

    /// The picture in some bytes, at most `side` pixels across.
    static func read(_ data: Data) async -> CGImage? {
        if PictureFormat.sniff(data) != nil { return await SafePictures.shared.decode(data, maxSide: side)?.image }
        if data.starts(with: Array("%PDF-".utf8)) { return await readPDF(data) }
        return readLocalBitmap(data)
    }

    /// HEIC or ICNS, only as what the bytes say they are.
    private static func readLocalBitmap(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.heic, .heif, .icns].contains(where: { $0.identifier == type }),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        // An ICNS holds several sizes; ImageIO's first is its largest.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A PDF's first page, drawn to fit `side` by the sandboxed PDF helper (`SafePDF`), as every PDF is.
    @MainActor private static func readPDF(_ data: Data) async -> CGImage? {
        let pdf = SafePDF(data: data)
        defer { pdf.close() }
        guard let page = await pdf.open()?.pageSizes.first,
              page.width > 0, page.height > 0, page.width.isFinite, page.height.isFinite else { return nil }
        let scale = CGFloat(side) / max(page.width, page.height)
        return await pdf.render(page: 0, rect: CGRect(origin: .zero, size: page), scale: scale, dark: false)
    }

    /// The picture centered on a transparent square as wide as its longer side, so it's never stretched.
    static func square(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let s = max(w, h)
        guard let context = bitmap(width: s, height: s) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        return context.makeImage()
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The kept image for an icon string, in a square of `points`; nil when it isn't one or its file is gone.
    static func image(_ icon: String, points: CGFloat, in folder: URL = folder) -> NSImage? {
        guard let name = name(of: icon),
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: points, height: points)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Deletes every kept image that none of `references` names (the saved library and session, read as text) and
    /// that was made before `before`, so one chosen while this runs stays. Run as Zigzag starts: an icon taken away
    /// is kept until then, so ⌘Z can bring it back.
    static func prune(keepingNamesIn references: [Data], before: Date, in folder: URL = folder) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let text = references.map { String(decoding: $0, as: UTF8.self) }
        for file in files where isOwnName(file) && !text.contains(where: { $0.contains(file) }) {
            let url = folder.appendingPathComponent(file)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if made < before { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Only a plain `<UUID>.png` in the folder: an icon string can never name a path anywhere else.
    private static func isOwnName(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }
}

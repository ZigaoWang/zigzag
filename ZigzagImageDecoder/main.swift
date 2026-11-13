import AppKit
import ImageIO

// Zigzag's picture helper: reads the pictures websites send, in the App Sandbox with no network and no files, and
// hands back plain pixels (PictureService.swift). Only Zigzag itself can reach it: an XPC service bundled in the app
// is visible to that app alone.

/// Reads one picture into pixels.
enum PictureReader {
    static func read(_ data: Data, maxSide requested: Int) -> DecodedPicture? {
        let maxSide = min(max(requested, 1), PictureFormat.maxSide)
        guard let format = PictureFormat.sniff(data) else { return nil }
        if format == .svg { return readSVG(data, maxSide: maxSide) }
        return readBitmap(data, format: format, maxSide: maxSide)
    }

    private static func readBitmap(_ data: Data, format: PictureFormat, maxSide: Int) -> DecodedPicture? {
        guard let expected = format.imageIOType else { return nil }
        let options = [kCGImageSourceTypeIdentifierHint: expected, kCGImageSourceShouldCache: false] as CFDictionary
        // ImageIO must read it as the same kind the bytes said: a PNG name on a PDF's bytes is never read as a PDF.
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == expected else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // An icon file holds several sizes: the largest, scaled down to fit. A GIF's first frame.
        var sizes: [(index: Int, width: Int, height: Int)] = []
        for index in 0..<(format == .ico ? min(count, 64) : 1) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width * height <= PictureFormat.maxSourcePixels else { continue }
            sizes.append((index, width, height))
        }
        guard let pick = sizes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let thumbnail = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                         kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceShouldCacheImmediately: true,
                         kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, pick.index, thumbnail) else { return nil }
        let width = min(image.width, maxSide), height = min(image.height, maxSide)
        return pixels(width: width, height: height, pointWidth: Double(width), pointHeight: Double(height), isVector: false) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// An SVG, drawn by AppKit at its own size, scaled down to fit `maxSide`, or at `maxSide` when it has no size.
    private static func readSVG(_ data: Data, maxSide: Int) -> DecodedPicture? {
        guard let image = NSImage(data: data), !image.representations.isEmpty,
              // Only AppKit's SVG reader: whatever else NSImage could make of the bytes isn't drawn.
              image.representations.allSatisfy({ String(describing: type(of: $0)).localizedCaseInsensitiveContains("svg") }) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let scale = Double(maxSide) / max(size.width, size.height)
        let width = max(1, min(maxSide, Int((size.width * scale).rounded())))
        let height = max(1, min(maxSide, Int((size.height * scale).rounded())))
        return pixels(width: width, height: height, pointWidth: size.width, pointHeight: size.height, isVector: true) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws into a fresh RGBA bitmap and hands its bytes back.
    private static func pixels(width: Int, height: Int, pointWidth: Double, pointHeight: Double, isVector: Bool,
                               draw: (CGContext) -> Void) -> DecodedPicture? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        draw(context)
        guard let base = context.data else { return nil }
        let picture = DecodedPicture(pixels: Data(bytes: base, count: width * height * 4), width: width, height: height,
                                     pointWidth: pointWidth, pointHeight: pointHeight, isVector: isVector)
        return picture.isWellFormed ? picture : nil
    }
}

final class Decoder: NSObject, PictureDecoding {
    /// How long one picture may take. A decoder stuck past it (a picture made to hang it) ends the helper; Zigzag
    /// starts it again for the next one.
    static let limit: TimeInterval = 5

    func decode(_ data: Data, maxSide: Int, reply: @escaping @Sendable (DecodedPicture?) -> Void) {
        let done = Flag()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.limit) {
            if !done.isSet { exit(0) }
        }
        DispatchQueue.global(qos: .utility).async {
            let picture = autoreleasepool { PictureReader.read(data, maxSide: maxSide) }
            done.set()
            reply(picture)
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = PictureService.interface()
        connection.exportedObject = Decoder()
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

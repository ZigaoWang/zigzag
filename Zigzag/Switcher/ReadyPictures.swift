import AppKit

/// Page pictures made ready for the screen ahead of time, off the main thread: decoded, drawn in the window's colors
/// and no bigger than they're shown. Handed a page's picture as it is, Core Animation decodes it and converts its
/// colors on the main thread as it first draws it, which held the tab overview's first frame back by as much as a
/// tenth of a second, and every new picture cost a little more the next time.
enum ReadyPictures {
    /// How a picture shows: in a card, at most a desk card's width, or filling the page area as it flies.
    enum Size { case card, full }

    private final class Entry {
        let image: CGImage
        let full: Bool
        init(image: CGImage, full: Bool) {
            self.image = image
            self.full = full
        }
    }

    /// Kept on the picture itself, so a ready copy goes exactly when its picture does (the tab took a new one, or
    /// closed).
    nonisolated(unsafe) private static var key: UInt8 = 0
    private static func entry(of image: NSImage) -> Entry? { objc_getAssociatedObject(image, &key) as? Entry }

    /// The ready copy of `image`, if there's one big enough for `size`.
    static func copy(of image: NSImage, for size: Size) -> CGImage? {
        guard let entry = entry(of: image), size == .card || entry.full else { return nil }
        return entry.image
    }

    /// Whether `image` has a ready copy big enough for `size`.
    static func isReady(_ image: NSImage, for size: Size) -> Bool { copy(of: image, for: size) != nil }

    /// Makes ready copies of `images` for showing in `window`, off the main thread, all at once, then calls
    /// `completion` on the main thread. Their blankness is noted on the way, so asking it later costs nothing.
    static func prepare(_ images: [NSImage], for size: Size, in window: NSWindow?, completion: @escaping () -> Void) {
        var seen = Set<ObjectIdentifier>()
        let wanted = images.filter { !isReady($0, for: size) && seen.insert(ObjectIdentifier($0)).inserted }
        let sources = wanted.map { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard sources.contains(where: { $0 != nil }) else { completion(); return }
        let scale = window?.backingScaleFactor ?? 2
        let width = size == .full ? nil : Int(ceil(Tokens.Metric.deskCardMaxWidth * scale))
        let space = colorSpace(of: window)
        nonisolated(unsafe) let done = completion
        DispatchQueue.global(qos: .userInitiated).async {
            var made = [(CGImage, Bool)?](repeating: nil, count: sources.count)
            made.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let out = buffer
                DispatchQueue.concurrentPerform(iterations: sources.count) { i in
                    guard let source = sources[i], let image = render(source, width: width, in: space) else { return }
                    out[i] = (image, TabThumbnailView.isBlank(image))
                }
            }
            let results = made
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (i, picture) in wanted.enumerated() {
                        guard let (image, blank) = results[i] else { continue }
                        // Smaller than a card's picture, it's the whole of it, and good for flying too.
                        let entry = Entry(image: image, full: size == .full || image.width >= (sources[i]?.width ?? 0))
                        objc_setAssociatedObject(picture, &key, entry, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        TabThumbnailView.remember(picture, blank: blank)
                    }
                    done()
                }
            }
        }
    }

    /// The colors the window is drawn in, so Core Animation has nothing to convert; plain sRGB when it's another
    /// kind of space a bitmap can't be drawn in.
    private static func colorSpace(of window: NSWindow?) -> CGColorSpace {
        let space = (window?.colorSpace ?? window?.screen?.colorSpace ?? NSScreen.main?.colorSpace)?.cgColorSpace
        if let space, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// `source` decoded into a bitmap in `space`, `width` pixels across at most (nil: its own size), in the pixel
    /// order the screen uses. Drawn in bands at once, one per core, so even a whole page's picture is quick.
    nonisolated static func render(_ source: CGImage, width: Int?, in space: CGColorSpace) -> CGImage? {
        guard source.width > 0, source.height > 0 else { return nil }
        let w = min(width ?? source.width, source.width)
        let h = max(1, Int((CGFloat(source.height) * CGFloat(w) / CGFloat(source.width)).rounded()))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let space = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) != nil
            ? space : CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = (w * 4 + 63) / 64 * 64
        guard let data = CFDataCreateMutable(nil, bytesPerRow * h) else { return nil }
        CFDataSetLength(data, bytesPerRow * h)
        guard let base = CFDataGetMutableBytePtr(data) else { return nil }
        nonisolated(unsafe) let pixels = base
        let bands = max(1, min(ProcessInfo.processInfo.activeProcessorCount, h / 96))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            // Rows run down from the picture's top; each band draws the whole picture, placed so its own rows land.
            let top = band * h / bands, bottom = (band + 1) * h / bands
            guard let context = CGContext(data: pixels + top * bytesPerRow, width: w, height: bottom - top, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else { return }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: -CGFloat(h - bottom), width: CGFloat(w), height: CGFloat(h)))
        }
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

import AppKit

/// A site icon that turns into the folding ribbon while its page loads. Falls back to a globe for sites without icons.
final class FaviconView: NSView {
    private let imageLayer = CALayer()
    private let spinner = RibbonView()
    private let fallback = NSImageView()
    /// One-color icons (GitHub, X, Vercel) come in black or white, often whichever the page was in, so either can
    /// vanish against the sidebar. They take the sidebar's own ink instead, readable in light and dark.
    private var isInk = false
    private struct RenderKey: Equatable {
        let base: ObjectIdentifier?
        let side: CGFloat, scale: CGFloat
        let dark: Bool, ink: Bool
    }
    private var lastRender: RenderKey?

    var image: NSImage? { didSet { refreshImage() } }
    var isLoading = false { didSet { if oldValue != isLoading { refreshLoading() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.cornerRadius = Tokens.Radius.small - 1
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        spinner.weight = 0.3
        // A page that never says it's done (long polling, a hung load) would keep it flowing forever: after a
        // while it rests as the still ribbon, which reads as loading just the same.
        spinner.loopLimit = 10
        spinner.alphaValue = 0
        addSubview(spinner)

        fallback.image = Tokens.Symbol.image("globe", size: Tokens.TypeSize.body)
        fallback.contentTintColor = Tokens.Color.textTertiary
        fallback.imageScaling = .scaleNone
        addSubview(fallback)
        refreshImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            imageLayer.frame = bounds
            spinner.frame = bounds
            spinner.ribbonWidth = bounds.width * 0.62
            fallback.frame = bounds
        }
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        if isLoading { startSpinning() }
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            spinner.color = Tokens.Color.icon
            imageLayer.cornerRadius = isInk ? 0 : Tokens.Radius.small - 1
            let scale = window?.backingScaleFactor ?? 2
            // Drawn once at exactly the pixels it fills, with the best filtering, rather than scaled on the fly; again
            // only when the icon, its size or its ink changes.
            let key = RenderKey(base: image.map(ObjectIdentifier.init), side: bounds.width,
                                scale: scale, dark: effectiveAppearance.isDark, ink: isInk)
            if key != lastRender {
                lastRender = key
                let shown = isInk ? image.map { Self.inked($0, Tokens.Color.textPrimary, appearance: effectiveAppearance) } : image
                imageLayer.contents = shown.flatMap { Self.render($0, side: bounds.width, scale: scale) }
            }
            imageLayer.contentsScale = scale
        }
    }

    private func refreshImage() {
        isInk = image.map(FaviconView.isMonochrome) ?? false
        refreshColors()
        fallback.isHidden = image != nil || isLoading
    }

    private static func render(_ image: NSImage, side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((max(side, 1) * scale).rounded())
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The icon's shape filled with one color, resolved for the view's light or dark look. Done in a bitmap of its
    /// own (the icon, then the color kept only where it is), so it never depends on where it's later drawn.
    private static func inked(_ image: NSImage, _ color: NSColor, appearance: NSAppearance) -> NSImage {
        var ink = color.cgColor
        appearance.performAsCurrentDrawingAppearance { ink = color.cgColor }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(ink)
        context.fill(rect)
        guard let result = context.makeImage() else { return image }
        return NSImage(cgImage: result, size: image.size)
    }

    /// When loading began, so a page that's done almost at once doesn't flash the loader.
    private var loadingSince: Date?
    private var pendingLoad: DispatchWorkItem?

    private func refreshLoading() {
        pendingLoad?.cancel()
        // Only show the loader once loading has gone on a moment; quick pages just keep their icon.
        if isLoading, loadingSince == nil {
            loadingSince = Date()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if let self, self.isLoading { self.showLoading(true) } }
            }
            pendingLoad = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }
        if !isLoading {
            loadingSince = nil
            showLoading(false)
        }
    }

    private func showLoading(_ on: Bool) {
        let showSpinner = on
        fallback.isHidden = image != nil || isLoading
        let toSpinner: Float = showSpinner ? 1 : 0
        let toImage: Float = showSpinner ? 0 : 1
        for (layer, target) in [(spinner.layer!, toSpinner), (imageLayer, toImage)] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = Tokens.Motion.quick
            layer.add(fade, forKey: "fade")
            Tokens.Motion.withoutAnimation { layer.opacity = target }
        }
        if showSpinner {
            startSpinning()
        } else if spinner.isLooping {
            // Keeps flowing while it fades, then stops out of sight.
            DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.quick + 0.05) { [weak self] in
                MainActor.assumeIsolated { if let self, !self.isLoading { self.spinner.stopLooping() } }
            }
        }
    }

    private static var monochromeCache: [ObjectIdentifier: Bool] = [:]

    /// True for icons drawn in one colorless ink, black or white, on transparency. A black mark on a white disc
    /// (Apple) is two tones and keeps its own colors.
    static func isMonochrome(_ image: NSImage) -> Bool {
        let key = ObjectIdentifier(image)
        if let cached = monochromeCache[key] { return cached }
        var result = false
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let side = 16
            if let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let data = ctx.data {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
                let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
                var opaque = 0, transparent = 0, dark = 0, light = 0, colorful = 0
                for i in 0..<(side * side) {
                    let a = Int(px[i * 4 + 3])
                    if a < 40 { transparent += 1; continue }
                    opaque += 1
                    let r = Int(px[i * 4]) * 255 / a, g = Int(px[i * 4 + 1]) * 255 / a, b = Int(px[i * 4 + 2]) * 255 / a
                    if max(r, g, b) < 90 { dark += 1 }
                    if min(r, g, b) > 200 { light += 1 }
                    if max(r, g, b) - min(r, g, b) > 40 { colorful += 1 }
                }
                result = opaque > 0 && transparent > side * side / 6 && max(dark, light) * 10 >= opaque * 7
                    && min(dark, light) * 10 < opaque && colorful * 10 < opaque
            }
        }
        monochromeCache[key] = result
        return result
    }

    private func startSpinning() { spinner.startLooping() }
}

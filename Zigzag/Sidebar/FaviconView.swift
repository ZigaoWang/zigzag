import AppKit

/// A site icon that turns into the folding ribbon while its page loads. Falls back to a globe for sites without icons.
final class FaviconView: NSView {
    private let imageLayer = CALayer()
    private let spinner = RibbonView()
    private let fallback = NSImageView()
    /// One-color icons (GitHub, X, Vercel) come in black or white, often whichever the page was in, so either can
    /// vanish against the sidebar. They take the sidebar's own ink instead, readable in light and dark.
    private var isInk = false
    /// An icon you chose rather than the site's (`IconChoice.pageIcon`): a symbol takes the row's ink, as a folder's
    /// does; an emoji keeps its colors. Neither is rounded off like a site's square icon.
    private var isChosen = false
    private var isSymbol = false
    private struct RenderKey: Equatable {
        let base: ObjectIdentifier?
        let side: CGFloat, scale: CGFloat
        let dark: Bool, ink: Bool
    }
    private var lastRender: RenderKey?
    /// The image last drawn, held, so a new image at a reused address is never mistaken for it.
    private var renderedImage: NSImage?

    var image: NSImage? { didSet { refreshImage() } }
    var isLoading = false { didSet { if oldValue != isLoading { refreshLoading() } } }
    /// A tab put to sleep: a dotted ring round its icon, as Chrome marks a tab whose page it let go.
    var isAsleep = false { didSet { if oldValue != isAsleep { asleepRing.isHidden = !isAsleep } } }
    private let asleepRing = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.cornerRadius = Tokens.Radius.small - 1
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        asleepRing.fillColor = nil
        asleepRing.lineWidth = 1.25
        asleepRing.lineCap = .round
        asleepRing.lineDashPattern = [0.01, 2.6]
        asleepRing.isHidden = true
        layer?.addSublayer(asleepRing)

        spinner.weight = 0.3
        // A page that never says it's done (long polling, a hung load) would keep it flowing forever: after a
        // while it rests as the still ribbon, which reads as loading just the same.
        spinner.loopLimit = 10
        spinner.alphaValue = 0
        addSubview(spinner)

        fallback.image = Tokens.Symbol.image("globe", size: Tokens.Symbol.row)
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
            // Just outside the icon, so the icon itself reads as it always does.
            let ring = bounds.insetBy(dx: -2.5, dy: -2.5)
            asleepRing.frame = bounds
            asleepRing.path = CGPath(ellipseIn: ring.offsetBy(dx: -bounds.minX, dy: -bounds.minY), transform: nil)
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
            var ink = Tokens.Color.textSecondary.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { ink = Tokens.Color.textSecondary.cgColor }
            asleepRing.strokeColor = ink
            asleepRing.contentsScale = window?.backingScaleFactor ?? 2
            imageLayer.cornerRadius = isInk || isChosen ? 0 : Tokens.Radius.small - 1
            let scale = window?.backingScaleFactor ?? 2
            // Drawn once at exactly the pixels it fills, with the best filtering, rather than scaled on the fly; again
            // only when the icon, its size or its ink changes.
            let key = RenderKey(base: image.map(ObjectIdentifier.init), side: bounds.width,
                                scale: scale, dark: effectiveAppearance.isDark, ink: isInk)
            if key != lastRender || renderedImage !== image {
                // A site's icon swapping for another (a better one arriving, the page moving on) cross-fades; a
                // first icon, a new size or a change of ink is simply drawn.
                let swaps = renderedImage != nil && image != nil && renderedImage !== image && imageLayer.contents != nil && window != nil
                lastRender = key
                renderedImage = image
                let shown = isSymbol ? image.map { Self.tinted($0, Tokens.Color.textSecondary, appearance: effectiveAppearance) }
                    : isInk ? image.map { Self.inked($0, Tokens.Color.textPrimary, appearance: effectiveAppearance) } : image
                imageLayer.contents = shown.flatMap { Self.render($0, side: bounds.width, scale: scale) }
                if swaps {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = Tokens.Motion.selection
                    fade.timingFunction = Tokens.Motion.easeOut
                    imageLayer.add(fade, forKey: "swap")
                }
            }
            imageLayer.contentsScale = scale
        }
    }

    private func refreshImage() {
        isChosen = image.map(IconChoice.isPageIcon) ?? false
        isSymbol = isChosen && image?.isTemplate == true
        isInk = !isChosen && (image.map(FaviconView.isMonochrome) ?? false)
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

    /// A template (a chosen symbol) in one color, resolved for the view's light or dark look. Still drawn, not a
    /// bitmap, so it's as sharp at a favorite's size as at a row's.
    private static func tinted(_ image: NSImage, _ color: NSColor, appearance: NSAppearance) -> NSImage {
        var ink = color.cgColor
        appearance.performAsCurrentDrawingAppearance { ink = color.cgColor }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setBlendMode(.sourceIn)
            context.setFillColor(ink)
            context.fill(rect)
            return true
        }
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

    /// Keyed by the image itself, held: a freed image's address can be reused by a new one, which must not inherit
    /// its answer (a colorful icon drawn as a black disc).
    private static var monochromeCache: [ObjectIdentifier: (image: NSImage, result: Bool)] = [:]

    /// True for icons drawn in one colorless ink, black or white, on transparency. A black mark on a white disc
    /// (Apple) is two tones and keeps its own colors.
    static func isMonochrome(_ image: NSImage) -> Bool {
        let key = ObjectIdentifier(image)
        if let cached = monochromeCache[key], cached.image === image { return cached.result }
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
        if monochromeCache.count > 500 { monochromeCache.removeAll() }
        monochromeCache[key] = (image, result)
        return result
    }

    private func startSpinning() { spinner.startLooping() }
}

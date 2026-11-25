import AppKit

/// A site icon that turns into the folding ribbon while its page loads. Falls back to a globe for sites without icons.
final class FaviconView: NSView {
    /// The picture, the sleeping ring and the globe together, so Developer Mode's chip can cut its gap out of all of
    /// them at once.
    private let body = CALayer()
    private let imageLayer = CALayer()
    private let spinner = RibbonView()
    /// The globe for a site without an icon.
    private let fallback = CALayer()
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
    private var lastGlobeDark: Bool?
    private static let globe = Tokens.Symbol.image("globe", size: Tokens.Symbol.row)
    /// The image last drawn, held, so a new image at a reused address is never mistaken for it.
    private var renderedImage: NSImage?

    var image: NSImage? { didSet { refreshImage() } }
    var isLoading = false { didSet { if oldValue != isLoading { refreshLoading() } } }
    /// A tab whose page isn't running, however it got there (put to sleep, or not loaded yet since Zigzag reopened):
    /// a thin dashed ring round its icon, as Chrome marks a tab whose page it let go.
    var isUnloaded = false { didSet { if oldValue != isUnloaded { asleepRing.isHidden = !isUnloaded; needsLayout = true } } }
    private let asleepRing = CAShapeLayer()

    /// Developer Mode (#141): a small round chip on the icon's bottom-trailing corner in this color, the mode's hammer
    /// knocked out of it so the ground shows through, and the icon cut away round it by an even gap, as a status on
    /// an avatar is. Beside the sleeping ring, the loader and every other state, on any space. Nil: no chip.
    var developerBadge: NSColor? {
        didSet {
            // Drawn again only if the color it resolves to changed (`layoutBadge`).
            guard oldValue !== developerBadge else { return }
            Tokens.Motion.withoutAnimation { badge.isHidden = developerBadge == nil && originalIcon == nil }
            renderedOriginal = nil
            needsLayout = true
        }
    }
    /// What the chip has knocked out of it: Developer Mode's hammer, or a live folder's feed mark.
    enum BadgeMark { case developer, feed }
    var badgeMark = BadgeMark.developer {
        didSet { if oldValue != badgeMark { renderedBadge = nil; needsLayout = true } }
    }
    private let badge = CALayer()
    private let badgeCut = CAShapeLayer()
    private var renderedBadge: (side: CGFloat, scale: CGFloat, color: CGColor)?

    /// For an away favorite: the saved page's icon as a small badge in the Developer Mode chip's corner, with a gap cut
    /// around it. The chip, if present, keeps the corner. Nil: none.
    var originalIcon: NSImage? {
        didSet {
            guard oldValue !== originalIcon else { return }
            renderedOriginal = nil
            Tokens.Motion.withoutAnimation { badge.isHidden = developerBadge == nil && originalIcon == nil }
            needsLayout = true
        }
    }
    private var renderedOriginal: (side: CGFloat, scale: CGFloat, image: NSImage)?
    /// A round badge laid on the icon from outside it (a favorite's speaker), in the icon's own coordinates: the icon
    /// is cut away round it by `speakerGap`, so the ground shows as a ring. Nil: none.
    var speakerCut: CGRect? { didSet { if oldValue != speakerCut { needsLayout = true } } }
    static let speakerGap: CGFloat = 1.5

    /// Where a speaker badge of `chip` points sits on an icon of `side`: the bottom-trailing corner as the Developer
    /// Mode chip's, reaching as far past it, or the bottom-leading one while that chip (or an away icon) has the corner.
    static func speakerFrame(side: CGFloat, chip: CGFloat, leading: Bool) -> CGRect {
        let out = (chip * Tokens.Sidebar.developerBadgeOverhang * 2).rounded() / 2
        return CGRect(x: leading ? -out : side + out - chip, y: -out, width: chip, height: chip)
    }
    /// The globe a site without an icon shows, for a badge.
    static var globeIcon: NSImage { globe }
    /// A question waits for this page but can't show (background tab or hidden window): a filled dot at the developer chip's
    /// corner, or the other top corner when the chip is there. No cutout; one dot per page.
    var attentionColor: NSColor? {
        didSet {
            guard oldValue !== attentionColor else { return }
            Tokens.Motion.withoutAnimation { attentionDot.isHidden = attentionColor == nil }
            needsLayout = true
        }
    }
    private let attentionDot = CALayer()
    private var renderedAttention: (side: CGFloat, scale: CGFloat, color: CGColor)?

    /// Where the chip sits for an icon of `side` points (x right, y up, from the icon's bottom-left), its side a share
    /// of the icon's and reaching a little past the icon's corner.
    static func badgeFrame(side: CGFloat) -> CGRect {
        let chip = (side * Tokens.Sidebar.developerBadgeShare * 2).rounded() / 2
        let out = (chip * Tokens.Sidebar.developerBadgeOverhang * 2).rounded() / 2
        return CGRect(x: side + out - chip, y: -out, width: chip, height: chip)
    }

    /// Dot position: the chip's corner, or the other top corner when the chip shows, so they never overlap.
    static func attentionFrame(side: CGFloat, overBadge: Bool) -> CGRect {
        let frame = badgeFrame(side: side)
        guard overBadge else { return frame }
        return CGRect(x: frame.minX, y: side - frame.minY - frame.height, width: frame.width, height: frame.height)
    }

    /// The sleeping mark's look, as Chrome marks a tab it let go: a hairline ring of short even dashes in a quiet
    /// ink, an even gap out from the icon, which is drawn a little smaller inside it so the two never crowd.
    struct AsleepStyle {
        /// From the icon's usual square to the ring's inner edge.
        var gap: CGFloat
        var lineWidth: CGFloat
        /// A dash and the space after it, before they're evened out round the circle (`evenDashes`).
        var dash: CGFloat
        var space: CGFloat
        /// The icon inside the ring, as a share of its usual side.
        var iconScale: CGFloat
    }
    static let asleepStyle = AsleepStyle(gap: 1.5, lineWidth: 0.75, dash: 1.5, space: 1.3, iconScale: 0.85)

    /// A dash and the space after it, stretched or squeezed a little so a whole number of them goes exactly round a
    /// circle of this circumference: no short dash or long gap where the circle starts and ends.
    nonisolated static func evenDashes(circumference: CGFloat, dash: CGFloat, space: CGFloat) -> (dash: CGFloat, space: CGFloat, count: Int) {
        let period = dash + space
        guard circumference > 0, period > 0 else { return (dash, space, 0) }
        let count = max(4, Int((circumference / period).rounded()))
        let scale = circumference / CGFloat(count) / period
        return (dash * scale, space * scale, count)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(body)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.cornerRadius = Tokens.Radius.small - 1
        imageLayer.masksToBounds = true
        body.addSublayer(imageLayer)
        asleepRing.fillColor = nil
        asleepRing.isHidden = true
        body.addSublayer(asleepRing)
        badgeCut.fillRule = .evenOdd
        badge.contentsGravity = .resizeAspect
        badge.isHidden = true
        layer?.addSublayer(badge)
        attentionDot.contentsGravity = .resizeAspect
        attentionDot.isHidden = true
        layer?.addSublayer(attentionDot)

        spinner.weight = 0.3
        // A page that never says it's done (long polling, a hung load) would keep it flowing forever: after a
        // while it rests as the still ribbon, which reads as loading just the same.
        spinner.loopLimit = 10
        spinner.alphaValue = 0
        addSubview(spinner)

        fallback.contentsGravity = .center
        body.addSublayer(fallback)
        refreshImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            body.frame = bounds
            layoutAsleep()
            spinner.frame = bounds
            spinner.ribbonWidth = bounds.width * 0.62
            fallback.frame = bounds
            layoutBadge()
            layoutAttention()
        }
        refreshColors()
    }

    /// The chip on its corner, drawn again only when its size, the screen or its color changes; and the gap cut out
    /// of the icon round it (the rest of the cut reaching well past the sleeping ring).
    private func layoutBadge() {
        let hasBadge = developerBadge != nil || originalIcon != nil
        guard hasBadge || speakerCut != nil, bounds.width > 0 else { body.mask = nil; return }
        let frame = Self.badgeFrame(side: bounds.width)
        let gap = Tokens.Sidebar.developerBadgeGap
        let reach = bounds.insetBy(dx: -bounds.width, dy: -bounds.height)
        let path = CGMutablePath()
        path.addRect(reach)
        if hasBadge {
            badge.frame = frame
            let round = developerBadge == nil ? Self.originalRadius(side: frame.width) + gap : frame.width / 2 + gap
            path.addRoundedRect(in: frame.insetBy(dx: -gap, dy: -gap), cornerWidth: round, cornerHeight: round)
        }
        if let speaker = speakerCut { path.addEllipse(in: speaker.insetBy(dx: -Self.speakerGap, dy: -Self.speakerGap)) }
        let scale = window?.backingScaleFactor ?? 2
        badgeCut.frame = body.bounds
        badgeCut.path = path
        // Masked layers render offscreen at the mask's scale; at 1 the icon under the badge cut is half resolution on Retina.
        badgeCut.contentsScale = scale
        body.contentsScale = scale
        if body.mask !== badgeCut { body.mask = badgeCut }
        guard hasBadge else { return }
        guard let color = developerBadge else {
            guard let original = originalIcon else { return }
            if let last = renderedOriginal, last.side == frame.width, last.scale == scale, last.image === original { return }
            renderedOriginal = (frame.width, scale, original)
            renderedBadge = nil
            badge.contents = Self.renderOriginal(original, side: frame.width, scale: scale, appearance: effectiveAppearance)
            badge.contentsScale = scale
            return
        }
        renderedOriginal = nil
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        if let last = renderedBadge, last.side == frame.width, last.scale == scale, last.color == resolved { return }
        renderedBadge = (frame.width, scale, resolved)
        badge.contents = Self.renderBadge(side: frame.width, scale: scale, color: resolved, mark: badgeMark)
        badge.contentsScale = scale
    }

    /// Badge site icons are rounded like full-size ones, a bit more for the small size.
    private static func originalRadius(side: CGFloat) -> CGFloat { max(1.5, side * 0.22) }

    /// Saved page icon for the corner, pixel-exact and rounded like site icons; symbols (globe, chosen icon) in secondary ink.
    private static func renderOriginal(_ image: NSImage, side: CGFloat, scale: CGFloat, appearance: NSAppearance) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        let radius = originalRadius(side: side) * scale
        let drawn = image.isTemplate ? tinted(image, Tokens.Color.textSecondary, appearance: appearance) : image
        context.interpolationQuality = .high
        if !image.isTemplate {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            drawn.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false,
                       hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Waiting question dot: at the chip's corner, or the other top corner while the chip shows.
    private func layoutAttention() {
        guard let color = attentionColor, bounds.width > 0 else { return }
        let frame = Self.attentionFrame(side: bounds.width, overBadge: developerBadge != nil || originalIcon != nil)
        attentionDot.frame = frame
        let scale = window?.backingScaleFactor ?? 2
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        if let last = renderedAttention, last.side == frame.width, last.scale == scale, last.color == resolved { return }
        renderedAttention = (frame.width, scale, resolved)
        attentionDot.contents = Self.renderDot(side: frame.width, scale: scale, color: resolved)
        attentionDot.contentsScale = scale
    }

    /// A plain pixel-exact disc: the badge without hammer or cutout.
    private static func renderDot(side: CGFloat, scale: CGFloat, color: CGColor) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }

    /// The chip: a disc of `color` with its mark cut out of it, at exactly the pixels it fills.
    static func renderBadge(side: CGFloat, scale: CGFloat, color: CGColor, mark: BadgeMark = .developer) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.setFillColor(color)
        context.fillEllipse(in: rect)
        if mark == .feed {
            cutFeedMark(in: context, side: rect.width)
            return context.makeImage()
        }
        let config = NSImage.SymbolConfiguration(pointSize: side * scale, weight: .bold)
        if let glyph = NSImage(systemSymbolName: DeveloperTool.modeSymbol + ".fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: DeveloperTool.modeSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            // Its longer side a share of the disc's, in the middle of it.
            let size = glyph.size
            let fit = rect.width * Tokens.Sidebar.developerGlyphShare / max(size.width, size.height, 1)
            let drawn = CGSize(width: size.width * fit, height: size.height * fit)
            let target = CGRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            glyph.draw(in: target, from: .zero, operation: .destinationOut, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }

    /// The feed mark, a dot and two arcs evenly apart, drawn rather than a symbol so it stays sharp at a chip's size;
    /// its box in the middle of the disc.
    private static func cutFeedMark(in context: CGContext, side: CGFloat) {
        let line = side * Tokens.Sidebar.feedLineShare, dot = line * 0.85
        let ink = side * Tokens.Sidebar.feedMarkShare
        let gap = (ink - 2 * dot - 2 * line) / 2
        let inner = dot + gap + line / 2, outer = inner + line + gap
        let corner = side / 2 - ink / 2 + dot
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: corner - dot, y: corner - dot, width: dot * 2, height: dot * 2))
        context.setLineWidth(line)
        context.setLineCap(.round)
        for radius in [inner, outer] {
            context.addArc(center: CGPoint(x: corner, y: corner), radius: radius, startAngle: 0, endAngle: .pi / 2, clockwise: false)
            context.strokePath()
        }
        context.restoreGState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
        renderedOriginal = nil
        if developerBadge != nil || originalIcon != nil { needsLayout = true }
    }

    /// The ring an even gap out from the icon, clear of its corners, its dashes dividing the circle exactly.
    private func layoutAsleep() {
        let style = Self.asleepStyle
        let local = NSRect(origin: .zero, size: bounds.size)
        let shrink = isUnloaded ? bounds.width * (1 - style.iconScale) / 2 : 0
        imageLayer.frame = bounds.insetBy(dx: shrink, dy: shrink)
        guard isUnloaded else { return }
        let ring = local.insetBy(dx: -style.gap - style.lineWidth / 2, dy: -style.gap - style.lineWidth / 2)
        let even = Self.evenDashes(circumference: .pi * ring.width, dash: style.dash, space: style.space)
        asleepRing.frame = bounds
        asleepRing.path = CGPath(ellipseIn: ring, transform: nil)
        asleepRing.lineWidth = style.lineWidth
        // A dash centered on the circle's start, so the pattern is symmetric.
        asleepRing.lineDashPattern = [NSNumber(value: Double(even.dash)), NSNumber(value: Double(even.space))]
        asleepRing.lineDashPhase = even.dash / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if developerBadge != nil || originalIcon != nil { needsLayout = true }
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        if isLoading { startSpinning() }
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            spinner.color = Tokens.Color.icon
            var ink = Tokens.Color.textTertiary.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { ink = Tokens.Color.textTertiary.cgColor }
            asleepRing.strokeColor = ink
            if fallback.contents == nil || lastGlobeDark != effectiveAppearance.isDark {
                lastGlobeDark = effectiveAppearance.isDark
                fallback.contents = Self.tinted(Self.globe, Tokens.Color.textTertiary, appearance: effectiveAppearance)
                fallback.contentsScale = window?.backingScaleFactor ?? 2
            }
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
        Tokens.Motion.withoutAnimation { fallback.isHidden = image != nil || isLoading }
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
        Tokens.Motion.withoutAnimation { fallback.isHidden = image != nil || isLoading }
        let toSpinner: Float = showSpinner ? 1 : 0
        let toImage: Float = showSpinner ? 0 : 1
        for (layer, target) in [(spinner.layer!, toSpinner), (imageLayer, toImage)] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = Tokens.Motion.state
            fade.timingFunction = Tokens.Motion.easeOut
            layer.add(fade, forKey: "fade")
            Tokens.Motion.withoutAnimation { layer.opacity = target }
        }
        if showSpinner {
            startSpinning()
        } else if spinner.isLooping {
            // Keeps flowing while it fades, then stops out of sight.
            DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.state + 0.05) { [weak self] in
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

/// A page's speaker as a small badge on its icon's bottom corner, the icon cut away round it (`FaviconView.speakerCut`):
/// a favorite's, and an icon-only part of a split row's. A disc of the selected card's light under the glyph, its
/// target a favorite ×'s size round it.
@MainActor enum SpeakerBadge {
    static var target: CGFloat { Tokens.Sidebar.favoriteClose }
    private static let discName = "speaker badge disc"

    private static func disc(of button: IconButton) -> CALayer? { button.layer?.sublayers?.first { $0.name == discName } }
    static func isBadge(_ button: IconButton) -> Bool { disc(of: button) != nil }

    /// Makes `button` the badge: its target's size, round, with the disc under its glyph.
    static func style(_ button: IconButton) {
        guard !isBadge(button) else { return }
        button.wantsLayer = true
        button.setFrameSize(NSSize(width: target, height: target))
        button.radius = target / 2
        let disc = CALayer()
        disc.name = discName
        button.layer?.insertSublayer(disc, at: 0)
    }

    /// Takes the disc off again; the caller gives the button back its own size and corners.
    static func unstyle(_ button: IconButton) { disc(of: button)?.removeFromSuperlayer() }

    /// The glyph: playing and muted in the disc's middle together, the speaker's body on the same pixels in both.
    static func glyph(muted: Bool) -> (image: NSImage, ink: CGSize) {
        if glyphs.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: Tokens.Sidebar.favoriteSpeakerGlyph, weight: .semibold, scale: .small)
            let names = ["speaker.wave.2", "speaker.slash"], keys = names.map { "favorite speaker \($0)" }
            let images = names.map { name in
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
                image.isTemplate = true
                return image
            }
            glyphs = Array(zip(images, Tokens.Symbol.sharedInkOffsets(of: images, keys: keys)))
        }
        return glyphs[muted ? 1 : 0]
    }
    private static var glyphs: [(image: NSImage, ink: CGSize)] = []

    static func show(_ button: IconButton, muted: Bool) {
        let glyph = glyph(muted: muted)
        guard button.glyph !== glyph.image else { return }
        button.glyph = glyph.image
        button.glyphInk = glyph.ink
    }

    /// Puts the badge on `icon`'s bottom corner (the leading one while Developer Mode's chip or an away icon has the
    /// trailing one), cuts the icon round it, and centers the button on it.
    static func place(_ button: IconButton, on icon: FaviconView) {
        let side = icon.frame.width
        let chip = (side * Tokens.Sidebar.favoriteSpeakerShare * 2).rounded() / 2
        let leading = icon.developerBadge != nil || icon.originalIcon != nil
        let cut = FaviconView.speakerFrame(side: side, chip: chip, leading: leading)
        icon.speakerCut = cut
        guard let host = button.superview else { return }
        let disc = host.convert(cut, from: icon)
        button.frame = NSRect(x: disc.midX - target / 2, y: disc.midY - target / 2, width: target, height: target)
        Tokens.Motion.withoutAnimation {
            guard let disc = Self.disc(of: button) else { return }
            disc.frame = CGRect(x: (target - chip) / 2, y: (target - chip) / 2, width: chip, height: chip)
            disc.cornerRadius = chip / 2
            disc.backgroundColor = button.cgColor(Tokens.Chrome.card)
        }
    }

    /// The disc again in the current appearance.
    static func refreshColor(_ button: IconButton) {
        Tokens.Motion.withoutAnimation { disc(of: button)?.backgroundColor = button.cgColor(Tokens.Chrome.card) }
    }
}

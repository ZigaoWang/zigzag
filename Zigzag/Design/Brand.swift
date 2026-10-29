import AppKit

// The logo and wordmark drawn here are trademarks of Zigao Wang and aren't covered by the Apache license;
// see TRADEMARKS.md. A fork keeps the code and draws its own.

/// Zigzag's brand: the icon's navy and pale ribbon, one warm accent (Ember) for live things only, and the ribbon
/// Z itself, drawn from the icon's exact geometry. It appears in key moments (banners, first launch, import
/// finished, the active tab, loading); controls stay native.
enum Brand {
    // MARK: Color

    static let navy = Tokens.Color.hex(0x1E3A5F)
    /// Relative luminance targets for the accent: about 5:1 against white text in light mode, and about 6.5:1
    /// against deep text in dark mode.
    static let accentLuminance = (light: 0.16, dark: 0.36)

    /// A color of `hue` and `saturation` whose WCAG relative luminance is `luminance`, found by solving brightness.
    static func color(hue: Double, saturation: Double, luminance target: Double) -> NSColor {
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if relativeLuminance(NSColor(hue: hue, saturation: saturation, brightness: mid, alpha: 1)) < target { low = mid } else { high = mid }
        }
        // Past full brightness the hue can't get any lighter at this saturation; ease off the saturation instead.
        if high >= 0.999, relativeLuminance(NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1)) < target {
            return color(hue: hue, saturation: saturation * 0.8, luminance: target)
        }
        return NSColor(hue: hue, saturation: saturation, brightness: (low + high) / 2, alpha: 1)
    }

    /// WCAG 2 relative luminance of an sRGB color.
    static func relativeLuminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    /// WCAG 2 contrast ratio between two colors.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    static let navyHue: Double = 213.0 / 360
    static let ribbon = Tokens.Color.hex(0xDAE5F2)
    /// Banners are navy in both appearances; a touch deeper in dark so they sit in a dark window.
    static let bannerFill = Tokens.Color.dynamic(light: navy, dark: Tokens.Color.hex(0x18304F))
    /// The ribbon on ordinary surfaces: navy in light, the pale ribbon in dark.
    static let mark = Tokens.Color.dynamic(light: navy, dark: ribbon)

    // MARK: Theme

    /// Brand moments take the color of the space you're in: a deep shade of its hue for banners, and a pale one
    /// for the ribbon on it. The Sky space gives exactly the icon's navy; Graphite falls back to navy too.
    /// Its accent is the space's own hue, brighter: one color family per space, never a second competing hue.
    struct Theme: Equatable {
        let hue: Double?

        var deep: NSColor {
            guard let hue else { return Brand.bannerFill }
            return Tokens.Color.dynamic(light: NSColor(hue: hue, saturation: 0.64, brightness: 0.38, alpha: 1),
                                        dark: NSColor(hue: hue, saturation: 0.58, brightness: 0.27, alpha: 1))
        }

        /// The ribbon on a banner.
        var tint: NSColor {
            guard let hue else { return Brand.ribbon }
            return NSColor(hue: hue, saturation: 0.15, brightness: 0.96, alpha: 1)
        }

        /// The ribbon on an ordinary surface.
        var mark: NSColor {
            guard let hue else { return Brand.mark }
            return Tokens.Color.dynamic(light: NSColor(hue: hue, saturation: 0.64, brightness: 0.38, alpha: 1), dark: tint)
        }

        /// The one accent, from the space's own hue: the primary action, selection, the active tab, progress.
        /// The one accent, from the space's own hue: the primary action, selection, the active tab, progress.
        /// Its lightness is solved per hue so text on it always passes WCAG AA (4.5:1): white on a deep accent in
        /// light mode, deep text on a light accent in dark mode. Yellow spaces get a deeper gold, blue ones stay vivid.
        var accent: NSColor {
            let h = hue ?? Brand.navyHue
            return Tokens.Color.dynamic(light: Brand.color(hue: h, saturation: 0.6, luminance: Brand.accentLuminance.light),
                                        dark: Brand.color(hue: h, saturation: 0.48, luminance: Brand.accentLuminance.dark))
        }

        /// Text on the accent.
        var onAccent: NSColor {
            Tokens.Color.dynamic(light: .white, dark: Brand.color(hue: hue ?? Brand.navyHue, saturation: 0.7, luminance: 0.012))
        }

        static let navy = Theme(hue: nil)

        static func of(_ space: SpaceInfo?) -> Theme {
            guard let space else { return .navy }
            if let hue = space.hue { return Theme(hue: hue) }
            return space.color.isNeutral || space.color == .sky ? .navy : Theme(hue: space.color.hue)
        }

        /// The space in front: the key browser window's, or the first one's.
        /// Zigzag's own blue, for windows that belong to the app rather than a space: Settings, Passwords,
        /// Import, Welcome and About.
        static let brand = Theme(hue: Brand.navyHue)

        /// The theme for a view: its browser window's space, or the brand blue in any other window.
        /// A view not in a window yet gets the brand; views refresh when they join one.
        @MainActor static func `for`(_ view: NSView?) -> Theme {
            guard let window = view?.window else { return brand }
            guard let controller = WindowManager.shared.controllers.first(where: { $0.window === window }) else { return brand }
            return of(controller.tabManager.currentSpace)
        }

        @MainActor static var current: Theme {
            let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first
            return of(controller?.tabManager.currentSpace)
        }
    }

    /// Sent when the space in front changes, or its color does.
    @MainActor static let themeChanged = Signal<Void>()

    // MARK: Type

    /// Display type for brand moments: SF Pro, heavy, tight.
    /// `wraps` lets a heading run onto more lines instead of ending in "…"; use it wherever the text is a
    /// sentence or a name of unknown length.
    /// The display face on its own, for labels that set their own text.
    static func displayFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .heavy) }

    static func display(_ text: String, size: CGFloat, color: NSColor, alignment: NSTextAlignment = .natural, wraps: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .kern: -size * 0.025,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: The ribbon

    /// The icon's ribbon: six points on a 368 × 344 run, stroked at 100 with round caps and joins.
    static let points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 34.0 / 368, y: 0.5),
                                    CGPoint(x: 334.0 / 368, y: 0.5), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
    static let aspect: CGFloat = 344.0 / 368
    static let weight: CGFloat = 100.0 / 368

    /// The ribbon's centerline in `rect` (y-up coordinates, top run at the top), folded by `unfold`: 0 is a flat
    /// strip through the middle, 1 the full Z.
    static func centerline(in rect: CGRect, unfold: CGFloat = 1) -> [CGPoint] {
        points.map { p in
            let y = rect.maxY - p.y * rect.height
            return CGPoint(x: rect.minX + p.x * rect.width, y: rect.midY + (y - rect.midY) * unfold)
        }
    }

    static func path(_ points: [CGPoint], segments: [Int]? = nil) -> CGPath {
        let path = CGMutablePath()
        if let segments {
            for i in segments { path.move(to: points[i]); path.addLine(to: points[i + 1]) }
        } else {
            path.addLines(between: points)
        }
        return path
    }

    /// The rect a ribbon of `width` takes, centered in `bounds`, leaving room for its round ends.
    static func ribbonRect(width: CGFloat, in bounds: CGRect) -> CGRect {
        let height = width * aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    // MARK: Motion

    static let drawDuration: CFTimeInterval = 0.7

    /// The one entrance: a fade while rising 8pt, on a critically damped spring (no bounce), each view a beat after
    /// the last. Used for everything that arrives; the ribbon's writing is the only other motion.
    @MainActor static func enter(_ views: [NSView], delay: CFTimeInterval = 0, stagger: CFTimeInterval = 0.04) {
        let now = CACurrentMediaTime()
        for (i, view) in views.enumerated() {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let begin = now + delay + stagger * Double(i)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.22
            fade.beginTime = begin
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "enter.fade")
            // With Reduce Motion, it only fades in, in place.
            guard !Tokens.Motion.reduceMotion else { continue }
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.mass = 1
            rise.stiffness = 300
            rise.damping = 2 * sqrt(300)   // critically damped: settles without overshoot
            rise.fromValue = view.isFlipped || view.superview?.isFlipped == true ? 8 : -8
            rise.toValue = 0
            rise.duration = rise.settlingDuration
            rise.beginTime = begin
            rise.fillMode = .backwards
            layer.add(rise, forKey: "enter.rise")
        }
    }

    static func ease(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    /// First launch writes the wordmark in, letter by letter, once; after that only the ribbon writes itself in.
    static var hasDrawnIn: Bool {
        get { UserDefaults.standard.bool(forKey: "BrandDrawnIn") }
        set { UserDefaults.standard.set(newValue, forKey: "BrandDrawnIn") }
    }
}

/// The ribbon Z. At rest it's one stroke with round joins, exactly like the icon. Its motion is writing: it draws
/// itself in along its path when it appears, and while something loads it writes, lifts from its start, and
/// writes again, like a pen that never stops.
class RibbonView: NSView {
    var color: NSColor = Brand.mark { didSet { refreshColors() } }
    /// The stroke width as a share of the ribbon's width; the icon's own by default.
    var weight: CGFloat = Brand.weight { didSet { needsLayout = true } }
    /// The ribbon's width inside the view; nil fits the view, leaving room for the round ends.
    var ribbonWidth: CGFloat? { didSet { needsLayout = true } }

    private let stroke = CAShapeLayer()
    private(set) var isLooping = false
    /// How long to keep flowing before resting as the whole ribbon, for loads that may never end; nil flows on.
    var loopLimit: TimeInterval?
    /// True while the flow is actually running: only while it can be seen, and not past its limit.
    private var isFlowing = false
    private var limitReached = false
    private var limitWork: DispatchWorkItem?
    private var occlusionToken: NSObjectProtocol?

    /// Decelerating, like a pen landing: quick to start, long gentle finish.
    static let writing = CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.18, 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineCap = .round
        stroke.lineJoin = .round
        layer?.addSublayer(stroke)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        limitWork?.cancel()
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
    }

    override var isFlipped: Bool { false }

    private var rect: CGRect {
        let width = ribbonWidth ?? min(bounds.width, bounds.height / Brand.aspect) / (1 + Brand.weight * 1.05)
        return Brand.ribbonRect(width: width, in: bounds)
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            stroke.frame = bounds
            stroke.lineWidth = rect.width * weight
            stroke.path = isFlowing ? loopPath : Brand.path(Brand.centerline(in: rect))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchWindow()
        refreshLoop()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshLoop()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshLoop()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation { stroke.strokeColor = cgColor(color) }
    }

    /// Writes the ribbon in along its path, once.
    func drawIn(delay: CFTimeInterval = 0, duration: CFTimeInterval = Brand.drawDuration) {
        layoutSubtreeIfNeeded()
        resetStroke()
        // With Reduce Motion, the whole ribbon fades in rather than being written.
        if Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
            stroke.add(fade, forKey: "fade")
            return
        }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = duration
        draw.beginTime = CACurrentMediaTime() + delay
        draw.fillMode = .backwards
        draw.timingFunction = Self.writing
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration * 0.3
        fade.beginTime = draw.beginTime
        fade.fillMode = .backwards
        stroke.add(draw, forKey: "draw")
        stroke.add(fade, forKey: "fade")
    }

    /// The ribbon twice over, end to end: a stretch of stroke can run off the end of one and straight into
    /// the start of the next, so the loop never restarts.
    private var loopPath: CGPath {
        let single = Brand.path(Brand.centerline(in: rect))
        let doubled = CGMutablePath()
        doubled.addPath(single)
        doubled.addPath(single)
        return doubled
    }

    /// A stretch of stroke flows along the ribbon at an even pace for as long as something loads: as it leaves
    /// the end it is already coming back in at the start, so there's no pause, no restart and no easing seam.
    func startLooping() {
        guard !isLooping else { return }
        isLooping = true
        if let loopLimit {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.limitReached = true
                    self?.refreshLoop()
                }
            }
            limitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + loopLimit, execute: work)
        }
        watchWindow()
        refreshLoop()
    }

    /// Stops and goes back to the whole ribbon. Callers fade it out first, while it's still moving.
    func stopLooping() {
        guard isLooping else { return }
        isLooping = false
        limitReached = false
        limitWork?.cancel()
        limitWork = nil
        watchWindow()
        refreshLoop()
    }

    /// A flow nobody can see (no window, hidden, the window covered or in the Dock) still costs a frame
    /// every refresh, so it only runs while it shows, and picks up again when it does.
    private func refreshLoop() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let flow = isLooping && !limitReached && visible && !isHiddenOrHasHiddenAncestor
        guard flow != isFlowing else { return }
        isFlowing = flow
        flow ? beginFlow() : endFlow()
    }

    /// Only a looping ribbon listens for its window being covered or minimized.
    private func watchWindow() {
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
        occlusionToken = nil
        guard isLooping, let window else { return }
        occlusionToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLoop() }
        }
    }

    private func beginFlow() {
        layoutSubtreeIfNeeded()
        stroke.removeAllAnimations()
        // With Reduce Motion, nothing travels: the whole ribbon breathes, softly, while it waits.
        if Tokens.Motion.reduceMotion {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.45
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stroke.add(breathe, forKey: "loop")
            return
        }
        Tokens.Motion.withoutAnimation { stroke.path = loopPath }
        let cycle: CFTimeInterval = 1.1, length: CGFloat = 0.2
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = 0
        start.toValue = 0.5
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = length
        end.toValue = 0.5 + length
        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = cycle
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        stroke.add(group, forKey: "loop")
    }

    private func endFlow() {
        stroke.removeAnimation(forKey: "loop")
        Tokens.Motion.withoutAnimation { stroke.path = Brand.path(Brand.centerline(in: rect)) }
        resetStroke()
    }

    /// Back to the whole ribbon at rest.
    private func resetStroke() {
        Tokens.Motion.withoutAnimation {
            stroke.strokeStart = 0
            stroke.strokeEnd = 1
        }
    }
}

/// Zigzag's spinner: the ribbon, flowing, in place of the system's. Hidden while stopped.
final class Spinner: RibbonView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        weight = 0.3
        color = Tokens.Color.textSecondary
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func startAnimation(_ sender: Any?) {
        isHidden = false
        startLooping()
    }

    func stopAnimation(_ sender: Any?) {
        stopLooping()
        isHidden = true
    }
}

/// The surface for Zigzag's big moments (first launch, import finished): deep in the space's hue, lit from one
/// corner by its accent, with fine grain and a hairline edge, and one large ribbon written in at its right, tone on tone.
final class BrandSurface: NSView {
    private let base = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let grain = CALayer()
    let watermark = RibbonView()
    private var themeToken: SignalToken?
    var fixedTheme: Brand.Theme? { didSet { applyTheme() } }
    private(set) var theme = Brand.Theme.navy
    var cornerRadius: CGFloat = 18 { didSet { layer?.cornerRadius = cornerRadius } }
    /// One Z per screen: off where the wordmark is already the logo.
    var showsWatermark = true { didSet { watermark.isHidden = !showsWatermark } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        base.startPoint = CGPoint(x: 0, y: 1)
        base.endPoint = CGPoint(x: 1, y: 0)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        grain.backgroundColor = NSColor(patternImage: Self.noise).cgColor
        grain.opacity = 0.05
        grain.compositingFilter = "overlayBlendMode"
        layer?.addSublayer(base)
        layer?.addSublayer(glow)
        addSubview(watermark)
        layer?.addSublayer(grain)
        watermark.weight = Brand.weight
        themeToken = Brand.themeChanged.observe { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    /// Fine monochrome grain, made once. Also the texture a space can have.
    static let noise: NSImage = {
        let size = 96
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt32 = 0x9E3779B9
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let v = UInt8(truncatingIfNeeded: seed)
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32) {
            _ = bytes.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, bytes.count) }
            image.addRepresentation(rep)
        }
        return image
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    private func applyTheme() {
        theme = fixedTheme ?? Brand.Theme.for(self)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let deep = (theme.deep.usingColorSpace(.sRGB) ?? theme.deep)
            let lit = deep.blended(withFraction: 0.12, of: .white) ?? deep
            let shade = deep.blended(withFraction: 0.28, of: .black) ?? deep
            Tokens.Motion.withoutAnimation {
                base.colors = [lit.cgColor, deep.cgColor, shade.cgColor]
                base.locations = [0, 0.45, 1]
                glow.colors = [theme.accent.withAlphaComponent(0.42).cgColor, theme.accent.withAlphaComponent(0).cgColor]
                layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
            }
        }
        watermark.color = theme.tint.withAlphaComponent(0.13)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            base.frame = bounds
            grain.frame = bounds
            // The light comes from the top right, beyond the edge.
            let g = max(bounds.width, bounds.height) * 1.1
            glow.frame = CGRect(x: bounds.maxX - g * 0.62, y: bounds.maxY - g * 0.6, width: g, height: g)
        }
        // One big ribbon at the right. At most a sliver runs off the edge, so it always reads as the Z. On a tall
        // surface it's sized by the width and sits in the lower part, clear of the text above.
        let tall = bounds.height > bounds.width * 1.2
        let h = tall ? bounds.width * 0.78 * Brand.aspect : bounds.height * 0.86
        let w = h / Brand.aspect
        let y = tall ? bounds.height * 0.2 : bounds.midY - h / 2
        watermark.frame = NSRect(x: bounds.maxX - w * 0.92, y: y, width: w, height: h)
        watermark.ribbonWidth = w / (1 + Brand.weight * 1.05)
    }
}

/// "ZIGZAG", stroked like the ribbon: heavy round strokes, and both Zs are the ribbon itself. It can draw itself
/// in, letter by letter.
final class WordmarkView: NSView {
    var color: NSColor = Brand.mark { didSet { refreshColors() } }
    private var strokes: [CAShapeLayer] = []

    /// Letter skeletons on a 60-high cap line (y-up), with their advance widths.
    private static let letters: [(width: CGFloat, strokes: [[CGPoint]])] = {
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, _ n: Int = 36) -> [CGPoint] {
            (0...n).map { i in let t = a0 + (a1 - a0) * CGFloat(i) / CGFloat(n); return CGPoint(x: cx + cos(t) * r, y: cy + sin(t) * r) }
        }
        let z = Brand.centerline(in: CGRect(x: 0, y: 0, width: 50, height: 60))
        // The I stands a little off the Z: the Z's flat bars reach its edge, so an even gap reads tight there.
        let i = [CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 60)]
        // Open on the right, closing with a bar into the middle.
        let g = arc(27, 30, 30, .pi * 0.28, .pi * 2 - 0.02, 40) + [CGPoint(x: 57, y: 30), CGPoint(x: 36, y: 30)]
        let a = [CGPoint(x: 0, y: 0), CGPoint(x: 26, y: 60), CGPoint(x: 52, y: 0)]
        let bar = [CGPoint(x: 12, y: 20), CGPoint(x: 40, y: 20)]
        // The I gets a little room after it: against the G's round side the even gap looks tight.
        return [(50, [z]), (9, [i]), (54, [g]), (50, [z]), (52, [a, bar]), (54, [g])]
    }()
    private static let gap: CGFloat = 17
    private static let strokeWeight: CGFloat = 13

    /// Width over height, for sizing.
    static var aspect: CGFloat {
        let width = letters.map(\.width).reduce(0, +) + gap * CGFloat(letters.count - 1)
        return (width + strokeWeight) / (60 + strokeWeight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for letter in Self.letters {
            for _ in letter.strokes {
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineCap = .round
                shape.lineJoin = .round
                layer?.addSublayer(shape)
                strokes.append(shape)
            }
        }
        refreshColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Zigzag")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let scale = min(bounds.width / (Self.aspect * (60 + Self.strokeWeight)), bounds.height / (60 + Self.strokeWeight))
        let inset = Self.strokeWeight / 2 * scale
        let originY = (bounds.height - (60 + Self.strokeWeight) * scale) / 2 + inset
        var x = inset, index = 0
        Tokens.Motion.withoutAnimation {
            for letter in Self.letters {
                for skeleton in letter.strokes {
                    let shape = strokes[index]
                    shape.frame = bounds
                    shape.lineWidth = Self.strokeWeight * scale
                    shape.path = Brand.path(skeleton.map { CGPoint(x: x + $0.x * scale, y: originY + $0.y * scale) })
                    index += 1
                }
                x += (letter.width + Self.gap) * scale
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation { strokes.forEach { $0.strokeColor = cgColor(color) } }
    }

    /// Draws each stroke in, one after another, like a pen.
    func drawIn(delay: CFTimeInterval = 0, total: CFTimeInterval = 1.1) {
        layoutSubtreeIfNeeded()
        if Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
            layer?.add(fade, forKey: "fade")
            return
        }
        let each = total / Double(strokes.count) * 1.6
        for (i, shape) in strokes.enumerated() {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = each
            draw.beginTime = CACurrentMediaTime() + delay + total * Double(i) / Double(strokes.count)
            draw.fillMode = .backwards
            draw.timingFunction = RibbonView.writing
            shape.add(draw, forKey: "draw")
        }
    }
}

/// The top of a branded window (Settings, Passwords, Import): a soft wash of the space's accent that fades into the
/// window, big display type, and the ribbon, whole, at the right, written in when it appears. No band, no hard edge. Leaves the top-left free for the traffic lights.
final class BrandBanner: NSView {
    private let wash = CAGradientLayer()
    let ribbonMark = RibbonView()
    private let titleLabel = Label("", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let subtitleLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = Tokens.Font.body()
        label.textColor = Tokens.Color.textSecondary
        label.isSelectable = false
        label.maximumNumberOfLines = 2
        return label
    }()
    private var themeToken: SignalToken?
    var fixedTheme: Brand.Theme? { didSet { applyTheme() } }
    private(set) var theme = Brand.Theme.navy

    var title: String = "" { didSet { applyTheme(); needsLayout = true } }
    var subtitle: String = "" { didSet { subtitleLabel.stringValue = subtitle; subtitleLabel.isHidden = subtitle.isEmpty; needsLayout = true } }
    var titleSize: CGFloat = 28 { didSet { applyTheme() } }
    /// How far below the banner the wash keeps fading, so it melts into the window.
    var washOverhang: CGFloat = 60
    /// Where the title starts, so it lines up with the content below.
    var contentInset: CGFloat = Tokens.Space.x8 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(wash)
        subtitleLabel.isHidden = true
        [ribbonMark, titleLabel, subtitleLabel].forEach { addSubview($0) }
        themeToken = Brand.themeChanged.observe { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func applyTheme() {
        theme = fixedTheme ?? Brand.Theme.for(self)
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Tokens.Motion.withoutAnimation {
                wash.colors = [theme.accent.withAlphaComponent(dark ? 0.22 : 0.16).cgColor, theme.accent.withAlphaComponent(dark ? 0.07 : 0.05).cgColor,
                               theme.accent.withAlphaComponent(0).cgColor]
                wash.locations = [0, 0.55, 1]
            }
        }
        ribbonMark.color = theme.accent.withAlphaComponent(dark ? 0.34 : 0.26)
        titleLabel.attributedStringValue = Brand.display(title, size: titleSize, color: Tokens.Color.textPrimary)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            // The layer is flipped: the wash starts at the top and runs past the bottom edge.
            wash.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + washOverhang)
            wash.startPoint = CGPoint(x: 0.5, y: 0)
            wash.endPoint = CGPoint(x: 0.5, y: 1)
        }
        // The ribbon, whole: a mark at the right, level with the title, never cropped.
        let markHeight = min(bounds.height * 0.5, 56)
        let markWidth = markHeight / Brand.aspect
        ribbonMark.frame = NSRect(x: bounds.width - contentInset - markWidth, y: bounds.height - Tokens.Space.x4 - markHeight - 2,
                                  width: markWidth, height: markHeight)
        ribbonMark.ribbonWidth = markWidth / (1 + Brand.weight * 1.05)
        let x = contentInset
        // Text stops short of the ribbon, so the two never overlap.
        let textWidth = ribbonMark.frame.minX - Tokens.Space.x5 - x
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let subtitleHeight = subtitleLabel.isHidden ? 0 : ceil(subtitleLabel.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
        let bottom = bounds.height - Tokens.Space.x4
        subtitleLabel.frame = NSRect(x: x, y: bottom - subtitleHeight, width: textWidth, height: subtitleHeight)
        titleLabel.frame = NSRect(x: x - 1, y: subtitleLabel.frame.minY - titleHeight - (subtitleHeight > 0 ? 2 : 0), width: textWidth, height: titleHeight)
    }
}

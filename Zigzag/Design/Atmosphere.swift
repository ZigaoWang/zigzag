import AppKit
import CoreImage

// The backdrop for Zigzag's brand moments (onboarding, Import, About, What's New): a few large, soft fields of
// color, Gaussian-blurred, drifting slowly over a deep (or, in light mode, pale) wash with a little grain, like light
// through glass. Glass panels float over it with a real shadow (`DepthShadow`); a picture of the app can stand in it
// as a slightly tilted object that settles flat (`Stage3D`). See Design/DESIGN.md, "Atmosphere".

/// Soft color fields drifting over a wash. The drift runs on the render server (no per-frame work here), pauses
/// while the window is hidden or covered, and holds still with Reduce Motion.
final class Atmosphere: NSView {
    /// The hue the fields lean toward (0...1); nil is Zigzag's own navy and ribbon.
    private(set) var hue: Double?
    private let base = CAGradientLayer()
    private var fields: [CALayer] = []
    private let grain = CALayer()
    private var occlusionToken: Any?
    private var driftSize: CGSize = .zero

    /// Where each field sits (as a fraction of the view), how big it is (of the longer side), and how it drifts.
    private static let layout: [(x: CGFloat, y: CGFloat, size: CGFloat, dx: CGFloat, dy: CGFloat, period: CFTimeInterval)] = [
        (0.18, 0.22, 0.95, 0.10, 0.06, 29),
        (0.86, 0.18, 0.80, -0.08, 0.09, 34),
        (0.72, 0.88, 0.90, -0.06, -0.08, 26),
        (0.20, 0.84, 0.70, 0.09, -0.05, 38),
    ]

    init(hue: Double? = nil) {
        self.hue = hue
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        guard let layer else { return }
        base.startPoint = CGPoint(x: 0, y: 1)
        base.endPoint = CGPoint(x: 1, y: 0)
        layer.addSublayer(base)
        for _ in Self.layout {
            let field = CALayer()
            let mask = CALayer()
            mask.contents = Self.softDisc
            field.mask = mask
            layer.addSublayer(field)
            fields.append(field)
        }
        if let noise = Self.grainTile { grain.backgroundColor = NSColor(patternImage: NSImage(cgImage: noise, size: NSSize(width: 96, height: 96))).cgColor }
        grain.compositingFilter = "overlayBlendMode"
        layer.addSublayer(grain)
        applyColors(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
    }

    /// Leans the fields toward a hue (a step's, a space's), easing there over a second, or back to the brand's.
    func setHue(_ hue: Double?, animated: Bool) {
        guard hue != self.hue else { return }
        self.hue = hue
        applyColors(animated: animated)
    }

    // MARK: Colors

    /// A wash from top to bottom and the four fields' colors.
    struct Palette { var top: NSColor; var bottom: NSColor; var fields: [NSColor] }

    /// A palette of its own in place of the hue's (a sky), for light and for dark.
    var customPalette: ((_ dark: Bool) -> Palette)? { didSet { applyColors(animated: false) } }

    private func palette(dark: Bool) -> Palette {
        if let customPalette { return customPalette(dark) }
        func hsb(_ h: Double, _ s: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
            NSColor(calibratedHue: CGFloat((h + 1).truncatingRemainder(dividingBy: 1)), saturation: s, brightness: b, alpha: a)
        }
        let h = hue ?? Brand.navyHue
        // Deep: a near-black wash of the hue with luminous pools in it. Pale: a soft tint with clear color in the pools.
        if dark {
            return Palette(top: hsb(h, 0.72, 0.10), bottom: hsb(h + 0.02, 0.70, 0.20),
                           fields: [hsb(h, 0.78, 1.0, 0.55), hsb(h + 0.09, 0.66, 0.95, 0.46),
                                    hsb(h - 0.08, 0.72, 0.92, 0.42), hsb(h + 0.03, 0.85, 0.62, 0.62)])
        }
        return Palette(top: hsb(h, 0.10, 0.99), bottom: hsb(h + 0.02, 0.20, 0.95),
                       fields: [hsb(h, 0.62, 1, 0.62), hsb(h + 0.10, 0.48, 1, 0.55),
                                hsb(h - 0.08, 0.55, 1, 0.50), NSColor.white.withAlphaComponent(0.7)])
    }

    /// Colors the fields and wash again, easing there over a second when `animated` (a custom palette changed).
    func applyColors(animated: Bool) {
        let palette = palette(dark: effectiveAppearance.isDark)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? Tokens.Motion.Ambient.atmosphere : 0)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.drawer)
        base.colors = [palette.top.cgColor, palette.bottom.cgColor]
        for (field, color) in zip(fields, palette.fields) { field.backgroundColor = color.cgColor }
        grain.opacity = effectiveAppearance.isDark ? 0.14 : 0.10
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }

    // MARK: Layout and drift

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        grain.frame = bounds
        let long = max(bounds.width, bounds.height)
        for (field, spot) in zip(fields, Self.layout) {
            let side = long * spot.size
            field.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            field.position = CGPoint(x: bounds.width * spot.x, y: bounds.height * spot.y)
            field.mask?.frame = field.bounds
        }
        CATransaction.commit()
        if bounds.size != driftSize { startDrift() }
    }

    /// Each field wanders a little and breathes, on its own long, out-of-step loop, so the whole never repeats
    /// visibly. Nothing moves with Reduce Motion.
    private func startDrift() {
        driftSize = bounds.size
        fields.forEach { $0.removeAllAnimations() }
        guard !Tokens.Motion.reduceMotion, bounds.width > 0 else { return }
        for (field, spot) in zip(fields, Self.layout) {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: field.position)
            move.toValue = NSValue(point: CGPoint(x: field.position.x + bounds.width * spot.dx, y: field.position.y + bounds.height * spot.dy))
            move.duration = spot.period
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 1.14
            breathe.duration = spot.period * 0.73
            for animation in [move, breathe] {
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.isRemovedOnCompletion = false
            }
            field.add(move, forKey: "drift")
            field.add(breathe, forKey: "breathe")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
        occlusionToken = nil
        guard let window else { return }
        applyColors(animated: false)
        occlusionToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePaused() }
        }
        updatePaused()
    }

    /// Out of sight, the drift stops where it is, and goes on from there when the window is seen again.
    private func updatePaused() {
        guard let layer else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible, layer.speed == 0 {
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !visible, layer.speed != 0 {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
    }

    /// Fine, even grain: random gray pixels, made once and tiled, so the color reads as a surface, not a screen.
    private static let grainTile: CGImage? = {
        let side = 192
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let v = UInt8.random(in: 0...255, using: &generator)
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /// A white disc blurred with a true Gaussian, made once: each field is its color seen through it.
    private static let softDisc: CGImage? = {
        let side: CGFloat = 256
        guard let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: side * 0.28, y: side * 0.28, width: side * 0.44, height: side * 0.44))
        guard let disc = context.makeImage() else { return nil }
        let blurred = CIImage(cgImage: disc).applyingGaussianBlur(sigma: Double(side) * 0.12)
        return CIContext().createCGImage(blurred, from: CGRect(x: 0, y: 0, width: side, height: side))
    }()
}

/// The shadow under a panel floating over an atmosphere: deeper and softer than a panel's own, so the glass reads as
/// lifted well off the color. Put it just below the panel, at the panel's frame.
final class DepthShadow: NSView {
    var radius: CGFloat = Tokens.Radius.large { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -18)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() { layer?.shadowOpacity = effectiveAppearance.isDark ? 0.45 : 0.18 }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 12, dy: 8), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// Shows a view as an object in space: it arrives tilted back a little in perspective, with a soft shadow under it,
/// and settles flat. Hit-testing follows the flat frame, which is where it rests.
final class Stage3D: NSView {
    let content: NSView
    private let floor = DepthShadow()

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        floor.radius = Tokens.Radius.panel
        [floor, content].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        floor.frame = bounds
        content.frame = bounds
    }

    /// Tilted back about its middle by `degrees`, seen from a little way off.
    private func tilt(_ degrees: CGFloat, scale: CGFloat) -> CATransform3D {
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // Applied in order: to the middle, scaled and tilted, seen in perspective, and back.
        let steps = [CATransform3DMakeTranslation(-c.x, -c.y, 0), CATransform3DMakeScale(scale, scale, 1),
                     CATransform3DMakeRotation(degrees * .pi / 180, 1, 0, 0), perspective, CATransform3DMakeTranslation(c.x, c.y, 0)]
        return steps.dropFirst().reduce(steps[0]) { CATransform3DConcat($0, $1) }
    }

    /// Arrives a little tilted and settles flat, as anything showing up does (`Motion.enter`, eased out, from
    /// `enterScale`). With Reduce Motion it is simply flat.
    func settle(delay: CFTimeInterval = 0) {
        guard let layer, !Tokens.Motion.reduceMotion, bounds.width > 0 else { return }
        let from = tilt(6, scale: Tokens.Motion.enterScale)
        let arrive = Tokens.Motion.easeAnimation(keyPath: "sublayerTransform", duration: Tokens.Motion.enter)
        arrive.fromValue = NSValue(caTransform3D: from)
        arrive.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        arrive.beginTime = CACurrentMediaTime() + delay
        arrive.fillMode = .backwards
        layer.sublayerTransform = CATransform3DIdentity
        layer.add(arrive, forKey: "settle")
    }
}

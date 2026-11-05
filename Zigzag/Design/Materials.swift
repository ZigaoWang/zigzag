import AppKit

// The tactile kit for Zigzag's brand moments (onboarding, Import, About): things that read as objects lit by one
// light straight above. Glass with a specular rim, grain and a glow inside its edge (`GlassSurface`); raised tiles
// like app icons (`RaisedTile`); buttons that rise under the pointer and sink when pressed (`TactileButton`); a
// switch with a glassy knob in a recessed track (`TactileToggle`); a field set into the surface (`RecessedField`);
// the wordmark as a beveled object (`EmbossedWordmark`); and the sky they float in (`SkyBackdrop`).
// Every value comes from `Tokens.Material`. See Design/DESIGN.md, "Materials".
//
// They're drawn with layers, y up (none of these views is flipped), so a gradient's top is y = 1.

// MARK: - Shapes

enum MaterialShape {
    /// A rounded rect with continuous corners, the curve Apple's own icons and `cornerCurve = .continuous` use, as a
    /// path: for the rims, bevels and shadows that have to follow a layer's continuous corner exactly.
    static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        guard radius < limit / 1.52866483 else { return capsule(rect) }
        let r = max(0, radius)
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }
        // Each corner in (a, b): a back along the edge coming into it, b in from that edge, in units of r.
        let corners: [(CGFloat, CGFloat) -> CGPoint] = [
            { a, b in CGPoint(x: rect.maxX - a * r, y: rect.minY + b * r) },
            { a, b in CGPoint(x: rect.maxX - b * r, y: rect.maxY - a * r) },
            { a, b in CGPoint(x: rect.minX + a * r, y: rect.maxY - b * r) },
            { a, b in CGPoint(x: rect.minX + b * r, y: rect.minY + a * r) },
        ]
        let path = CGMutablePath()
        for (i, p) in corners.enumerated() {
            if i == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
            path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0.02246195))
            path.addLine(to: p(0.63149399, 0.07491100))
            path.addCurve(to: p(0.07491100, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16905899, 0.37282392))
            path.addLine(to: p(0.06549600, 0.66993427))
            path.addCurve(to: p(0, 1.52866483), control1: p(0.02246195, 0.86840689), control2: p(0, 1.08849323))
        }
        path.closeSubpath()
        return path
    }

    static func capsule(_ rect: CGRect) -> CGPath {
        let r = min(rect.width, rect.height) / 2
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

// MARK: - Layer recipes

extension CALayer {
    /// This layer and every one under it (and their masks) drawn at `scale`: shape and text layers we add ourselves
    /// don't follow the window's backing scale on their own, and would be soft on a Retina screen.
    func applyContentsScale(_ scale: CGFloat) {
        contentsScale = scale
        if shouldRasterize { rasterizationScale = scale }
        mask?.applyContentsScale(scale)
        sublayers?.forEach { $0.applyContentsScale(scale) }
    }
}

enum MaterialMotion {
    /// Changes our own layers with the material ease-out (interruptible: each starts from where the last one has
    /// got to), or at once from the keyboard, with Reduce Motion for movement, or when `duration` is 0.
    static func animate(_ duration: TimeInterval, moves: Bool = false, _ changes: () -> Void) {
        let instant = duration == 0 || Tokens.Motion.isFromKey || (moves && Tokens.Motion.reduceMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(instant)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        changes()
        CATransaction.commit()
    }

    /// A thing raised by `rise` points (negative sinks it) and scaled about its middle.
    static func pose(rise: CGFloat, scale: CGFloat = 1) -> CATransform3D {
        CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(0, rise, 0))
    }

    /// Turned toward a point (x, y in -1...1 from the middle) by up to `degrees`, seen in perspective: the side
    /// nearest the pointer turns away, so the face looks toward it.
    static func tilt(toward point: CGPoint, degrees: CGFloat = Tokens.Material.tilt) -> CATransform3D {
        let radians = degrees * .pi / 180
        var perspective = CATransform3DIdentity
        perspective.m34 = Tokens.Material.perspective
        let turn = CATransform3DConcat(CATransform3DMakeRotation(-point.y * radians, 1, 0, 0), CATransform3DMakeRotation(point.x * radians, 0, 1, 0))
        return CATransform3DConcat(turn, perspective)
    }
}

/// A gradient seen only along a line: a rim, a bevel, the lit lip under a recess.
final class GradientStroke {
    let layer = CAGradientLayer()
    private let line = CAShapeLayer()

    init(width: CGFloat = 1) {
        line.fillColor = nil
        line.strokeColor = NSColor.black.cgColor
        line.lineWidth = width
        layer.mask = line
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
    }

    func set(frame: CGRect, path: CGPath) {
        layer.frame = frame
        line.frame = layer.bounds
        line.path = path
    }

    func set(_ colors: [CGColor], at locations: [Double]) {
        layer.colors = colors
        layer.locations = locations.map { NSNumber(value: $0) }
    }
}

/// A shadow cast inside a shape: the shade under a recess's lip, the light along a bevel's top edge.
final class InnerShadow {
    let layer = CALayer()
    private let clip = CAShapeLayer()
    private let caster = CAShapeLayer()

    init() {
        layer.mask = clip
        caster.fillRule = .evenOdd
        layer.addSublayer(caster)
    }

    func set(frame: CGRect, path: CGPath) {
        layer.frame = frame
        clip.frame = layer.bounds
        clip.path = path
        // The outside runs clockwise and the shape (as `MaterialShape` draws it) the other way, so the shadow's own
        // path, which fills by winding, has the shape as its hole.
        let r = layer.bounds.insetBy(dx: -40, dy: -40)
        let outer = CGMutablePath()
        outer.move(to: CGPoint(x: r.minX, y: r.minY))
        outer.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        outer.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        outer.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        outer.closeSubpath()
        outer.addPath(path)
        caster.frame = layer.bounds
        caster.path = outer
        caster.shadowPath = outer
    }

    /// `drop` moves the shadow down (y up), so the shade lands under the top edge; negative lights the bottom one.
    func set(color: CGColor, opacity: Float, radius: CGFloat, drop: CGFloat) {
        caster.fillColor = color
        caster.shadowColor = color
        caster.shadowOpacity = opacity
        caster.shadowRadius = radius
        caster.shadowOffset = CGSize(width: 0, height: -drop)
    }
}

/// The two shadows under a thing standing off a surface: a wide, soft ambient one and a tight contact one. Both
/// are drawn from a path, so they cost nothing to move.
final class CastShadow {
    let ambient = CALayer()
    let contact = CALayer()

    init() {
        for layer in [ambient, contact] { layer.shadowOpacity = 0 }
    }

    func set(frame: CGRect, path: CGPath) {
        for layer in [ambient, contact] {
            layer.frame = frame
            layer.shadowPath = path
        }
    }

    /// `color` tints it (a primary button's shadow is its own color, deepened); `gain` deepens it.
    func apply(_ elevation: Tokens.Material.Elevation, isDark: Bool, color: CGColor? = nil, gain: Float = 1) {
        let ink = color ?? Tokens.Material.shadowInk.cg(isDark)
        let boost = (isDark ? Tokens.Material.darkShadowGain : 1) * gain
        ambient.shadowColor = ink
        ambient.shadowRadius = elevation.ambientRadius
        ambient.shadowOffset = CGSize(width: 0, height: -elevation.ambientDrop)
        ambient.shadowOpacity = min(0.85, elevation.ambientOpacity * boost)
        contact.shadowColor = ink
        contact.shadowRadius = elevation.contactRadius
        contact.shadowOffset = CGSize(width: 0, height: -elevation.contactDrop)
        contact.shadowOpacity = min(0.9, elevation.contactOpacity * boost)
    }
}

enum MaterialImages {
    /// Fine, even grain with its own transparency: random light and dark specks, made once and tiled. The tile is
    /// large (256 points) so its repeat never shows as a pattern across a window.
    static let grain: NSColor = {
        let side = 512
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        // A quick generator: a quarter of a million specks from the system's would hold up launch.
        var state = UInt64.random(in: 1...UInt64.max)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let v: UInt8 = state & 1 == 0 ? 255 : 0
            let a = UInt8(truncatingIfNeeded: state >> 8)
            // Premultiplied.
            let c = UInt8((Int(v) * Int(a)) / 255)
            bytes[i] = c; bytes[i + 1] = c; bytes[i + 2] = c; bytes[i + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return .clear }
        return NSColor(patternImage: NSImage(cgImage: image, size: NSSize(width: side / 2, height: side / 2)))
    }()

    /// A symbol drawn in one color, for a tile that has no picture of its own.
    static func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// Stops a layer's animations where they are while its window is out of sight, and goes on from there.
final class OcclusionPause {
    private var token: Any?
    private weak var layer: CALayer?

    func attach(_ layer: CALayer, to window: NSWindow?) {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        self.layer = layer
        guard let window else { return }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated { self?.update(visible: window?.occlusionState.contains(.visible) ?? false) }
        }
        update(visible: window.occlusionState.contains(.visible))
    }

    private func update(visible: Bool) {
        guard let layer else { return }
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

    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

extension NSView {
    /// A dynamic color resolved for this view, in sRGB, for working out lighter and deeper steps of it.
    func resolved(_ color: NSColor) -> NSColor {
        let cg = cgColor(color)
        return NSColor(cgColor: cg)?.usingColorSpace(.sRGB) ?? color
    }
}

// MARK: - Raised tile

/// The app-icon object, as layers: a body with a gradient, a picture, a bevel (a light top edge, a darker bottom
/// one), a hairline, a specular hot spot that slides toward the pointer, and the two shadows under it. Use it as
/// `RaisedTile`, or put `root` into a 3D scene of your own (onboarding's wall of sites).
final class RaisedTileLayers {
    enum Finish {
        /// A light porcelain body, a breath of `tint` in its lower half: for a site's own logo.
        case porcelain(tint: NSColor?)
        /// A body in a color, for a white symbol.
        case color(NSColor)
    }

    /// Place and turn this in a scene; the tile's own lift and tilt happen inside it.
    let root = CALayer()
    private let cast = CastShadow()
    private let object = CALayer()
    /// Everything that never changes once drawn, rasterized so a wall of tiles costs nothing to move.
    private let face = CALayer()
    private let body = CAGradientLayer()
    private let glyph = CALayer()
    private let bevel = GradientStroke(width: 1)
    private let outline = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private var side: CGFloat = 64

    var finish: Finish = .porcelain(tint: nil) { didSet { refresh() } }
    var image: NSImage? { didSet { refresh() } }
    /// The picture is a square design of its own (a site's icon on its own color): it fills the face, its own
    /// corners trimmed off, as an app icon's artwork does.
    var fillsFace = false { didSet { if oldValue != fillsFace { layout(side: side) } } }
    var isDark = false { didSet { if oldValue != isDark { refresh() } } }
    private(set) var isLifted = false
    private var tilt = CGPoint.zero

    init() {
        root.addSublayer(cast.ambient)
        root.addSublayer(cast.contact)
        root.addSublayer(object)
        object.addSublayer(face)
        [body, glyph, bevel.layer, outline].forEach { face.addSublayer($0) }
        object.addSublayer(sheen)
        body.cornerCurve = .continuous
        body.masksToBounds = true
        body.startPoint = CGPoint(x: 0.5, y: 1)
        body.endPoint = CGPoint(x: 0.5, y: 0)
        glyph.contentsGravity = .resizeAspect
        glyph.minificationFilter = .trilinear
        outline.fillColor = nil
        outline.lineWidth = 0.5
        sheen.type = .radial
        sheen.cornerCurve = .continuous
        sheen.masksToBounds = true
        face.shouldRasterize = true
        refresh()
    }

    func layout(side: CGFloat) {
        self.side = side
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let radius = side * Tokens.Material.tileCorner
        Tokens.Motion.withoutAnimation {
            root.bounds = rect
            object.bounds = rect
            object.position = CGPoint(x: rect.midX, y: rect.midY)
            face.frame = rect
            body.frame = rect
            body.cornerRadius = radius
            if fillsFace {
                glyph.frame = rect
                glyph.contentsRect = CGRect(x: 0.07, y: 0.07, width: 0.86, height: 0.86)
            } else {
                let g = round(side * 0.5)
                glyph.frame = CGRect(x: (side - g) / 2, y: (side - g) / 2, width: g, height: g)
                glyph.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            glyph.cornerRadius = fillsFace ? radius : 0
            glyph.cornerCurve = .continuous
            glyph.masksToBounds = fillsFace
            bevel.set(frame: rect, path: MaterialShape.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5))
            outline.frame = rect
            outline.path = MaterialShape.rounded(rect.insetBy(dx: -0.25, dy: -0.25), radius: radius + 0.25)
            sheen.frame = rect
            sheen.cornerRadius = radius
            // The shadow comes from a little inside the tile's footprint, so it reads as under it.
            cast.set(frame: rect, path: MaterialShape.rounded(rect.insetBy(dx: side * 0.06, dy: side * 0.03), radius: radius))
        }
        applyPose(animated: false)
    }

    private func refresh() {
        let m = Tokens.Material.self
        Tokens.Motion.withoutAnimation {
            switch finish {
            case .porcelain(let tint):
                let bottom = m.porcelainBottom.cg(isDark)
                let tinted = tint.flatMap { NSColor(cgColor: bottom)?.blended(withFraction: 0.12, of: $0)?.cgColor } ?? bottom
                body.colors = [m.porcelainTop.cg(isDark), tinted]
            case .color(let color):
                let c = color.usingColorSpace(.sRGB) ?? color
                body.colors = [(c.blended(withFraction: 0.2, of: .white) ?? c).cgColor, (c.blended(withFraction: 0.18, of: .black) ?? c).cgColor]
            }
            glyph.contents = image
            let rim = m.rim.cg(false), shade = m.bevelShade.cg(isDark)
            bevel.set([rim, rim.copy(alpha: 0)!, shade.copy(alpha: 0)!, shade], at: [0, 0.3, 0.62, 1])
            outline.strokeColor = m.outline.cg(isDark)
            let hot = m.sheen.cg(false)
            sheen.colors = [hot, hot.copy(alpha: 0)!]
        }
        applyPose(animated: false)
    }

    /// Rises off the surface (under the pointer), its shadow growing as it goes.
    func setLifted(_ lifted: Bool, animated: Bool) {
        guard lifted != isLifted else { return }
        isLifted = lifted
        applyPose(animated: animated)
    }

    /// Turns toward a point (x, y in -1...1), its hot spot sliding the same way. `turns` false only moves the light,
    /// for a tile whose scene turns as a whole.
    func setTilt(_ point: CGPoint, turns: Bool = true, animated: Bool) {
        tilt = point
        applyPose(animated: animated, turns: turns)
    }

    private func applyPose(animated: Bool, turns: Bool = true) {
        let scale = side / 64
        MaterialMotion.animate(animated ? Tokens.Material.settle : 0, moves: true) {
            let rise = isLifted && !Tokens.Motion.reduceMotion ? Tokens.Material.tileLift * scale : 0
            let turn = turns && !Tokens.Motion.reduceMotion ? MaterialMotion.tilt(toward: tilt) : CATransform3DIdentity
            object.transform = CATransform3DConcat(turn, CATransform3DMakeTranslation(0, rise, 0))
            cast.apply((isLifted ? Tokens.Material.tileLifted : Tokens.Material.tileRest).scaled(scale), isDark: isDark)
            // The hot spot rides near the top edge, toward the light.
            let cx = 0.5 + tilt.x * 0.4, cy = 1.04 + tilt.y * 0.08
            sheen.startPoint = CGPoint(x: cx, y: cy)
            sheen.endPoint = CGPoint(x: cx + 0.85, y: cy - 0.62)
            sheen.opacity = isLifted ? 1 : 0.8
        }
    }
}

/// A raised tile on its own: hover lifts it, and it turns a few degrees toward the pointer while over it.
final class RaisedTile: InteractiveView {
    let tile = RaisedTileLayers()
    private var moveArea: NSTrackingArea?

    init(side: CGFloat = 64) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        layer?.addSublayer(tile.root)
        setAccessibilityRole(.image)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        tile.layout(side: min(bounds.width, bounds.height))
        Tokens.Motion.withoutAnimation { tile.root.position = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveArea { removeTrackingArea(moveArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        moveArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: max(-1, min(1, (p.x - bounds.midX) / (bounds.width / 2))), y: max(-1, min(1, (p.y - bounds.midY) / (bounds.height / 2))))
        tile.setTilt(point, animated: true)
    }

    override func stateDidChange(animated: Bool) {
        tile.isDark = effectiveAppearance.isDark
        tile.setLifted(isHovered && isEnabled, animated: window != nil)
        if !isHovered { tile.setTilt(.zero, animated: window != nil) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tile.root.applyContentsScale(window?.backingScaleFactor ?? 2)
    }
}

// MARK: - Glass

/// A floating surface of glass, for a brand moment's one panel: Liquid Glass on macOS 26 (frost before it) under a
/// wash brighter at the top, a soft glow just inside the edge, a specular rim on the top edge with a fainter catch
/// light on the bottom one, a hot spot that leans toward `light`, grain, and the two shadows of a floating thing.
/// Put content in `contentView`.
final class GlassSurface: NSView {
    let contentView = NSView()
    var radius: CGFloat { didSet { PanelMaterial.setRadius(radius, of: material); needsLayout = true } }
    /// Where the light is, x and y in -1...1 from the middle: the hot spot leans toward it.
    var light = CGPoint.zero { didSet { applyLight(animated: true) } }

    private let shadowHost = NSView()
    private let cast = CastShadow()
    private let material: NSView
    private let overlay = PassThroughView()
    private let wash = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let glow = InnerShadow()
    private let rim = GradientStroke(width: 1)
    private let outline = CAShapeLayer()
    private let grain = CALayer()

    init(radius: CGFloat = Tokens.Material.heroRadius) {
        self.radius = radius
        material = PanelMaterial.make(radius: radius)
        super.init(frame: .zero)
        wantsLayer = true
        [shadowHost, overlay].forEach { $0.wantsLayer = true }
        shadowHost.layer?.addSublayer(cast.ambient)
        shadowHost.layer?.addSublayer(cast.contact)
        for layer in [wash, sheen, grain] {
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.type = .radial
        grain.backgroundColor = MaterialImages.grain.cgColor
        grain.opacity = Tokens.Material.grainOpacity
        outline.fillColor = nil
        outline.lineWidth = 0.5
        [wash, sheen, grain, glow.layer, rim.layer, outline].forEach { overlay.layer?.addSublayer($0) }
        [shadowHost, material, overlay, contentView].forEach { addSubview($0) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let rect = bounds
        [shadowHost, material, overlay, contentView].forEach { $0.frame = rect }
        let shape = MaterialShape.rounded(rect, radius: radius)
        Tokens.Motion.withoutAnimation {
            cast.set(frame: rect, path: MaterialShape.rounded(rect.insetBy(dx: 16, dy: 8), radius: radius))
            for layer in [wash, sheen, grain] {
                layer.frame = rect
                layer.cornerRadius = radius
            }
            glow.set(frame: rect, path: shape)
            rim.set(frame: rect, path: MaterialShape.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5))
            outline.frame = rect
            outline.path = MaterialShape.rounded(rect.insetBy(dx: -0.25, dy: -0.25), radius: radius + 0.25)
        }
        applyLight(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [shadowHost.layer, overlay.layer].forEach { $0?.applyContentsScale(scale) }
    }

    private func refresh() {
        let m = Tokens.Material.self
        let dark = effectiveAppearance.isDark
        Tokens.Motion.withoutAnimation {
            cast.apply(m.floating, isDark: dark)
            wash.colors = [m.glassWashTop.cg(dark), m.glassWashBottom.cg(dark)]
            let hot = m.sheen.cg(dark)
            sheen.colors = [hot, hot.copy(alpha: 0)!]
            sheen.opacity = 0.7
            // The glow is lit from above: thicker under the top edge than over the bottom one.
            glow.set(color: m.glassGlow.cg(dark), opacity: dark ? 0.45 : 0.75, radius: 10, drop: 3)
            let top = m.rim.cg(dark), catchLight = m.rimCatch.cg(dark)
            rim.set([top, top.copy(alpha: top.alpha * 0.25)!, catchLight.copy(alpha: 0)!, catchLight], at: [0, 0.16, 0.7, 1])
            outline.strokeColor = m.outline.cg(dark)
        }
        applyContentsScaleIfNeeded()
    }

    private func applyContentsScaleIfNeeded() {
        guard let scale = window?.backingScaleFactor else { return }
        [shadowHost.layer, overlay.layer].forEach { $0?.applyContentsScale(scale) }
    }

    private func applyLight(animated: Bool) {
        MaterialMotion.animate(animated ? Tokens.Material.follow : 0) {
            let cx = 0.5 + light.x * 0.35, cy = 1.0 + light.y * 0.06
            sheen.startPoint = CGPoint(x: cx, y: cy)
            sheen.endPoint = CGPoint(x: cx + 0.62, y: cy - 0.5)
        }
    }
}

/// A view for layers that never takes clicks.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Wordmark as a material

/// The drawn ZIGZAG as an object: solid navy with only a fine light along the top edges of its strokes by day; the
/// ribbon's pale blue, beveled, by night. A glint slides toward `light` while `glints` (the pointer is over it).
final class EmbossedWordmark: NSView {
    var light = CGPoint.zero { didSet { applyLight(animated: true) } }
    var glints = false { didSet { if oldValue != glints { MaterialMotion.animate(Tokens.Material.settle) { glint.opacity = glints ? 1 : 0 } } } }
    private let cast = CastShadow()
    private let body = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let glint = CAGradientLayer()
    private let glintMask = CAShapeLayer()
    private let topLight = InnerShadow()
    private let bottomShade = InnerShadow()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        body.mask = bodyMask
        body.startPoint = CGPoint(x: 0.5, y: 1)
        body.endPoint = CGPoint(x: 0.5, y: 0)
        glint.mask = glintMask
        glint.type = .radial
        glint.opacity = 0
        [cast.ambient, cast.contact, body, bottomShade.layer, topLight.layer, glint].forEach { layer?.addSublayer($0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Zigzag")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let path = WordmarkView.outline(in: bounds.insetBy(dx: 2, dy: 2))
        Tokens.Motion.withoutAnimation {
            cast.set(frame: bounds, path: path)
            for (layer, mask) in [(body, bodyMask), (glint, glintMask)] {
                layer.frame = bounds
                mask.frame = bounds
                mask.path = path
            }
            topLight.set(frame: bounds, path: path)
            bottomShade.set(frame: bounds, path: path)
        }
        applyLight(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    private func refresh() {
        let dark = effectiveAppearance.isDark
        Tokens.Motion.withoutAnimation {
            body.colors = dark ? [Tokens.Color.hex(0xFFFFFF).cgColor, Tokens.Color.hex(0xC3D3E7).cgColor]
                : [Tokens.Color.hex(0x23446B).cgColor, Brand.navy.cgColor]
            body.locations = [0, 1]
            topLight.set(color: NSColor.white.cgColor, opacity: dark ? 0.9 : 0.22, radius: 0.4, drop: 0.8)
            bottomShade.set(color: Tokens.Material.shadowInk.cg(dark), opacity: dark ? 0.35 : 0, radius: 1, drop: -1.2)
            let hot = NSColor.white.withAlphaComponent(dark ? 0.9 : 0.5).cgColor
            glint.colors = [hot, hot.copy(alpha: 0)!]
            cast.apply(Tokens.Material.Elevation(ambientRadius: dark ? 7 : 3, ambientDrop: dark ? 5 : 2, ambientOpacity: dark ? 0.2 : 0.08,
                                                 contactRadius: 0.5, contactDrop: 0.5, contactOpacity: dark ? 0.18 : 0.12),
                       isDark: dark, color: dark ? nil : Brand.navy.cgColor)
        }
    }

    private func applyLight(animated: Bool) {
        MaterialMotion.animate(animated ? Tokens.Material.follow : 0) {
            let cx = 0.5 + light.x * 0.5, cy = 0.9 + light.y * 0.2
            glint.startPoint = CGPoint(x: cx, y: cy)
            glint.endPoint = CGPoint(x: cx + 0.22, y: cy - 0.9)
        }
    }
}

// MARK: - Buttons

/// A capsule you can feel: lit along its top edge, a step deeper at the bottom, standing on a contact shadow and a
/// soft ambient one. Under the pointer it rises a point and its shadow grows; pressed it sinks a point, shrinks a
/// touch, its gradient turns over and its shadow tightens, as something pushed in. `.primary` is glossy in the
/// accent with a shadow of its own color (one per surface); `.secondary` is porcelain; `.link` is only words in the
/// accent, underlined under the pointer, for the quieter way on beside a primary. `.large` is a brand moment's one
/// big action.
final class TactileButton: InteractiveView {
    enum Style { case primary, secondary, link }
    enum Size { case regular, large }
    let style: Style
    let size: Size
    var title: String { didSet { refreshText(); invalidateIntrinsicContentSize(); needsLayout = true } }
    /// The accent for `.primary`; nil takes its window's.
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }

    private let cast = CastShadow()
    private let plate = CALayer()
    private let body = CAGradientLayer()
    private let gloss = CAGradientLayer()
    private let pressShade = InnerShadow()
    private let rim = GradientStroke(width: 1)
    private let outline = CAShapeLayer()
    private let text = CATextLayer()
    private var hasAppeared = false

    init(title: String, style: Style = .secondary, size: Size = .regular) {
        self.title = title
        self.style = style
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: size == .large ? Tokens.Material.largeControlHeight : Tokens.Material.controlHeight))
        [cast.ambient, cast.contact, plate].forEach { layer?.addSublayer($0) }
        [body, gloss, pressShade.layer, rim.layer, outline, text].forEach { plate.addSublayer($0) }
        body.startPoint = CGPoint(x: 0.5, y: 1)
        body.endPoint = CGPoint(x: 0.5, y: 0)
        gloss.startPoint = CGPoint(x: 0.5, y: 1)
        gloss.endPoint = CGPoint(x: 0.5, y: 0)
        for layer in [body, gloss] { layer.masksToBounds = true }
        outline.fillColor = nil
        outline.lineWidth = 0.5
        pressShade.layer.opacity = 0
        text.alignmentMode = .center
        text.truncationMode = .end
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        refreshText()
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    private var font: NSFont {
        NSFont.systemFont(ofSize: size == .large ? Tokens.Material.largeText : Tokens.TypeSize.row, weight: style == .primary ? .semibold : .medium)
    }

    var fittingWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width + (style == .link ? Tokens.Space.x3 : Tokens.Space.x6) * 2)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fittingWidth, height: size == .large ? Tokens.Material.largeControlHeight : Tokens.Material.controlHeight)
    }

    override func layout() {
        super.layout()
        let rect = bounds
        let capsule = MaterialShape.capsule(rect)
        layer?.cornerRadius = rect.height / 2   // the focus ring's shape
        Tokens.Motion.withoutAnimation {
            cast.set(frame: rect, path: MaterialShape.capsule(rect.insetBy(dx: 3, dy: 0)))
            plate.bounds = rect
            plate.position = CGPoint(x: rect.midX, y: rect.midY)
            body.frame = rect
            body.cornerRadius = rect.height / 2
            gloss.frame = rect.insetBy(dx: 1, dy: 1)
            gloss.cornerRadius = (rect.height - 2) / 2
            pressShade.set(frame: rect, path: capsule)
            rim.set(frame: rect, path: MaterialShape.capsule(rect.insetBy(dx: 0.5, dy: 0.5)))
            outline.frame = rect
            outline.path = MaterialShape.capsule(rect.insetBy(dx: -0.25, dy: -0.25))
            let line = ceil(font.ascender - font.descender + font.leading)
            // Optically centered: a hair above the box's middle, as capitals sit.
            text.frame = CGRect(x: Tokens.Space.x3, y: round((rect.height - line) / 2) + 0.5, width: rect.width - Tokens.Space.x3 * 2, height: line)
        }
    }

    private func refreshText() {
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func stateDidChange(animated: Bool) {
        let m = Tokens.Material.self
        let dark = effectiveAppearance.isDark
        let pressed = isPressed && isEnabled, hovered = isHovered && isEnabled
        var ink = Tokens.Color.textPrimary
        let duration = !animated || window == nil ? 0 : pressed ? m.pressIn : m.settle
        MaterialMotion.animate(duration) {
            [cast.ambient, cast.contact, body, gloss, rim.layer, outline].forEach { $0.isHidden = style == .link }
            switch style {
            case .link:
                ink = resolved(tint ?? Brand.Theme.for(self).accent)
                if pressed { ink = ink.withAlphaComponent(0.7) }
            case .primary:
                // The deep accent in both modes: glossy and saturated, white text on it at AA.
                let accent = tint ?? Brand.Theme.for(self).accent
                var deep = accent.cgColor
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { deep = accent.cgColor }
                let base = NSColor(cgColor: deep)?.usingColorSpace(.sRGB) ?? accent
                let top = base.blended(withFraction: hovered ? 0.3 : 0.22, of: .white) ?? base
                let bottom = base.blended(withFraction: 0.16, of: .black) ?? base
                body.colors = pressed ? [bottom.cgColor, base.cgColor] : [top.cgColor, base.cgColor, bottom.cgColor]
                body.locations = pressed ? [0, 1] : [0, 0.55, 1]
                let white = NSColor.white
                // The specular band: bright along the top, gone by the middle.
                gloss.colors = [white.withAlphaComponent(dark ? 0.4 : 0.34).cgColor, white.withAlphaComponent(0.08).cgColor, white.withAlphaComponent(0).cgColor]
                gloss.locations = [0, 0.48, 0.62]
                gloss.opacity = pressed ? 0.35 : 1
                rim.set([white.withAlphaComponent(0.6).cgColor, white.withAlphaComponent(0.1).cgColor,
                         white.withAlphaComponent(0).cgColor, white.withAlphaComponent(0.25).cgColor], at: [0, 0.4, 0.7, 1])
                outline.strokeColor = (base.blended(withFraction: 0.5, of: .black) ?? base).withAlphaComponent(0.6).cgColor
                let shade = (base.blended(withFraction: 0.45, of: .black) ?? base).cgColor
                cast.apply(pressed ? m.raisedPressed : hovered ? m.raisedHover : m.raisedRest, isDark: dark, color: shade, gain: dark ? 1 : 2.2)
                ink = m.primaryInk
            case .secondary:
                body.colors = pressed ? [m.pressedTop.cg(dark), m.pressedBottom.cg(dark)] : [m.raisedTop.cg(dark), m.raisedBottom.cg(dark)]
                body.locations = [0, 1]
                let white = NSColor.white
                gloss.colors = [white.withAlphaComponent(dark ? 0.06 : 0.5).cgColor, white.withAlphaComponent(0).cgColor]
                gloss.locations = [0, 0.5]
                gloss.opacity = pressed ? 0 : 1
                let top = m.rim.cg(dark)
                rim.set([top, top.copy(alpha: 0)!, top.copy(alpha: 0)!], at: [0, 0.45, 1])
                outline.strokeColor = m.outline.cg(dark)
                cast.apply(pressed ? m.raisedPressed : hovered ? m.raisedHover : m.raisedRest, isDark: dark)
                ink = resolved(Tokens.Color.textPrimary)
            }
            pressShade.set(color: m.recessShade.cg(dark), opacity: 0.5, radius: 3, drop: 1.5)
            pressShade.layer.opacity = pressed ? 1 : 0
            let rise = style == .link ? 0 : pressed ? -m.sink : hovered ? m.lift : 0
            plate.transform = Tokens.Motion.reduceMotion ? CATransform3DIdentity : MaterialMotion.pose(rise: rise, scale: pressed ? m.pressScale : 1)
        }
        // Letterpress: light text stands on a dark hairline, dark text on a light one.
        let lightInk = Tokens.Color.luminance(of: ink) > 0.5
        Tokens.Motion.withoutAnimation {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            if style == .link, hovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            text.string = NSAttributedString(string: title, attributes: attributes)
            text.shadowColor = (lightInk ? NSColor.black : NSColor.white).cgColor
            text.shadowOpacity = style == .link ? 0 : lightInk ? 0.25 : (dark ? 0 : 0.6)
            text.shadowRadius = 0
            text.shadowOffset = CGSize(width: 0, height: lightInk ? 0.5 : -0.5)
        }
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

// MARK: - Toggle

/// A switch you can feel: a glassy knob, lit at the top with a specular spot and standing on its own shadows, in a
/// track set into the surface (shaded under its top lip, the lower lip catching light). On, the accent fills the
/// track. Pressed, the knob stretches toward where it's going. With a title, the whole row is the control.
final class TactileToggle: InteractiveView {
    var onChange: ((Bool) -> Void)?
    var isOn: Bool { didSet { if oldValue != isOn { stateDidChange(animated: window != nil) } } }
    /// The accent when on; nil takes its window's.
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }

    static let trackSize = NSSize(width: 46, height: 28)
    private static let inset: CGFloat = 2

    private let label: Label?
    private let track = CALayer()
    private let trackBody = CAGradientLayer()
    private let trackFill = CAGradientLayer()
    private let trackShade = InnerShadow()
    private let lip = GradientStroke(width: 1)
    private let knob = CALayer()
    private let knobShadow = CastShadow()
    private let knobBody = CAGradientLayer()
    private let knobSpecular = CAGradientLayer()
    private let knobRim = GradientStroke(width: 1)

    init(title: String? = nil, isOn: Bool = false) {
        self.isOn = isOn
        label = title.map { Label($0, font: Tokens.Font.row(), color: Tokens.Color.textPrimary) }
        super.init(frame: NSRect(origin: .zero, size: Self.trackSize))
        label.map { addSubview($0) }
        layer?.addSublayer(track)
        [lip.layer, trackBody, trackFill, trackShade.layer, knob].forEach { track.addSublayer($0) }
        [knobShadow.ambient, knobShadow.contact, knobBody, knobSpecular, knobRim.layer].forEach { knob.addSublayer($0) }
        for layer in [trackBody, trackFill, knobBody] {
            layer.startPoint = CGPoint(x: 0.5, y: 1)
            layer.endPoint = CGPoint(x: 0.5, y: 0)
            layer.masksToBounds = true
        }
        knobSpecular.type = .radial
        knobSpecular.masksToBounds = true
        onClick = { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    override var intrinsicContentSize: NSSize {
        guard let label else { return Self.trackSize }
        return NSSize(width: label.inkWidth + Tokens.Space.x4 + Self.trackSize.width, height: max(Self.trackSize.height, Tokens.Space.x8))
    }

    private var trackFrame: CGRect {
        CGRect(x: bounds.maxX - Self.trackSize.width, y: round((bounds.height - Self.trackSize.height) / 2),
               width: Self.trackSize.width, height: Self.trackSize.height)
    }

    private func knobFrame(stretched: Bool) -> CGRect {
        let side = Self.trackSize.height - Self.inset * 2
        let width = side + (stretched && !Tokens.Motion.reduceMotion ? 5 : 0)
        let x = isOn ? Self.trackSize.width - Self.inset - width : Self.inset
        return CGRect(x: x, y: Self.inset, width: width, height: side)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Tokens.Radius.row
        if let label {
            label.frame = NSRect(x: -Label.inset, y: round((bounds.height - label.lineHeight) / 2), width: trackFrame.minX - Tokens.Space.x2, height: label.lineHeight)
        }
        let local = CGRect(origin: .zero, size: Self.trackSize)
        let r = local.height / 2
        Tokens.Motion.withoutAnimation {
            track.frame = trackFrame
            for layer in [trackBody, trackFill] {
                layer.frame = local
                layer.cornerRadius = r
            }
            trackShade.set(frame: local, path: MaterialShape.capsule(local))
            // The lit lower lip sits just outside the track.
            let lipRect = local.insetBy(dx: -1, dy: -1)
            lip.set(frame: lipRect, path: MaterialShape.capsule(CGRect(origin: .zero, size: lipRect.size).insetBy(dx: 0.5, dy: 0.5)))
        }
        layoutKnob(animated: false)
    }

    private func layoutKnob(animated: Bool) {
        let frame = knobFrame(stretched: isPressed)
        let local = CGRect(origin: .zero, size: frame.size)
        MaterialMotion.animate(animated ? (isPressed ? Tokens.Material.pressIn : Tokens.Material.settle) : 0, moves: true) {
            knob.frame = frame
            knobShadow.set(frame: local, path: MaterialShape.capsule(local.insetBy(dx: 1, dy: 1)))
            for layer in [knobBody, knobSpecular] {
                layer.frame = local
                layer.cornerRadius = local.height / 2
            }
            knobRim.set(frame: local, path: MaterialShape.capsule(local.insetBy(dx: 0.5, dy: 0.5)))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func stateDidChange(animated: Bool) {
        let m = Tokens.Material.self
        let dark = effectiveAppearance.isDark
        let accent = resolved(tint ?? Brand.Theme.for(self).accent)
        MaterialMotion.animate(animated && window != nil ? m.settle : 0) {
            trackBody.colors = [m.recessTop.cg(dark), m.recessBottom.cg(dark)]
            // On, the accent is set into the track too: deeper under the lip, lighter toward the bottom.
            trackFill.colors = [(accent.blended(withFraction: 0.18, of: .black) ?? accent).cgColor, (accent.blended(withFraction: 0.12, of: .white) ?? accent).cgColor]
            trackFill.opacity = isOn ? 1 : 0
            trackShade.set(color: m.recessShade.cg(dark), opacity: isOn ? 0.55 : 0.4, radius: 2.5, drop: 1.2)
            let lipColor = m.lip.cg(dark)
            lip.set([lipColor.copy(alpha: 0)!, lipColor.copy(alpha: 0)!, lipColor], at: [0, 0.55, 1])
            knobBody.colors = [m.porcelainTop.cg(false), m.porcelainBottom.cg(false)]
            let white = NSColor.white
            knobSpecular.colors = [white.withAlphaComponent(0.95).cgColor, white.withAlphaComponent(0).cgColor]
            knobSpecular.startPoint = CGPoint(x: 0.5, y: 0.92)
            knobSpecular.endPoint = CGPoint(x: 0.95, y: 0.55)
            let shade = m.bevelShade.cg(false)
            knobRim.set([white.cgColor, white.withAlphaComponent(0).cgColor, shade.copy(alpha: 0)!, shade], at: [0, 0.45, 0.7, 1])
            knobShadow.apply(Tokens.Material.Elevation(ambientRadius: 3, ambientDrop: 2, ambientOpacity: 0.22, contactRadius: 0.5, contactDrop: 0.5, contactOpacity: 0.3), isDark: dark)
        }
        layoutKnob(animated: animated && window != nil)
        label?.textColor = Tokens.Color.textPrimary
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

// MARK: - Field

/// A field set into the surface: darker under its top lip, an inner shadow beneath that lip, the lower lip catching
/// the light. Typing in it, the accent rings it and glows softly.
final class RecessedField: NSView {
    let field: PlainTextField
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    /// Capsule ends (the default), or the field radius.
    var isPill = true { didSet { needsLayout = true } }
    /// The ring's color; nil takes its window's accent.
    var tint: NSColor? { didSet { refresh(animated: false) } }

    private let well = PassThroughView()
    private let body = CAGradientLayer()
    private let shade = InnerShadow()
    private let lip = GradientStroke(width: 1)
    private let ring = CAShapeLayer()
    private let symbolView: NSImageView?

    init(placeholder: String, symbol: String? = nil) {
        field = PlainTextField(font: Tokens.Font.row(), placeholder: placeholder)
        symbolView = symbol.map {
            let view = NSImageView(image: Tokens.Symbol.image($0, size: Tokens.TypeSize.row))
            view.contentTintColor = Tokens.Color.textSecondary
            view.imageScaling = .scaleNone
            return view
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Tokens.Material.controlHeight))
        wantsLayer = true
        well.wantsLayer = true
        body.startPoint = CGPoint(x: 0.5, y: 1)
        body.endPoint = CGPoint(x: 0.5, y: 0)
        body.masksToBounds = true
        body.cornerCurve = .continuous
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.opacity = 0
        [lip.layer, body, shade.layer, ring].forEach { well.layer?.addSublayer($0) }
        addSubview(well)
        symbolView.map { addSubview($0) }
        addSubview(field)
        field.setAccessibilityLabel(placeholder)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: NSControl.textDidBeginEditingNotification, object: field)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: NSControl.textDidEndEditingNotification, object: field)
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    private var isEditing: Bool { field.currentEditor() != nil }
    @objc private func editingChanged() { refresh(animated: true) }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    override func layout() {
        super.layout()
        well.frame = bounds
        let radius = isPill ? bounds.height / 2 : Tokens.Radius.field
        let rect = bounds
        Tokens.Motion.withoutAnimation {
            body.frame = rect
            body.cornerRadius = radius
            shade.set(frame: rect, path: MaterialShape.rounded(rect, radius: radius))
            let lipRect = rect.insetBy(dx: -1, dy: -1)
            lip.set(frame: lipRect, path: MaterialShape.rounded(CGRect(origin: .zero, size: lipRect.size).insetBy(dx: 0.5, dy: 0.5), radius: radius + 0.5))
            ring.frame = rect
            ring.path = MaterialShape.rounded(rect.insetBy(dx: 0.75, dy: 0.75), radius: radius - 0.75)
        }
        let h = ceil(field.intrinsicContentSize.height)
        var x = isPill ? Tokens.Space.x4 : Tokens.Space.x3
        if let symbolView {
            let side = Tokens.Space.x5
            symbolView.frame = NSRect(x: x - 2, y: round((bounds.height - side) / 2), width: side, height: side)
            x = symbolView.frame.maxX + Tokens.Space.x2 - 2
        }
        field.frame = NSRect(x: x, y: round((bounds.height - h) / 2), width: bounds.width - x - Tokens.Space.x4, height: h)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh(animated: false)
        well.layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        well.layer?.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    private func refresh(animated: Bool) {
        let m = Tokens.Material.self
        let dark = effectiveAppearance.isDark
        let accent = resolved(tint ?? Brand.Theme.for(self).accent)
        MaterialMotion.animate(animated ? Tokens.Motion.selection : 0) {
            body.colors = [m.recessTop.cg(dark), m.recessBottom.cg(dark)]
            shade.set(color: m.recessShade.cg(dark), opacity: 0.45, radius: 3, drop: 1.5)
            let lipColor = m.lip.cg(dark)
            lip.set([lipColor.copy(alpha: 0)!, lipColor.copy(alpha: 0)!, lipColor], at: [0, 0.55, 1])
            ring.strokeColor = accent.withAlphaComponent(0.75).cgColor
            ring.shadowColor = accent.cgColor
            ring.shadowRadius = 5
            ring.shadowOffset = .zero
            ring.shadowOpacity = 0.5
            ring.opacity = isEditing ? 1 : 0
        }
    }
}

// MARK: - Sky

/// The world a brand moment stands in: Zigzag's own colors as a sky, pale ribbon blue by day and deep navy by night,
/// a few soft fields of color drifting in it (`Atmosphere`), grain, and the light everything is lit by, falling from
/// above. Drifts only while the window is seen, and holds still with Reduce Motion.
final class SkyBackdrop: NSView {
    /// A color the sky leans toward (the space in front), easing there over a second; nil is Zigzag's own.
    var tint: NSColor? { didSet { atmosphere.applyColors(animated: window != nil && !Tokens.Motion.reduceMotion) } }
    private let atmosphere = Atmosphere()
    private let lightView = PassThroughView()
    private let sun = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        atmosphere.customPalette = { [weak self] dark in Self.palette(dark: dark, tint: self?.tint) }
        lightView.wantsLayer = true
        sun.type = .radial
        lightView.layer?.addSublayer(sun)
        [atmosphere, lightView].forEach { addSubview($0) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func palette(dark: Bool, tint: NSColor?) -> Atmosphere.Palette {
        let hex = Tokens.Color.hex
        // The tint colors two of the fields a little: the sky leans toward it rather than turning into it.
        func lean(_ color: NSColor, _ amount: CGFloat) -> NSColor {
            guard let tint = tint?.usingColorSpace(.sRGB), let c = color.usingColorSpace(.sRGB) else { return color }
            return (c.blended(withFraction: amount, of: tint) ?? c).withAlphaComponent(c.alphaComponent)
        }
        if dark {
            return Atmosphere.Palette(top: hex(0x10213A, 1), bottom: hex(0x050A13, 1),
                                      fields: [lean(hex(0x1E3A5F, 0.9), 0.35), hex(0x0A1424, 0.8), lean(hex(0x335E8F, 0.55), 0.5), hex(0x284B75, 0.6)])
        }
        return Atmosphere.Palette(top: hex(0xE4EDF7, 1), bottom: hex(0xC9D7E8, 1),
                                  fields: [lean(hex(0xF4F7FB, 0.9), 0.3), hex(0xB4C8DF, 0.55), lean(hex(0xDAE5F2, 0.9), 0.45), hex(0xFFFFFF, 0.7)])
    }

    override func layout() {
        super.layout()
        atmosphere.frame = bounds
        lightView.frame = bounds
        Tokens.Motion.withoutAnimation {
            sun.frame = bounds
            // A wide pool of light from above the top edge, falling off by two thirds of the way down.
            sun.startPoint = CGPoint(x: 0.5, y: 1.08)
            sun.endPoint = CGPoint(x: 1.15, y: 0.3)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let dark = effectiveAppearance.isDark
        let light = dark ? Brand.ribbon.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.75)
        Tokens.Motion.withoutAnimation {
            sun.colors = [light.cgColor, light.withAlphaComponent(light.alphaComponent * 0.35).cgColor, light.withAlphaComponent(0).cgColor]
            sun.locations = [0, 0.45, 1]
        }
    }
}

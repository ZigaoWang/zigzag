import AppKit

/// The space's color wheel: a disc of small dots, each painted the very color it gives. Around the disc picks the
/// hue, and out from the middle how much of it: the rim is the color at its fullest, the middle no color at all,
/// white, a gray or black. Every dot shows at the depth the Shade slider sets. Drag a knob, or click anywhere to bring
/// the selected knob there. With two colors there are two knobs; clicking one selects it.
final class ColorWheel: NSView {
    struct Spot: Equatable {
        var hue: Double
        /// How much color, from none in the middle (0) to all of it at the rim (1).
        var amount: Double
    }

    /// One or two: the color, or where a gradient starts and ends.
    private(set) var spots: [Spot] = [Spot(hue: 0.6, amount: 1)]
    /// How deep each knob's color is, for its fill.
    private(set) var depths: [Double] = [0.3]
    /// The knob the wheel, the Shade slider and VoiceOver act on.
    private(set) var selected = 0
    /// Called while dragging (`final` false) and once on release (`final` true), with which knob moved.
    var onChange: ((Int, Spot, Bool) -> Void)?
    /// A knob was clicked and is now the selected one.
    var onSelect: ((Int) -> Void)?

    private let dots = CALayer()
    /// A faint disc behind the dots, so the wheel stays round where its deepest colors meet a dark panel.
    private let disc = CALayer()
    private let knobs = [WheelKnob(), WheelKnob()]
    /// With a gradient, a line from one knob to the other: the two are one gradient, from here to there.
    private let link = CAShapeLayer()
    private var paintedSize: CGSize = .zero
    private var paintedDepth: Double = -1
    private var pressed: Int?
    private var shownCount = 1
    private let elements = [KnobElement(), KnobElement()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        layer?.addSublayer(dots)
        link.fillColor = nil
        link.strokeColor = NSColor.white.cgColor
        link.lineWidth = 2
        link.lineCap = .round
        link.shadowColor = NSColor.black.cgColor
        link.shadowOpacity = 0.25
        link.shadowRadius = 1.5
        link.shadowOffset = .zero
        layer?.addSublayer(link)
        knobs.forEach { layer?.addSublayer($0.layer) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Color")
        for (i, element) in elements.enumerated() {
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.slider)
            element.setAccessibilityLabel(i == 0 ? "Color" : "Second color")
            element.step = { [weak self] amount, hue in self?.nudge(i, amount: amount, hue: hue) }
            element.addHueActions()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Shows these spots, the dots at the selected one's depth; `animated` glides the knobs there, as when a preset is
    /// picked, and a second knob comes out of the first.
    func show(_ spots: [Spot], depths: [Double], selected: Int, animated: Bool) {
        self.spots = spots
        self.depths = depths
        self.selected = min(selected, spots.count - 1)
        if abs(depths[self.selected] - paintedDepth) > 0.001 { paintDots() }
        placeKnobs(animated: animated && !Tokens.Motion.reduceMotion)
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    /// Room for a whole knob, and a little more, around the dots, so one at the rim never leaves the wheel's frame.
    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 - 14 }

    private func point(_ spot: Spot) -> CGPoint {
        let a = spot.hue * 2 * .pi - .pi / 2
        let r = radius * CGFloat(spot.amount)
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    private func spot(at p: CGPoint, keeping hue: Double) -> Spot {
        let dx = p.x - center.x, dy = p.y - center.y
        let amount = min(Double(hypot(dx, dy) / radius), 1)
        // Right in the middle every hue is the same gray: keep the one it had.
        guard amount > 0.03 else { return Spot(hue: hue, amount: amount) }
        var h = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if h < 0 { h += 1 }
        return Spot(hue: Double(h), amount: amount)
    }

    override func layout() {
        super.layout()
        if bounds.size != paintedSize { paintDots() }
        Tokens.Motion.withoutAnimation {
            let r = radius + 6
            disc.frame = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            disc.cornerRadius = r
            effectiveAppearance.performAsCurrentDrawingAppearance { disc.backgroundColor = Tokens.Color.fieldFill.cgColor }
        }
        placeKnobs(animated: false)
    }

    /// The dots on a honeycomb, so the disc's edge reads round, painted again whenever the depth changes.
    private func paintDots() {
        paintedSize = bounds.size
        let depth = depths[min(selected, depths.count - 1)]
        paintedDepth = depth
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let step: CGFloat = 9.6, size: CGFloat = 6
        let rowStep = step * 0.866
        let rows = Int(radius / rowStep)
        for row in -rows...rows {
            let y = center.y + CGFloat(row) * rowStep
            let offset = row % 2 == 0 ? 0 : step / 2
            let columns = Int(radius / step) + 1
            for column in -columns...columns {
                let x = center.x + CGFloat(column) * step + offset
                guard hypot(x - center.x, y - center.y) <= radius - size / 2 + 0.5 else { continue }
                let spot = spot(at: CGPoint(x: x, y: y), keeping: 0)
                context.setFillColor(SpaceColor.paint(hue: spot.hue, depth: depth, tint: spot.amount).cgColor)
                context.fillEllipse(in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
            }
        }
        Tokens.Motion.withoutAnimation {
            dots.frame = bounds
            dots.contentsScale = scale
            dots.contents = context.makeImage()
        }
    }

    private func placeKnobs(animated: Bool) {
        // A second knob just added starts on the first and slides out from it.
        if animated, spots.count > shownCount, spots.count > 1 {
            Tokens.Motion.withoutAnimation {
                knobs[1].layer.position = point(spots[0])
                knobs[1].layer.isHidden = false
            }
        }
        shownCount = spots.count
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.standard)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        for (i, knob) in knobs.enumerated() {
            knob.layer.isHidden = i >= spots.count
            guard i < spots.count else { continue }
            knob.layer.position = point(spots[i])
            knob.fill = SpaceColor.paint(hue: spots[i].hue, depth: depths[i], tint: spots[i].amount)
            // With two, the one not selected sits a little smaller and lower.
            knob.isSelected = spots.count == 1 || i == selected
            knob.layer.zPosition = pressed == i ? 3 : i == selected ? 2 : 1
        }
        if spots.count > 1 {
            let path = CGMutablePath()
            path.move(to: point(spots[0]))
            path.addLine(to: point(spots[1]))
            link.frame = bounds
            link.path = path
            link.isHidden = false
        } else {
            link.isHidden = true
        }
        CATransaction.commit()
        for (i, element) in elements.enumerated() where i < spots.count {
            let p = point(spots[i])
            element.setAccessibilityFrameInParentSpace(NSRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
            element.setAccessibilityValue(Self.describe(spots[i]))
        }
        setAccessibilityChildren(Array(elements.prefix(spots.count)))
    }

    /// What VoiceOver says for a knob: the color's family, and how much of it.
    static func describe(_ spot: Spot) -> String {
        guard spot.amount > 0.005 else { return "No color" }
        let names: [(Double, String)] = [(0.04, "Red"), (0.11, "Orange"), (0.18, "Yellow"), (0.43, "Green"), (0.53, "Teal"),
                                         (0.7, "Blue"), (0.83, "Purple"), (0.96, "Pink"), (1.01, "Red")]
        let name = names.first { spot.hue < $0.0 }?.1 ?? "Red"
        return "\(name), \(Int((spot.amount * 100).rounded())) percent color"
    }

    /// Within a knob's reach, clicking takes hold of it without moving it.
    private func knob(at p: CGPoint) -> Int? {
        let distances = spots.indices.map { (index: $0, distance: hypot(point(spots[$0]).x - p.x, point(spots[$0]).y - p.y)) }
        // Over both, the selected one wins, since it's drawn on top.
        let hits = distances.filter { $0.distance <= 14 }
        return hits.first { $0.index == selected }?.index ?? hits.min { $0.distance < $1.distance }?.index
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let index = knob(at: p) ?? selected
        // Grabbed off-center, a knob keeps that offset rather than jumping under the pointer.
        let grip = knob(at: p).map { CGPoint(x: point(spots[$0]).x - p.x, y: point(spots[$0]).y - p.y) } ?? .zero
        if index != selected {
            selected = index
            onSelect?(index)
        }
        pressed = index
        var moved = knob(at: p) == nil
        if moved { move(index, to: p, final: false) } else { placeKnobs(animated: false) }
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            let q = self.convert(event.locationInWindow, from: nil)
            let target = CGPoint(x: q.x + grip.x, y: q.y + grip.y)
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.pressed = nil
                if moved { self.move(index, to: target, final: true) } else { self.placeKnobs(animated: false) }
            } else {
                moved = true
                self.move(index, to: target, final: false)
            }
        }
    }

    private func move(_ index: Int, to p: CGPoint, final: Bool) {
        guard index < spots.count else { return }
        var spot = spot(at: p, keeping: spots[index].hue)
        // The middle holds on a little, with a tap, so no color at all is easy to land on.
        if spot.amount < 0.07 {
            if spots[index].amount > 0 { Haptics.snap() }
            spot.amount = 0
        }
        spots[index] = spot
        placeKnobs(animated: false)
        onChange?(index, spot, final)
    }

    /// VoiceOver: more or less color, or the next hue around.
    private func nudge(_ index: Int, amount: Double, hue: Double) {
        guard index < spots.count else { return }
        var spot = spots[index]
        spot.amount = min(max(spot.amount + amount, 0), 1)
        spot.hue = (spot.hue + hue + 1).truncatingRemainder(dividingBy: 1)
        spots[index] = spot
        placeKnobs(animated: false)
        onChange?(index, spot, true)
    }
}

/// A knob on the wheel, for VoiceOver: up and down is how much color, and two actions turn it to the next hue.
nonisolated private final class KnobElement: NSAccessibilityElement {
    var step: (@MainActor @Sendable (Double, Double) -> Void)?

    func addHueActions() {
        let step = step
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Next hue") { MainActor.assumeIsolated { step?(0, 1 / 12) }; return true },
            NSAccessibilityCustomAction(name: "Previous hue") { MainActor.assumeIsolated { step?(0, -1 / 12) }; return true },
        ])
    }

    override func accessibilityPerformIncrement() -> Bool {
        let step = step
        MainActor.assumeIsolated { step?(0.1, 0) }
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        let step = step
        MainActor.assumeIsolated { step?(-0.1, 0) }
        return true
    }
}

/// A knob on the wheel: the chosen color in a white ring, lifted by a soft shadow.
private final class WheelKnob {
    let layer = CALayer()
    private let inner = CALayer()
    var fill: NSColor = .white { didSet { inner.backgroundColor = fill.cgColor } }
    var isSelected = true {
        didSet {
            layer.setAffineTransform(isSelected ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8))
            layer.shadowOpacity = isSelected ? 0.3 : 0.18
        }
    }

    init() {
        let size: CGFloat = 24
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        layer.backgroundColor = .white
        layer.shadowColor = .black
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        inner.frame = layer.bounds.insetBy(dx: 3.5, dy: 3.5)
        inner.cornerRadius = inner.frame.width / 2
        inner.borderWidth = Tokens.Metric.hairline
        inner.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer.addSublayer(inner)
    }
}

/// A ready-made look: one of the curated colors, which follows the Mac between its soft day and deep night shades.
struct SpaceLook {
    let name: String
    /// One of the curated colors.
    var curated: SpaceColor? = nil
    var hue: Double = 0
    /// How much color: 0 for white, grays and black.
    var tint: Double = 1
    var depth: Double
    var hue2: Double? = nil
    var depth2: Double = 0
    var angle: Double = 90
    var seeThrough: Double = 0
    var grain: Double = 0

    /// How it looks as a space.
    var space: SpaceInfo {
        var space = SpaceInfo(name: name, color: .graphite)
        apply(to: &space)
        return space
    }

    /// A curated color, as a preset: light by day and deep at night with the Mac, with any see-through and grain.
    static func curated(_ color: SpaceColor, name: String? = nil, seeThrough: Double = 0, grain: Double = 0) -> SpaceLook {
        SpaceLook(name: name ?? color.name, curated: color, depth: 0, seeThrough: seeThrough, grain: grain)
    }

    /// A preset is the whole look: its see-through and grain come with it, and one without them is solid and smooth.
    func apply(to space: inout SpaceInfo) {
        space.glass = nil
        space.grain = grain > 0 ? grain : nil
        if let curated {
            space.color = curated
            space.hue = nil
            space.tint = nil
            space.intensity = nil
            space.brightness = nil
            space.hue2 = nil
            space.tint2 = nil
            space.intensity2 = nil
            space.brightness2 = nil
            space.translucency = seeThrough > 0 ? seeThrough : nil
            space.appearance = nil
            return
        }
        if tint < 0.005 {
            space.hue = nil
            space.color = .graphite
            space.tint = 0
        } else {
            space.hue = hue
            space.tint = tint > 0.995 ? nil : tint
        }
        space.intensity = nil
        space.brightness = depth
        space.hue2 = hue2
        // The second color as quiet as the first.
        space.tint2 = hue2 == nil || tint > 0.995 ? nil : tint
        space.intensity2 = nil
        space.brightness2 = hue2 == nil ? nil : depth2
        if hue2 != nil { space.angle = angle }
        space.translucency = seeThrough > 0 ? seeThrough : nil
    }

    func matches(_ space: SpaceInfo) -> Bool {
        guard abs((space.grain ?? 0) - grain) < 0.01 else { return false }
        if let curated {
            return space.hue == nil && space.color == curated && space.brightness == nil && space.hue2 == nil
                && abs(space.seeThrough - seeThrough) < 0.01 && (curated.isNeutral || space.tintAmount > 0.99)
        }
        // A space saved as the old white or black (no Shade of its own) is the White or Black here.
        if space.brightness == nil, space.hue == nil, space.hue2 == nil, hue2 == nil, tint < 0.005, seeThrough == 0, !space.isSeeThrough,
           space.color == .snow || space.color == .ink {
            return depth == (space.color == .snow ? 0 : 1)
        }
        guard let b = space.brightness, abs(b - depth) < 0.005, abs(space.seeThrough - seeThrough) < 0.01 else { return false }
        if tint < 0.005 {
            guard space.isNeutral else { return false }
        } else {
            guard !space.isNeutral, let h = space.hue, abs(h - hue) < 0.002, abs(space.tintAmount - tint) < 0.01 else { return false }
        }
        guard let hue2 else { return space.hue2 == nil }
        guard let h2 = space.hue2, abs(h2 - hue2) < 0.002, abs((space.brightness2 ?? b) - depth2) < 0.005,
              abs(space.tintAmount2 - min(tint, 1)) < 0.01 else { return false }
        return true
    }

    /// Two rows of looks taken from real materials, muted, each its own color. First white, black, clear and smoky
    /// glass, then the deep ones. Then paper and the light ones, warm to cool, the last of them glass. Every one is a
    /// spot on the wheel, a Shade and the effects, so whatever a preset gives, the controls show and can reach.
    static let presets: [SpaceLook] = [
        SpaceLook(name: "White", tint: 0, depth: 0),
        SpaceLook(name: "Black", tint: 0, depth: 1),
        SpaceLook(name: "Glass", tint: 0, depth: 0.02, seeThrough: 0.7),
        SpaceLook(name: "Smoke", tint: 0, depth: 0.9, seeThrough: 0.6),
        fade("Charcoal", 0.08, 0.84, 0.08, 0.94, tint: 0.12, grain: 0.3),
        fade("Espresso", 0.07, 0.8, 0.07, 0.93, tint: 0.45),
        fade("Oxblood", 0.99, 0.78, 0.99, 0.92, tint: 0.5),
        fade("Pine", 0.42, 0.8, 0.42, 0.93, tint: 0.45),
        fade("Slate", 0.62, 0.76, 0.62, 0.9, tint: 0.35),
        SpaceLook(name: "Paper", hue: 0.11, tint: 0.55, depth: 0.1, grain: 0.5),
        fade("Oat", 0.1, 0.02, 0.1, 0.26, tint: 0.45),
        fade("Butter", 0.13, 0.02, 0.13, 0.26),
        fade("Clay", 0.075, 0.06, 0.06, 0.36, tint: 0.55),
        fade("Rose", 0.97, 0.04, 0.97, 0.32, tint: 0.55),
        fade("Matcha", 0.12, 0.02, 0.27, 0.32),
        fade("Mint", 0.46, 0.03, 0.46, 0.32, tint: 0.55),
        fade("Sky", 0.6, 0.04, 0.6, 0.34, tint: 0.6),
        fade("Frost", 0.6, 0.02, 0.6, 0.18, tint: 0.3, seeThrough: 0.5),
    ]

    /// A quiet fade, top to bottom, from one color to a shade (or a neighbor) of it.
    private static func fade(_ name: String, _ hue: Double, _ depth: Double, _ hue2: Double, _ depth2: Double, tint: Double = 1,
                             grain: Double = 0, seeThrough: Double = 0) -> SpaceLook {
        SpaceLook(name: name, hue: hue, tint: tint, depth: depth, hue2: hue2, depth2: depth2, angle: 90, seeThrough: seeThrough, grain: grain)
    }
}

/// A small checkerboard, the usual sign for see-through.
enum Checker {
    static let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor(white: 0.97, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSRect(x: 4, y: 4, width: 4, height: 4).fill()
        return true
    }
}

/// One preset: a round swatch of the look, ringed when it's the one in use. A see-through one shows over a checkerboard,
/// a grainy one with its grain.
final class LookSwatch: InteractiveView {
    let look: SpaceLook
    private let fill = CAGradientLayer()
    private let checker = CALayer()
    private let grain = CALayer()
    private let ring = CALayer()

    init(look: SpaceLook) {
        self.look = look
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        layer?.addSublayer(checker)
        layer?.addSublayer(fill)
        fill.masksToBounds = true
        checker.masksToBounds = true
        checker.isHidden = look.seeThrough == 0
        checker.backgroundColor = NSColor(patternImage: Checker.image).cgColor
        grain.isHidden = look.grain == 0
        grain.backgroundColor = MaterialImages.grain.cgColor
        grain.opacity = Float(min(1, look.grain * 0.5))
        fill.addSublayer(grain)
        toolTip = look.name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(look.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.frame = bounds
                ring.cornerRadius = bounds.width / 2
                ring.borderWidth = 2
                ring.borderColor = (isSelected ? Tokens.Color.textPrimary.withAlphaComponent(0.85) : .clear).cgColor
                // Chosen, the swatch sits inside a fine ring; under the pointer it swells to meet the edge.
                let inset: CGFloat = isSelected ? 3.5 : (isHovered ? 0 : 2)
                fill.frame = bounds.insetBy(dx: inset, dy: inset)
                fill.cornerRadius = fill.frame.width / 2
                checker.frame = fill.frame
                checker.cornerRadius = fill.cornerRadius
                let space = look.space
                // Each color at its own strength (the space's dot), so the row reads as distinct colors even in dark
                // mode, where every frame color is deep; white, grays and black as they are.
                // A designed look (a gradient, smoke) shows its real frame colors.
                let start = space.isNeutral || look.curated == nil ? space.frameColor : space.swatch
                // See-through shows the checkerboard through the color, as the window shows the desktop.
                let alpha = 1 - 0.45 * look.seeThrough
                fill.colors = [start, space.frameColor2 ?? start].map { $0.withAlphaComponent(alpha).cgColor }
                grain.frame = fill.bounds
                fill.startPoint = CGPoint(x: 0.2, y: 0.1)
                fill.endPoint = CGPoint(x: 0.8, y: 0.9)
                fill.borderWidth = Tokens.Metric.hairline
                // A firmer edge than a panel's, so black still reads on a dark panel and white on a light one.
                fill.borderColor = Tokens.Color.textTertiary.withAlphaComponent(0.3).cgColor
            }
        }
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// One of the editor's sliders: a pill whose track shows what each point gives, with a white knob riding in it.
/// Shade runs light to dark in the space's own color; see-through runs from solid to clear over a checkerboard;
/// grain builds texture from smooth on the left.
final class LookSlider: NSView {
    enum Kind { case shade, seeThrough, grain }
    let kind: Kind
    var value: Double = 0 { didSet { needsLayout = true } }
    /// The colors along the track: light to dark for shade; the space's one or two colors otherwise.
    var colors: [NSColor] = [SpaceColor.sky.background] { didSet { needsLayout = true } }
    /// Called while dragging (`final` false) and once on release (`final` true).
    var onChange: ((Double, Bool) -> Void)?
    private let checker = CALayer()
    private let track = CAGradientLayer()
    private let texture = CALayer()
    private let texture2 = CALayer()
    private let ramp = CAGradientLayer()
    private let ramp2 = CAGradientLayer()
    private let knob = CALayer()
    private let stopDots = CAShapeLayer()

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        track.masksToBounds = true
        track.cornerCurve = .continuous
        track.borderWidth = Tokens.Metric.hairline
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        // The texture builds from the left, clearly: smooth at 0, heavy grain at the far end.
        // Light and dark specks, as in the window, so it shows on black as well as white.
        for (layer, mask) in [(texture, ramp), (texture2, ramp2)] where kind == .grain {
            layer.backgroundColor = MaterialImages.grain.cgColor
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.cgColor]
            layer.mask = mask
            track.addSublayer(layer)
        }
        checker.masksToBounds = true
        checker.isHidden = kind != .seeThrough
        checker.backgroundColor = NSColor(patternImage: Checker.image).cgColor
        layer?.addSublayer(checker)
        layer?.addSublayer(track)
        track.addSublayer(stopDots)
        // A white disc riding inside the track.
        knob.backgroundColor = .white
        knob.shadowOpacity = 1
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: 1)
        knob.borderWidth = Tokens.Metric.hairline
        knob.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.addSublayer(knob)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(kind == .shade ? "Shade" : kind == .seeThrough ? "See-through" : "Grain")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var knobWidth: CGFloat { bounds.height - 8 }
    private var inset: CGFloat { 4 + knobWidth / 2 }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            track.frame = bounds
            track.cornerRadius = track.frame.height / 2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let first = colors.first ?? .white
                switch kind {
                case .shade: track.colors = colors.map(\.cgColor)
                // Solid on the left, and as thin as the frame gets on the right.
                case .seeThrough: track.colors = [first.withAlphaComponent(1).cgColor, first.withAlphaComponent(0.2).cgColor]
                case .grain: track.colors = [first.cgColor, (colors.last ?? first).cgColor]
                }
                track.borderColor = Tokens.Color.panelEdge.cgColor
                knob.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
            }
            checker.frame = track.frame
            checker.cornerRadius = track.cornerRadius
            for (layer, mask) in [(texture, ramp), (texture2, ramp2)] {
                layer.frame = track.bounds
                mask.frame = layer.bounds
            }
            let x = inset + CGFloat(value) * (bounds.width - inset * 2)
            knob.bounds = CGRect(x: 0, y: 0, width: knobWidth, height: knobWidth)
            knob.position = CGPoint(x: x, y: bounds.height / 2)
            knob.cornerRadius = knobWidth / 2
            stopDots.frame = track.bounds
            let path = CGMutablePath()
            for stop in stops.dropFirst().dropLast() {
                let sx = inset + CGFloat(stop) * (bounds.width - inset * 2)
                path.addEllipse(in: CGRect(x: sx - 1.5, y: bounds.height / 2 - 1.5, width: 3, height: 3))
            }
            stopDots.path = path
            stopDots.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        }
        // Held, the knob swells a little under your finger.
        knob.setAffineTransform(pressed ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity)
        let percent = "\(Int((value * 100).rounded())) percent"
        switch kind {
        case .shade: setAccessibilityValue(value < 0.01 ? "Lightest" : value > 0.99 ? "Darkest" : "\(percent) dark")
        case .seeThrough: setAccessibilityValue(value < 0.01 ? "Solid" : percent)
        case .grain: setAccessibilityValue(value < 0.01 ? "Smooth" : percent)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Stops it settles into, with a tap at each, so it feels like a real control with some resistance. Shade runs
    /// smooth: every depth is as good as the next.
    private var stops: [Double] { kind == .shade ? [] : [0, 0.25, 0.5, 0.75, 1] }
    private var lastStop: Double?

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        let v = Double(min(max((x - inset) / (bounds.width - inset * 2), 0), 1))
        if let stop = stops.first(where: { abs($0 - v) < 0.045 }) {
            if stop != lastStop { Haptics.snap() }
            lastStop = stop
            return stop
        }
        lastStop = nil
        return v
    }

    private var pressed = false { didSet { needsLayout = true } }

    override func mouseDown(with event: NSEvent) {
        lastStop = stops.first { abs($0 - value) < 0.001 }
        pressed = true
        value = value(at: event)
        layoutSubtreeIfNeeded()
        onChange?(value, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.value = self.value(at: event)
            self.layoutSubtreeIfNeeded()
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.pressed = false
                self.onChange?(self.value, true)
            } else {
                self.onChange?(self.value, false)
            }
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(0.1) }
    override func accessibilityPerformDecrement() -> Bool { step(-0.1) }

    private func step(_ delta: Double) -> Bool {
        value = min(max(value + delta, 0), 1)
        onChange?(value, true)
        return true
    }
}

/// Which way the gradient runs: a small knob you turn. A white thumb, the sliders' own, with a notch toward where the
/// gradient goes, set in a ring of the gradient itself that turns with it, inside a fine ring of ticks with the one
/// it points at lit. A soft click at each of the eight main directions. Drag around it, or click where it should point.
final class DirectionKnob: NSView {
    var angle: Double = 45 { didSet { needsLayout = true } }
    /// Where the gradient starts and ends, shown on the ring.
    var colors: (NSColor, NSColor) = (.white, .black) { didSet { needsLayout = true } }
    var onChange: ((Double, Bool) -> Void)?
    private let ticks = CAShapeLayer()
    private let lit = CAShapeLayer()
    private let ring = CAGradientLayer()
    private let thumb = CALayer()
    private let notch = CALayer()
    private var lastDetent: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ticks)
        layer?.addSublayer(lit)
        ring.masksToBounds = true
        ring.borderWidth = Tokens.Metric.hairline
        layer?.addSublayer(ring)
        // The same white disc as a slider's knob.
        thumb.backgroundColor = .white
        thumb.shadowOpacity = 1
        thumb.shadowRadius = 3
        thumb.shadowOffset = CGSize(width: 0, height: 1)
        thumb.borderWidth = Tokens.Metric.hairline
        thumb.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.addSublayer(thumb)
        notch.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
        layer?.addSublayer(notch)
        toolTip = "Gradient Direction"
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Gradient direction")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2
        let ringRadius = outer - 5
        let thumbRadius = ringRadius - 3.5
        let a = angle * .pi / 180
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ticks.fillColor = Tokens.Color.textTertiary.withAlphaComponent(0.6).cgColor
                lit.fillColor = Tokens.Color.textPrimary.cgColor
                ring.borderColor = Tokens.Color.panelEdge.cgColor
                ring.colors = [colors.0.cgColor, colors.1.cgColor]
                thumb.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
            }
            ring.frame = CGRect(x: c.x - ringRadius, y: c.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            ring.cornerRadius = ringRadius
            // The ring runs the way the window does: from the first color to the second, along the angle.
            let dx = cos(a) / 2, dy = sin(a) / 2
            ring.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            ring.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
            thumb.frame = CGRect(x: c.x - thumbRadius, y: c.y - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2)
            thumb.cornerRadius = thumbRadius
            let ticksPath = CGMutablePath(), litPath = CGMutablePath()
            let nearest = Int((angle / 15).rounded()) % 24
            for i in 0..<24 {
                let t = Double(i) / 24 * 2 * .pi
                let size: CGFloat = i % 3 == 0 ? 1.1 : 0.7
                let p = CGPoint(x: c.x + cos(t) * (outer - 1.5), y: c.y + sin(t) * (outer - 1.5))
                let dot = CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
                if i == nearest { litPath.addEllipse(in: dot.insetBy(dx: -0.5, dy: -0.5)) } else { ticksPath.addEllipse(in: dot) }
            }
            ticks.path = ticksPath
            ticks.frame = bounds
            lit.path = litPath
            lit.frame = bounds
            // The notch turns with the knob, from near the middle out toward the second color.
            let length = thumbRadius * 0.6
            notch.bounds = CGRect(x: 0, y: 0, width: length, height: 2)
            notch.cornerRadius = 1
            let reach = thumbRadius - 2.5 - length / 2
            notch.position = CGPoint(x: c.x + cos(a) * reach, y: c.y + sin(a) * reach)
            notch.setAffineTransform(CGAffineTransform(rotationAngle: a))
        }
        setAccessibilityValue("\(Int(angle)) degrees")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func angle(at event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        var a = atan2(p.y - bounds.midY, p.x - bounds.midX) * 180 / .pi
        if a < 0 { a += 360 }
        // Settles on the eight main directions when close.
        let nearest = (a / 45).rounded() * 45
        return abs(nearest - a) < 8 ? nearest.truncatingRemainder(dividingBy: 360) : a
    }

    /// A light tap under your finger at each main direction, as a detent would give.
    private func detent() {
        let step = Int((angle / 45).rounded()) % 8
        guard angle.truncatingRemainder(dividingBy: 45) == 0, step != lastDetent else { return }
        lastDetent = step
        Haptics.snap()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        lastDetent = Int((angle / 45).rounded()) % 8
        angle = angle(at: event)
        detent()
        onChange?(angle, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            Tokens.Motion.withoutAnimation {
                self.angle = self.angle(at: event)
                self.layoutSubtreeIfNeeded()
            }
            self.detent()
            if event.type == .leftMouseUp {
                stop.pointee = true
                NSCursor.pop()
                self.onChange?(self.angle, true)
            } else {
                self.onChange?(self.angle, false)
            }
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func accessibilityPerformIncrement() -> Bool { angle = (angle + 45).truncatingRemainder(dividingBy: 360); onChange?(angle, true); return true }
    override func accessibilityPerformDecrement() -> Bool { angle = (angle + 315).truncatingRemainder(dividingBy: 360); onChange?(angle, true); return true }
}

/// One of the space's own colors in the Colors row: a round swatch like a preset's, ringed when its knob is the
/// selected one on the wheel. The second shows a small × on hover that takes it away.
final class ColorChip: InteractiveView {
    var color: NSColor = .white { didSet { stateDidChange(animated: false) } }
    /// Set for the second color: the × that removes it, and the same for VoiceOver.
    var onRemove: (() -> Void)? {
        didSet {
            setAccessibilityCustomActions(onRemove == nil ? nil : [
                NSAccessibilityCustomAction(name: "Remove second color") { [weak self] in self?.onRemove?(); return true },
            ])
        }
    }
    private let fill = CALayer()
    private let ring = CALayer()
    private let badge = CALayer()
    private let cross = CAShapeLayer()
    private static let badgeSize: CGFloat = 14

    init(label: String) {
        super.init(frame: .zero)
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        // A dark dot with a white ×, edged in white so it lifts off any color, in either mode.
        badge.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
        badge.borderColor = NSColor.white.cgColor
        badge.borderWidth = 1.5
        badge.isHidden = true
        cross.strokeColor = NSColor.white.cgColor
        cross.lineWidth = 1.4
        cross.lineCap = .round
        badge.addSublayer(cross)
        layer?.addSublayer(badge)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    private var badgeFrame: CGRect {
        CGRect(x: bounds.maxX - Self.badgeSize + 3, y: -3, width: Self.badgeSize, height: Self.badgeSize)
    }

    /// Whether a click landed on the ×.
    func hitsBadge(_ event: NSEvent) -> Bool {
        guard onRemove != nil else { return false }
        return badgeFrame.insetBy(dx: -2, dy: -2).contains(convert(event.locationInWindow, from: nil))
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.frame = bounds
                ring.cornerRadius = bounds.width / 2
                ring.borderWidth = 2
                ring.borderColor = (isSelected ? Tokens.Color.textPrimary : .clear).cgColor
                let inset: CGFloat = isSelected ? 4 : (isHovered ? 0.5 : 1.5)
                fill.frame = bounds.insetBy(dx: inset, dy: inset)
                fill.cornerRadius = fill.frame.width / 2
                fill.backgroundColor = color.cgColor
                fill.borderWidth = Tokens.Metric.hairline
                fill.borderColor = Tokens.Color.textTertiary.withAlphaComponent(0.3).cgColor
            }
            badge.frame = badgeFrame
            badge.cornerRadius = Self.badgeSize / 2
            let path = CGMutablePath()
            let m = Self.badgeSize / 2, r: CGFloat = 2.6
            path.move(to: CGPoint(x: m - r, y: m - r))
            path.addLine(to: CGPoint(x: m + r, y: m + r))
            path.move(to: CGPoint(x: m + r, y: m - r))
            path.addLine(to: CGPoint(x: m - r, y: m + r))
            cross.path = path
            cross.frame = badge.bounds
            badge.isHidden = onRemove == nil || !isHovered
        }
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// An empty round slot with a +, beside the space's color: click it for a second color and a gradient.
final class AddColorSlot: InteractiveView {
    private let outline = CAShapeLayer()
    private let plus = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.fillColor = nil
        outline.lineWidth = 1.2
        outline.lineDashPattern = [3, 2.5]
        layer?.addSublayer(outline)
        plus.lineWidth = 1.5
        plus.lineCap = .round
        layer?.addSublayer(plus)
        toolTip = "Add a Second Color"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add a second color")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
                outline.frame = bounds
                outline.path = CGPath(ellipseIn: rect, transform: nil)
                outline.strokeColor = (isHovered ? Tokens.Color.textSecondary : Tokens.Color.textTertiary).cgColor
                outline.fillColor = isHovered ? Tokens.Color.fieldFill.cgColor : nil
                plus.strokeColor = (isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary).cgColor
            }
            let path = CGMutablePath()
            let c = CGPoint(x: bounds.midX, y: bounds.midY), r: CGFloat = 4.5
            path.move(to: CGPoint(x: c.x - r, y: c.y))
            path.addLine(to: CGPoint(x: c.x + r, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x, y: c.y + r))
            plus.frame = bounds
            plus.path = path
        }
    }
}

/// A quiet heading that folds what's under it away: its name, and a chevron that turns as it opens.
final class DisclosureRow: InteractiveView {
    private let label: Label
    private let chevron = NSImageView()
    var isOpen = false { didSet { if oldValue != isOpen { turn(animated: true) } } }

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.light), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        chevron.image = Tokens.Symbol.image("chevron.right", size: Tokens.Symbol.inline)
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: label.textWidth, height: h)
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: label.frame.maxX + Tokens.Space.x1, y: (bounds.height - side) / 2, width: side, height: side)
        turn(animated: false)
    }

    /// The chevron points right when folded and down when open, as the space name's does.
    private func turn(animated: Bool) {
        chevron.image = Tokens.Symbol.image(isOpen ? "chevron.down" : "chevron.right", size: Tokens.Symbol.inline)
        setAccessibilityValue(isOpen ? 1 : 0)
    }

    override func stateDidChange(animated: Bool) {
        label.textColor = isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        chevron.contentTintColor = label.textColor
    }
}

/// How a space looks, in one piece, the same wherever it's edited: a row of curated colors first (one tap, tried on
/// the window while the pointer is on one), then the wheel (around for the hue, out from the middle for how much of
/// it) and Shade for a color of your own, then Effects, folded until wanted: Colors (a slot to add a second, and the
/// direction once there are two), See-through and Grain. `onPreview` fires while you drag or point at a preset,
/// `onCommit` when you let go or pick something.
final class SpaceLookEditor: NSView {
    private let wheel = ColorWheel()
    private let colorsLabel = SpaceLookEditor.rowLabel("Gradient")
    /// The space's colors, one per knob on the wheel; clicking one selects its knob.
    private let chips = [ColorChip(label: "Color"), ColorChip(label: "Second color")]
    /// Adds a second color for a gradient; the second chip's × takes it away again.
    private let addSlot = AddColorSlot()
    private let dial = DirectionKnob()
    private let swatches = SpaceLook.presets.map { LookSwatch(look: $0) }
    /// Gradient, see-through and grain: there when you want them, folded away until then.
    private let effects = DisclosureRow(title: "Effects")
    private var showsEffects = false
    /// Whether the Frosted or Clear row is out (a see-through space with Effects open).
    private var showsGlass = false
    private let shadeLabel = SpaceLookEditor.rowLabel("Shade")
    private let shadeSlider = LookSlider(.shade)
    private let clearLabel = SpaceLookEditor.rowLabel("See-through")
    private let clearSlider = LookSlider(.seeThrough)
    /// Frosted or clear glass, for a see-through space.
    private let glassLabel = SpaceLookEditor.rowLabel("Glass")
    private let glassSwitch = SlidingSwitch([.text("Clear"), .text("Frosted")])
    private let grainLabel = SpaceLookEditor.rowLabel("Grain")
    private let grainSlider = LookSlider(.grain)

    var onPreview: ((SpaceInfo) -> Void)?
    var onCommit: ((SpaceInfo) -> Void)?
    /// The editor grew or shrank (Effects opened or folded).
    var onResize: (() -> Void)?

    /// The space as the editor has it right now.
    private var draft: SpaceInfo
    /// As it was when the editor opened.
    private let original: SpaceInfo
    /// A space never given a color follows the Mac, light by day and dark at night, until you choose one.
    private var colorChosen: Bool
    /// Which color the wheel's selected knob is, and Shade shows: 0, or 1 for a gradient's second.
    private var selected = 0

    /// `dark`: whether the window looks dark right now, for where a space that follows the Mac starts.
    init(space: SpaceInfo, dark: Bool) {
        let space = space.upgraded
        isDark = dark
        original = space
        draft = space
        colorChosen = space.brightness != nil
        super.init(frame: .zero)
        if draft.brightness == nil { draft.brightness = Self.startingDepth(space, dark: dark) }
        let views: [NSView] = [wheel, colorsLabel, addSlot, dial, shadeLabel, shadeSlider, clearLabel, clearSlider, glassLabel, glassSwitch, grainLabel, grainSlider, effects]
        showsEffects = space.hue2 != nil || space.isSeeThrough || (space.grain ?? 0) > 0.01
        (views + chips + swatches).forEach { addSubview($0) }

        wheel.onChange = { [weak self] index, spot, final in
            guard let self else { return }
            let tint = spot.amount > 0.995 ? nil : spot.amount
            if index == 0 {
                self.draft.hue = spot.hue
                self.draft.tint = tint
            } else {
                self.draft.hue2 = spot.hue
                self.draft.tint2 = tint
            }
            self.draft.intensity = nil
            self.draft.intensity2 = nil
            self.colorChosen = true
            self.changed(final: final, animated: false)
        }
        wheel.onSelect = { [weak self] index in
            self?.selected = index
            self?.sync(animated: false)
        }
        for (i, chip) in chips.enumerated() {
            chip.onClick = { [weak self, weak chip] event in
                guard let self else { return }
                if chip?.hitsBadge(event) == true { self.toggleSecondColor(); return }
                guard self.selected != i else { return }
                self.selected = i
                self.sync(animated: false)
            }
        }
        chips[1].onRemove = { [weak self] in self?.toggleSecondColor() }
        addSlot.onClick = { [weak self] _ in self?.toggleSecondColor() }
        addSlot.toolTip = "Add a second color to fade into"
        dial.toolTip = "Which way the colors fade"
        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let look = swatch?.look else { return }
                look.apply(to: &self.draft)
                self.selected = 0
                self.colorChosen = true
                self.changed(final: true, animated: true)
            }
        }
        effects.onClick = { [weak self] _ in
            guard let self else { return }
            self.showsEffects.toggle()
            self.sync(animated: true)
            self.onResize?()
        }
        shadeSlider.onChange = { [weak self] value, final in self?.shade(to: value, final: final) }
        clearSlider.onChange = { [weak self] value, final in
            guard let self else { return }
            self.draft.translucency = value > 0.005 ? value : nil
            self.changed(final: final, animated: false)
        }
        glassSwitch.onChange = { [weak self] index in
            guard let self else { return }
            self.draft.clearGlass = index == 0 ? nil : false
            self.changed(final: true, animated: false)
        }
        grainSlider.onChange = { [weak self] grain, final in
            guard let self else { return }
            self.draft.grain = grain > 0.01 ? grain : nil
            self.changed(final: final, animated: false)
        }
        dial.onChange = { [weak self] angle, final in
            guard let self else { return }
            self.draft.angle = angle
            self.changed(final: final, animated: false)
        }
        sync(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func rowLabel(_ text: String) -> Label {
        Label(text, font: Tokens.Font.body(.light), color: Tokens.Color.textSecondary)
    }

    /// Where the knob starts for a space that follows the Mac: about how it looks right now, so nothing jumps.
    private static func startingDepth(_ space: SpaceInfo, dark: Bool) -> Double {
        // White and black are the two ends of Shade.
        if space.hue == nil, space.brightness == nil, space.color == .snow { return 0 }
        if space.hue == nil, space.brightness == nil, space.color == .ink { return 1 }
        if space.isNeutral { return dark ? 0.9 : 0.06 }
        let strength = space.intensity ?? SpaceColor.defaultIntensity
        return dark ? 0.86 : 0.06 + 0.2 * strength
    }

    // MARK: Changing it

    /// The space as it should be saved or shown: untouched colors keep following the Mac.
    var look: SpaceInfo {
        var space = draft
        if !colorChosen {
            space.brightness = original.brightness
            space.brightness2 = original.brightness2
            space.appearance = original.appearance
            return space
        }
        // Light or dark: whichever text reads better on it.
        space.appearance = space.readableAppearance
        return space
    }

    private func depth(_ index: Int) -> Double {
        // A space that follows the Mac shows on the wheel at about the shade it has right now.
        let follows = Self.startingDepth(draft, dark: isDark)
        return index == 0 ? draft.brightness ?? follows : draft.brightness2 ?? draft.brightness ?? follows
    }
    private let isDark: Bool

    /// Lighter or darker. With two colors both move together, keeping the step between them; holding Option moves
    /// only the selected one.
    private func shade(to value: Double, final: Bool) {
        if draft.hue2 == nil || NSEvent.modifierFlags.contains(.option) {
            if selected == 0 { draft.brightness = value } else { draft.brightness2 = value }
        } else {
            let first = depth(0), second = depth(1)
            let delta = min(max(value - depth(selected), -min(first, second)), 1 - max(first, second))
            draft.brightness = first + delta
            draft.brightness2 = second + delta
        }
        colorChosen = true
        changed(final: final, animated: false)
    }

    /// The + slot: a second color, the first's neighbor on the wheel and a step deeper, so the gradient reads at once.
    /// The second chip's × takes it away.
    private func toggleSecondColor() {
        if draft.hue2 == nil {
            // From white, a gray or black, the second is Zigzag's blue, so there's something to fade into.
            draft.hue2 = draft.isNeutral ? 0.6 : (draft.baseHue + 0.22).truncatingRemainder(dividingBy: 1)
            draft.tint2 = draft.isNeutral ? nil : draft.tint
            let first = depth(0)
            draft.brightness2 = first < 0.6 ? first + 0.16 : first - 0.16
            draft.angle = draft.angle ?? 90
            selected = 1
        } else {
            draft.hue2 = nil
            draft.tint2 = nil
            draft.brightness2 = nil
            draft.intensity2 = nil
            selected = 0
        }
        draft.intensity = nil
        colorChosen = true
        changed(final: true, animated: true)
    }

    private func changed(final: Bool, animated: Bool) {
        if final { onCommit?(look) } else { onPreview?(look) }
        sync(animated: animated)
    }

    // MARK: Showing it

    /// Every control from the draft.
    private func sync(animated: Bool) {
        let space = draft
        if space.hue2 == nil { selected = 0 }
        var spots = [ColorWheel.Spot(hue: space.baseHue, amount: space.tintAmount)]
        var depths = [depth(0)]
        if let hue2 = space.hue2 {
            spots.append(ColorWheel.Spot(hue: hue2, amount: space.tintAmount2))
            depths.append(depth(1))
        }
        wheel.show(spots, depths: depths, selected: selected, animated: animated)
        for swatch in swatches { swatch.isSelected = swatch.look.matches(look) }
        let shown = look
        let colors = [shown.background] + (shown.background2.map { [$0] } ?? [])
        let spot = spots[selected]
        shadeSlider.value = depth(selected)
        shadeSlider.colors = stride(from: 0.0, through: 1, by: 0.2).map { SpaceColor.paint(hue: spot.hue, depth: $0, tint: spot.amount) }
        clearSlider.value = space.seeThrough
        clearSlider.colors = colors
        // What you chose, even while battery saving shows frosted for now.
        glassSwitch.selectedIndex = space.clearGlass != false ? 0 : 1
        grainSlider.value = space.grain ?? 0
        grainSlider.colors = colors
        dial.angle = space.gradientAngle
        let two = space.hue2 != nil
        chips[0].color = colors[0]
        chips[1].color = colors.last ?? colors[0]
        for (i, chip) in chips.enumerated() { chip.isSelected = two && i == selected }
        chips[1].isHidden = !two
        addSlot.isHidden = two
        dial.colors = (colors[0], colors.last ?? colors[0])
        effects.isOpen = showsEffects
        for view in [colorsLabel, chips[0], clearLabel, clearSlider, grainLabel, grainSlider] as [NSView] { view.isHidden = !showsEffects }
        // Frosted or clear only matters once the space is see-through.
        let glassShown = showsEffects && space.isSeeThrough && SpaceInfo.hasClearGlass
        for view in [glassLabel, glassSwitch] as [NSView] { view.isHidden = !glassShown }
        if glassShown != showsGlass { showsGlass = glassShown; onResize?() }
        if !showsEffects { chips[1].isHidden = true; addSlot.isHidden = true }
        showDial(two && showsEffects, animated: animated)
        needsLayout = true
    }

    /// The direction dial fades in beside the two colors.
    private func showDial(_ show: Bool, animated: Bool) {
        guard show == dial.isHidden || dial.alphaValue != (show ? 1 : 0) else { return }
        dial.isHidden = false
        guard animated, !Tokens.Motion.reduceMotion else {
            dial.alphaValue = show ? 1 : 0
            dial.isHidden = !show
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.standard
            context.timingFunction = Tokens.Motion.easeOut
            dial.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.draft.hue2 == nil || !self.showsEffects else { return }
                self.dial.isHidden = true
            }
        }
    }

    // MARK: Layout

    private let swatchSize: CGFloat = 24
    /// The presets sit in rows of nine.
    private static let swatchesPerRow = 9
    private var swatchRowsHeight: CGFloat {
        let rows = CGFloat((swatches.count + Self.swatchesPerRow - 1) / Self.swatchesPerRow)
        return rows * swatchSize + (rows - 1) * Tokens.Space.x2
    }
    private let chipSize: CGFloat = 26
    private let sliderHeight: CGFloat = 30
    /// The Colors row: as tall as the dial, a little more than a slider.
    private let dialSize: CGFloat = 40
    private let disclosureHeight: CGFloat = 28
    /// How tall the wheel is.
    var wheelHeight: CGFloat = 200 { didSet { needsLayout = true } }

    /// The presets first, one tap each; the wheel and Shade for a color of your own; then Effects, folded.
    var preferredHeight: CGFloat {
        var h = swatchRowsHeight + Tokens.Space.x4 + wheelHeight + Tokens.Space.x3 + sliderHeight + Tokens.Space.x3 + disclosureHeight
        if showsEffects { h += Tokens.Space.x2 + dialSize + Tokens.Space.x3 + (sliderHeight + Tokens.Space.x3) * 2 - Tokens.Space.x3 }
        if showsGlass { h += sliderHeight + Tokens.Space.x3 }
        return h
    }

    /// Wide enough for the longest name, so every control starts at the same line.
    private var labelWidth: CGFloat {
        let widest = [colorsLabel, shadeLabel, clearLabel, glassLabel, grainLabel].map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        return max(72, widest + Tokens.Space.x3)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        let perRow = Self.swatchesPerRow
        let gap = (width - CGFloat(perRow) * swatchSize) / CGFloat(max(perRow - 1, 1))
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: CGFloat(i % perRow) * (swatchSize + gap), y: y + CGFloat(i / perRow) * (swatchSize + Tokens.Space.x2),
                                  width: swatchSize, height: swatchSize)
        }
        y += swatchRowsHeight + Tokens.Space.x4
        wheel.frame = NSRect(x: 0, y: y, width: width, height: wheelHeight)
        y += wheelHeight + Tokens.Space.x3
        row(shadeLabel, shadeSlider, y: y, height: sliderHeight)
        y += sliderHeight + Tokens.Space.x3
        effects.frame = NSRect(x: 0, y: y, width: width, height: disclosureHeight)
        y += disclosureHeight + Tokens.Space.x2
        // Colors: the space's own, then the slot for a second or, with two, which way they run.
        let lh = ceil(colorsLabel.intrinsicContentSize.height)
        colorsLabel.frame = NSRect(x: 0, y: y + (dialSize - lh) / 2, width: labelWidth, height: lh)
        var x = labelWidth
        let chipY = y + (dialSize - chipSize) / 2
        chips[0].frame = NSRect(x: x, y: chipY, width: chipSize, height: chipSize)
        x += chipSize + Tokens.Space.x2
        chips[1].frame = NSRect(x: x, y: chipY, width: chipSize, height: chipSize)
        addSlot.frame = chips[1].frame
        x += chipSize + Tokens.Space.x3
        dial.frame = NSRect(x: x, y: y, width: dialSize, height: dialSize)
        y += dialSize + Tokens.Space.x3
        row(clearLabel, clearSlider, y: y, height: sliderHeight)
        y += sliderHeight + Tokens.Space.x3
        if showsGlass {
            row(glassLabel, glassSwitch, y: y, height: sliderHeight)
            y += sliderHeight + Tokens.Space.x3
        }
        row(grainLabel, grainSlider, y: y, height: sliderHeight)
        y += sliderHeight + Tokens.Space.x3
    }

    /// A name on the left and its control beside it, every control starting at the same line.
    private func row(_ label: Label, _ control: NSView, y: CGFloat, height: CGFloat) {
        let lh = ceil(label.intrinsicContentSize.height)
        let x = labelWidth
        label.frame = NSRect(x: 0, y: y + (height - lh) / 2, width: x, height: lh)
        control.frame = NSRect(x: x, y: y, width: bounds.width - x, height: height)
    }
}

/// Edits one space: its name, and how it looks with `SpaceLookEditor`. Everything shows in the window as you drag,
/// and saves when you let go.
final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    /// The name in the app's voice, as the sidebar shows it.
    private let nameField = PlainTextField(font: Tokens.Font.voice(20), placeholder: "Name this space")
    /// The name sits on a soft field, so it reads as something you can type into.
    private let nameBackground = ColorView(color: Tokens.Color.fieldFill)
    private let editor: SpaceLookEditor
    /// The space's icon, at the start of its name; click it to choose one in place of the colors.
    private let iconButton = IconButton(symbol: "circle.dashed", size: .compact, toolTip: "Choose Icon")
    private var iconGrid: IconGrid?
    private var monitor: Any?
    static let width: CGFloat = 300

    /// `controller` is the browser window it belongs to; Settings passes nil and hosts it in its own window.
    init(spaceID: UUID, controller: BrowserWindowController?) {
        self.spaceID = spaceID
        self.controller = controller
        let space = Library.shared.space(spaceID) ?? SpaceInfo(name: "", color: .sky)
        let dark = (controller?.window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        editor = SpaceLookEditor(space: space, dark: dark)
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        nameField.stringValue = space.name
        nameField.delegate = self
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerCurve = .continuous
        nameBackground.layer?.cornerRadius = Tokens.Radius.row
        [nameBackground, nameField, editor, iconButton].forEach { addSubview($0) }
        refreshIconButton(space.icon)
        iconButton.onClick = { [weak self] _ in self?.toggleIcons() }
        editor.onPreview = { [weak self] look in
            guard let self else { return }
            (self.controller ?? BrowserWindowController.undoTarget)?.previewSpace(look)
        }
        editor.onCommit = { [weak self] look in
            guard let self else { return }
            Library.shared.setLook(look)
            self.edited = true
        }
        editor.onResize = { [weak self] in
            self?.layoutContent()
            self?.resizeToFit()
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// A panel's padding, and its name a row tall.
    private let pad = Tokens.Space.x3
    private let nameHeight = Tokens.Metric.rowHeight

    var contentHeight: CGFloat { pad + nameHeight + Tokens.Space.x3 + (iconGrid != nil ? IconGrid.height : editor.preferredHeight) + pad }

    private func refreshIconButton(_ icon: String?) {
        iconButton.glyph = icon.map { IconChoice.image($0, size: Tokens.Symbol.compactGlyph) }
        iconButton.isSelected = iconGrid != nil
    }

    /// The icons take the colors' place, and the button again (or picking one) brings the colors back.
    private func toggleIcons() {
        if let grid = iconGrid {
            grid.removeFromSuperview()
            iconGrid = nil
            editor.isHidden = false
        } else {
            let grid = IconGrid(noneSymbol: "circle.dashed", selected: Library.shared.space(spaceID)?.icon)
            grid.onPick = { [weak self] icon in
                guard let self else { return }
                Library.shared.setIcon(icon, forSpace: self.spaceID)
                self.edited = true
                self.refreshIconButton(icon)
                // An emoji is typed one at a time; a symbol is one click and done.
                if icon.map(IconChoice.isSymbol) != false { self.toggleIcons() }
            }
            addSubview(grid)
            iconGrid = grid
            editor.isHidden = true
        }
        refreshIconButton(Library.shared.space(spaceID)?.icon)
        layoutContent()
        resizeToFit()
    }

    /// The panel grows or shrinks between the colors and the icons, keeping the edge nearest what opened it.
    private func resizeToFit() {
        guard superview != nil, abs(frame.height - contentHeight) > 0.5 else { return }
        var target = frame
        let delta = contentHeight - frame.height
        target.size.height = contentHeight
        if superview?.isFlipped == true, anchoredBelow == false { target.origin.y -= delta }
        target.origin.y = max(Tokens.Space.x2, target.origin.y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.standard
            context.timingFunction = Tokens.Motion.easeOut
            context.allowsImplicitAnimation = true
            animator().frame = target
            layoutSubtreeIfNeeded()
        }
    }

    /// True when it hangs down from what opened it; false when it rises from the dots at the bottom.
    private var anchoredBelow = false

    private func layoutContent() {
        let width = bounds.width - pad * 2
        let fh = ceil(nameField.intrinsicContentSize.height)
        nameBackground.frame = NSRect(x: pad, y: pad, width: width, height: nameHeight)
        let ib = iconButton.frame.width
        iconButton.frame.origin = NSPoint(x: pad + (nameHeight - ib) / 2, y: pad + (nameHeight - ib) / 2)
        let textX = pad + nameHeight
        nameField.frame = NSRect(x: textX, y: pad + (nameHeight - fh) / 2, width: pad + width - textX - Tokens.Space.x2, height: fh)
        editor.frame = NSRect(x: pad, y: pad + nameHeight + Tokens.Space.x3, width: width, height: editor.preferredHeight)
        iconGrid?.frame = NSRect(x: pad, y: pad + nameHeight + Tokens.Space.x3, width: width, height: IconGrid.height)
    }

    func show(from anchor: NSView? = nil) {
        guard let controller else { return }
        let overlay = controller.root.overlay
        let sidebar = controller.root.sidebarContainer.frame
        let height = contentHeight
        let x: CGFloat
        var top: CGFloat
        if let anchor, anchor.window != nil, anchor is SpaceDotView {
            // From a space dot: beside the sidebar, its bottom level with the dots, so it covers neither the dots
            // nor the tabs and the sidebar shows the new look in full.
            let dot = anchor.convert(anchor.bounds, to: overlay)
            top = dot.maxY - height
            x = min(sidebar.maxX + Tokens.Space.x2, overlay.bounds.width - Self.width - Tokens.Space.x2)
        } else {
            // From the space's name: beside the sidebar, level with that header.
            top = controller.root.cardFrame.minY + Tokens.Space.x2
            if let header = controller.sidebar.list.headerView, header.window != nil {
                top = header.convert(header.bounds, to: overlay).minY - Tokens.Space.x2
            }
            x = sidebar.maxX + Tokens.Space.x2
            // Hanging from the header, it grows downward when the icons take the colors' place.
            anchoredBelow = true
        }
        top = max(Tokens.Space.x2, min(top, overlay.bounds.height - height - Tokens.Space.x4))
        frame = NSRect(x: x, y: top, width: Self.width, height: height)
        overlay.addSubview(self)
        // From a dot it rises out of the bottom; from the space's name it hangs from the top.
        growsFrom = anchor is SpaceDotView ? CGPoint(x: 0.1, y: 1) : CGPoint(x: 0, y: 0.1)
        present(arrival: .pop)
        controller.window?.makeFirstResponder(nameField)
        // The cursor at the end, not the whole name selected: you came to change the color as often as the name. A
        // name Zigzag made up ("Space 2") is selected instead, so typing replaces it.
        if let editor = nameField.currentEditor() {
            let placeholder = nameField.stringValue.range(of: #"^Space \d+$"#, options: .regularExpression) != nil
            editor.selectedRange = placeholder ? NSRange(location: 0, length: nameField.stringValue.utf16.count)
                                               : NSRange(location: nameField.stringValue.utf16.count, length: 0)
        }
        controller.root.holdReveal = true
        startMonitoring()
    }

    /// In Settings: dropping from the Edit button that opened it, its right edge on the button's, inside that window.
    func show(in host: NSView, below anchor: NSView) {
        let button = anchor.convert(anchor.bounds, to: host)
        let height = contentHeight
        let below = host.isFlipped ? button.maxY + Tokens.Space.x1 : button.minY - Tokens.Space.x1 - height
        let fits = host.isFlipped ? below + height <= host.bounds.height - Tokens.Space.x2 : below >= Tokens.Space.x2
        // Not enough room underneath: it opens upward from the button instead.
        let above = host.isFlipped ? button.minY - Tokens.Space.x1 - height : button.maxY + Tokens.Space.x1
        // Never past the window's edges: if neither way fits, it slides to fit and sits left of the button.
        let y = max(Tokens.Space.x2, min(fits ? below : above, host.bounds.height - height - Tokens.Space.x2))
        let x = max(Tokens.Space.x2, min(button.maxX - Self.width, host.bounds.width - Self.width - Tokens.Space.x2))
        frame = NSRect(x: x, y: y, width: Self.width, height: height)
        anchoredBelow = fits
        host.addSubview(self)
        present(arrival: .instant)
        window?.makeFirstResponder(nameField)
        if let editor = nameField.currentEditor() { editor.selectedRange = NSRange(location: nameField.stringValue.count, length: 0) }
        startMonitoring()
    }

    var onClose: (() -> Void)?

    private func startMonitoring() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Esc in another window (Settings, a second browser window) is that window's; mid-word in a
                // Chinese or Japanese input method, it belongs to the input method.
                if event.keyCode == 53, event.window === self.window,
                   (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true { self.cancel(); return nil }
                return event
            }
            if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    /// The space as it was when the editor opened; closing registers one ⌘Z for everything changed.
    private let before = Library.shared.snapshot
    private var edited = false

    /// Set for a space just made with +: Esc takes the space away again instead of keeping it.
    var onCancel: (() -> Void)?
    private var cancelled = false

    /// Esc: closes, and a space just made goes away again. Return or a click outside keeps it.
    func cancel() {
        guard let onCancel else { close(); return }
        cancelled = true
        close()
        onCancel()
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if !cancelled { commitName() }
        if edited, !cancelled { (controller ?? BrowserWindowController.undoTarget)?.recordLibraryUndo("Edit Space", before: before) }
        if let controller {
            controller.root.holdReveal = false
            dismiss()
            if let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
        } else {
            window?.makeFirstResponder(nil)
            dismiss(instantly: true)
        }
        if SpaceEditorPanel.current === self { SpaceEditorPanel.current = nil }
        onClose?()
    }

    private func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != Library.shared.space(spaceID)?.name {
            Library.shared.renameSpace(spaceID, to: name)
            edited = true
        }
    }

    func controlTextDidChange(_ obj: Notification) { commitName() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            close()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    static weak var current: SpaceEditorPanel?

    static func toggle(spaceID: UUID, anchor: NSView? = nil, in controller: BrowserWindowController) {
        if let current {
            let same = current.spaceID == spaceID
            current.close()
            if same { return }
        }
        controller.closeFloatingPanels()
        let panel = SpaceEditorPanel(spaceID: spaceID, controller: controller)
        current = panel
        panel.show(from: anchor)
    }
}

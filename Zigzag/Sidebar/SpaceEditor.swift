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
    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 - 4 }

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

    /// Anywhere on the disc can be clicked to pick that color.
    override func resetCursorRects() {
        let r = radius
        addCursorRect(NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), cursor: .pointingHand)
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

/// A ready-made look: a color, or two in a gradient, maybe see-through.
struct SpaceLook {
    let name: String
    var hue: Double = 0
    /// How much color: 0 for white, grays and black.
    var tint: Double = 1
    var depth: Double
    var hue2: Double? = nil
    var depth2: Double = 0
    var angle: Double = 90
    var seeThrough: Double = 0

    /// How it looks as a space.
    var space: SpaceInfo {
        var space = SpaceInfo(name: name, color: .graphite)
        apply(to: &space)
        return space
    }

    func apply(to space: inout SpaceInfo) {
        space.glass = nil
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
        space.tint2 = nil
        space.intensity2 = nil
        space.brightness2 = hue2 == nil ? nil : depth2
        if hue2 != nil { space.angle = angle }
        space.translucency = seeThrough > 0 ? seeThrough : nil
    }

    func matches(_ space: SpaceInfo) -> Bool {
        guard let b = space.brightness, abs(b - depth) < 0.005, abs(space.seeThrough - seeThrough) < 0.01 else { return false }
        if tint < 0.005 {
            guard space.isNeutral else { return false }
        } else {
            guard !space.isNeutral, let h = space.hue, abs(h - hue) < 0.002, abs(space.tintAmount - tint) < 0.01 else { return false }
        }
        guard let hue2 else { return space.hue2 == nil }
        guard let h2 = space.hue2, abs(h2 - hue2) < 0.002, abs((space.brightness2 ?? b) - depth2) < 0.005,
              space.tintAmount2 > 0.99 else { return false }
        return true
    }

    /// One row: white, gray and black, three colors (Zigzag's navy among them), two gradients, and frosted white.
    static let presets: [SpaceLook] = [
        SpaceLook(name: "White", tint: 0, depth: 0),
        SpaceLook(name: "Gray", tint: 0, depth: 0.12),
        SpaceLook(name: "Black", tint: 0, depth: 1),
        SpaceLook(name: "Sky", hue: 0.57, depth: 0.22),
        SpaceLook(name: "Rose", hue: 0.96, depth: 0.2),
        SpaceLook(name: "Navy", hue: 0.62, depth: 0.82),
        // Neighbors on the wheel, one a little deeper than the other, the way light falls across a wall.
        SpaceLook(name: "Dawn", hue: 0.07, depth: 0.16, hue2: 0.95, depth2: 0.3, angle: 90),
        SpaceLook(name: "Deep Sea", hue: 0.5, depth: 0.62, hue2: 0.63, depth2: 0.86, angle: 90),
        SpaceLook(name: "Frost", tint: 0, depth: 0.04, seeThrough: 0.6),
    ]
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

/// One preset: a round swatch of the look, ringed when it's the one in use. A see-through one shows over a checkerboard.
final class LookSwatch: InteractiveView {
    let look: SpaceLook
    private let fill = CAGradientLayer()
    private let checker = CALayer()
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
                ring.borderColor = (isSelected ? Tokens.Color.textPrimary : .clear).cgColor
                let inset: CGFloat = isSelected ? 4 : (isHovered ? 0.5 : 1.5)
                fill.frame = bounds.insetBy(dx: inset, dy: inset)
                fill.cornerRadius = fill.frame.width / 2
                checker.frame = fill.frame
                checker.cornerRadius = fill.cornerRadius
                let space = look.space
                let start = space.frameColor
                fill.colors = [start, space.frameColor2 ?? start].map(\.cgColor)
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
        for (layer, mask, mode) in [(texture, ramp, "overlayBlendMode"), (texture2, ramp2, "softLightBlendMode")] where kind == .grain {
            layer.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
            layer.compositingFilter = mode
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

/// Which way the gradient runs: a knob you turn, like one on a good amplifier. A raised disc with a notch, a ring of
/// dots around it, and a soft click at each of the eight main directions. Drag around it, or click where it should point.
final class DirectionKnob: NSView {
    var angle: Double = 45 { didSet { needsLayout = true } }
    var onChange: ((Double, Bool) -> Void)?
    private let ticks = CAShapeLayer()
    private let lit = CAShapeLayer()
    private let disc = CAGradientLayer()
    private let discShadow = CALayer()
    private let notch = CALayer()
    private var lastDetent: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ticks)
        layer?.addSublayer(lit)
        discShadow.shadowOpacity = 1
        discShadow.shadowRadius = 4
        discShadow.shadowOffset = CGSize(width: 0, height: 2)
        layer?.addSublayer(discShadow)
        disc.masksToBounds = true
        disc.borderWidth = Tokens.Metric.hairline
        layer?.addSublayer(disc)
        disc.addSublayer(notch)
        toolTip = "Turn to change the direction"
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
        let r = outer - 11
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ticks.fillColor = Tokens.Color.textTertiary.withAlphaComponent(0.6).cgColor
                lit.fillColor = Tokens.Color.textPrimary.cgColor
                discShadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.18).cgColor
                disc.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
                notch.backgroundColor = Tokens.Color.textPrimary.cgColor
            }
            // A soft top light on the disc, so it reads raised.
            disc.colors = dark ? [Tokens.Color.hex(0x48484C).cgColor, Tokens.Color.hex(0x323235).cgColor]
                : [NSColor.white.cgColor, Tokens.Color.hex(0xF1F1F3).cgColor]
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            disc.frame = rect
            disc.cornerRadius = r
            discShadow.frame = rect
            discShadow.cornerRadius = r
            discShadow.backgroundColor = disc.colors?.last.map { $0 as! CGColor }
            let ticksPath = CGMutablePath(), litPath = CGMutablePath()
            let nearest = Int((angle / 15).rounded()) % 24
            for i in 0..<24 {
                let t = Double(i) / 24 * 2 * .pi
                let size: CGFloat = i % 3 == 0 ? 1.7 : 1.1
                let p = CGPoint(x: c.x + cos(t) * (outer - 3), y: c.y + sin(t) * (outer - 3))
                let dot = CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
                if i == nearest { litPath.addEllipse(in: dot.insetBy(dx: -0.6, dy: -0.6)) } else { ticksPath.addEllipse(in: dot) }
            }
            ticks.path = ticksPath
            ticks.frame = bounds
            lit.path = litPath
            lit.frame = bounds
        }
        // The notch turns with the disc; clicks jump with a short ease, drags follow exactly.
        let a = angle * .pi / 180
        notch.bounds = CGRect(x: 0, y: 0, width: 9, height: 3)
        notch.cornerRadius = 1.5
        notch.position = CGPoint(x: r + cos(a) * (r - 8), y: r + sin(a) * (r - 8))
        notch.setAffineTransform(CGAffineTransform(rotationAngle: a))
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


/// How a space looks, in one piece, the same wherever it's edited: the wheel (around for the hue, out from the
/// middle for how much of it, with a + for a second color and the direction dial once there are two), a row of
/// presets, then Shade, See-through and Grain. `onPreview` fires while you drag, `onCommit` when you let go or pick
/// something.
final class SpaceLookEditor: NSView {
    private let wheel = ColorWheel()
    /// Adds a second color for a gradient, or takes it away again.
    private let secondButton = IconButton(symbol: "plus", size: 26, toolTip: "Add Second Color")
    private let dial = DirectionKnob()
    private let swatches = SpaceLook.presets.map { LookSwatch(look: $0) }
    private let shadeLabel = SpaceLookEditor.rowLabel("Shade")
    private let shadeSlider = LookSlider(.shade)
    private let clearLabel = SpaceLookEditor.rowLabel("See-through")
    private let clearSlider = LookSlider(.seeThrough)
    private let grainLabel = SpaceLookEditor.rowLabel("Grain")
    private let grainSlider = LookSlider(.grain)

    var onPreview: ((SpaceInfo) -> Void)?
    var onCommit: ((SpaceInfo) -> Void)?

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
        original = space
        draft = space
        colorChosen = space.brightness != nil
        super.init(frame: .zero)
        if draft.brightness == nil { draft.brightness = Self.startingDepth(space, dark: dark) }
        let views: [NSView] = [wheel, secondButton, dial, shadeLabel, shadeSlider, clearLabel, clearSlider, grainLabel, grainSlider]
        (views + swatches).forEach { addSubview($0) }

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
        secondButton.radius = 13
        secondButton.onClick = { [weak self] _ in self?.toggleSecondColor() }
        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let look = swatch?.look else { return }
                look.apply(to: &self.draft)
                self.selected = 0
                self.colorChosen = true
                self.changed(final: true, animated: true)
            }
        }
        shadeSlider.onChange = { [weak self] value, final in self?.shade(to: value, final: final) }
        clearSlider.onChange = { [weak self] value, final in
            guard let self else { return }
            self.draft.translucency = value > 0.005 ? value : nil
            self.changed(final: final, animated: false)
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
        Label(text, font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
    }

    /// Where the knob starts for a space that follows the Mac: about how it looks right now, so nothing jumps.
    private static func startingDepth(_ space: SpaceInfo, dark: Bool) -> Double {
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
        index == 0 ? draft.brightness ?? 0 : draft.brightness2 ?? draft.brightness ?? 0
    }

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

    /// The +: a second color, the first's neighbor on the wheel and a step deeper, so the gradient reads at once.
    /// The − takes it away.
    private func toggleSecondColor() {
        if draft.hue2 == nil {
            // From white, a gray or black, the second is Zigzag's blue, so there's something to fade into.
            draft.hue2 = draft.isNeutral ? 0.6 : (draft.baseHue + 0.14).truncatingRemainder(dividingBy: 1)
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
        for swatch in swatches { swatch.isSelected = swatch.look.matches(space) }
        let shown = look
        let colors = [shown.background] + (shown.background2.map { [$0] } ?? [])
        let spot = spots[selected]
        shadeSlider.value = depth(selected)
        shadeSlider.colors = stride(from: 0.0, through: 1, by: 0.2).map { SpaceColor.paint(hue: spot.hue, depth: $0, tint: spot.amount) }
        clearSlider.value = space.seeThrough
        clearSlider.colors = colors
        grainSlider.value = space.grain ?? 0
        grainSlider.colors = colors
        dial.angle = space.gradientAngle
        let two = space.hue2 != nil
        secondButton.symbol = two ? "minus" : "plus"
        secondButton.toolTip = two ? "Remove Second Color" : "Add Second Color"
        secondButton.setAccessibilityLabel(secondButton.toolTip)
        showDial(two, animated: animated)
        needsLayout = true
    }

    /// The direction dial fades in beside the wheel once there are two colors.
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
                guard let self, self.draft.hue2 == nil else { return }
                self.dial.isHidden = true
            }
        }
    }

    // MARK: Layout

    private let swatchSize: CGFloat = 24
    private let sliderHeight: CGFloat = 30
    private let dialSize: CGFloat = 50
    /// How tall the wheel is.
    var wheelHeight: CGFloat = 216 { didSet { needsLayout = true } }

    var preferredHeight: CGFloat {
        wheelHeight + Tokens.Space.x3 + swatchSize + Tokens.Space.x5 + sliderHeight * 3 + Tokens.Space.x3 * 2
    }

    /// Wide enough for the longest name, so every control starts at the same line.
    private var labelWidth: CGFloat {
        let widest = [shadeLabel, clearLabel, grainLabel].map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        return max(72, widest + Tokens.Space.x3)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        wheel.frame = NSRect(x: 0, y: y, width: width, height: wheelHeight)
        // In the corners the round wheel leaves free: the + above, the dial below.
        secondButton.frame.origin = NSPoint(x: width - secondButton.frame.width, y: y)
        dial.frame = NSRect(x: width - dialSize, y: y + wheelHeight - dialSize, width: dialSize, height: dialSize)
        y += wheelHeight + Tokens.Space.x3
        let count = CGFloat(swatches.count)
        let gap = (width - count * swatchSize) / max(count - 1, 1)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: CGFloat(i) * (swatchSize + gap), y: y, width: swatchSize, height: swatchSize)
        }
        y += swatchSize + Tokens.Space.x5
        for (label, slider) in [(shadeLabel, shadeSlider), (clearLabel, clearSlider), (grainLabel, grainSlider)] {
            row(label, slider, y: y, height: sliderHeight)
            y += sliderHeight + Tokens.Space.x3
        }
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
    private let nameField = PlainTextField(font: Tokens.Font.large(.semibold), placeholder: "Name this space")
    /// The name sits on a soft field, so it reads as something you can type into.
    private let nameBackground = ColorView(color: Tokens.Color.fieldFill)
    private let editor: SpaceLookEditor
    /// The space's icon, at the start of its name; click it to choose one in place of the colors.
    private let iconButton = IconButton(symbol: "circle.dashed", size: 26, symbolSize: Tokens.TypeSize.body, toolTip: "Choose Icon")
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
        nameBackground.layer?.cornerRadius = Tokens.Radius.field
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
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private let pad = Tokens.Space.x4
    private let nameHeight: CGFloat = 34

    var contentHeight: CGFloat { pad + nameHeight + Tokens.Space.x3 + (iconGrid != nil ? IconGrid.height : editor.preferredHeight) + pad }

    private func refreshIconButton(_ icon: String?) {
        iconButton.glyph = icon.map { IconChoice.image($0, size: Tokens.TypeSize.body + 1) }
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
        // The cursor at the end, not the whole name selected: you came to change the color as often as the name.
        if let editor = nameField.currentEditor() { editor.selectedRange = NSRange(location: nameField.stringValue.count, length: 0) }
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

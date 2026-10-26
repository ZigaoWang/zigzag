import AppKit

/// The space's color wheel: a disc of small dots, each painted the very color it gives. Around the disc picks the
/// hue; the middle is white, and toward the rim the color deepens until it's nearly black, with the window turning
/// dark past halfway. Drag the knob, or click any dot to jump there. With a gradient there are two knobs, and a drag
/// moves whichever is nearer.
final class ColorWheel: NSView {
    struct Spot: Equatable {
        var hue: Double
        var depth: Double
    }

    /// One or two: the color, or where a gradient starts and ends.
    private(set) var spots: [Spot] = [Spot(hue: 0.6, depth: 0.3)]
    /// A gray or black has no hue: its knob sits in the middle, showing that gray, until you move it.
    private(set) var knobColors: [NSColor] = []
    /// Called while dragging (`final` false) and once on release (`final` true), with which knob moved.
    var onChange: ((Int, Spot, Bool) -> Void)?

    private let dots = CALayer()
    /// A faint disc behind the dots, so the wheel stays round where its deepest colors meet a dark panel.
    private let disc = CALayer()
    private let knobs = [WheelKnob(), WheelKnob()]
    private var paintedSize: CGSize = .zero
    private var pressed: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        layer?.addSublayer(dots)
        knobs.forEach { layer?.addSublayer($0.layer) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Color")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Shows these spots; `animated` glides the knobs there, as when a preset is picked.
    func show(_ spots: [Spot], colors: [NSColor], animated: Bool) {
        self.spots = spots
        knobColors = colors
        placeKnobs(animated: animated)
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 - 4 }

    private func point(_ spot: Spot) -> CGPoint {
        let a = spot.hue * 2 * .pi - .pi / 2
        let r = radius * CGFloat(spot.depth)
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    private func spot(at p: CGPoint, keeping hue: Double) -> Spot {
        let dx = p.x - center.x, dy = p.y - center.y
        let depth = min(Double(hypot(dx, dy) / radius), 1)
        // Right in the middle every hue is the same white: keep the one it had.
        guard depth > 0.03 else { return Spot(hue: hue, depth: depth) }
        var h = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if h < 0 { h += 1 }
        return Spot(hue: Double(h), depth: depth)
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

    /// The dots on a honeycomb, so the disc's edge reads round. They never change, so they're painted once.
    private func paintDots() {
        paintedSize = bounds.size
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
                context.setFillColor(SpaceColor.paint(hue: spot.hue, depth: spot.depth).cgColor)
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
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        for (i, knob) in knobs.enumerated() {
            knob.layer.isHidden = i >= spots.count
            guard i < spots.count else { continue }
            knob.layer.position = point(spots[i])
            knob.fill = i < knobColors.count ? knobColors[i] : SpaceColor.paint(hue: spots[i].hue, depth: spots[i].depth)
            knob.isPressed = pressed == i
            // The one you're holding rides on top.
            knob.layer.zPosition = pressed == i ? 2 : CGFloat(1 - i)
        }
        CATransaction.commit()
        setAccessibilityValue(spots.map { "\(Int($0.depth * 100)) percent deep" }.joined(separator: ", "))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let index = spots.indices.min { hypot(point(spots[$0]).x - p.x, point(spots[$0]).y - p.y) < hypot(point(spots[$1]).x - p.x, point(spots[$1]).y - p.y) } ?? 0
        pressed = index
        move(index, to: p, final: false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            let p = self.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.pressed = nil
                self.move(index, to: p, final: true)
            } else {
                self.move(index, to: p, final: false)
            }
        }
    }

    private func move(_ index: Int, to p: CGPoint, final: Bool) {
        guard index < spots.count else { return }
        let spot = spot(at: p, keeping: spots[index].hue)
        spots[index] = spot
        if index < knobColors.count { knobColors[index] = SpaceColor.paint(hue: spot.hue, depth: spot.depth) }
        placeKnobs(animated: false)
        onChange?(index, spot, final)
    }
}

/// A knob on the wheel: the chosen color in a white ring, lifted by a soft shadow. It swells a little while held.
private final class WheelKnob {
    let layer = CALayer()
    private let inner = CALayer()
    var fill: NSColor = .white { didSet { inner.backgroundColor = fill.cgColor } }
    var isPressed = false { didSet { layer.setAffineTransform(isPressed ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity) } }

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

/// A ready-made look: a color, or two in a gradient, at a spot on the wheel.
struct SpaceLook {
    let name: String
    /// Nil: no hue, for white, grays and black.
    var hue: Double?
    var depth: Double
    var hue2: Double? = nil
    var depth2: Double = 0
    var angle: Double = 90

    var colors: [NSColor] {
        let first = SpaceColor.paint(hue: hue ?? 0, depth: depth, neutral: hue == nil)
        return [first, hue2.map { SpaceColor.paint(hue: $0, depth: depth2) } ?? first]
    }

    func apply(to space: inout SpaceInfo) {
        space.glass = nil
        if let hue { space.hue = hue } else {
            space.hue = nil
            space.color = .graphite
        }
        space.intensity = nil
        space.brightness = depth
        space.hue2 = hue2
        space.intensity2 = nil
        space.brightness2 = hue2 == nil ? nil : depth2
        if hue2 != nil { space.angle = angle }
    }

    func matches(_ space: SpaceInfo) -> Bool {
        guard space.glass != true, let b = space.brightness, abs(b - depth) < 0.005 else { return false }
        if let hue { guard let h = space.hue, abs(h - hue) < 0.002 else { return false } } else if !space.isNeutral { return false }
        guard let hue2 else { return space.hue2 == nil }
        guard let h2 = space.hue2, abs(h2 - hue2) < 0.002, abs((space.brightness2 ?? b) - depth2) < 0.005 else { return false }
        return true
    }

    /// The four you can't get from the wheel, white to black, and three colors to start from, Zigzag's navy among them.
    static let colors: [SpaceLook] = [
        SpaceLook(name: "White", hue: nil, depth: 0),
        SpaceLook(name: "Silver", hue: nil, depth: 0.22),
        SpaceLook(name: "Graphite", hue: nil, depth: 0.74),
        SpaceLook(name: "Black", hue: nil, depth: 1),
        SpaceLook(name: "Sky", hue: 0.57, depth: 0.22),
        SpaceLook(name: "Rose", hue: 0.96, depth: 0.2),
        SpaceLook(name: "Navy", hue: 0.62, depth: 0.82),
    ]

    /// Neighbors on the wheel, one a little deeper than the other, the way light falls across a wall.
    static let gradients: [SpaceLook] = [
        SpaceLook(name: "Dawn", hue: 0.07, depth: 0.16, hue2: 0.95, depth2: 0.3, angle: 90),
        SpaceLook(name: "Lagoon", hue: 0.47, depth: 0.16, hue2: 0.58, depth2: 0.34, angle: 90),
        SpaceLook(name: "Meadow", hue: 0.17, depth: 0.14, hue2: 0.33, depth2: 0.3, angle: 45),
        SpaceLook(name: "Lilac", hue: 0.78, depth: 0.15, hue2: 0.62, depth2: 0.3, angle: 45),
        SpaceLook(name: "Ember", hue: 0.06, depth: 0.62, hue2: 0.97, depth2: 0.84, angle: 90),
        SpaceLook(name: "Deep Sea", hue: 0.5, depth: 0.62, hue2: 0.63, depth2: 0.86, angle: 90),
        SpaceLook(name: "Midnight", hue: 0.62, depth: 0.74, hue2: 0.76, depth2: 0.92, angle: 45),
    ]
}

/// One preset: a round swatch of the look, ringed when it's the one in use.
final class LookSwatch: InteractiveView {
    let look: SpaceLook
    private let fill = CAGradientLayer()
    private let ring = CALayer()

    init(look: SpaceLook) {
        self.look = look
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        fill.masksToBounds = true
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
                fill.colors = look.colors.map(\.cgColor)
                fill.startPoint = CGPoint(x: 0.2, y: 0.1)
                fill.endPoint = CGPoint(x: 0.8, y: 0.9)
                fill.borderWidth = Tokens.Metric.hairline
                fill.borderColor = Tokens.Color.panelEdge.cgColor
            }
        }
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// How grainy the space's frame is: a pill that goes from smooth on the left to the most grain on the right,
/// tinted like the space, so the track itself shows what each point gives.
final class GrainSlider: NSView {
    var grain: Double = 0 { didSet { needsLayout = true } }
    var tint: NSColor = SpaceColor.sky.background { didSet { needsLayout = true } }
    /// With a gradient, the track runs from one color to the other.
    var tint2: NSColor? { didSet { needsLayout = true } }
    /// As a brightness slider instead: light to dark in `toneColors`, no grain; over a checkerboard for glass.
    var isTone = false { didSet { needsLayout = true; setAccessibilityLabel(isTone ? "Brightness" : "Grain"); toolTip = isTone ? "Brightness" : "Grain" } }
    var toneColors: [NSColor] = [.white, .black] { didSet { needsLayout = true } }
    var showsChecker = false { didSet { needsLayout = true } }
    private let checker = CALayer()
    /// Called while dragging (`final` false) and once on release (`final` true).
    var onChange: ((Double, Bool) -> Void)?
    private let track = CAGradientLayer()
    private let texture = CALayer()
    private let texture2 = CALayer()
    private let ramp = CAGradientLayer()
    private let ramp2 = CAGradientLayer()
    private let knob = CALayer()
    private let stopDots = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.masksToBounds = true
        track.cornerCurve = .continuous
        track.borderWidth = Tokens.Metric.hairline
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        // The texture builds from the left, clearly: smooth at 0, heavy grain at the far end.
        for (layer, mask, mode) in [(texture, ramp, "overlayBlendMode"), (texture2, ramp2, "softLightBlendMode")] {
            layer.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
            layer.compositingFilter = mode
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.cgColor]
            layer.mask = mask
            track.addSublayer(layer)
        }
        checker.masksToBounds = true
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
        setAccessibilityLabel("Grain")
        toolTip = "Grain"
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
                track.colors = isTone ? toneColors.map { $0.withAlphaComponent(showsChecker ? 0.85 : 1).cgColor }
                    : [tint.cgColor, (tint2 ?? tint).cgColor]
                checker.backgroundColor = isTone && showsChecker ? NSColor(patternImage: Self.checkerImage).cgColor : nil
                checker.frame = track.frame
                checker.cornerRadius = track.cornerRadius
                track.borderColor = Tokens.Color.panelEdge.cgColor
                knob.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
            }
            for (layer, mask) in [(texture, ramp), (texture2, ramp2)] {
                layer.frame = track.bounds
                mask.frame = layer.bounds
                layer.isHidden = isTone
            }
            let x = inset + CGFloat(grain) * (bounds.width - inset * 2)
            knob.bounds = CGRect(x: 0, y: 0, width: knobWidth, height: knobWidth)
            knob.position = CGPoint(x: x, y: bounds.height / 2)
            knob.cornerRadius = knobWidth / 2
            stopDots.frame = track.bounds
            let path = CGMutablePath()
            for stop in Self.stops.dropFirst().dropLast() {
                let sx = inset + CGFloat(stop) * (bounds.width - inset * 2)
                path.addEllipse(in: CGRect(x: sx - 1.5, y: bounds.height / 2 - 1.5, width: 3, height: 3))
            }
            stopDots.path = path
            stopDots.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        }
        knob.opacity = 1
        // Held, the knob swells a little under your finger.
        knob.setAffineTransform(pressed ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity)
        setAccessibilityValue(grain < 0.01 ? "Smooth" : "\(Int(grain * 100)) percent")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private static let checkerImage = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor(white: 0.97, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSRect(x: 4, y: 4, width: 4, height: 4).fill()
        return true
    }

    /// Five stops it settles into, with a tap at each, so it feels like a real control with some resistance.
    private static let stops: [Double] = [0, 0.25, 0.5, 0.75, 1]
    private var lastStop: Double?

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        let v = Double(min(max((x - inset) / (bounds.width - inset * 2), 0), 1))
        if let stop = Self.stops.first(where: { abs($0 - v) < 0.045 }) {
            if stop != lastStop { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            lastStop = stop
            return stop
        }
        lastStop = nil
        return v
    }

    private var pressed = false { didSet { needsLayout = true } }

    override func mouseDown(with event: NSEvent) {
        lastStop = Self.stops.first { abs($0 - grain) < 0.001 }
        pressed = true
        grain = value(at: event)
        layoutSubtreeIfNeeded()
        onChange?(grain, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.grain = self.value(at: event)
            self.layoutSubtreeIfNeeded()
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.pressed = false
                self.onChange?(self.grain, true)
            } else {
                self.onChange?(self.grain, false)
            }
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(0.1) }
    override func accessibilityPerformDecrement() -> Bool { step(-0.1) }

    private func step(_ delta: Double) -> Bool {
        grain = min(max(grain + delta, 0), 1)
        onChange?(grain, true)
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
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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

/// How a space looks, in one piece that the space editor and the first-run color step both use, so they're the
/// same everywhere: Color, Gradient or Glass on top; then the wheel and a row of presets (or, for glass, how light or
/// dark the glass is); then grain, and for a gradient its direction. `onPreview` fires while you drag, `onCommit`
/// when you let go or pick something.
final class SpaceLookEditor: NSView {
    private let kindSwitch = SlidingSwitch([.text("Color"), .text("Gradient"), .text("Glass")])
    private let wheel = ColorWheel()
    private let colorSwatches = SpaceLook.colors.map { LookSwatch(look: $0) }
    private let gradientSwatches = SpaceLook.gradients.map { LookSwatch(look: $0) }
    private let shadeLabel = SpaceLookEditor.rowLabel("Shade")
    /// Glass: clear white to smoked black.
    private let shadeSlider = GrainSlider()
    private let grainLabel = SpaceLookEditor.rowLabel("Grain")
    private let grainSlider = GrainSlider()
    private let directionLabel = SpaceLookEditor.rowLabel("Direction")
    private let dial = DirectionKnob()

    var onPreview: ((SpaceInfo) -> Void)?
    var onCommit: ((SpaceInfo) -> Void)?
    /// The kind changed, and with it how tall this is.
    var onResize: (() -> Void)?

    /// The space as the editor has it right now.
    private var draft: SpaceInfo
    /// As it was when the editor opened.
    private let original: SpaceInfo
    /// A space never given a color follows the Mac, light by day and dark at night, until you choose one.
    private var colorChosen: Bool

    private enum Kind: Int { case color, gradient, glass }
    private var kind: Kind { draft.glass == true ? .glass : draft.hue2 != nil ? .gradient : .color }

    /// `dark`: whether the window looks dark right now, for where a space that follows the Mac starts on the wheel.
    init(space: SpaceInfo, dark: Bool) {
        original = space
        draft = space
        colorChosen = space.brightness != nil
        super.init(frame: .zero)
        if draft.brightness == nil { draft.brightness = Self.startingDepth(space, dark: dark) }
        let views: [NSView] = [kindSwitch, wheel, shadeLabel, shadeSlider, grainLabel, grainSlider, directionLabel, dial]
        (views + colorSwatches + gradientSwatches).forEach { addSubview($0) }

        kindSwitch.selectedIndex = kind.rawValue
        kindSwitch.onChange = { [weak self] index in self?.switchKind(Kind(rawValue: index) ?? .color) }

        wheel.onChange = { [weak self] index, spot, final in
            guard let self else { return }
            if index == 0 {
                self.draft.hue = spot.hue
                self.draft.brightness = spot.depth
            } else {
                self.draft.hue2 = spot.hue
                self.draft.brightness2 = spot.depth
            }
            self.draft.intensity = nil
            self.draft.intensity2 = nil
            self.colorChosen = true
            self.changed(final: final, wheel: false)
        }
        for swatch in colorSwatches + gradientSwatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let look = swatch?.look else { return }
                look.apply(to: &self.draft)
                self.colorChosen = true
                self.changed(final: true, wheel: true)
            }
        }
        shadeSlider.isTone = true
        shadeSlider.showsChecker = true
        shadeSlider.toneColors = [.white, .black]
        shadeSlider.setAccessibilityLabel("Shade")
        shadeSlider.toolTip = nil
        shadeSlider.onChange = { [weak self] value, final in
            guard let self else { return }
            self.draft.brightness = value
            self.colorChosen = true
            self.changed(final: final, wheel: false)
        }
        grainSlider.toolTip = nil
        grainSlider.onChange = { [weak self] grain, final in
            guard let self else { return }
            self.draft.grain = grain > 0.01 ? grain : nil
            self.changed(final: final, wheel: false)
        }
        dial.toolTip = nil
        dial.onChange = { [weak self] angle, final in
            guard let self else { return }
            self.draft.angle = angle
            self.changed(final: final, wheel: false)
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
        // Light or dark: glass goes by its shade, a color by whichever text reads better on it.
        space.appearance = space.glass == true ? ((draft.brightness ?? 0) < 0.5 ? "light" : "dark") : space.readableAppearance
        return space
    }

    private func changed(final: Bool, wheel moveWheel: Bool) {
        if final { onCommit?(look) } else { onPreview?(look) }
        sync(animated: moveWheel)
    }

    private func switchKind(_ new: Kind) {
        guard new != kind else { return }
        switch new {
        case .color:
            draft.glass = nil
            draft.hue2 = nil
            draft.brightness2 = nil
        case .gradient:
            draft.glass = nil
            // A gradient needs two colors: a gray takes on Zigzag's blue, and the second starts as its neighbor.
            if draft.hue == nil { draft.hue = 0.6 }
            let depth = min(max(draft.brightness ?? 0.3, 0.12), 0.88)
            draft.brightness = depth
            draft.hue2 = (draft.hue! + 0.1).truncatingRemainder(dividingBy: 1)
            draft.brightness2 = depth < 0.6 ? depth + 0.16 : depth - 0.16
            draft.angle = draft.angle ?? 90
        case .glass:
            draft.glass = true
            draft.hue2 = nil
            draft.brightness2 = nil
        }
        colorChosen = true
        changed(final: true, wheel: false)
        onResize?()
    }

    // MARK: Showing it

    /// Every control from the draft.
    private func sync(animated: Bool) {
        let space = draft
        kindSwitch.selectedIndex = kind.rawValue
        var spots = [ColorWheel.Spot(hue: space.baseHue, depth: space.isNeutral ? 0 : space.brightness ?? 0)]
        var colors = [space.background]
        if let hue2 = space.hue2, let end = space.background2 {
            spots.append(ColorWheel.Spot(hue: hue2, depth: space.brightness2 ?? space.brightness ?? 0))
            colors.append(end)
        }
        wheel.show(spots, colors: colors, animated: animated)
        for swatch in colorSwatches + gradientSwatches { swatch.isSelected = swatch.look.matches(space) }
        let shown = look
        grainSlider.grain = space.grain ?? 0
        grainSlider.tint = kind == .glass ? NSColor(white: 0.92 - 0.75 * CGFloat(space.brightness ?? 0), alpha: 1) : shown.background
        grainSlider.tint2 = kind == .glass ? nil : shown.background2
        shadeSlider.grain = space.brightness ?? 0
        dial.angle = space.gradientAngle
        let glass = kind == .glass
        wheel.isHidden = glass
        colorSwatches.forEach { $0.isHidden = kind != .color }
        gradientSwatches.forEach { $0.isHidden = kind != .gradient }
        shadeLabel.isHidden = !glass
        shadeSlider.isHidden = !glass
        directionLabel.isHidden = kind != .gradient
        dial.isHidden = kind != .gradient
        needsLayout = true
    }

    // MARK: Layout

    private let switchHeight: CGFloat = 30
    private let swatchSize: CGFloat = 26
    private let sliderHeight: CGFloat = 30
    private let dialSize: CGFloat = 60
    private let labelWidth: CGFloat = 72
    /// How tall the wheel is; the first-run step has a little less room.
    var wheelHeight: CGFloat = 236 { didSet { needsLayout = true } }

    /// How tall it is for the kind it shows.
    var preferredHeight: CGFloat {
        var height = switchHeight + Tokens.Space.x4
        height += kind == .glass ? sliderHeight + Tokens.Space.x3 : wheelHeight + Tokens.Space.x3 + swatchSize + Tokens.Space.x5
        height += sliderHeight
        if kind == .gradient { height += Tokens.Space.x3 + dialSize }
        return height
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        kindSwitch.frame = NSRect(x: 0, y: y, width: width, height: switchHeight)
        y += switchHeight + Tokens.Space.x4
        if kind == .glass {
            row(shadeLabel, shadeSlider, y: y, height: sliderHeight, width: width)
            y += sliderHeight + Tokens.Space.x3
        } else {
            wheel.frame = NSRect(x: 0, y: y, width: width, height: wheelHeight)
            y += wheelHeight + Tokens.Space.x3
            for swatches in [colorSwatches, gradientSwatches] {
                let count = CGFloat(swatches.count)
                let gap = (width - count * swatchSize) / max(count - 1, 1)
                for (i, swatch) in swatches.enumerated() {
                    swatch.frame = NSRect(x: CGFloat(i) * (swatchSize + gap), y: y, width: swatchSize, height: swatchSize)
                }
            }
            y += swatchSize + Tokens.Space.x5
        }
        row(grainLabel, grainSlider, y: y, height: sliderHeight, width: width)
        y += sliderHeight + Tokens.Space.x3
        if kind == .gradient { row(directionLabel, dial, y: y, height: dialSize, width: dialSize) }
    }

    /// A name on the left and its control beside it, every control starting at the same line.
    private func row(_ label: Label, _ control: NSView, y: CGFloat, height: CGFloat, width: CGFloat) {
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: y + (height - lh) / 2, width: labelWidth, height: lh)
        control.frame = NSRect(x: labelWidth, y: y, width: min(width, bounds.width - labelWidth), height: height)
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
        nameBackground.layer?.cornerRadius = Tokens.Radius.control + 2
        [nameBackground, nameField, editor].forEach { addSubview($0) }
        editor.onPreview = { [weak self] look in
            guard let self else { return }
            (self.controller ?? BrowserWindowController.undoTarget)?.previewSpace(look)
        }
        editor.onCommit = { [weak self] look in
            guard let self else { return }
            Library.shared.setLook(look)
            self.edited = true
        }
        editor.onResize = { [weak self] in self?.resizeToFit() }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private let pad = Tokens.Space.x4
    private let nameHeight: CGFloat = 34

    var contentHeight: CGFloat { pad + nameHeight + Tokens.Space.x3 + editor.preferredHeight + pad }

    /// The panel grows or shrinks with the kind, keeping the edge nearest what opened it.
    private func resizeToFit() {
        guard superview != nil, abs(frame.height - contentHeight) > 0.5 else { return }
        var target = frame
        let delta = contentHeight - frame.height
        target.size.height = contentHeight
        if superview?.isFlipped == true, anchoredBelow == false { target.origin.y -= delta }
        target.origin.y = max(Tokens.Space.x2, target.origin.y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        nameField.frame = NSRect(x: pad + Tokens.Space.x2 + 2, y: pad + (nameHeight - fh) / 2, width: width - Tokens.Space.x4, height: fh)
        editor.frame = NSRect(x: pad, y: pad + nameHeight + Tokens.Space.x3, width: width, height: editor.preferredHeight)
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
            // Hanging from the header, it grows downward when a gradient adds its row.
            anchoredBelow = true
        }
        top = max(Tokens.Space.x2, min(top, overlay.bounds.height - height - Tokens.Space.x4))
        frame = NSRect(x: x, y: top, width: Self.width, height: height)
        overlay.addSubview(self)
        present(arrival: .fade)
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
                // Esc in another window (Settings, a second browser window) is that window's.
                if event.keyCode == 53, event.window === self.window { self.close(); return nil }
                return event
            }
            if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    /// The space as it was when the editor opened; closing registers one ⌘Z for everything changed.
    private let before = Library.shared.snapshot
    private var edited = false

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        commitName()
        if edited { (controller ?? BrowserWindowController.undoTarget)?.recordLibraryUndo("Edit Space", before: before) }
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
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
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

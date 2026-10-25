import AppKit

/// A hue slider drawn in the space tints themselves, so it shows what you'll get, not a raw rainbow.
final class HueSlider: NSView {
    var hue: Double = 0.6 { didSet { needsLayout = true } }
    /// Called while dragging (`final` false) and once on release (`final` true).
    var onChange: ((Double, Bool) -> Void)?
    private let track = CAGradientLayer()
    private let knob = CALayer()
    private let knobFill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        track.cornerCurve = .continuous
        layer?.addSublayer(track)
        knob.shadowOpacity = 1
        knob.shadowRadius = 4
        knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knob)
        knob.addSublayer(knobFill)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Custom color")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let knobSize: CGFloat = Tokens.Space.x6
    private var trackInset: CGFloat { knobSize / 2 }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let h: CGFloat = Tokens.Space.x3
            track.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
            track.cornerRadius = h / 2
            track.colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { cgColor(SpaceColor.swatch(hue: $0)) }
            let x = trackInset + CGFloat(hue) * (bounds.width - trackInset * 2)
            knob.frame = NSRect(x: x - knobSize / 2, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
            knob.cornerRadius = knobSize / 2
            knob.backgroundColor = .white
            knob.shadowColor = cgColor(Tokens.Color.panelShadow)
            knobFill.frame = knob.bounds.insetBy(dx: 3, dy: 3)
            knobFill.cornerRadius = knobFill.frame.width / 2
            knobFill.backgroundColor = cgColor(SpaceColor.swatch(hue: hue))
        }
        setAccessibilityValue("\(Int(hue * 360)) degrees")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func hue(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return Double(min(max((x - trackInset) / (bounds.width - trackInset * 2), 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        hue = hue(at: event)
        layoutSubtreeIfNeeded()
        onChange?(hue, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.hue = self.hue(at: event)
            self.layoutSubtreeIfNeeded()
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.onChange?(self.hue, true)
            } else {
                self.onChange?(self.hue, false)
            }
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(1.0 / 24) }
    override func accessibilityPerformDecrement() -> Bool { step(-1.0 / 24) }

    private func step(_ delta: Double) -> Bool {
        hue = min(max(hue + delta, 0), 1)
        onChange?(hue, true)
        return true
    }
}

/// How grainy the space's frame is: a pill that goes from smooth on the left to the most grain on the right,
/// tinted like the space, so the track itself shows what each point gives.
final class GrainSlider: NSView {
    var grain: Double = 0 { didSet { needsLayout = true } }
    var tint: NSColor = SpaceColor.sky.background { didSet { needsLayout = true } }
    /// With a gradient, the track runs from one color to the other.
    var tint2: NSColor? { didSet { needsLayout = true } }
    /// As the glass's shade instead: white to black over a checkerboard, no grain.
    var isTone = false { didSet { needsLayout = true; setAccessibilityLabel(isTone ? "Glass shade" : "Grain"); toolTip = isTone ? "Shade" : "Grain" } }
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
                track.colors = isTone ? [NSColor(white: 1, alpha: 0.85).cgColor, NSColor(white: 0, alpha: 0.85).cgColor]
                    : [tint.cgColor, (tint2 ?? tint).cgColor]
                checker.backgroundColor = isTone ? NSColor(patternImage: Self.checkerImage).cgColor : nil
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

/// One round choice in the look row: a ready-made look (a color, a gradient, or tinted glass), or the custom wheel.
final class TintSwatch: InteractiveView {
    enum Kind { case tint(SpaceColor), look(SpaceLook, glass: Bool), custom }
    var kind: Kind { didSet { applyKind(); stateDidChange(animated: false) } }
    private let fill = CAGradientLayer()
    private let checker = CALayer()
    private let wheel = CAGradientLayer()
    private let ring = CALayer()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        layer?.addSublayer(checker)
        layer?.addSublayer(fill)
        layer?.addSublayer(wheel)
        applyKind()
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyKind() {
        wheel.isHidden = true
        checker.isHidden = true
        fill.isHidden = false
        switch kind {
        case .custom:
            wheel.type = .conic
            wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
            wheel.endPoint = CGPoint(x: 0.5, y: 0)
            wheel.isHidden = false
            fill.isHidden = true
            toolTip = "Custom"
            setAccessibilityLabel("Custom color")
        case .tint(let color):
            toolTip = color.name
            setAccessibilityLabel(color.name)
        case .look(let look, let glass):
            checker.isHidden = !glass
            toolTip = look.name
            setAccessibilityLabel(look.name)
        }
    }

    /// The checkerboard everyone reads as "see-through".
    private static let checkerImage = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
        NSColor(white: 0.98, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 3, height: 3).fill()
        NSRect(x: 3, y: 3, width: 3, height: 3).fill()
        return true
    }

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
                // The chosen swatch sits inside its ring; the others grow slightly under the pointer.
                let inset: CGFloat = isSelected ? 4 : (isHovered ? 0.5 : 1.5)
                let inner = bounds.insetBy(dx: inset, dy: inset)
                for l in [fill, checker, wheel] as [CALayer] {
                    l.frame = inner
                    l.cornerRadius = inner.width / 2
                    l.masksToBounds = true
                }
                wheel.colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { SpaceColor.swatch(hue: $0).cgColor }
                fill.borderWidth = 0
                switch kind {
                case .tint(let color):
                    fill.colors = [color.swatch.cgColor, color.swatch.cgColor]
                    fill.startPoint = CGPoint(x: 0.5, y: 0)
                    fill.endPoint = CGPoint(x: 0.5, y: 1)
                    if color == .snow || color == .ink { fill.borderWidth = Tokens.Metric.hairline }
                case .look(let look, let glass):
                    let (a, b) = look.swatchColors
                    let alpha: CGFloat = glass ? 0.6 : 1
                    fill.colors = [a.withAlphaComponent(alpha).cgColor, b.withAlphaComponent(alpha).cgColor]
                    fill.startPoint = CGPoint(x: 0.15, y: 0.85)
                    fill.endPoint = CGPoint(x: 0.85, y: 0.15)
                    checker.backgroundColor = NSColor(patternImage: Self.checkerImage).cgColor
                    if look.color == .snow || look.color == .ink || glass { fill.borderWidth = Tokens.Metric.hairline }
                case .custom: break
                }
                fill.borderColor = Tokens.Color.panelEdge.cgColor
            }
        }
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// A two-dimensional color field: across is hue, up is how strong the tint is.
/// Drawn in the space tints themselves, so what you touch is what the window becomes.
final class ColorCanvas: NSView {
    var hue: Double = 0.6 { didSet { needsLayout = true } }
    var intensity: Double = SpaceColor.defaultIntensity { didSet { needsLayout = true } }
    /// The gradient's second color: a second knob at the same height, joined to the first. Nil: none.
    var hue2: Double? { didSet { needsLayout = true } }
    /// The second color's own strength; nil: the same as the first.
    var intensity2: Double? { didSet { needsLayout = true } }
    var onChange: ((Double, Double, Bool) -> Void)?
    /// The second knob moved: its hue, the shared intensity, and whether the drag has ended.
    var onChange2: ((Double, Double, Bool) -> Void)?
    private let knob2 = CALayer()
    private let knob2Fill = CALayer()

    private let hues = CAGradientLayer()
    private let fade = CAGradientLayer()
    private let dots = CALayer()
    private let knob = CALayer()
    private let knobFill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.panel - 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        hues.startPoint = CGPoint(x: 0, y: 0.5)
        hues.endPoint = CGPoint(x: 1, y: 0.5)
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(hues)
        layer?.addSublayer(fade)
        layer?.addSublayer(dots)
        for k in [knob2, knob] {
            k.shadowOpacity = 1
            k.shadowRadius = 4
            k.shadowOffset = CGSize(width: 0, height: -1)
            layer?.addSublayer(k)
        }
        knob.addSublayer(knobFill)
        knob2.addSublayer(knob2Fill)
        setAccessibilityRole(.colorWell)
        setAccessibilityLabel("Space color")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let knobSize = Tokens.Space.x6

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            hues.frame = bounds
            fade.frame = bounds
            hues.colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { cgColor(SpaceColor.swatch(hue: $0)) }
            // Toward the bottom the tint fades to the page color: less intense.
            let base = cgColor(Tokens.Color.panelBackground)
            fade.colors = [base.copy(alpha: 0) ?? base, base.copy(alpha: 0.55) ?? base]
            drawDots()
            // The knob's center keeps half a knob from each edge, so it's never cut off.
            let r = knobSize / 2
            let x = r + CGFloat(hue) * (bounds.width - knobSize)
            let y = r + (1 - CGFloat(intensity)) * (bounds.height - knobSize)
            knob.frame = NSRect(x: x - knobSize / 2, y: y - knobSize / 2, width: knobSize, height: knobSize)
            knob.cornerRadius = knobSize / 2
            knob.backgroundColor = .white
            knob.shadowColor = cgColor(Tokens.Color.panelShadow)
            knobFill.frame = knob.bounds.insetBy(dx: 4, dy: 4)
            knobFill.cornerRadius = knobFill.frame.width / 2
            knobFill.backgroundColor = cgColor(SpaceColor.swatch(hue: hue))
            knob2.isHidden = hue2 == nil
            if let hue2 {
                let x2 = r + CGFloat(hue2) * (bounds.width - knobSize)
                let y2 = r + (1 - CGFloat(intensity2 ?? intensity)) * (bounds.height - knobSize)
                knob2.frame = NSRect(x: x2 - knobSize / 2, y: y2 - knobSize / 2, width: knobSize, height: knobSize)
                knob2.cornerRadius = knobSize / 2
                knob2.backgroundColor = .white
                knob2.shadowColor = cgColor(Tokens.Color.panelShadow)
                knob2Fill.frame = knob2.bounds.insetBy(dx: 4, dy: 4)
                knob2Fill.cornerRadius = knob2Fill.frame.width / 2
                knob2Fill.backgroundColor = cgColor(SpaceColor.swatch(hue: hue2))
            }
        }
    }

    /// A fine dot grid gives the field texture and a sense of position, like graph paper.
    private func drawDots() {
        dots.frame = bounds
        let step: CGFloat = 12
        let image = NSImage(size: bounds.size, flipped: true) { rect in
            NSColor.white.withAlphaComponent(0.35).setFill()
            var y = step / 2
            while y < rect.height {
                var x = step / 2
                while x < rect.width {
                    NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
                    x += step
                }
                y += step
            }
            return true
        }
        dots.contents = image
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Which knob a drag moves: the second one when it's nearer the pointer.
    private var draggingSecond = false

    private func update(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = knobSize / 2
        let h = Double(min(max((p.x - r) / (bounds.width - knobSize), 0), 0.999))
        if draggingSecond {
            hue2 = h
            intensity2 = Double(min(max(1 - (p.y - r) / (bounds.height - knobSize), 0), 1))
        } else {
            hue = h
            intensity = Double(min(max(1 - (p.y - r) / (bounds.height - knobSize), 0), 1))
        }
        layoutSubtreeIfNeeded()
    }

    private func report(final: Bool) {
        if draggingSecond, let hue2 { onChange2?(hue2, intensity2 ?? intensity, final) } else { onChange?(hue, intensity, final) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        draggingSecond = !knob2.isHidden && hypot(p.x - knob2.frame.midX, p.y - knob2.frame.midY) < hypot(p.x - knob.frame.midX, p.y - knob.frame.midY)
        update(from: event)
        report(final: false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.update(from: event)
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.report(final: true)
            } else {
                self.report(final: false)
            }
        }
    }
}

/// One appearance choice for a space: a tiny window drawn in that mode, tinted like the space.
/// "Auto" is drawn half light, half dark. Click to choose.
final class AppearanceOption: InteractiveView {
    enum Mode: CaseIterable { case auto, light, dark }
    let mode: Mode
    private let lightHalf = MiniWindow(dark: false)
    private let darkHalf = MiniWindow(dark: true)
    private let clip = NSView()
    private let ring = CALayer()
    private let label: Label

    init(mode: Mode) {
        self.mode = mode
        label = Label(mode == .auto ? "Auto" : mode == .light ? "Light" : "Dark", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
        label.alignment = .center
        super.init(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Tokens.Radius.control + 1
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        addSubview(clip)
        if mode != .dark { clip.addSubview(lightHalf) }
        if mode != .light { clip.addSubview(darkHalf) }
        addSubview(label)
        ring.borderWidth = 2
        ring.cornerRadius = Tokens.Radius.control + 4
        ring.cornerCurve = .continuous
        layer?.addSublayer(ring)
        ring.zPosition = 5
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label.stringValue + " appearance")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ background: NSColor) {
        lightHalf.show(background)
        darkHalf.show(background)
    }

    override func layout() {
        super.layout()
        let labelHeight = label.lineHeight
        let preview = NSRect(x: 3, y: 3, width: bounds.width - 6, height: bounds.height - labelHeight - Tokens.Space.x2 - 3)
        clip.frame = preview
        switch mode {
        case .auto:
            lightHalf.frame = NSRect(x: 0, y: 0, width: clip.bounds.width, height: clip.bounds.height)
            darkHalf.frame = NSRect(x: clip.bounds.width / 2, y: 0, width: clip.bounds.width / 2, height: clip.bounds.height)
            darkHalf.offset = clip.bounds.width / 2
        case .light: lightHalf.frame = clip.bounds
        case .dark: darkHalf.frame = clip.bounds
        }
        label.frame = NSRect(x: 0, y: preview.maxY + Tokens.Space.x1, width: bounds.width, height: labelHeight)
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            ring.frame = clip.frame.insetBy(dx: -3, dy: -3)
            ring.borderColor = cgColor(isSelected ? Brand.Theme.for(self).accent : (isHovered ? Tokens.Color.textTertiary : .clear))
        }
        label.textColor = isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// A tiny window in light or dark: frame tint, sidebar lines, page card.
final class MiniWindow: NSView {
    private let frameView = ColorView()
    private let card = ColorView()
    private let lines: [ColorView] = (0..<3).map { _ in ColorView() }
    /// For the dark half of "Auto": draw as if this view started this far into the full preview.
    var offset: CGFloat = 0 { didSet { needsLayout = true } }

    init(dark: Bool) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.masksToBounds = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 3
        card.color = Tokens.Color.cardBackground
        addSubview(frameView)
        frameView.addSubview(card)
        for line in lines {
            line.wantsLayer = true
            line.layer?.cornerRadius = 1.5
            line.color = Tokens.Color.textTertiary
            frameView.addSubview(line)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ background: NSColor) { frameView.color = background }

    override func layout() {
        super.layout()
        let full = bounds.width + offset
        frameView.frame = NSRect(x: -offset, y: 0, width: full, height: bounds.height)
        let sidebarWidth = full * 0.3
        card.frame = NSRect(x: sidebarWidth, y: 4, width: full - sidebarWidth - 4, height: bounds.height - 8)
        for (i, line) in lines.enumerated() {
            line.frame = NSRect(x: 5, y: 7 + CGFloat(i) * 6, width: sidebarWidth - 10 - CGFloat(i % 2) * 4, height: 3)
        }
    }
}

/// Edits one space: its name and its color. A panel beside the sidebar, Arc-style but our own:
/// a living color field, light and dark previews, and the curated tints. The window is the preview too.
/// A ready-made look for a space: a curated color, or a hue and how strong it is, and optionally a second color and
/// which way the two run.
struct SpaceLook {
    let name: String
    var color: SpaceColor? = nil
    var hue: Double = 0, intensity: Double = SpaceColor.defaultIntensity
    var hue2: Double? = nil, intensity2: Double? = nil
    var angle: Double = 45

    static func tint(_ color: SpaceColor) -> SpaceLook { SpaceLook(name: color.name, color: color, hue: color.hue) }

    /// Bright enough to recognize at swatch size.
    var swatchColors: (NSColor, NSColor) {
        let a = color?.swatch ?? Self.swatch(hue: hue, intensity: intensity)
        return (a, hue2.map { Self.swatch(hue: $0, intensity: intensity2 ?? intensity) } ?? a)
    }

    private static func swatch(hue: Double, intensity: Double) -> NSColor {
        NSColor(hue: hue, saturation: 0.22 + 0.33 * intensity, brightness: 0.9 - 0.3 * intensity, alpha: 1)
    }

    /// A few that look good: white, gray and black, and four soft tints. The pad does the rest.
    static let solids: [SpaceLook] = [.tint(.snow), .tint(.graphite), .tint(.ink), .tint(.sky), .tint(.sage), .tint(.rose), .tint(.lavender)]

    /// Close, quiet pairs, the way light changes across a wall, rather than two loud colors fighting.
    static let gradients: [SpaceLook] = [
        SpaceLook(name: "Mist", hue: 0.58, intensity: 0.35, hue2: 0.68, intensity2: 0.4, angle: 90),
        SpaceLook(name: "Dusk", hue: 0.74, intensity: 0.5, hue2: 0.94, intensity2: 0.45, angle: 45),
        SpaceLook(name: "Sea", hue: 0.5, intensity: 0.5, hue2: 0.58, intensity2: 0.6, angle: 90),
        SpaceLook(name: "Moss", hue: 0.28, intensity: 0.4, hue2: 0.4, intensity2: 0.45, angle: 45),
        SpaceLook(name: "Sand", hue: 0.09, intensity: 0.4, hue2: 0.13, intensity2: 0.3, angle: 90),
        SpaceLook(name: "Blush", hue: 0.97, intensity: 0.4, hue2: 0.06, intensity2: 0.4, angle: 45),
        SpaceLook(name: "Night", hue: 0.63, intensity: 0.85, hue2: 0.72, intensity2: 0.8, angle: 90),
    ]

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

final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    private let nameField = PlainTextField(font: Tokens.Font.large(.semibold), placeholder: "Name this space")
    /// The name sits on a soft field, so it reads as something you can type into.
    private let nameBackground = ColorView(color: Tokens.Color.fieldFill)
    /// What kind of look: one color, two that fade into each other, or frosted glass.
    private let kindSwitch = SlidingSwitch([.text("Solid"), .text("Gradient"), .text("Glass")])
    private let canvas = ColorCanvas()
    /// Beside the name: match the system, always light, always dark.
    private static let modes: [String?] = [nil, "light", "dark"]
    private let modeSwitch = SlidingSwitch([.symbol("circle.lefthalf.filled", toolTip: "Match the System"),
                                            .symbol("sun.max", toolTip: "Always Light"), .symbol("moon", toolTip: "Always Dark")])
    /// A few ready-made looks for the chosen kind.
    private var swatches: [TintSwatch] = []
    private let grainSlider = GrainSlider()
    /// Glass: one slider, clear white to smoked black.
    private let toneSlider = GrainSlider()
    /// With a gradient: which way it runs.
    private let dial = DirectionKnob()
    private var monitor: Any?
    static let width: CGFloat = 316

    private enum Kind: Int { case solid, gradient, glass }
    private var kind: Kind {
        guard let space = Library.shared.space(spaceID) else { return .solid }
        return space.glass == true ? .glass : space.hue2 != nil ? .gradient : .solid
    }

    /// `controller` is the browser window it belongs to; Settings passes nil and hosts it in its own window.
    init(spaceID: UUID, controller: BrowserWindowController?) {
        self.spaceID = spaceID
        self.controller = controller
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        let space = Library.shared.space(spaceID)
        nameField.stringValue = space?.name ?? ""
        nameField.delegate = self
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerCurve = .continuous
        nameBackground.layer?.cornerRadius = Tokens.Radius.control + 2
        [nameBackground, nameField, modeSwitch, kindSwitch, canvas, grainSlider, toneSlider, dial].forEach { addSubview($0) }
        toneSlider.isTone = true
        toneSlider.grain = space?.glassTone ?? 0
        toneSlider.onChange = { [weak self] tone, final in
            guard let self else { return }
            if final {
                Library.shared.setGlassTone(tone, for: self.spaceID)
                // Text stays readable: light glass reads in light mode, dark glass in dark.
                Library.shared.setAppearance(tone < 0.5 ? "light" : "dark", for: self.spaceID)
                self.edited = true
                self.refresh()
            } else {
                (self.controller ?? BrowserWindowController.undoTarget)?.previewGlassTone(tone, for: self.spaceID)
                if let space = Library.shared.space(self.spaceID) {
                    var draft = space
                    draft.glassTone = tone
                    self.grainSlider.tint = self.glassTint(draft) ?? space.background
                }
            }
        }

        kindSwitch.selectedIndex = kind.rawValue
        kindSwitch.onChange = { [weak self] index in self?.switchKind(Kind(rawValue: index) ?? .solid) }

        canvas.onChange = { [weak self] hue, intensity, final in
            guard let self else { return }
            if final {
                Library.shared.setHue(hue, intensity: intensity, for: self.spaceID)
                self.edited = true
                self.refresh()
            } else {
                self.preview()
            }
        }
        canvas.onChange2 = { [weak self] hue2, intensity2, final in
            guard let self else { return }
            if final {
                Library.shared.setHue(self.canvas.hue, intensity: self.canvas.intensity, for: self.spaceID)
                Library.shared.setSecondHue(hue2, intensity: intensity2, for: self.spaceID)
                self.edited = true
                self.refresh()
            } else {
                self.preview()
            }
        }
        dial.onChange = { [weak self] angle, final in
            guard let self else { return }
            if final {
                Library.shared.setGradientAngle(angle, for: self.spaceID)
                self.edited = true
                self.refresh()
            } else {
                self.preview()
            }
        }
        grainSlider.grain = space?.grain ?? 0
        grainSlider.onChange = { [weak self] grain, final in
            guard let self else { return }
            if final {
                Library.shared.setGrain(grain, for: self.spaceID)
                self.edited = true
            } else {
                (self.controller ?? BrowserWindowController.undoTarget)?.previewSpaceGrain(grain, for: self.spaceID)
            }
        }
        modeSwitch.onChange = { [weak self] index in
            guard let self else { return }
            Library.shared.setAppearance(Self.modes[index], for: self.spaceID)
            self.edited = true
            self.refresh()
        }
        rebuildSwatches()
        refresh()
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Changing the look

    private var looks: [SpaceLook] {
        switch kind {
        case .solid: SpaceLook.solids
        case .gradient: SpaceLook.gradients
        case .glass: []
        }
    }

    private func switchKind(_ new: Kind) {
        guard let space = Library.shared.space(spaceID), new != kind else { return }
        switch new {
        case .solid:
            Library.shared.setGlass(false, for: spaceID)
            Library.shared.setSecondHue(nil, for: spaceID)
        case .gradient:
            Library.shared.setGlass(false, for: spaceID)
            // Starts from the color you had, fading into a neighbor; pick a ready-made one below or drag either knob.
            if space.hue == nil { Library.shared.setHue(space.baseHue, intensity: SpaceColor.defaultIntensity, for: spaceID) }
            let base = Library.shared.space(spaceID)!
            Library.shared.setSecondHue((base.baseHue + 0.2).truncatingRemainder(dividingBy: 1), intensity: base.intensity, for: spaceID)
        case .glass:
            Library.shared.setSecondHue(nil, for: spaceID)
            Library.shared.setGlass(true, for: spaceID)
            Library.shared.setAppearance((space.glassTone ?? 0) < 0.5 ? "light" : "dark", for: spaceID)
        }
        edited = true
        rebuildSwatches()
        refresh()
        resizeToFit()
    }

    private func apply(_ look: SpaceLook) {
        let glass = kind == .glass
        let before = Library.shared.space(spaceID)
        if let color = look.color {
            Library.shared.setColor(color, for: spaceID)
        } else {
            Library.shared.setHue(look.hue, intensity: look.intensity, for: spaceID)
        }
        Library.shared.setSecondHue(look.hue2, intensity: look.intensity2, for: spaceID)
        if look.hue2 != nil { Library.shared.setGradientAngle(look.angle, for: spaceID) }
        Library.shared.setGlass(glass, for: spaceID)
        if before?.appearance == nil, let color = look.color, color == .snow || color == .ink {
            // White and black come with the mode that keeps text readable, unless you've chosen one yourself.
            Library.shared.setAppearance(color == .ink ? "dark" : "light", for: spaceID)
        }
        edited = true
        refresh()
    }

    private func matches(_ look: SpaceLook, _ space: SpaceInfo) -> Bool {
        if let color = look.color { return space.hue == nil && space.color == color && space.hue2 == nil }
        guard let hue = space.hue, abs(hue - look.hue) < 0.001, abs((space.intensity ?? SpaceColor.defaultIntensity) - look.intensity) < 0.001 else { return false }
        guard let h2 = look.hue2 else { return space.hue2 == nil }
        return space.hue2.map { abs($0 - h2) < 0.001 } == true && space.gradientAngle == look.angle
    }

    /// The same seven swatches stay put; switching kinds only changes what they show, with a quick fade.
    private func rebuildSwatches() {
        let glass = kind == .glass
        let looks = self.looks
        if swatches.count != looks.count {
            swatches.forEach { $0.removeFromSuperview() }
            swatches = looks.map { TintSwatch(kind: .look($0, glass: glass)) }
            for (i, swatch) in swatches.enumerated() {
                swatch.onClick = { [weak self] _ in
                    guard let self, i < self.looks.count else { return }
                    self.apply(self.looks[i])
                }
                addSubview(swatch)
            }
            needsLayout = true
            return
        }
        for (swatch, look) in zip(swatches, looks) {
            let fade = CATransition()
            fade.duration = Tokens.Motion.standard
            swatch.layer?.add(fade, forKey: "look")
            swatch.kind = .look(look, glass: glass)
        }
    }

    // MARK: Showing it

    /// Everything on the panel from what's saved.
    private func refresh() {
        guard let space = Library.shared.space(spaceID) else { return }
        canvas.hue = space.baseHue
        canvas.intensity = space.intensity ?? SpaceColor.defaultIntensity
        canvas.hue2 = space.hue2
        canvas.intensity2 = space.intensity2
        dial.angle = space.gradientAngle
        dial.isHidden = space.hue2 == nil
        kindSwitch.selectedIndex = kind.rawValue
        grainSlider.tint = glassTint(space) ?? space.background
        grainSlider.tint2 = space.glass == true ? nil : space.background2
        modeSwitch.selectedIndex = Self.modes.firstIndex { $0 == space.appearance } ?? 0
        for (i, swatch) in swatches.enumerated() { swatch.isSelected = matches(looks[i], space) }
        let glass = kind == .glass
        canvas.isHidden = glass
        toneSlider.isHidden = !glass
        toneSlider.grain = space.glassTone ?? 0
        // Glass picks its own mode from its shade.
        modeSwitch.isHidden = glass
        needsLayout = true
    }

    /// Glass's grain shows on its shade, opaque so the texture reads.
    private func glassTint(_ space: SpaceInfo) -> NSColor? {
        space.glass == true ? NSColor(white: 0.92 - 0.75 * CGFloat(space.glassTone ?? 0), alpha: 1) : nil
    }

    /// Mid-drag: the window and the slider show it before anything is saved.
    private func preview() {
        let start = SpaceColor.background(hue: canvas.hue, intensity: canvas.intensity)
        let end = canvas.hue2.map { SpaceColor.background(hue: $0, intensity: canvas.intensity2 ?? canvas.intensity) }
        let target = controller ?? BrowserWindowController.undoTarget
        if end == nil { target?.previewSpaceColor(background: start, swatch: SpaceColor.swatch(hue: canvas.hue), for: spaceID) }
        target?.previewSpaceGradient(hue: canvas.hue, intensity: canvas.intensity, hue2: canvas.hue2,
                                     intensity2: canvas.intensity2 ?? canvas.intensity, angle: dial.angle, for: spaceID)
        grainSlider.tint = start
        grainSlider.tint2 = end
    }

    // MARK: Layout

    private let pad = Tokens.Space.x4
    private let canvasHeight: CGFloat = 172
    private let swatchSize: CGFloat = 24
    private let rowHeight: CGFloat = 30
    private let knobSize: CGFloat = 76
    private let sliderHeight: CGFloat = 34

    var contentHeight: CGFloat {
        let middle = kind == .glass ? sliderHeight : canvasHeight + Tokens.Space.x3 + swatchSize
        return pad + Tokens.Space.x8 + 2 + Tokens.Space.x3 + rowHeight + Tokens.Space.x3 + middle
            + Tokens.Space.x4 + (kind == .gradient ? knobSize : sliderHeight) + pad
    }

    /// A gradient brings the direction knob; the panel grows or shrinks for it, keeping the edge nearest what opened it.
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

    /// True when it hangs down from what opened it (Settings); false when it sits above (a space dot).
    private var anchoredBelow = false

    private func layoutContent() {
        let width = bounds.width - pad * 2
        var y = pad
        let nameHeight = Tokens.Space.x8 + 2
        // The name, and at its right, how the space looks: system, light or dark.
        let modeWidth: CGFloat = 3 * 30 + 6
        let modeShown = !modeSwitch.isHidden
        let nameWidth = modeShown ? width - modeWidth - Tokens.Space.x2 : width
        let fh = ceil(nameField.intrinsicContentSize.height)
        nameBackground.frame = NSRect(x: pad, y: y, width: nameWidth, height: nameHeight)
        nameField.frame = NSRect(x: pad + Tokens.Space.x2, y: y + (nameHeight - fh) / 2, width: nameWidth - Tokens.Space.x4, height: fh)
        modeSwitch.frame = NSRect(x: pad + width - modeWidth, y: y, width: modeWidth, height: nameHeight)
        y += nameHeight + Tokens.Space.x3
        kindSwitch.frame = NSRect(x: pad, y: y, width: width, height: rowHeight)
        y += rowHeight + Tokens.Space.x3
        if kind == .glass {
            toneSlider.frame = NSRect(x: pad, y: y, width: width, height: sliderHeight)
            y += sliderHeight + Tokens.Space.x4
            grainSlider.frame = NSRect(x: pad, y: y, width: width, height: sliderHeight)
            return
        }
        canvas.frame = NSRect(x: pad, y: y, width: width, height: canvasHeight)
        y = canvas.frame.maxY + Tokens.Space.x3
        // The ready-made looks, spread evenly across the width.
        let count = CGFloat(swatches.count)
        let gap = (width - count * swatchSize) / max(count - 1, 1)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + CGFloat(i) * (swatchSize + gap), y: y, width: swatchSize, height: swatchSize)
        }
        y += swatchSize + Tokens.Space.x4
        // How textured, and with a gradient, the knob that turns it.
        if kind == .gradient {
            dial.frame = NSRect(x: pad + width - knobSize, y: y, width: knobSize, height: knobSize)
            grainSlider.frame = NSRect(x: pad, y: y + (knobSize - sliderHeight) / 2, width: width - knobSize - Tokens.Space.x3, height: sliderHeight)
        } else {
            grainSlider.frame = NSRect(x: pad, y: y, width: width, height: sliderHeight)
        }
    }

    func show(from anchor: NSView? = nil) {
        guard let controller else { return }
        let overlay = controller.root.overlay
        let sidebar = controller.root.sidebarContainer.frame
        let height = contentHeight
        let x: CGFloat
        var top: CGFloat
        if let anchor, anchor.window != nil, anchor is SpaceDotView {
            // From a space dot: just above the dot you clicked, its left edge near it, like a menu from that dot.
            let dot = anchor.convert(anchor.bounds, to: overlay)
            top = dot.minY - Tokens.Space.x2 - height
            x = min(max(Tokens.Space.x2, dot.midX - Tokens.Space.x8), overlay.bounds.width - Self.width - Tokens.Space.x2)
        } else {
            // From the space's name: beside the sidebar, level with that header.
            top = controller.root.cardFrame.minY + Tokens.Space.x2
            if let header = controller.sidebar.list.headerView, header.window != nil {
                top = header.convert(header.bounds, to: overlay).minY - Tokens.Space.x2
            }
            x = sidebar.maxX + Tokens.Space.x2
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

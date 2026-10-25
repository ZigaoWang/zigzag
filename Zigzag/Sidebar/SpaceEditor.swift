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
    /// Called while dragging (`final` false) and once on release (`final` true).
    var onChange: ((Double, Bool) -> Void)?
    private let track = CALayer()
    private let texture = CALayer()
    private let ramp = CAGradientLayer()
    private let knob = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.masksToBounds = true
        track.cornerCurve = .continuous
        track.borderWidth = Tokens.Metric.hairline
        texture.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
        texture.compositingFilter = "overlayBlendMode"
        // The texture fades in from the left: smooth at 0, full grain at 1.
        ramp.startPoint = CGPoint(x: 0, y: 0.5)
        ramp.endPoint = CGPoint(x: 1, y: 0.5)
        ramp.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        texture.mask = ramp
        track.addSublayer(texture)
        layer?.addSublayer(track)
        knob.shadowOpacity = 1
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: -1)
        knob.borderWidth = 2
        layer?.addSublayer(knob)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Grain")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let knobSize: CGFloat = 18
    private var inset: CGFloat { 5 + knobSize / 2 }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.backgroundColor = tint.cgColor
                track.borderColor = Tokens.Color.panelEdge.cgColor
                knob.shadowColor = Tokens.Color.panelShadow.cgColor
            }
            texture.frame = track.bounds
            texture.opacity = 0.9
            ramp.frame = texture.bounds
            let x = inset + CGFloat(grain) * (bounds.width - inset * 2)
            knob.frame = NSRect(x: x - knobSize / 2, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
            knob.cornerRadius = knobSize / 2
            knob.backgroundColor = .white
            knob.borderColor = NSColor.white.cgColor
        }
        setAccessibilityValue(grain < 0.01 ? "Smooth" : "\(Int(grain * 100)) percent")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        let v = Double(min(max((x - inset) / (bounds.width - inset * 2), 0), 1))
        // Close to the left end snaps to smooth, so "none" is easy to choose.
        return v < 0.04 ? 0 : v
    }

    override func mouseDown(with event: NSEvent) {
        grain = value(at: event)
        layoutSubtreeIfNeeded()
        onChange?(grain, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.grain = self.value(at: event)
            self.layoutSubtreeIfNeeded()
            if event.type == .leftMouseUp {
                stop.pointee = true
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

/// One round choice in the tint row: a curated tint, or the custom wheel.
final class TintSwatch: InteractiveView {
    enum Kind { case tint(SpaceColor), custom }
    let kind: Kind
    private let fill = CALayer()
    private let wheel = CAGradientLayer()
    private let ring = CALayer()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        if case .custom = kind {
            wheel.type = .conic
            wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
            wheel.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(wheel)
            toolTip = "Custom"
            setAccessibilityLabel("Custom color")
        } else if case .tint(let color) = kind {
            layer?.addSublayer(fill)
            toolTip = color.name
            setAccessibilityLabel(color.name)
        }
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            ring.frame = bounds
            ring.cornerRadius = bounds.width / 2
            ring.borderWidth = 2
            ring.borderColor = cgColor(isSelected ? Tokens.Color.textPrimary : .clear)
            // The chosen swatch sits inside its ring; the others grow slightly under the pointer.
            let inset: CGFloat = isSelected ? 4 : (isHovered ? 1 : 2)
            let inner = bounds.insetBy(dx: inset, dy: inset)
            fill.frame = inner
            fill.cornerRadius = inner.width / 2
            wheel.frame = inner
            wheel.cornerRadius = inner.width / 2
            wheel.masksToBounds = true
            wheel.colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { cgColor(SpaceColor.swatch(hue: $0)) }
            if case .tint(let color) = kind { fill.backgroundColor = cgColor(color.swatch) }
        }
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// A two-dimensional color field: across is hue, up is how strong the tint is.
/// Drawn in the space tints themselves, so what you touch is what the window becomes.
final class ColorCanvas: NSView {
    var hue: Double = 0.6 { didSet { needsLayout = true } }
    var intensity: Double = SpaceColor.defaultIntensity { didSet { needsLayout = true } }
    var onChange: ((Double, Double, Bool) -> Void)?
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
        knob.shadowOpacity = 1
        knob.shadowRadius = 4
        knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knob)
        knob.addSublayer(knobFill)
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

    private func update(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = knobSize / 2
        hue = Double(min(max((p.x - r) / (bounds.width - knobSize), 0), 0.999))
        intensity = Double(min(max(1 - (p.y - r) / (bounds.height - knobSize), 0), 1))
        layoutSubtreeIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        update(from: event)
        onChange?(hue, intensity, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.update(from: event)
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.onChange?(self.hue, self.intensity, true)
            } else {
                self.onChange?(self.hue, self.intensity, false)
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
final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    private let nameField = PlainTextField(font: Tokens.Font.large(.semibold), placeholder: "Name this space")
    /// The name sits on a soft field, so it reads as something you can type into.
    private let nameBackground = ColorView(color: Tokens.Color.fieldFill)
    private let canvas = ColorCanvas()
    private let grainLabel = Label("Grain", font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
    private let grainSlider = GrainSlider()
    private let appearanceOptions = AppearanceOption.Mode.allCases.map { AppearanceOption(mode: $0) }
    private var swatches: [TintSwatch] = []
    private var monitor: Any?
    static let width: CGFloat = 304

    /// `controller` is the browser window it belongs to; Settings passes nil and hosts it in its own window.
    init(spaceID: UUID, controller: BrowserWindowController?) {
        self.spaceID = spaceID
        self.controller = controller
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        let space = Library.shared.space(spaceID)
        nameField.stringValue = space?.name ?? ""
        nameField.delegate = self
        canvas.hue = space?.hue ?? space?.color.hue ?? 0.6
        canvas.intensity = space?.intensity ?? SpaceColor.defaultIntensity
        swatches = SpaceColor.allCases.map { TintSwatch(kind: .tint($0)) }
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerRadius = Tokens.Radius.control + 2
        nameBackground.layer?.cornerCurve = .continuous
        [nameBackground, nameField, canvas, grainLabel, grainSlider].forEach { addSubview($0) }
        grainSlider.grain = space?.grain ?? 0
        grainSlider.tint = space?.background ?? SpaceColor.sky.background
        grainSlider.onChange = { [weak self] grain, final in
            guard let self else { return }
            if final {
                Library.shared.setGrain(grain, for: self.spaceID)
                self.edited = true
            } else {
                (self.controller ?? BrowserWindowController.undoTarget)?.previewSpaceGrain(grain, for: self.spaceID)
            }
        }
        appearanceOptions.forEach { addSubview($0) }
        for option in appearanceOptions {
            option.onClick = { [weak self, weak option] _ in
                guard let self, let option else { return }
                let value: String? = option.mode == .light ? "light" : option.mode == .dark ? "dark" : nil
                Library.shared.setAppearance(value, for: self.spaceID)
                self.edited = true
                self.refreshAppearance()
            }
        }
        refreshAppearance()
        swatches.forEach { addSubview($0) }

        canvas.onChange = { [weak self] hue, intensity, final in
            guard let self else { return }
            if final {
                Library.shared.setHue(hue, intensity: intensity, for: self.spaceID)
                self.edited = true
            } else {
                let background = SpaceColor.background(hue: hue, intensity: intensity)
                (self.controller ?? BrowserWindowController.undoTarget)?.previewSpaceColor(background: background, swatch: SpaceColor.swatch(hue: hue), for: self.spaceID)
                self.showPreviews(background)
            }
            self.refreshSelection()
        }
        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let swatch, case .tint(let color) = swatch.kind else { return }
                Library.shared.setColor(color, for: self.spaceID)
                self.edited = true
                self.canvas.hue = color.hue
                self.canvas.intensity = SpaceColor.defaultIntensity
                self.showPreviews(color.background)
                self.refreshSelection()
            }
        }
        showPreviews(space?.background ?? SpaceColor.sky.background)
        refreshSelection()
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private let pad = Tokens.Space.x4
    private let canvasHeight: CGFloat = 148
    private let previewHeight = Tokens.Space.x16
    private let swatchSize = Tokens.Space.x6
    private let grainHeight: CGFloat = 26

    var contentHeight: CGFloat {
        pad + Tokens.Space.x8 + Tokens.Space.x3 + canvasHeight + Tokens.Space.x3 + previewHeight + Tokens.Space.x4 + grainHeight
            + Tokens.Space.x4 + swatchSize + pad
    }

    private func showPreviews(_ background: NSColor) {
        appearanceOptions.forEach { $0.show(background) }
        grainSlider.tint = background
    }

    private func refreshAppearance() {
        let current = Library.shared.space(spaceID)?.appearance
        for option in appearanceOptions {
            switch option.mode {
            case .auto: option.isSelected = current == nil
            case .light: option.isSelected = current == "light"
            case .dark: option.isSelected = current == "dark"
            }
        }
    }

    private func refreshSelection() {
        let space = Library.shared.space(spaceID)
        for swatch in swatches {
            if case .tint(let color) = swatch.kind { swatch.isSelected = space?.hue == nil && space?.color == color }
        }
    }

    private func layoutContent() {
        let width = bounds.width - pad * 2
        var y = pad
        let fh = ceil(nameField.intrinsicContentSize.height)
        nameBackground.frame = NSRect(x: pad, y: y, width: width, height: Tokens.Space.x8 + 2)
        nameField.frame = NSRect(x: pad + Tokens.Space.x2, y: y + (Tokens.Space.x8 + 2 - fh) / 2, width: width - Tokens.Space.x4, height: fh)
        y += Tokens.Space.x8 + Tokens.Space.x3
        canvas.frame = NSRect(x: pad, y: y, width: width, height: canvasHeight)
        y = canvas.frame.maxY + Tokens.Space.x3
        let gap = Tokens.Space.x2
        let optionWidth = (width - gap * 2) / 3
        for (i, option) in appearanceOptions.enumerated() {
            option.frame = NSRect(x: pad + CGFloat(i) * (optionWidth + gap), y: y, width: optionWidth, height: previewHeight)
        }
        y += previewHeight + Tokens.Space.x4
        let labelWidth = grainLabel.textWidth + Tokens.Space.x3
        grainLabel.frame = NSRect(x: pad, y: y + (grainHeight - grainLabel.lineHeight) / 2, width: labelWidth, height: grainLabel.lineHeight)
        grainSlider.frame = NSRect(x: pad + labelWidth, y: y, width: width - labelWidth, height: grainHeight)
        y += grainHeight + Tokens.Space.x4
        let count = CGFloat(swatches.count)
        let swatchGap = (width - count * swatchSize) / max(count - 1, 1)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + CGFloat(i) * (swatchSize + swatchGap), y: y, width: swatchSize, height: swatchSize)
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

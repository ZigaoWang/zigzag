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
            fade.colors = [base.copy(alpha: 0) ?? base, base.copy(alpha: 0.85) ?? base]
            drawDots()
            let x = CGFloat(hue) * bounds.width
            let y = (1 - CGFloat(intensity)) * bounds.height
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
        hue = Double(min(max(p.x / bounds.width, 0), 0.999))
        intensity = Double(min(max(1 - p.y / bounds.height, 0), 1))
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

/// A tiny window in light or dark, tinted like the space: a quick check that the color works both ways.
final class TintPreview: NSView {
    private let frameView = ColorView()
    private let card = ColorView()
    private let sidebarLines: [ColorView] = (0..<3).map { _ in ColorView() }

    init(dark: Bool) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = Tokens.Radius.control
        frameView.layer?.cornerCurve = .continuous
        card.wantsLayer = true
        card.layer?.cornerRadius = 3
        card.color = Tokens.Color.cardBackground
        addSubview(frameView)
        frameView.addSubview(card)
        for line in sidebarLines {
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
        frameView.frame = bounds
        let sidebarWidth = bounds.width * 0.3
        card.frame = NSRect(x: sidebarWidth, y: 4, width: bounds.width - sidebarWidth - 4, height: bounds.height - 8)
        for (i, line) in sidebarLines.enumerated() {
            line.frame = NSRect(x: 5, y: 8 + CGFloat(i) * 7, width: sidebarWidth - 10 - CGFloat(i % 2) * 4, height: 3)
        }
    }
}

/// Edits one space: its name and its color. A panel beside the sidebar, Arc-style but our own:
/// a living color field, light and dark previews, and the curated tints. The window is the preview too.
final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    private let nameField = PlainTextField(font: Tokens.Font.large(.semibold), placeholder: "Name this space")
    private let canvas = ColorCanvas()
    private let lightPreview = TintPreview(dark: false)
    private let darkPreview = TintPreview(dark: true)
    private var swatches: [TintSwatch] = []
    private var monitor: Any?
    static let width: CGFloat = 304

    init(spaceID: UUID, controller: BrowserWindowController) {
        self.spaceID = spaceID
        self.controller = controller
        super.init(frame: .zero)
        radius = Tokens.Radius.panel + Tokens.Space.x1
        let space = Library.shared.space(spaceID)
        nameField.stringValue = space?.name ?? ""
        nameField.delegate = self
        canvas.hue = space?.hue ?? space?.color.hue ?? 0.6
        canvas.intensity = space?.intensity ?? SpaceColor.defaultIntensity
        swatches = SpaceColor.allCases.map { TintSwatch(kind: .tint($0)) }
        [nameField, canvas, lightPreview, darkPreview].forEach { addSubview($0) }
        swatches.forEach { addSubview($0) }

        canvas.onChange = { [weak self] hue, intensity, final in
            guard let self else { return }
            if final {
                Library.shared.setHue(hue, intensity: intensity, for: self.spaceID)
            } else {
                let background = SpaceColor.background(hue: hue, intensity: intensity)
                self.controller?.previewSpaceColor(background: background, swatch: SpaceColor.swatch(hue: hue), for: self.spaceID)
                self.showPreviews(background)
            }
            self.refreshSelection()
        }
        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let swatch, case .tint(let color) = swatch.kind else { return }
                Library.shared.setColor(color, for: self.spaceID)
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
    private let previewHeight = Tokens.Space.x10
    private let swatchSize = Tokens.Space.x6

    var contentHeight: CGFloat {
        pad + Tokens.Space.x8 + Tokens.Space.x3 + canvasHeight + Tokens.Space.x3 + previewHeight + Tokens.Space.x4 + swatchSize + pad
    }

    private func showPreviews(_ background: NSColor) {
        lightPreview.show(background)
        darkPreview.show(background)
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
        nameField.frame = NSRect(x: pad, y: y + (Tokens.Space.x8 - fh) / 2, width: width, height: fh)
        y += Tokens.Space.x8 + Tokens.Space.x3
        canvas.frame = NSRect(x: pad, y: y, width: width, height: canvasHeight)
        y = canvas.frame.maxY + Tokens.Space.x3
        let previewWidth = (width - Tokens.Space.x2) / 2
        lightPreview.frame = NSRect(x: pad, y: y, width: previewWidth, height: previewHeight)
        darkPreview.frame = NSRect(x: lightPreview.frame.maxX + Tokens.Space.x2, y: y, width: previewWidth, height: previewHeight)
        y = lightPreview.frame.maxY + Tokens.Space.x4
        let count = CGFloat(swatches.count)
        let gap = (width - count * swatchSize) / max(count - 1, 1)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + CGFloat(i) * (swatchSize + gap), y: y, width: swatchSize, height: swatchSize)
        }
    }

    func show() {
        guard let controller else { return }
        let overlay = controller.root.overlay
        let sidebar = controller.root.sidebarContainer.frame
        let height = contentHeight
        let top = controller.root.cardFrame.minY + Tokens.Space.x2
        frame = NSRect(x: sidebar.maxX + Tokens.Space.x2, y: min(top, overlay.bounds.height - height - Tokens.Space.x4),
                       width: Self.width, height: height)
        overlay.addSubview(self)
        present()
        controller.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
        controller.root.holdReveal = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        commitName()
        controller?.root.holdReveal = false
        dismiss()
        if let webView = controller?.selectedWebView { controller?.window?.makeFirstResponder(webView) }
        if SpaceEditorPanel.current === self { SpaceEditorPanel.current = nil }
    }

    private func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != Library.shared.space(spaceID)?.name { Library.shared.renameSpace(spaceID, to: name) }
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

    static func toggle(spaceID: UUID, in controller: BrowserWindowController) {
        if let current {
            let same = current.spaceID == spaceID
            current.close()
            if same { return }
        }
        let panel = SpaceEditorPanel(spaceID: spaceID, controller: controller)
        current = panel
        panel.show()
    }
}

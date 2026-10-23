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

/// Edits one space, in place: the bottom of the sidebar opens up to show its name and tint.
/// No card, no shadow; it's part of the sidebar. The window recolors as you choose.
final class SpaceEditorInline: NSView, NSTextFieldDelegate {
    private(set) var spaceID: UUID?
    private let separator = ColorView(color: Tokens.Color.separator)
    private let nameField = PlainTextField(font: Tokens.Font.body(.semibold), placeholder: "Name this space")
    private var swatches: [TintSwatch] = []
    private let slider = HueSlider()
    private(set) var showsSlider = false
    var onPreview: ((NSColor, NSColor, UUID) -> Void)?
    var onClose: (() -> Void)?
    var onHeightChange: (() -> Void)?

    static let swatchSize = Tokens.Space.x5

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameField.delegate = self
        swatches = SpaceColor.allCases.map { TintSwatch(kind: .tint($0)) } + [TintSwatch(kind: .custom)]
        [separator, nameField, slider].forEach { addSubview($0) }
        swatches.forEach { addSubview($0) }
        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let swatch, let id = self.spaceID else { return }
                switch swatch.kind {
                case .tint(let color):
                    Library.shared.setColor(color, for: id)
                    self.slider.hue = color.hue
                    self.setSliderVisible(false)
                case .custom:
                    Library.shared.setHue(self.slider.hue, for: id)
                    self.setSliderVisible(true)
                }
                self.refreshSelection()
            }
        }
        slider.onChange = { [weak self] hue, final in
            guard let self, let id = self.spaceID else { return }
            if final { Library.shared.setHue(hue, for: id) }
            else { self.onPreview?(SpaceColor.background(hue: hue), SpaceColor.swatch(hue: hue), id) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private let pad = Tokens.Space.x2

    var fittingHeight: CGFloat {
        Tokens.Space.x3 + Tokens.Space.x8 + Tokens.Space.x2 + Self.swatchSize + (showsSlider ? Tokens.Space.x3 + Tokens.Space.x6 : 0) + Tokens.Space.x2
    }

    func edit(_ spaceID: UUID) {
        self.spaceID = spaceID
        let space = Library.shared.space(spaceID)
        nameField.stringValue = space?.name ?? ""
        showsSlider = space?.hue != nil
        slider.hue = space?.hue ?? space?.color.hue ?? 0.6
        slider.isHidden = !showsSlider
        refreshSelection()
        needsLayout = true
    }

    func focusName() {
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    private func refreshSelection() {
        guard let id = spaceID else { return }
        let space = Library.shared.space(id)
        for swatch in swatches {
            switch swatch.kind {
            case .tint(let color): swatch.isSelected = space?.hue == nil && space?.color == color
            case .custom: swatch.isSelected = space?.hue != nil
            }
        }
    }

    private func setSliderVisible(_ visible: Bool) {
        guard visible != showsSlider else { return }
        showsSlider = visible
        slider.isHidden = !visible
        onHeightChange?()
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: pad, y: 0, width: bounds.width - pad * 2, height: Tokens.Metric.hairline)
        var y = Tokens.Space.x3
        let fh = ceil(nameField.intrinsicContentSize.height)
        nameField.frame = NSRect(x: pad + Tokens.Space.x2, y: y + (Tokens.Space.x8 - fh) / 2, width: bounds.width - pad * 2 - Tokens.Space.x4, height: fh)
        y += Tokens.Space.x8 + Tokens.Space.x2
        // Tints spread evenly between the sidebar's inner edges.
        let inner = bounds.width - (pad + Tokens.Space.x2) * 2
        let size = Self.swatchSize
        let count = CGFloat(swatches.count)
        let gap = max(0, (inner - count * size) / (count - 1))
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + Tokens.Space.x2 + CGFloat(i) * (size + gap), y: y, width: size, height: size)
        }
        y += size + Tokens.Space.x3
        slider.frame = NSRect(x: pad + Tokens.Space.x2, y: y, width: inner, height: Tokens.Space.x6)
    }

    private func commitName() {
        guard let id = spaceID else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != Library.shared.space(id)?.name { Library.shared.renameSpace(id, to: name) }
    }

    func controlTextDidChange(_ obj: Notification) { commitName() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    func finish() {
        commitName()
        spaceID = nil
    }
}

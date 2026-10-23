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

/// Edits one space: its name and its tint. Rises from the space dots; the window itself is the preview.
final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    private let nameField = PlainTextField(font: Tokens.Font.large(.semibold), placeholder: "Name this space")
    private let deleteButton = IconButton(symbol: "trash", size: Tokens.Space.x6 + Tokens.Space.x1, toolTip: "Delete Space")
    private var swatches: [TintSwatch] = []
    private let slider = HueSlider()
    private var showsSlider = false
    private var monitor: Any?

    init(spaceID: UUID, controller: BrowserWindowController) {
        self.spaceID = spaceID
        self.controller = controller
        super.init(frame: .zero)
        let space = Library.shared.space(spaceID)
        nameField.stringValue = space?.name ?? ""
        nameField.delegate = self
        swatches = SpaceColor.allCases.map { TintSwatch(kind: .tint($0)) } + [TintSwatch(kind: .custom)]
        [nameField, deleteButton, slider].forEach { addSubview($0) }
        swatches.forEach { addSubview($0) }
        deleteButton.isHidden = Library.shared.spaces.count < 2
        deleteButton.tint = Tokens.Color.textSecondary
        showsSlider = space?.hue != nil
        slider.hue = space?.hue ?? space?.color.hue ?? 0.6
        slider.isHidden = !showsSlider
        refreshSelection()

        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let swatch else { return }
                switch swatch.kind {
                case .tint(let color):
                    Library.shared.setColor(color, for: self.spaceID)
                    self.slider.hue = color.hue
                    self.setSliderVisible(false)
                case .custom:
                    Library.shared.setHue(self.slider.hue, for: self.spaceID)
                    self.setSliderVisible(true)
                }
                self.refreshSelection()
            }
        }
        slider.onChange = { [weak self] hue, final in
            guard let self else { return }
            if final {
                Library.shared.setHue(hue, for: self.spaceID)
            } else {
                self.controller?.previewSpaceColor(background: SpaceColor.background(hue: hue), swatch: SpaceColor.swatch(hue: hue), for: self.spaceID)
            }
        }
        deleteButton.onClick = { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            let id = self.spaceID
            self.close()
            SpaceEditor.confirmDelete(spaceID: id, in: controller)
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshSelection() {
        let space = Library.shared.space(spaceID)
        for swatch in swatches {
            switch swatch.kind {
            case .tint(let color): swatch.isSelected = space?.hue == nil && space?.color == color
            case .custom: swatch.isSelected = space?.hue != nil
            }
        }
    }

    private let pad = Tokens.Space.x3
    private let swatchSize = Tokens.Space.x6

    private var height: CGFloat {
        pad + Tokens.Space.x8 + Tokens.Space.x3 + swatchSize + (showsSlider ? Tokens.Space.x3 + Tokens.Space.x6 : 0) + pad + Tokens.Space.x1
    }

    private func layoutContent() {
        let width = bounds.width - pad * 2
        let b = deleteButton.frame.width
        deleteButton.frame.origin = NSPoint(x: bounds.width - pad - b + Tokens.Space.x1, y: pad + (Tokens.Space.x8 - b) / 2)
        let fh = ceil(nameField.intrinsicContentSize.height)
        let nameRight = deleteButton.isHidden ? bounds.width - pad : deleteButton.frame.minX - Tokens.Space.x2
        nameField.frame = NSRect(x: pad + Tokens.Space.x1, y: pad + (Tokens.Space.x8 - fh) / 2, width: nameRight - pad - Tokens.Space.x1, height: fh)
        // Swatches spread evenly across the full width.
        let y = pad + Tokens.Space.x8 + Tokens.Space.x3
        let count = CGFloat(swatches.count)
        let gap = (width - count * swatchSize) / max(count - 1, 1)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + CGFloat(i) * (swatchSize + gap), y: y, width: swatchSize, height: swatchSize)
        }
        slider.frame = NSRect(x: pad, y: y + swatchSize + Tokens.Space.x3, width: width, height: Tokens.Space.x6)
    }

    private func setSliderVisible(_ visible: Bool) {
        guard visible != showsSlider, let controller else { return }
        showsSlider = visible
        slider.isHidden = !visible
        var frame = self.frame
        let newHeight = height
        frame.origin.y -= newHeight - frame.height
        frame.size.height = newHeight
        _ = controller
        Tokens.Motion.animate(Tokens.Motion.snappy) { self.animator().frame = frame }
        if visible {
            slider.alphaValue = 0
            Tokens.Motion.animate(Tokens.Motion.snappy) { self.slider.animator().alphaValue = 1 }
        }
    }

    /// Opens just above the space dots, spanning the sidebar.
    func show(above anchor: NSRect, sidebarFrame: NSRect) {
        guard let controller else { return }
        let overlay = controller.root.overlay
        let inset = Tokens.Space.x2
        let width = sidebarFrame.width - inset * 2
        let h = height
        frame = NSRect(x: sidebarFrame.minX + inset, y: anchor.minY - h - Tokens.Space.x1, width: width, height: h)
        overlay.addSubview(self)
        present()
        Tokens.Motion.slideVertically(self, fromOffsetY: Tokens.Space.x2)
        controller.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
        controller.root.holdReveal = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
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

    static func open(spaceID: UUID, above anchor: NSRect, sidebarFrame: NSRect, in controller: BrowserWindowController) {
        if let current {
            let same = current.spaceID == spaceID
            current.close()
            if same { return }
        }
        let panel = SpaceEditorPanel(spaceID: spaceID, controller: controller)
        current = panel
        panel.show(above: anchor, sidebarFrame: sidebarFrame)
    }
}

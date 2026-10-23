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
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knob)
        knob.addSublayer(knobFill)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Space color")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let knobSize: CGFloat = Tokens.Space.x5
    private var trackInset: CGFloat { knobSize / 2 }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let h: CGFloat = Tokens.Space.x2
            track.frame = NSRect(x: trackInset, y: (bounds.height - h) / 2, width: bounds.width - trackInset * 2, height: h)
            track.cornerRadius = h / 2
            track.colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { cgColor(SpaceColor.swatch(hue: $0)) }
            let x = trackInset + CGFloat(hue) * (bounds.width - trackInset * 2)
            knob.frame = NSRect(x: x - knobSize / 2, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
            knob.cornerRadius = knobSize / 2
            knob.backgroundColor = .white
            knob.shadowColor = cgColor(Tokens.Color.panelShadow)
            knobFill.frame = knob.bounds.insetBy(dx: 4, dy: 4)
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

/// Edits one space: its name and its color. Opens next to the sidebar; the window itself is the preview.
final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    private let nameField = PlainTextField(font: Tokens.Font.large(.semibold), placeholder: "Space name")
    private let nameBackground = ColorView(color: Tokens.Color.fieldFill)
    private let swatches: SwatchPicker
    private let slider = HueSlider()
    private let colorLabel = Label("Color", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    private let deleteButton = TextButton(title: "Delete Space", font: Tokens.Font.body(.medium))
    private var monitor: Any?
    static let width: CGFloat = 288

    init(spaceID: UUID, controller: BrowserWindowController) {
        self.spaceID = spaceID
        self.controller = controller
        let space = Library.shared.space(spaceID)
        swatches = SwatchPicker(selected: space?.color ?? .sky)
        super.init(frame: .zero)
        nameField.stringValue = space?.name ?? ""
        nameField.delegate = self
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerRadius = Tokens.Radius.row
        nameBackground.layer?.cornerCurve = .continuous
        slider.hue = space?.hue ?? space?.color.hue ?? 0.6
        if space?.hue != nil { swatches.selected = .graphite; swatches.clearSelection() }
        [nameBackground, nameField, colorLabel, swatches, slider, deleteButton].forEach { addSubview($0) }
        deleteButton.isHidden = Library.shared.spaces.count < 2
        deleteButton.textColor = Tokens.Color.destructive

        swatches.onPick = { [weak self] color in
            guard let self else { return }
            Library.shared.setColor(color, for: self.spaceID)
            self.slider.hue = color.hue
        }
        slider.onChange = { [weak self] hue, final in
            guard let self else { return }
            self.swatches.clearSelection()
            if final {
                Library.shared.setHue(hue, for: self.spaceID)
            } else {
                self.controller?.previewSpaceColor(background: SpaceColor.background(hue: hue), swatch: SpaceColor.swatch(hue: hue), for: self.spaceID)
            }
        }
        deleteButton.onClick = { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            self.close()
            SpaceEditor.confirmDelete(spaceID: self.spaceID, in: controller)
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private let pad = Tokens.Space.x4

    var contentHeight: CGFloat {
        pad + Tokens.Space.x10 + Tokens.Space.x4 + colorLabel.lineHeight + Tokens.Space.x2 + Tokens.Space.x6
            + Tokens.Space.x3 + Tokens.Space.x6 + (deleteButton.isHidden ? 0 : Tokens.Space.x3 + Tokens.Space.x8) + pad
    }

    private func layoutContent() {
        let width = bounds.width - pad * 2
        var y = pad
        nameBackground.frame = NSRect(x: pad, y: y, width: width, height: Tokens.Space.x10)
        let fh = ceil(nameField.intrinsicContentSize.height)
        nameField.frame = NSRect(x: pad + Tokens.Space.x3, y: y + (Tokens.Space.x10 - fh) / 2, width: width - Tokens.Space.x6, height: fh)
        y = nameBackground.frame.maxY + Tokens.Space.x4
        colorLabel.frame = NSRect(x: pad, y: y, width: width, height: colorLabel.lineHeight)
        y = colorLabel.frame.maxY + Tokens.Space.x2
        let sw = swatches.fittingWidth
        swatches.frame = NSRect(x: pad + (width - sw) / 2, y: y, width: sw, height: Tokens.Space.x6)
        y = swatches.frame.maxY + Tokens.Space.x3
        slider.frame = NSRect(x: pad, y: y, width: width, height: Tokens.Space.x6)
        y = slider.frame.maxY + Tokens.Space.x3
        let dw = deleteButton.fittingWidth
        deleteButton.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: dw, height: Tokens.Space.x8)
    }

    func show(near anchor: NSRect) {
        guard let controller else { return }
        let overlay = controller.root.overlay
        let x = controller.root.sidebarContainer.frame.maxX + Tokens.Space.x2
        let height = contentHeight
        let y = max(Tokens.Metric.cardInset * 2, min(anchor.minY - Tokens.Space.x2, overlay.bounds.height - height - Tokens.Metric.cardInset * 2))
        frame = NSRect(x: x, y: y, width: Self.width, height: height)
        overlay.addSubview(self)
        present()
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
        SpaceEditorPanel.current = nil
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

    static func open(spaceID: UUID, anchor: NSRect, in controller: BrowserWindowController) {
        if let current {
            let same = current.spaceID == spaceID
            current.close()
            if same { return }
        }
        let panel = SpaceEditorPanel(spaceID: spaceID, controller: controller)
        current = panel
        panel.show(near: anchor)
    }
}

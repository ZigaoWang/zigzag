import AppKit

extension NSView {
    /// Resolves a dynamic color for this view's appearance.
    func cgColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}

extension CALayer {
    /// Sets a property with a short fade, or instantly.
    func set(backgroundColor color: CGColor?, animated: Bool, duration: TimeInterval = Tokens.Motion.quick) {
        if animated {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = presentation()?.backgroundColor ?? backgroundColor
            animation.toValue = color
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            add(animation, forKey: "backgroundColor")
        }
        Tokens.Motion.withoutAnimation { backgroundColor = color }
    }
}

/// Base for everything clickable we draw ourselves: tracks hover, press, selection and enabled state.
class InteractiveView: NSView {
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            stateDidChange(animated: true)
            hoverChanged?(isHovered)
        }
    }
    var hoverChanged: ((Bool) -> Void)?
    var isPressed = false { didSet { if oldValue != isPressed { stateDidChange(animated: false) } } }
    var isSelected = false { didSet { if oldValue != isSelected { stateDidChange(animated: false) } } }
    var isEnabled = true { didSet { if oldValue != isEnabled { stateDidChange(animated: false) } } }

    var onClick: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> NSMenu?)?
    /// Called once the mouse moves far enough while pressed. Return true to take over the drag.
    var onDragStart: ((NSEvent) -> Bool)?
    /// Fires the click on mouse down instead of mouse up (tabs feel faster this way).
    var clicksOnMouseDown = false

    private var trackingArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Decorative children (icons, labels, layers) never take clicks; they belong to this control.
    /// Only nested controls of our own, or editable text, keep their clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is InteractiveView { return hit }
            if let field = current as? NSTextField, field.isEditable { return hit }
            if current is NSButton || current is NSPopUpButton || current is NSSlider { return hit }
            view = current.superview
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        // Keep hover honest after scrolling or relayout.
        if let window, window.isVisible {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let inside = bounds.contains(point) && !isHiddenOrHasHiddenAncestor
            if inside != isHovered { isHovered = inside }
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; if !dragging { isPressed = false } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        isPressed = true
        mouseDownEvent = event
        dragging = false
        if clicksOnMouseDown { onClick?(event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let start = mouseDownEvent, !dragging else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        if distance > 4, let onDragStart {
            if onDragStart(start) {
                dragging = true
                isPressed = false
                mouseDownEvent = nil
            }
        }
        if !dragging {
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if inside != isPressed { isPressed = inside }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil; dragging = false }
        guard isEnabled, mouseDownEvent != nil else { isPressed = false; return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside && !clicksOnMouseDown { onClick?(event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { onMiddleClick?() }
    }
    var onMiddleClick: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onRightClick?(event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    /// Subclasses redraw their state here.
    func stateDidChange(animated: Bool) {}
}

/// A square icon button: back, forward, reload, close, and friends.
final class IconButton: InteractiveView {
    private let imageView = NSImageView()
    var symbol: String { didSet { imageView.image = Tokens.Symbol.image(symbol, size: symbolSize) } }
    /// A full-color image instead of a symbol (extension icons).
    var image: NSImage? {
        didSet {
            imageView.image = image ?? Tokens.Symbol.image(symbol, size: symbolSize)
            imageView.imageScaling = image == nil ? .scaleNone : .scaleProportionallyDown
        }
    }
    var tint: NSColor = Tokens.Color.icon { didSet { stateDidChange(animated: false) } }
    var radius: CGFloat = Tokens.Radius.control { didSet { layer?.cornerRadius = radius } }
    var showsFillAtRest = false { didSet { stateDidChange(animated: false) } }
    private let symbolSize: CGFloat

    init(symbol: String, size: CGFloat = Tokens.Metric.iconButton, symbolSize: CGFloat = Tokens.Symbol.pointSize, toolTip: String? = nil) {
        self.symbol = symbol
        self.symbolSize = symbolSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        imageView.image = Tokens.Symbol.image(symbol, size: symbolSize)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        self.toolTip = toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        if image != nil {
            let side = Tokens.Metric.favicon
            imageView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        } else {
            imageView.frame = bounds
        }
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = !isEnabled ? nil : isPressed ? Tokens.Color.pressedFill : (isHovered || isSelected) ? Tokens.Color.hoverFill : showsFillAtRest ? Tokens.Color.fieldFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        imageView.contentTintColor = image == nil ? tint : nil
        imageView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}

/// A plain text label that never wraps and never accepts clicks.
final class Label: NSTextField {
    init(_ text: String = "", font: NSFont = Tokens.Font.body(), color: NSColor = Tokens.Color.textPrimary) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Exact width of the text, plus the cell's own padding.
    var textWidth: CGFloat {
        let width = (stringValue as NSString).size(withAttributes: [.font: font ?? Tokens.Font.body()]).width
        return ceil(width) + Tokens.Space.x2
    }

    /// The text's own width, without the padding `textWidth` adds: for laying out text inside a pill.
    var inkWidth: CGFloat { ceil((stringValue as NSString).size(withAttributes: [.font: font ?? Tokens.Font.body()]).width) }

    /// The label's built-in inset on each side, so text can sit exactly where it's placed.
    static let inset: CGFloat = 2

    /// Height of one line in this label's font.
    var lineHeight: CGFloat { ceil(intrinsicContentSize.height) }
}

/// A view that paints a single flat color from a dynamic NSColor, following appearance changes.
class ColorView: NSView {
    var color: NSColor? { didSet { refresh(animated: false) } }

    init(color: NSColor? = nil) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setColor(_ color: NSColor?, animated: Bool, duration: TimeInterval = Tokens.Motion.standard) {
        self.color = color
        if animated { refresh(animated: true, duration: duration) }
    }

    private func refresh(animated: Bool, duration: TimeInterval = Tokens.Motion.quick) {
        layer?.set(backgroundColor: color.map { cgColor($0) }, animated: animated, duration: duration)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }
}

/// Our scroll bar: a slim rounded thumb, no track, visible only while scrolling.
final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        Tokens.Space.x2 + Tokens.Space.x1
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        let width: CGFloat = isHovered ? 6 : 4
        let rect = NSRect(x: knob.maxX - width - 2, y: knob.minY + 2, width: width, height: max(knob.height - 4, width))
        Tokens.Color.textTertiary.setFill()
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
    }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); isHovered = false; needsDisplay = true }
}

extension NSScrollView {
    /// Swaps in our slim scroller.
    func useSlimScroller() {
        scrollerStyle = .overlay
        verticalScroller = SlimScroller()
        hasVerticalScroller = true
        autohidesScrollers = true
    }
}

/// The one filled button style: the main action on a screen, in the space's accent. Use one per screen.
final class PrimaryButton: InteractiveView {
    private let label: Label
    private var themeToken: SignalToken?
    /// The space's accent unless set.
    var fixedTheme: Brand.Theme? { didSet { stateDidChange(animated: false) } }
    /// For actions that can't be undone (Clear History, Delete): red, whatever the space.
    var isDestructive = false { didSet { stateDidChange(animated: false) } }
    /// Moves the title off center, to leave room for something beside it (a keycap).
    var labelOffset: CGFloat = 0 { didSet { needsLayout = true } }

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.semibold), color: Brand.Theme.current.onAccent)
        super.init(frame: .zero)
        themeToken = Brand.themeChanged.observe { [weak self] in self?.stateDidChange(animated: false) }
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }

    var fittingWidth: CGFloat { label.textWidth + Tokens.Space.x8 }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(max(fittingWidth, 72)), height: Tokens.Space.x8) }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: Tokens.Space.x4 + labelOffset, y: (bounds.height - h) / 2, width: bounds.width - Tokens.Space.x8, height: h)
        label.alignment = .center
    }

    override func stateDidChange(animated: Bool) {
        // The space's accent: the one primary action on a screen.
        let theme = fixedTheme ?? Brand.Theme.for(self)
        let base = isDestructive ? Tokens.Color.destructive : theme.accent
        label.textColor = isDestructive ? .white : theme.onAccent
        let color = !isEnabled ? base.withAlphaComponent(Tokens.Opacity.disabled) : isPressed ? (base.shadow(withLevel: 0.15) ?? base) : isHovered ? (base.highlight(withLevel: 0.08) ?? base) : base
        layer?.set(backgroundColor: cgColor(color), animated: false)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}

/// A text field on a soft fill, ringed in the accent while typing: the one look for fields in panels and windows.
final class FilledField: NSView {
    let field: NSTextField
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    /// The focus ring's color: the system accent, or the space's color in brand moments.
    var tint: NSColor = Tokens.Color.accent { didSet { updateColors() } }

    init(placeholder: String, secure: Bool = false, font: NSFont = Tokens.Font.body()) {
        if secure {
            let secureField = NSSecureTextField()
            secureField.font = font
            secureField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: Tokens.Color.textTertiary])
            field = secureField
        } else {
            field = PlainTextField(font: font, placeholder: placeholder)
        }
        super.init(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Tokens.Color.textPrimary
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        addSubview(field)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: NSControl.textDidBeginEditingNotification, object: field)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: NSControl.textDidEndEditingNotification, object: field)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isEditing: Bool { field.currentEditor() != nil }

    @objc private func editingChanged() { updateColors() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.fieldFill.cgColor
            layer?.borderColor = (isEditing ? tint.withAlphaComponent(0.6) : .clear).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    override func layout() {
        super.layout()
        let h = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: Tokens.Space.x2 + 2, y: round((bounds.height - h) / 2), width: bounds.width - Tokens.Space.x5, height: h)
    }
}

/// A choice that's on or off, drawn as a pill with a check: used where several things can be picked at once.
final class ChoicePill: InteractiveView {
    private let label: Label
    private let check = NSImageView()
    var onChange: ((Bool) -> Void)?
    var isOn = true { didSet { stateDidChange(animated: true) } }
    /// The system accent, or the space's color in brand moments.
    var tint: NSColor = Tokens.Color.accent { didSet { stateDidChange(animated: false) } }

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        [check, label].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `textWidth` already carries the cell's padding, so only the check and the edges are added.
    var fittingWidth: CGFloat { ceil(Tokens.Space.x2 + Tokens.Space.x3 + Tokens.Space.x1 + label.inkWidth + Tokens.Space.x3) }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x3
        check.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - side) / 2, width: side, height: side)
        let h = label.lineHeight
        label.frame = NSRect(x: check.frame.maxX + Tokens.Space.x1 - Label.inset, y: (bounds.height - h) / 2, width: label.inkWidth + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let fill = isOn ? tint.withAlphaComponent(isPressed ? 0.26 : isHovered ? 0.2 : 0.14)
            : (isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : Tokens.Color.fieldFill)
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        label.textColor = isOn ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        check.image = Tokens.Symbol.image(isOn ? "checkmark" : "plus", size: Tokens.TypeSize.small)
        check.contentTintColor = isOn ? tint : Tokens.Color.textTertiary
    }
}

/// A row of filters where one is chosen (All · Weak · Reused…), each with an optional count. The chosen one takes
/// a soft fill of the space's accent; the rest are plain until hovered.
final class SegmentedPills: NSView {
    private final class Segment: InteractiveView {
        let title: Label
        let count = Label("", font: Tokens.Font.small(.semibold), color: Tokens.Color.textTertiary)
        var tint: NSColor = Tokens.Color.accent { didSet { stateDidChange(animated: false) } }

        init(_ text: String) {
            title = Label(text, font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
            super.init(frame: .zero)
            layer?.cornerRadius = Tokens.Radius.control + 2
            layer?.cornerCurve = .continuous
            [title, count].forEach { addSubview($0) }
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(text)
        }

        required init?(coder: NSCoder) { fatalError() }

        private var hasCount: Bool { !count.stringValue.isEmpty }

        var fittingWidth: CGFloat { Tokens.Space.x3 * 2 + title.inkWidth + (hasCount ? Tokens.Space.x1 + 2 + count.inkWidth : 0) }

        override func layout() {
            super.layout()
            let x = Tokens.Space.x3
            title.frame = NSRect(x: x - Label.inset, y: (bounds.height - title.lineHeight) / 2, width: title.inkWidth + Label.inset * 2, height: title.lineHeight)
            count.frame = NSRect(x: x + title.inkWidth + Tokens.Space.x1 + 2 - Label.inset, y: (bounds.height - count.lineHeight) / 2,
                                 width: count.inkWidth + Label.inset * 2, height: count.lineHeight)
        }

        override func stateDidChange(animated: Bool) {
            let fill: NSColor? = isSelected ? tint.withAlphaComponent(isPressed ? 0.24 : 0.16) : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
            layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
            title.font = Tokens.Font.body(isSelected ? .semibold : .medium)
            title.textColor = isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
            count.textColor = isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
        }
    }

    private var segments: [Segment] = []
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 { didSet { segments.enumerated().forEach { $0.element.isSelected = $0.offset == selectedIndex } } }
    var tint: NSColor = Tokens.Color.accent { didSet { segments.forEach { $0.tint = tint } } }

    init(_ titles: [String]) {
        super.init(frame: .zero)
        segments = titles.enumerated().map { index, text in
            let segment = Segment(text)
            segment.onClick = { [weak self] _ in
                guard let self, self.selectedIndex != index else { return }
                self.selectedIndex = index
                self.onChange?(index)
            }
            addSubview(segment)
            return segment
        }
        setAccessibilityRole(.radioGroup)
        selectedIndex = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCount(_ value: Int?, at index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].count.stringValue = value.map { $0 > 0 ? "\($0)" : "" } ?? ""
        needsLayout = true
    }

    var fittingWidth: CGFloat { segments.map(\.fittingWidth).reduce(0, +) + CGFloat(max(0, segments.count - 1)) * 2 }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for segment in segments {
            let w = ceil(segment.fittingWidth)
            segment.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + 2
        }
    }
}

/// Zigzag's switch: a capsule in the space's accent when on, a knob that slides on a soft spring.
final class Toggle: InteractiveView {
    private let knob = CALayer()
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { if oldValue != isOn { update(animated: window != nil) } } }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 20))
        layer?.cornerRadius = 10
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = 8
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.22
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knob)
        onClick = { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
        setAccessibilityRole(.checkBox)
        update(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    private var knobFrame: CGRect {
        let side: CGFloat = 16
        return CGRect(x: isOn ? bounds.width - side - 2 : 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation { knob.frame = knobFrame }
    }

    private func update(animated: Bool) {
        stateDidChange(animated: animated)
        guard animated else { Tokens.Motion.withoutAnimation { knob.frame = knobFrame }; return }
        let move = CASpringAnimation(keyPath: "position.x")
        move.damping = 20
        move.stiffness = 300
        move.fromValue = knob.presentation()?.position.x ?? knob.position.x
        move.toValue = knobFrame.midX
        move.duration = move.settlingDuration
        knob.add(move, forKey: "move")
        Tokens.Motion.withoutAnimation { knob.frame = knobFrame }
    }

    override func stateDidChange(animated: Bool) {
        let off = Tokens.Color.dynamic(light: Tokens.Color.hex(0x000000, alpha: 0.13), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.18))
        let track = isOn ? Brand.Theme.for(self).accent : off
        layer?.set(backgroundColor: cgColor(isPressed ? (track.blended(withFraction: 0.08, of: .black) ?? track) : track), animated: animated)
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

/// A choice from a list, in Zigzag's style: the current choice (with its icon) on a quiet fill and a chevron;
/// clicking opens the native menu right over it.
final class MenuButton: InteractiveView {
    struct Option { var title: String; var image: NSImage? }
    private let label = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let icon = NSImageView()
    private let chevron = NSImageView()
    var options: [Option] = [] { didSet { refresh() } }
    var selectedIndex = 0 { didSet { refresh() } }
    var onSelect: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        chevron.image = Tokens.Symbol.image("chevron.up.chevron.down", size: Tokens.TypeSize.small)
        chevron.contentTintColor = Tokens.Color.textSecondary
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, label, chevron].forEach { addSubview($0) }
        onClick = { [weak self] _ in self?.openMenu() }
        setAccessibilityRole(.popUpButton)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var current: Option? { options.indices.contains(selectedIndex) ? options[selectedIndex] : nil }

    private func refresh() {
        label.stringValue = current?.title ?? ""
        icon.image = current?.image
        icon.isHidden = current?.image == nil
        setAccessibilityValue(label.stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let widest = options.map { ($0.title as NSString).size(withAttributes: [.font: Tokens.Font.body(.medium)]).width }.max() ?? 0
        let iconWidth: CGFloat = options.contains { $0.image != nil } ? 16 + Tokens.Space.x2 : 0
        return NSSize(width: ceil(Tokens.Space.x3 + iconWidth + widest + Tokens.Space.x2 + 12 + Tokens.Space.x3), height: Tokens.Space.x7Height)
    }

    override func layout() {
        super.layout()
        var x = Tokens.Space.x3
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x = icon.frame.maxX + Tokens.Space.x2
        }
        chevron.frame = NSRect(x: bounds.width - Tokens.Space.x3 - 10, y: (bounds.height - 12) / 2, width: 10, height: 12)
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: chevron.frame.minX - x - Tokens.Space.x1, height: label.lineHeight)
    }

    private func openMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, option) in options.enumerated() {
            let item = SidebarMenus.Item(option.title) { [weak self] in
                self?.selectedIndex = index
                self?.onSelect?(index)
            }
            item.image = option.image
            item.state = index == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        menu.minimumWidth = bounds.width
        menu.popUp(positioning: menu.items.indices.contains(selectedIndex) ? menu.items[selectedIndex] : nil,
                   at: NSPoint(x: Tokens.Space.x1, y: bounds.height - 3), in: self)
    }

    override func stateDidChange(animated: Bool) {
        let fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
    }
}

/// A state, said calmly: a check in the space's accent and a few words ("Zigzag is your default browser").
final class StatusLabel: NSView {
    private let check = NSImageView()
    private let label: Label

    init(_ text: String, symbol: String = "checkmark.circle.fill") {
        label = Label(text, font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        check.image = Tokens.Symbol.image(symbol, size: Tokens.TypeSize.body)
        check.contentTintColor = Brand.Theme.for(self).accent
        [check, label].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 16 + Tokens.Space.x2 + label.inkWidth + Label.inset, height: Tokens.Space.x7Height) }

    override func layout() {
        super.layout()
        check.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 16 + Tokens.Space.x2 - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }
}

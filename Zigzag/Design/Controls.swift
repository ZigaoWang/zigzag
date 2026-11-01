import AppKit

extension NSView {
    /// Resolves a dynamic color for this view's appearance.
    func cgColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    /// The selected card's edge and shadow: a hairline and a faint shadow just under it, or neither. Its fill is
    /// the caller's (`Tokens.Color.selectedFill`, or a tint of it).
    func setLifted(_ lifted: Bool) {
        guard let layer else { return }
        Tokens.Motion.withoutAnimation {
            layer.borderWidth = lifted ? Tokens.Metric.hairline : 0
            layer.borderColor = cgColor(Tokens.Color.selectedEdge)
            layer.shadowOpacity = lifted ? 1 : 0
            layer.shadowColor = cgColor(Tokens.Color.liftShadow)
            layer.shadowRadius = Tokens.Shadow.liftRadius
            // A layer's y runs up unless its view is flipped: either way the shadow falls below.
            layer.shadowOffset = CGSize(width: 0, height: isFlipped ? Tokens.Shadow.liftDrop : -Tokens.Shadow.liftDrop)
        }
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
            // A color changing in place: the plain ease, not the arrival curve.
            animation.timingFunction = CAMediaTimingFunction(name: .default)
            add(animation, forKey: "backgroundColor")
        }
        Tokens.Motion.withoutAnimation { backgroundColor = color }
    }
}

/// Base for everything clickable we draw ourselves: tracks hover, press, selection and enabled state.
class InteractiveView: NSView {
    /// Hover shows and goes at once, both ways: a fade on something you sweep past a hundred times a day only reads
    /// as lag (https://emilkowal.ski/ui/you-dont-need-animations#frequency-of-use).
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            stateDidChange(animated: false)
            hoverChanged?(isHovered)
        }
    }
    var hoverChanged: ((Bool) -> Void)?
    var isPressed = false {
        didSet {
            guard oldValue != isPressed else { return }
            stateDidChange(animated: false)
            if pressScales { showPress(isPressed) }
        }
    }
    /// Buttons and rows give under the finger: `Tokens.Motion.pressScale` while held, springing back on release.
    var pressScales = false
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            setAccessibilitySelected(isSelected)
            stateDidChange(animated: false)
        }
    }
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            setAccessibilityEnabled(isEnabled)
            stateDidChange(animated: false)
        }
    }

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
        // A control's faint shadow and keyboard focus ring fall just outside it.
        clipsToBounds = false
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
            // With the button held, something is being dragged: rows sliding under it aren't hovered.
            let inside = bounds.contains(point) && !isHiddenOrHasHiddenAncestor && NSEvent.pressedMouseButtons == 0
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
            // Picked up, it's no longer being pressed: it doesn't keep the pressed look through the whole drag.
            isPressed = false
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

    /// VoiceOver's press (VO-Space) does what a click does, for any control drawn on this.
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        let event = NSApp.currentEvent ?? NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        guard let event else { return false }
        onClick(event)
        return true
    }

    // MARK: Keyboard

    /// True while this control has keyboard focus.
    private(set) var hasKeyboardFocus = false
    /// Told when keyboard focus arrives or leaves, for controls that otherwise show only on hover.
    var keyboardFocusChanged: ((Bool) -> Void)?

    /// With Full Keyboard Access on, Tab reaches these controls as it does AppKit's own: a focus ring shows where
    /// you are, and Space or Return presses. A click never moves focus here, so the mouse works as it always has.
    override var acceptsFirstResponder: Bool {
        guard Self.keyboardAccess, isEnabled, onClick != nil else { return false }
        if let type = NSApp.currentEvent?.type, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { return false }
        return true
    }

    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        setKeyboardFocus(true)
        scrollToVisible(bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        setKeyboardFocus(false)
        return true
    }

    private static var keyboardAccess: Bool {
        #if DEBUG
        if debugKeyboardAccess { return true }
        #endif
        return NSApp.isFullKeyboardAccessEnabled
    }
    #if DEBUG
    /// Debug builds: Tab reaches drawn controls without turning on Full Keyboard Access, for testing.
    static var debugKeyboardAccess = false
    #endif

    private func setKeyboardFocus(_ focused: Bool) {
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
        keyboardFocusChanged?(focused)
        updateFocusRing()
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        // Space, Return or Enter press the focused control.
        if hasKeyboardFocus, plain, [49, 36, 76].contains(event.keyCode), accessibilityPerformPress() { return }
        super.keyDown(with: event)
    }

    /// Keyboard focus, drawn as the design has it rather than the system's blue: a ring in the window's accent just
    /// outside the control, following its rounded shape. Only the keyboard brings it; a click never does.
    private var focusRing: CAShapeLayer?

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    private func updateFocusRing() {
        guard hasKeyboardFocus, let layer else {
            focusRing?.removeFromSuperlayer()
            focusRing = nil
            return
        }
        layer.masksToBounds = false
        let ring = focusRing ?? CAShapeLayer()
        let width = Tokens.Metric.focusRing, out = Tokens.Metric.focusGap + width / 2
        let rect = bounds.insetBy(dx: -out, dy: -out)
        let radius = min(layer.cornerRadius + out, rect.height / 2, rect.width / 2)
        Tokens.Motion.withoutAnimation {
            ring.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ring.fillColor = nil
            ring.lineWidth = width
            ring.strokeColor = cgColor(Brand.Theme.for(self).accent.withAlphaComponent(Tokens.Color.focusAlpha))
            ring.zPosition = 10
            if ring.superlayer == nil { layer.addSublayer(ring) }
        }
        focusRing = ring
    }

    override func layout() {
        super.layout()
        // AppKit can turn clipping back on for a backing layer; the shadow and the ring need it off.
        if layer?.masksToBounds == true { layer?.masksToBounds = false }
        if hasKeyboardFocus { updateFocusRing() }
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
        updateFocusRing()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    /// Subclasses redraw their state here.
    func stateDidChange(animated: Bool) {}
}

/// A square icon button: back, forward, reload, close, and friends. `Metric.iconButton` with a `Symbol.glyph` by
/// default; inside a row or a field, `.compact` (`Metric.compactIconButton`, `Symbol.compactGlyph`).
final class IconButton: InteractiveView {
    private let imageView = NSImageView()
    var symbol: String { didSet { imageView.image = Tokens.Symbol.image(symbol, size: symbolSize); needsLayout = true } }
    /// A full-color image instead of a symbol (extension icons).
    var image: NSImage? {
        didSet {
            imageView.image = image ?? Tokens.Symbol.image(symbol, size: symbolSize)
            imageView.imageScaling = image == nil ? .scaleNone : .scaleProportionallyDown
        }
    }
    /// A glyph drawn in code in place of the symbol: a template image, centered and tinted exactly like one.
    var glyph: NSImage? {
        didSet {
            imageView.image = glyph ?? Tokens.Symbol.image(symbol, size: symbolSize)
            imageView.imageScaling = .scaleNone
            needsLayout = true
        }
    }
    var tint: NSColor = Tokens.Color.icon { didSet { stateDidChange(animated: false) } }
    var radius: CGFloat = Tokens.Radius.control { didSet { layer?.cornerRadius = radius } }
    var showsFillAtRest = false { didSet { stateDidChange(animated: false) } }
    private let symbolSize: CGFloat

    /// The two sizes an icon button comes in.
    enum Size {
        /// The toolbar, the bottom bar, a pane's header, the find bar, a panel's close: big and easy to press.
        case regular
        /// Inside a row or a field: a tab's close and mute, the address's Reader and extensions.
        case compact
        var side: CGFloat { self == .regular ? Tokens.Metric.iconButton : Tokens.Metric.compactIconButton }
        var glyph: CGFloat { self == .regular ? Tokens.Symbol.glyph : Tokens.Symbol.compactGlyph }
    }

    convenience init(symbol: String, size: Size = .regular, toolTip: String? = nil) {
        self.init(symbol: symbol, size: size.side, symbolSize: size.glyph, toolTip: toolTip)
    }

    init(symbol: String, size: CGFloat, symbolSize: CGFloat, toolTip: String? = nil) {
        self.symbol = symbol
        self.symbolSize = symbolSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        pressScales = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        imageView.image = Tokens.Symbol.image(symbol, size: symbolSize)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        self.toolTip = toolTip
        setAccessibilityRole(.button)
    }

    /// The tooltip is the button's name, so VoiceOver reads whatever it says now (Reload or Stop, Mute or Unmute).
    /// The shortcut the tooltip ends with stays out of it: "Back", not "Back (⌘[)".
    override var toolTip: String? {
        didSet { setAccessibilityLabel(toolTip.map(Self.withoutShortcut)) }
    }

    /// "Back (⌘[)" → "Back".
    static func withoutShortcut(_ tip: String) -> String {
        tip.replacingOccurrences(of: #"\s*\([⌃⌥⇧⌘][^()]*\)\s*$"#, with: "", options: .regularExpression)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        if image != nil {
            let side = Tokens.Metric.favicon
            imageView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        } else if glyph == nil {
            // The symbol's ink, not its image, in the middle.
            let ink = Tokens.Symbol.inkOffset(symbol, size: symbolSize)
            imageView.frame = bounds.offsetBy(dx: -ink.width, dy: isFlipped ? ink.height : -ink.height)
        } else {
            imageView.frame = bounds
        }
    }

    /// Chosen, it's the soft card (`applyRowStyle`) rather than the hover fill: a choice among many, like an icon
    /// in a grid.
    var selectsAsCard = false { didSet { stateDidChange(animated: false) } }

    override func stateDidChange(animated: Bool) {
        if selectsAsCard {
            applyRowStyle(animated: animated)
            imageView.contentTintColor = image == nil ? (isSelected ? Tokens.Color.textPrimary : tint) : nil
            imageView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
            return
        }
        let fill: NSColor? = !isEnabled ? nil : isPressed ? Tokens.Color.pressedFill : (isHovered || isSelected) ? Tokens.Color.hoverFill : showsFillAtRest ? Tokens.Color.fieldFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        imageView.contentTintColor = image == nil ? tint : nil
        imageView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
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
    /// The edge's color, redrawn for light and dark like the fill (its width is the layer's own).
    var edgeColor: NSColor? { didSet { refresh(animated: false) } }

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
        if let edgeColor { Tokens.Motion.withoutAnimation { layer?.borderColor = cgColor(edgeColor) } }
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

/// The primary action on a screen: the dark filled pill (`ButtonLook.primary`), one per screen. Kept for the forms
/// that still build on it; new code uses `PillButton(style: .prominent)`, which looks the same.
final class PrimaryButton: InteractiveView {
    private let label: Label
    /// Kept for callers from when the primary took its window's accent; the primary is dark whatever the theme.
    var fixedTheme: Brand.Theme? { didSet { stateDidChange(animated: false) } }
    /// For actions that can't be undone (Clear History, Delete): red, whatever the space.
    var isDestructive = false { didSet { stateDidChange(animated: false) } }
    /// Set both to draw the button in other colors, like a light button on the brand's blue.
    var customFill: NSColor? { didSet { stateDidChange(animated: false) } }
    var customInk: NSColor? { didSet { stateDidChange(animated: false) } }
    /// Moves the title off center, to leave room for something beside it (a keycap).
    var labelOffset: CGFloat = 0 { didSet { needsLayout = true } }

    init(title: String) {
        label = Label(title, font: Tokens.Font.control(), color: Tokens.Color.onPrimary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }

    var fittingWidth: CGFloat { label.textWidth + Tokens.Space.x8 }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(max(fittingWidth, 72)), height: Tokens.Page.controlHeight) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let h = label.lineHeight
        label.frame = NSRect(x: Tokens.Space.x4 + labelOffset, y: (bounds.height - h) / 2, width: bounds.width - Tokens.Space.x8, height: h)
        label.alignment = .center
    }

    override func stateDidChange(animated: Bool) {
        let tint = customFill ?? (isDestructive ? Tokens.Color.destructive : nil)
        label.textColor = applyButtonLook(.primary, tint: tint, ink: customInk ?? (isDestructive ? .white : nil))
    }
}

/// A text button: quiet text that fills under the pointer ("Clear", "Skip"), or with `form` the secondary look
/// (`ButtonLook.secondary`). Kept for the forms that still build on it; new code uses `PillButton`.
final class TextButton: InteractiveView {
    private let label: Label
    /// The secondary look (white, a hairline, a faint shadow) rather than text alone.
    var showsFillAtRest = false { didSet { needsLayout = true; stateDidChange(animated: false) } }
    /// Overrides the label color (destructive actions).
    var textColor: NSColor? { didSet { stateDidChange(animated: false) } }
    /// Moves the title off center, to leave room for something beside it (a keycap).
    var labelOffset: CGFloat = 0 { didSet { needsLayout = true } }

    init(title: String, font: NSFont = Tokens.Font.small(.medium)) {
        label = Label(title, font: font, color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize(); needsLayout = true; superview?.needsLayout = true
        }
    }

    /// Says what just happened in place of the title for a moment ("Cleared"), then goes back.
    func flash(_ text: String, for seconds: TimeInterval = 1.6) {
        let original = title
        title = text
        isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.title = original
            self?.isEnabled = true
        }
    }

    /// The button used in forms and windows: the secondary look.
    static func form(_ title: String) -> TextButton {
        let button = TextButton(title: title, font: Tokens.Font.control())
        button.showsFillAtRest = true
        return button
    }

    /// `textWidth` already carries the label's own inset; the label is centered, so the padding is even.
    var fittingWidth: CGFloat { label.textWidth + (showsFillAtRest ? Tokens.Space.x6 : Tokens.Space.x3) }

    /// So stacks and form rows can size it like any control.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(fittingWidth), height: showsFillAtRest ? Tokens.Page.controlHeight : Tokens.Space.x7Height)
    }

    override func layout() {
        super.layout()
        if showsFillAtRest {
            layer?.cornerRadius = bounds.height / 2
            updateButtonShadowPath()
        }
        let h = label.lineHeight
        label.alignment = .center
        label.frame = NSRect(x: labelOffset, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let ink = applyButtonLook(showsFillAtRest ? .secondary : .quiet)
        // Text alone dims only its words when it can't be used, not the whole button.
        if !showsFillAtRest { alphaValue = 1 }
        label.textColor = textColor ?? ink
        label.alphaValue = isEnabled || showsFillAtRest ? 1 : Tokens.Opacity.disabled
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
    /// The focus ring's color; nil takes its window's accent.
    var tint: NSColor? { didSet { updateColors() } }

    /// A symbol before the text (the magnifying glass on a search field), or nil.
    private let symbolView: NSImageView?

    /// A search field, as every page and panel has it: the magnifying glass, then the text.
    static func search(_ placeholder: String) -> FilledField {
        let field = FilledField(placeholder: placeholder, symbol: "magnifyingglass")
        field.field.setAccessibilityLabel(placeholder)
        return field
    }

    init(placeholder: String, secure: Bool = false, font: NSFont = Tokens.Font.body(), symbol: String? = nil) {
        symbolView = symbol.map { name in
            let view = NSImageView(image: Tokens.Symbol.image(name, size: Tokens.Symbol.inline))
            view.contentTintColor = Tokens.Color.textTertiary
            view.imageScaling = .scaleNone
            return view
        }
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
        layer?.cornerRadius = Tokens.Radius.field
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        addSubview(field)
        symbolView.map { addSubview($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: NSControl.textDidBeginEditingNotification, object: field)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: NSControl.textDidEndEditingNotification, object: field)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isEditing: Bool { field.currentEditor() != nil }

    @objc private func editingChanged() { updateColors() }

    /// The page look: white with a hairline edge and a faint shadow, like the secondary button beside it, where a
    /// panel's field is a soft fill. A page's header sets it for its search.
    var isOutlined = false { didSet { updateColors(); needsLayout = true } }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isOutlined ? Tokens.Color.controlFill : Tokens.Color.fieldFill).cgColor
            let ring = (tint ?? Brand.Theme.for(self).accent).withAlphaComponent(Tokens.Color.focusAlpha)
            layer?.borderColor = (isEditing ? ring : isOutlined ? Tokens.Color.controlEdge : .clear).cgColor
            layer?.borderWidth = isEditing ? 1.5 : isOutlined ? Tokens.Metric.hairline : 1.5
            layer?.shadowOpacity = isOutlined ? 1 : 0
            layer?.shadowColor = Tokens.Color.controlShadow.cgColor
            layer?.shadowRadius = Tokens.Shadow.controlRadius
            layer?.shadowOffset = CGSize(width: 0, height: -Tokens.Shadow.controlDrop)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    /// Capsule ends instead of the field's corners: a search or address field standing on its own in a panel.
    var isPill = false { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        layer?.cornerRadius = isPill ? bounds.height / 2 : Tokens.Radius.field
        if isOutlined {
            let r = layer?.cornerRadius ?? 0
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let h = ceil(field.intrinsicContentSize.height)
        var x = (isPill ? Tokens.Space.x3 : Tokens.Space.x2) + 2
        if let symbolView {
            let side = Tokens.Space.x4
            symbolView.frame = NSRect(x: isPill ? Tokens.Space.x3 : Tokens.Space.x2, y: round((bounds.height - side) / 2), width: side, height: side)
            x = symbolView.frame.maxX + Tokens.Space.x1
        }
        field.frame = NSRect(x: x, y: round((bounds.height - h) / 2), width: bounds.width - x - Tokens.Space.x3, height: h)
    }
}

/// A choice that's on or off, drawn as a pill with a check: used where several things can be picked at once.
final class ChoicePill: InteractiveView {
    private let label: Label
    private let check = NSImageView()
    var onChange: ((Bool) -> Void)?
    var isOn = true { didSet { stateDidChange(animated: true) } }
    /// Nil takes its window's accent.
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.field
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
        let tint = tint ?? Brand.Theme.for(self).accent
        let fill = isOn ? tint.withAlphaComponent(isPressed ? 0.26 : isHovered ? 0.2 : 0.14)
            : (isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : Tokens.Color.fieldFill)
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        label.textColor = isOn ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        check.image = Tokens.Symbol.image(isOn ? "checkmark" : "plus", size: Tokens.Symbol.inline)
        check.contentTintColor = isOn ? tint : Tokens.Color.textTertiary
    }
}

/// A row of filters where one is chosen (All · Weak · Reused…), each with an optional count. The chosen one takes
/// a soft fill of its window's accent; the rest are plain until hovered.
final class SegmentedPills: NSView {
    private final class Segment: InteractiveView {
        let title: Label
        let count = Label("", font: Tokens.Font.small(.semibold), color: Tokens.Color.textTertiary)
        var tint: NSColor? { didSet { stateDidChange(animated: false) } }

        init(_ text: String) {
            title = Label(text, font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
            super.init(frame: .zero)
            pressScales = true
            layer?.cornerRadius = Tokens.Radius.field
            layer?.cornerCurve = .continuous
            [title, count].forEach { addSubview($0) }
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(text)
        }

        required init?(coder: NSCoder) { fatalError() }

        private var hasCount: Bool { !count.stringValue.isEmpty }

        /// Measured in the chosen weight, so choosing a segment never squeezes its own title.
        private var titleWidth: CGFloat {
            ceil((title.stringValue as NSString).size(withAttributes: [.font: Tokens.Font.body(.semibold)]).width)
        }

        var fittingWidth: CGFloat { Tokens.Space.x3 * 2 + titleWidth + (hasCount ? Tokens.Space.x1 + 2 + count.inkWidth : 0) }

        override func layout() {
            super.layout()
            let x = Tokens.Space.x3
            title.frame = NSRect(x: x - Label.inset, y: (bounds.height - title.lineHeight) / 2, width: titleWidth + Label.inset * 2, height: title.lineHeight)
            count.frame = NSRect(x: x + titleWidth + Tokens.Space.x1 + 2 - Label.inset, y: (bounds.height - count.lineHeight) / 2,
                                 width: count.inkWidth + Label.inset * 2, height: count.lineHeight)
        }

        override func stateDidChange(animated: Bool) {
            // The chosen one's fill is the row's one gliding selection (`SelectionGlide`).
            let fill: NSColor? = isSelected ? nil : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
            layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
            title.textColor = isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
            count.textColor = isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
        }
    }

    private var segments: [Segment] = []
    private let selection = SelectionGlide(radius: Tokens.Radius.field)
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet {
            segments.enumerated().forEach { $0.element.isSelected = $0.offset == selectedIndex }
            if segments.indices.contains(selectedIndex), window != nil { selection.move(to: segments[selectedIndex].frame, animated: oldValue != selectedIndex) }
        }
    }
    /// Nil takes its window's accent.
    var tint: NSColor? { didSet { segments.forEach { $0.tint = tint }; needsLayout = true } }

    init(_ titles: [String]) {
        super.init(frame: .zero)
        addSubview(selection)
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
        selection.tint = tint ?? Brand.Theme.for(self).accent
        if segments.indices.contains(selectedIndex) { selection.move(to: segments[selectedIndex].frame, animated: false) }
    }
}

/// Zigzag's switch: a capsule track, clearly on in its window's accent and clearly off in a plain gray, with a white
/// knob that slides across. The knob settles in `Motion.standard` with no bounce, and stretches a little while held,
/// so a press reads at once; with Reduce Motion it moves at once and only the color fades.
final class Toggle: InteractiveView {
    private let knob = CALayer()
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { if oldValue != isOn { update(animated: window != nil) } } }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Tokens.Metric.toggleSize))
        layer?.cornerRadius = Tokens.Metric.toggleSize.height / 2
        layer?.cornerCurve = .continuous
        knob.cornerRadius = Tokens.Metric.toggleKnob / 2
        knob.cornerCurve = .continuous
        knob.borderWidth = 0.5
        knob.shadowOpacity = 1
        knob.shadowRadius = 2
        layer?.addSublayer(knob)
        onClick = { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        update(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Tokens.Metric.toggleSize }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    private var inset: CGFloat { (bounds.height - Tokens.Metric.toggleKnob) / 2 }

    private var knobFrame: CGRect {
        let side = Tokens.Metric.toggleKnob
        // Held, the knob stretches toward the middle, as if about to go.
        let width = side + (isPressed ? 4 : 0)
        return CGRect(x: isOn ? bounds.width - width - inset : inset, y: inset, width: width, height: side)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        Tokens.Motion.withoutAnimation { knob.frame = knobFrame }
    }

    private func update(animated: Bool) {
        if animated && !Tokens.Motion.reduceMotion {
            let move = Tokens.Motion.springAnimation(keyPath: "position.x")
            move.fromValue = knob.presentation()?.position.x ?? knob.position.x
            move.toValue = knobFrame.midX
            knob.add(move, forKey: "move")
        }
        Tokens.Motion.withoutAnimation { knob.frame = knobFrame }
        paint(fading: animated)
    }

    override func stateDidChange(animated: Bool) {
        // Pressing stretches the knob at once; letting go puts it back.
        Tokens.Motion.withoutAnimation { knob.frame = knobFrame }
        paint(fading: animated)
    }

    private func paint(fading: Bool) {
        var track = isOn ? Brand.Theme.for(self).accent : Tokens.Color.toggleOff
        if isHovered || isPressed {
            // A touch deeper under the pointer, either way.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let base = track.usingColorSpace(.sRGB) ?? track
                track = base.blended(withFraction: isPressed ? 0.12 : 0.06, of: effectiveAppearance.isDark && !isOn ? .white : .black) ?? base
            }
        }
        layer?.set(backgroundColor: cgColor(track), animated: fading, duration: Tokens.Motion.standard)
        Tokens.Motion.withoutAnimation {
            knob.backgroundColor = cgColor(Tokens.Color.dynamic(light: .white, dark: Tokens.Color.hex(0xF4F4F6)))
            knob.borderColor = cgColor(Tokens.Color.dynamic(light: Tokens.Color.hex(0x000000, alpha: 0.06), dark: .clear))
            knob.shadowColor = cgColor(Tokens.Color.dynamic(light: Tokens.Color.hex(0x000000, alpha: 0.2), dark: Tokens.Color.hex(0x000000, alpha: 0.4)))
            knob.shadowOffset = CGSize(width: 0, height: isFlipped ? 1 : -1)
        }
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

/// A small square box and its label, the whole of it clickable: for a yes or no that rides along with a button
/// ("Always open on this site"), where a switch would say too much.
final class CheckBox: InteractiveView {
    private let box = ColorView(color: .clear)
    private let mark = NSImageView()
    private let label: Label
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { if oldValue != isOn { stateDidChange(animated: false) } } }
    /// The color the box fills with when on; its window's accent unless set.
    var fixedColor: NSColor? { didSet { stateDidChange(animated: false) } }
    private static let side: CGFloat = 14

    init(title: String) {
        label = Label(title, font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        // One weight for symbols everywhere, but a tick this small needs bold to read.
        mark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        mark.imageScaling = .scaleNone
        mark.contentTintColor = .white
        box.addSubview(mark)
        [box, label].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    var fittingWidth: CGFloat { Self.side + Tokens.Space.x2 + label.textWidth }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(fittingWidth), height: max(Self.side, label.lineHeight)) }

    override func layout() {
        super.layout()
        box.frame = NSRect(x: 0, y: floor((bounds.height - Self.side) / 2), width: Self.side, height: Self.side)
        mark.frame = box.bounds
        let h = label.lineHeight
        label.frame = NSRect(x: box.frame.maxX + Tokens.Space.x2 - Label.inset, y: (bounds.height - h) / 2,
                             width: max(0, bounds.width - box.frame.maxX - Tokens.Space.x2 + Label.inset), height: h)
    }

    override func stateDidChange(animated: Bool) {
        let accent = fixedColor ?? Brand.Theme.for(self).accent
        let edge = Tokens.Color.dynamic(light: Tokens.Color.hex(0x000000, alpha: 0.25), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.3))
        let fill: NSColor = isOn ? accent : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : .clear
        box.color = fill
        box.layer?.borderColor = cgColor(isOn ? accent : edge)
        mark.isHidden = !isOn
        label.textColor = isHovered || isOn ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

/// A choice from a list, drawn as Zigzag's: the current choice (with its icon) on the secondary look, a chevron at
/// the end, and Zigzag's own menu (`MenuPanel`) when clicked, its chosen item right over the button as macOS places it.
/// Press and drag to an item to choose in one go; with the keyboard, Space, Return or an arrow opens it.
final class DropdownButton: InteractiveView {
    struct Option {
        var title: String
        var image: NSImage?
        init(title: String, image: NSImage? = nil) { self.title = title; self.image = image }
    }
    private let label = Label("", font: Tokens.Font.control(), color: Tokens.Color.textPrimary)
    private let icon = NSImageView()
    private let chevron = NSImageView()
    var options: [Option] = [] { didSet { refresh() } }
    var selectedIndex = 0 { didSet { refresh() } }
    var onSelect: ((Int) -> Void)?
    private var openedAt: TimeInterval = 0
    private var menuOpen = false { didSet { stateDidChange(animated: false) } }

    static let iconSide: CGFloat = Tokens.Space.x4
    /// From the button's edge to its icon or title: the menu's items line up with it.
    static let textInset: CGFloat = Tokens.Space.x3

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        chevron.image = Tokens.Symbol.image("chevron.up.chevron.down", size: Tokens.Symbol.inline)
        chevron.imageScaling = .scaleNone
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, label, chevron].forEach { addSubview($0) }
        clicksOnMouseDown = true
        onClick = { [weak self] _ in self?.openMenu() }
        setAccessibilityRole(.popUpButton)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var current: Option? { options.indices.contains(selectedIndex) ? options[selectedIndex] : nil }

    private func refresh() {
        label.stringValue = current?.title ?? ""
        // A neutral globe where a site's icon is missing, so the column of pictures never has a gap.
        let pictured = options.contains { $0.image != nil }
        icon.image = current?.image ?? (pictured ? MenuPanel.placeholder : nil)
        icon.contentTintColor = Tokens.Color.icon
        icon.isHidden = icon.image == nil
        setAccessibilityValue(label.stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let widest = options.map { ($0.title as NSString).size(withAttributes: [.font: Tokens.Font.control()]).width }.max() ?? 0
        let iconWidth: CGFloat = options.contains { $0.image != nil } ? Self.iconSide + Tokens.Space.x2 : 0
        return NSSize(width: ceil(Self.textInset + iconWidth + widest + Tokens.Space.x3 + 10 + Self.textInset), height: Tokens.Page.controlHeight)
    }

    override func layout() {
        super.layout()
        updateButtonShadowPath()
        var x = Self.textInset
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (bounds.height - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
            x = icon.frame.maxX + Tokens.Space.x2
        }
        chevron.frame = NSRect(x: bounds.width - Self.textInset - 10, y: (bounds.height - 14) / 2, width: 10, height: 14)
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: max(0, chevron.frame.minX - x - Tokens.Space.x1), height: label.lineHeight)
    }

    func openMenu() {
        guard !options.isEmpty, MenuPanel.current?.anchor !== self else { return }
        let items: [MenuPanel.Entry] = options.enumerated().map { index, option in
            .item(MenuPanel.Item(title: option.title, image: option.image, isChecked: index == selectedIndex) { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.onSelect?(index)
            })
        }
        openedAt = ProcessInfo.processInfo.systemUptime
        menuOpen = true
        MenuPanel.show(items, from: self, placement: .over(selectedIndex, textInset: Self.textInset), minWidth: bounds.width) { [weak self] in
            self?.menuOpen = false
        }
    }

    // Press, drag to an item and let go: chosen in one movement, as macOS menus allow.
    override func mouseDragged(with event: NSEvent) {
        guard let menu = MenuPanel.current, menu.anchor === self else { return super.mouseDragged(with: event) }
        menu.track(windowPoint: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let menu = MenuPanel.current, menu.anchor === self else { return }
        // A quick click leaves the menu open; a press held or dragged onto an item chooses it.
        let held = ProcessInfo.processInfo.systemUptime - openedAt > 0.35
        let onButton = bounds.contains(convert(event.locationInWindow, from: nil))
        if held && !onButton { menu.chooseTracked(windowPoint: event.locationInWindow) }
    }

    override func keyDown(with event: NSEvent) {
        // Up or Down opens it, as a pop-up button does.
        if hasKeyboardFocus, [125, 126].contains(event.keyCode) { openMenu(); return }
        super.keyDown(with: event)
    }

    override func accessibilityPerformShowMenu() -> Bool { openMenu(); return true }

    override func stateDidChange(animated: Bool) {
        let ink = applyButtonLook(.secondary)
        if menuOpen { layer?.set(backgroundColor: cgColor(Tokens.Color.controlHover), animated: false) }
        label.textColor = ink
        chevron.contentTintColor = Tokens.Color.textSecondary
    }
}

/// Zigzag's own menu, drawn rather than the system's, for choosing from a list (a dropdown's options) or acting on
/// something (a button's few actions): a solid panel with a hairline edge and the panel shadow, 15pt items, a soft gray
/// row under the pointer or the arrow keys, a check at the trailing end of the chosen one. It arrives in a quick fade
/// from a touch smaller and leaves the same way; opened or closed from the keyboard it's simply there.
/// Keys: Up and Down move, Return or Space chooses, Esc closes, and typing a name jumps to it. Right-click menus stay
/// the system's.
final class MenuPanel: FloatingPanelView {
    enum Entry {
        case item(Item)
        /// A quiet heading over the items after it ("Save Downloads To").
        case header(String)
        case separator
    }

    struct Item {
        var title: String
        var image: NSImage?
        var symbol: String?
        var isChecked = false
        var isDestructive = false
        var isEnabled = true
        var action: () -> Void

        init(title: String, image: NSImage? = nil, symbol: String? = nil, isChecked: Bool = false, isDestructive: Bool = false,
             isEnabled: Bool = true, action: @escaping () -> Void) {
            self.title = title; self.image = image; self.symbol = symbol; self.isChecked = isChecked
            self.isDestructive = isDestructive; self.isEnabled = isEnabled; self.action = action
        }
    }

    /// Where it opens: with item `index` right over the control, its text `textInset` from the control's edge, as a
    /// pop-up button's menu does (below it when there's no room); or under the control, as a button's menu does.
    enum Placement { case over(Int, textInset: CGFloat), below }

    /// The menu that's open, if any. Panels that close on Esc or a click elsewhere leave those to it while it's open.
    static weak var current: MenuPanel?
    private(set) weak var anchor: NSView?

    private let entries: [Entry]
    private var rows: [Row] = []
    private let scroll = NSScrollView()
    private let list = FlippedView()
    /// One soft gray pill that glides from row to row under the pointer, rather than each row lighting on its own.
    private let pill = ColorView(color: Tokens.Color.highlight)
    private var highlighted: Int? {
        didSet {
            rows.enumerated().forEach { $0.element.isHighlighted = $0.offset == highlighted }
            movePill(from: oldValue)
        }
    }
    /// The glass, the contact shadow and the lit top edge that give the panel its depth.
    private let contact = CALayer()
    private let rim = CAShapeLayer()
    /// The neutral picture for an item whose own is missing (a site with no favicon yet).
    static var placeholder: NSImage { Tokens.Symbol.image("globe", size: Tokens.TypeSize.body) }
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?
    private var typed = ""
    private var typedAt: TimeInterval = 0

    private static let pad = Tokens.Space.x1
    private static let rowHeight = Tokens.Page.controlHeight
    private static let headerHeight = Tokens.Space.x7Height
    private static let separatorHeight = Tokens.Space.x2 + 1
    /// From a row's edge to its icon or text, and from its check to the trailing edge.
    private static let rowInset = Tokens.Space.x2 + 2
    private static let margin = Tokens.Space.x2

    private init(entries: [Entry]) {
        self.entries = entries
        super.init(frame: .zero)
        isGlass = false
        radius = Tokens.Radius.panel
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.useSlimScroller()
        scroll.documentView = list
        addSubview(scroll)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Tokens.Radius.row
        pill.layer?.cornerCurve = .continuous
        pill.alphaValue = 0
        list.addSubview(pill)
        layer?.insertSublayer(contact, at: 0)
        rim.fillColor = nil
        rim.lineWidth = Tokens.Metric.hairline
        layer?.addSublayer(rim)
        let hasImages = entries.contains { if case .item(let item) = $0 { return item.image != nil || item.symbol != nil }; return false }
        for entry in entries {
            switch entry {
            case .item(let item):
                let row = Row(item, reservesIcon: hasImages)
                let index = rows.count
                row.onClick = { [weak self] _ in self?.choose(index) }
                row.hoverChanged = { [weak self] hovered in
                    guard let self else { return }
                    if hovered { self.highlighted = self.rows[index].item.isEnabled ? index : nil } else if self.highlighted == index { self.highlighted = nil }
                }
                rows.append(row)
                list.addSubview(row)
            case .header(let text):
                list.addSubview(Label.section(text))
            case .separator:
                list.addSubview(ColorView(color: Tokens.Color.separator))
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var contentHeight: CGFloat {
        Self.pad * 2 + entries.map { entry -> CGFloat in
            switch entry {
            case .item: Self.rowHeight
            case .header: Self.headerHeight
            case .separator: Self.separatorHeight
            }
        }.reduce(0, +)
    }

    /// The top of item `index` in the list.
    private func top(ofItem index: Int) -> CGFloat {
        var y = Self.pad, seen = 0
        for entry in entries {
            switch entry {
            case .item:
                if seen == index { return y }
                seen += 1
                y += Self.rowHeight
            case .header: y += Self.headerHeight
            case .separator: y += Self.separatorHeight
            }
        }
        return y
    }

    private var fittingWidth: CGFloat {
        let font = Tokens.Font.body()
        let widest = rows.map { ceil(($0.item.title as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let icon: CGFloat = rows.first?.reservesIcon == true ? DropdownButton.iconSide + Tokens.Space.x2 : 0
        return Self.pad * 2 + Self.rowInset + icon + widest + Tokens.Space.x6 + Row.checkSide + Self.rowInset
    }

    // MARK: Showing

    /// Opens a menu from `anchor`. `closed` runs once it's gone, chosen or not.
    @discardableResult
    static func show(_ entries: [Entry], from anchor: NSView, placement: Placement = .below, minWidth: CGFloat = 0,
                     closed: (() -> Void)? = nil) -> MenuPanel? {
        current?.close(animated: false)
        guard let window = anchor.window, let host = window.contentView else { closed?(); return nil }
        let menu = MenuPanel(entries: entries)
        menu.anchor = anchor
        menu.onClose = closed

        let width = ceil(max(menu.fittingWidth, minWidth + Self.pad * 2))
        let a = anchor.convert(anchor.bounds, to: nil)
        let area = host.convert(host.bounds, to: nil).insetBy(dx: Self.margin, dy: Self.margin)
        let full = menu.contentHeight
        let height = min(full, area.height)
        var x = a.minX, maxY: CGFloat
        var growsY: CGFloat = 0
        var scrollTo: CGFloat = 0
        func fits(_ top: CGFloat) -> Bool { top <= area.maxY && top - height >= area.minY }
        switch placement {
        case .over(let index, let inset):
            // The chosen item's text right over the button's.
            x = a.minX + inset - Self.pad - Self.rowInset
            let rowMid = menu.top(ofItem: index) + Self.rowHeight / 2
            let aligned = a.midY + rowMid
            if height == full, fits(aligned) {
                maxY = aligned
                growsY = rowMid / height
            } else if fits(a.minY - Tokens.Space.x1) {
                maxY = a.minY - Tokens.Space.x1
            } else if fits(a.maxY + Tokens.Space.x1 + height) {
                maxY = a.maxY + Tokens.Space.x1 + height
                growsY = 1
            } else {
                // Taller than the room: as close to aligned as the window allows, scrolled to the chosen item.
                maxY = min(max(aligned, area.minY + height), area.maxY)
                scrollTo = min(max(0, rowMid - (maxY - a.midY)), full - height)
                growsY = min(max((maxY - a.midY) / height, 0), 1)
            }
        case .below:
            if fits(a.minY - Tokens.Space.x1) {
                maxY = a.minY - Tokens.Space.x1
            } else if fits(a.maxY + Tokens.Space.x1 + height) {
                maxY = a.maxY + Tokens.Space.x1 + height
                growsY = 1
            } else {
                maxY = area.maxY
            }
        }
        x = min(max(x, area.minX), max(area.minX, area.maxX - width))
        let rect = NSRect(x: x, y: maxY - height, width: width, height: height)
        menu.frame = host.convert(rect, from: nil)
        menu.growsFrom = CGPoint(x: min(max((a.midX - x) / width, 0), 1), y: growsY)
        host.addSubview(menu)
        menu.layoutSubtreeIfNeeded()
        menu.scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollTo))
        menu.scroll.reflectScrolledClipView(menu.scroll.contentView)
        if case .over(let index, _) = placement, menu.rows.indices.contains(index), menu.rows[index].item.isEnabled {
            menu.highlighted = index
        }
        menu.arrive()
        current = menu
        menu.watch(window)
        NSAccessibility.post(element: menu, notification: .created)
        if let index = menu.highlighted { Announcement.post(menu.rows[index].item.title) }
        return menu
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = bounds.width
        list.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        var y = Self.pad, index = 0
        for view in list.subviews where view !== pill {
            if let row = view as? Row {
                row.frame = NSRect(x: Self.pad, y: y, width: width - Self.pad * 2, height: Self.rowHeight)
                y += Self.rowHeight
                index += 1
            } else if let label = view as? Label {
                label.frame = NSRect(x: Self.pad + Self.rowInset - Label.inset, y: y + Self.headerHeight - Tokens.Space.x1 - label.lineHeight - 2,
                                     width: width - (Self.pad + Self.rowInset) * 2, height: label.lineHeight)
                y += Self.headerHeight
            } else {
                view.frame = NSRect(x: Self.pad + Self.rowInset, y: y + floor(Self.separatorHeight / 2), width: width - (Self.pad + Self.rowInset) * 2,
                                    height: Tokens.Metric.hairline)
                y += Self.separatorHeight
            }
        }
        if let highlighted, rows.indices.contains(highlighted) { Tokens.Motion.withoutAnimation { pill.frame = rows[highlighted].frame } }
        // Depth: a tight contact shadow right under the edge beneath the wide panel shadow, and a lit top rim.
        let r = radius
        Tokens.Motion.withoutAnimation {
            contact.frame = bounds
            contact.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
            contact.shadowColor = cgColor(Tokens.Color.contactShadow)
            contact.shadowOpacity = 1
            contact.shadowRadius = Tokens.Shadow.contactRadius
            contact.shadowOffset = CGSize(width: 0, height: isFlipped ? Tokens.Shadow.contactDrop : -Tokens.Shadow.contactDrop)
            let rimPath = CGMutablePath()
            let y = isFlipped ? 1.0 : bounds.height - 1
            rimPath.move(to: CGPoint(x: r, y: y))
            rimPath.addLine(to: CGPoint(x: bounds.width - r, y: y))
            rim.path = rimPath
            rim.strokeColor = cgColor(Tokens.Color.topHighlight)
            rim.frame = bounds
        }
    }

    /// The highlight glides from where it was to the row now under the pointer. From the keyboard, or arriving from
    /// nothing, it's simply there; leaving every row, it fades.
    private func movePill(from old: Int?) {
        guard let highlighted, rows.indices.contains(highlighted) else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Tokens.Motion.quick
                pill.animator().alphaValue = 0
            }
            return
        }
        let target = rows[highlighted].frame
        if old == nil || pill.alphaValue == 0 || Tokens.Motion.isFromKey || Tokens.Motion.reduceMotion {
            pill.layer?.removeAllAnimations()
            Tokens.Motion.withoutAnimation { pill.frame = target }
            pill.alphaValue = 1
        } else {
            pill.alphaValue = 1
            Tokens.Motion.glide(pill, to: target, duration: Tokens.Motion.highlightGlide, timing: Tokens.Motion.easeOut)
        }
    }

    /// Pressed, the highlight darkens a step.
    fileprivate func showPressed(_ pressed: Bool) { pill.color = pressed ? Tokens.Color.pressedFill : Tokens.Color.highlight }

    // MARK: Closing

    private func watch(_ window: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(animated: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        })
    }

    func close(animated: Bool = true) {
        guard Self.current === self || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if Self.current === self { Self.current = nil }
        let closed = onClose
        onClose = nil
        if animated { leave() } else { removeFromSuperview() }
        closed?()
    }

    /// Grows out of the control that opened it: from `Motion.menuFrom` with a fade, anchored at that control, eased
    /// out. From the keyboard it's simply there; with Reduce Motion it only fades.
    private func arrive() {
        guard let layer, !Tokens.Motion.isFromKey else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Tokens.Motion.menuIn * 0.7
        fade.timingFunction = Tokens.Motion.easeOut
        layer.add(fade, forKey: "arrive.fade")
        guard !Tokens.Motion.reduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.menuFrom, of: layer, around: growsFrom, flipped: layer.isGeometryFlipped || isFlipped))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Tokens.Motion.menuIn
        grow.timingFunction = Tokens.Motion.easeOut
        layer.add(grow, forKey: "arrive.grow")
    }

    /// Leaves quicker and subtler than it came: a fade as it eases a touch smaller toward its control, from wherever
    /// it is, so a quick open and close never jumps.
    private func leave() {
        guard let layer, !Tokens.Motion.isFromKey else { removeFromSuperview(); return }
        let shownOpacity = layer.presentation()?.opacity ?? 1
        let shownTransform = layer.presentation()?.transform ?? CATransform3DIdentity
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shownOpacity
        fade.toValue = 0
        fade.duration = Tokens.Motion.menuOut
        fade.timingFunction = Tokens.Motion.easeOut
        layer.add(fade, forKey: "leave.fade")
        layer.opacity = 0
        if !Tokens.Motion.reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: shownTransform)
            shrink.toValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.menuOutScale, of: layer, around: growsFrom, flipped: layer.isGeometryFlipped || isFlipped))
            shrink.duration = Tokens.Motion.menuOut
            shrink.timingFunction = Tokens.Motion.easeOut
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "leave.grow")
        }
        CATransaction.commit()
    }

    private func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].item.isEnabled else { return }
        let action = rows[index].item.action
        close()
        action()
    }

    // MARK: Pointer and keys

    private func row(at windowPoint: NSPoint) -> Int? {
        rows.firstIndex { $0.bounds.contains($0.convert(windowPoint, from: nil)) && $0.item.isEnabled }
    }

    /// The pointer moving with the button still held from the dropdown that opened it.
    func track(windowPoint: NSPoint) {
        highlighted = row(at: windowPoint)
    }

    func chooseTracked(windowPoint: NSPoint) {
        if let index = row(at: windowPoint) { choose(index) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let inSameWindow = event.window === window
        let inside = inSameWindow && bounds.contains(convert(event.locationInWindow, from: nil))
        switch event.type {
        case .keyDown:
            return handleKey(event) ? nil : event
        case .scrollWheel:
            if inside { return event }
            close(animated: false)
            return event
        default:
            if inside { return event }
            // A click elsewhere closes the menu and goes no further in this window, as with any menu.
            close()
            return inSameWindow ? nil : event
        }
    }

    /// True when the key was the menu's.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty {
            // A shortcut: the menu steps aside and lets it through.
            close(animated: false)
            return false
        }
        switch event.keyCode {
        case 53: close(); return true                                     // Esc
        case 125: move(1); return true                                    // Down
        case 126: move(-1); return true                                   // Up
        case 115: move(-rows.count); return true                          // Home
        case 119: move(rows.count); return true                           // End
        case 36, 76: if let highlighted { choose(highlighted) } else { close() }; return true   // Return, Enter
        case 48: close(); return true                                     // Tab
        case 49 where typed.isEmpty || ProcessInfo.processInfo.systemUptime - typedAt > 1:      // Space
            if let highlighted { choose(highlighted) }
            return true
        default:
            guard let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return true }
            typeSelect(text)
            return true
        }
    }

    private func move(_ step: Int) {
        let enabled = rows.indices.filter { rows[$0].item.isEnabled }
        guard !enabled.isEmpty else { return }
        let next: Int
        if let highlighted, let at = enabled.firstIndex(of: highlighted) {
            next = enabled[min(max(at + step, 0), enabled.count - 1)]
        } else {
            next = step > 0 ? enabled.first! : enabled.last!
        }
        highlight(next)
    }

    private func highlight(_ index: Int) {
        highlighted = index
        let row = rows[index]
        list.scrollToVisible(row.frame)
        Announcement.post(row.item.title)
    }

    /// Typing a name jumps to the first item that starts with it; a pause of a second starts over.
    private func typeSelect(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        typed = now - typedAt > 1 ? text : typed + text
        typedAt = now
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        if let index = rows.indices.first(where: { rows[$0].item.isEnabled && rows[$0].item.title.range(of: typed, options: options) != nil }) {
            highlight(index)
        }
    }

    // MARK: Rows

    fileprivate final class Row: InteractiveView {
        let item: Item
        let reservesIcon: Bool
        private let icon = NSImageView()
        private let label: Label
        private let check = NSImageView()
        static let checkSide: CGFloat = 12
        var isHighlighted = false { didSet { if oldValue != isHighlighted { stateDidChange(animated: false) } } }

        init(_ item: Item, reservesIcon: Bool) {
            self.item = item
            self.reservesIcon = reservesIcon
            label = Label(item.title, font: Tokens.Font.body(), color: item.isDestructive ? Tokens.Color.destructive : Tokens.Color.textPrimary)
            super.init(frame: .zero)
            layer?.cornerRadius = Tokens.Radius.row
            layer?.cornerCurve = .continuous
            if let image = item.image {
                icon.image = image
                icon.imageScaling = .scaleProportionallyUpOrDown
            } else if let symbol = item.symbol {
                icon.image = Tokens.Symbol.image(symbol, size: Tokens.TypeSize.body)
                icon.imageScaling = .scaleNone
                icon.contentTintColor = item.isDestructive ? Tokens.Color.destructive : Tokens.Color.icon
            } else if reservesIcon {
                // Every item has its picture: a neutral globe where one is missing, so the column stays aligned.
                icon.image = MenuPanel.placeholder
                icon.imageScaling = .scaleNone
                icon.contentTintColor = Tokens.Color.icon
            }
            check.image = Tokens.Symbol.image("checkmark", size: Tokens.Symbol.inline)
            check.imageScaling = .scaleNone
            check.isHidden = !item.isChecked
            [icon, label, check].forEach { addSubview($0) }
            isEnabled = item.isEnabled
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel(item.title)
            setAccessibilityValue(item.isChecked ? "selected" : nil)
            stateDidChange(animated: false)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            var x = MenuPanel.rowInset
            if reservesIcon {
                let side = DropdownButton.iconSide
                icon.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
                x = icon.frame.maxX + Tokens.Space.x2
            }
            let side = Self.checkSide + 4
            check.frame = NSRect(x: bounds.width - MenuPanel.rowInset - side, y: (bounds.height - side) / 2, width: side, height: side)
            label.frame = NSRect(x: x - Label.inset, y: (bounds.height - label.lineHeight) / 2,
                                 width: max(0, check.frame.minX - Tokens.Space.x2 - x + Label.inset * 2), height: label.lineHeight)
        }

        override func stateDidChange(animated: Bool) {
            // The highlight is the menu's one gliding pill (`MenuPanel.pill`); the chosen item has its check, in the
            // window's accent.
            check.contentTintColor = Brand.Theme.for(self).accent
            sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? MenuPanel }.first?.showPressed(isPressed)
            alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
            setAccessibilitySelected(isHighlighted)
        }
    }
}

/// A state, said calmly: a check in its window's accent and a few words ("Zigzag is your default browser").
final class StatusLabel: NSView {
    private let check = NSImageView()
    private let label: Label

    init(_ text: String, symbol: String = "checkmark.circle.fill") {
        label = Label(text, font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        check.image = Tokens.Symbol.image(symbol, size: Tokens.TypeSize.body)
        [check, label].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        check.contentTintColor = Brand.Theme.for(self).accent
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 16 + Tokens.Space.x2 + label.inkWidth + Label.inset, height: Tokens.Space.x7Height) }

    override func layout() {
        super.layout()
        check.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 16 + Tokens.Space.x2 - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }
}

/// A few choices on one soft track, the chosen one on a raised pill that slides to it. Words or icons; every
/// two- or three-way choice in Zigzag uses this, so they all look and move the same.
final class SlidingSwitch: NSView {
    /// `styled` shows its title in its own font (the Reader's "Serif" in a serif).
    enum Item { case text(String), styled(String, NSFont), symbol(String, toolTip: String) }
    var selectedIndex = 0 { didSet { if oldValue != selectedIndex { layoutPill(animated: window != nil) } } }
    var onChange: ((Int) -> Void)?
    private let items: [Item]
    private let track = ColorView(color: Tokens.Color.fieldFill)
    private let pill = ColorView(color: Tokens.Color.panelBackground)
    private var labels: [Label] = []
    private var icons: [NSImageView] = []
    private let inset: CGFloat = 3

    init(_ items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        for view in [track, pill] {
            view.wantsLayer = true
            view.layer?.cornerCurve = .continuous
            addSubview(view)
        }
        pill.layer?.shadowOpacity = 1
        pill.layer?.shadowRadius = 1.5
        pill.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        for item in items {
            switch item {
            case .text(let title), .styled(let title, _):
                var font = Tokens.Font.body(.medium)
                if case .styled(_, let own) = item { font = own }
                let label = Label(title, font: font, color: Tokens.Color.textSecondary)
                labels.append(label)
                addSubview(label)
            case .symbol(let name, let tip):
                let icon = NSImageView(image: Tokens.Symbol.image(name))
                icon.imageScaling = .scaleNone
                icon.toolTip = tip
                icons.append(icon)
                addSubview(icon)
            }
        }
        setAccessibilityRole(.radioGroup)
        // One radio button per choice for VoiceOver, each chosen with a press.
        segments = items.enumerated().map { i, item in
            let element = SegmentElement()
            element.setAccessibilityParent(self)
            switch item {
            case .text(let title), .styled(let title, _): element.setAccessibilityLabel(title)
            case .symbol(_, let tip): element.setAccessibilityLabel(tip)
            }
            element.press = { [weak self] in self?.choose(i) }
            return element
        }
        setAccessibilityChildren(segments)
    }

    private var segments: [SegmentElement] = []

    private func choose(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var segmentWidth: CGFloat { (bounds.width - inset * 2) / CGFloat(max(items.count, 1)) }

    private func segment(_ i: Int) -> NSRect {
        NSRect(x: inset + CGFloat(i) * segmentWidth, y: inset, width: segmentWidth, height: bounds.height - inset * 2)
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        track.layer?.cornerRadius = min(bounds.height / 2, Tokens.Radius.field + inset)
        // Each title spans its whole segment, centered, so bold or not it sits in the middle.
        for (i, label) in labels.enumerated() {
            let r = segment(i)
            label.alignment = .center
            label.frame = NSRect(x: r.minX, y: (r.midY - label.lineHeight / 2).rounded(), width: r.width, height: label.lineHeight)
        }
        for (i, icon) in icons.enumerated() { icon.frame = segment(i) }
        for (i, element) in segments.enumerated() { element.setAccessibilityFrameInParentSpace(segment(i)) }
        layoutPill(animated: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        }
    }

    private func layoutPill(animated: Bool) {
        let target = segment(selectedIndex)
        // Concentric with the track: the pill's corners follow the track's at the same inset.
        pill.layer?.cornerRadius = max((track.layer?.cornerRadius ?? 0) - inset, 0)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Tokens.Motion.standard
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                pill.animator().frame = target
            }
        } else {
            pill.frame = target
        }
        for (i, label) in labels.enumerated() {
            label.textColor = i == selectedIndex ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        }
        for (i, icon) in icons.enumerated() { icon.contentTintColor = i == selectedIndex ? Tokens.Color.textPrimary : Tokens.Color.icon }
        for (i, element) in segments.enumerated() { element.setAccessibilityValue(i == selectedIndex ? 1 : 0) }
    }

    /// The labels span whole segments, so a click anywhere lands on the switch, not on a label.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        choose(min(max(Int((x - inset) / segmentWidth), 0), items.count - 1))
    }
}

/// One choice of a sliding switch, for VoiceOver: a radio button that a press chooses.
nonisolated private final class SegmentElement: NSAccessibilityElement {
    var press: (@MainActor () -> Void)?

    override init() {
        super.init()
        setAccessibilityRole(.radioButton)
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        MainActor.assumeIsolated { press?() }
        return true
    }
}

/// Speaks a short line through VoiceOver (a toast, a match count, the row you moved to) without moving focus.
/// Nothing is posted while VoiceOver is off.
enum Announcement {
    static func post(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }
}

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

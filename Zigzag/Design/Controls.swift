import AppKit

extension NSView {
    /// The window frame's colors behind this view; none on a see-through frame.
    var frameGrounds: [NSColor] { Brand.Theme.for(self).inkGrounds }

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

extension NSView {
    /// The sidebar's card shadow-sm (`Tokens.Chrome.cardShadow`), on or off: tiny, straight down.
    func setCardShadow(_ on: Bool) {
        guard let layer else { return }
        layer.shadowOpacity = on ? 1 : 0
        guard on else { return }
        layer.shadowColor = cgColor(Tokens.Chrome.cardShadow)
        layer.shadowRadius = Tokens.Shadow.liftRadius
        layer.shadowOffset = CGSize(width: 0, height: isFlipped ? Tokens.Shadow.liftDrop : -Tokens.Shadow.liftDrop)
        refreshCardShadowPath()
    }

    /// The card is see-through: a shadow cast by its whole shape would show through it and darken it to a slab.
    /// It's cast from a ring along the edge instead, so it only falls outside. Called again whenever the card is
    /// sized; before it has a size, it casts none.
    func refreshCardShadowPath() {
        guard let layer, layer.shadowOpacity > 0 else { return }
        let b = layer.bounds
        guard b.width > 4, b.height > 4 else { layer.shadowPath = CGMutablePath(); return }
        let r = min(layer.cornerRadius, b.height / 2), inner = b.insetBy(dx: 2, dy: 2)
        let ring = CGMutablePath()
        ring.addRoundedRect(in: b, cornerWidth: r, cornerHeight: r)
        // The inner edge runs the other way round, so the shadow's nonzero fill leaves the middle empty.
        var flip = CGAffineTransform(translationX: inner.midX * 2, y: 0).scaledBy(x: -1, y: 1)
        if let reversed = CGPath(roundedRect: inner, cornerWidth: max(0, r - 2), cornerHeight: max(0, r - 2), transform: &flip) as CGPath? {
            ring.addPath(reversed)
        }
        layer.shadowPath = ring
    }
}

extension NSView {
    /// The card's top edge catching the light: a one-pixel line just inside its upper rim, short of the corners.
    func setCardRim(_ on: Bool) {
        guard let layer else { return }
        let rim = layer.sublayers?.first { $0.name == "rim" } ?? {
            let line = CALayer()
            line.name = "rim"
            layer.addSublayer(line)
            return line
        }()
        Tokens.Motion.withoutAnimation {
            rim.isHidden = !on
            guard on else { return }
            let inset = max(layer.cornerRadius, 3)
            let px = 1 / (window?.backingScaleFactor ?? 2)
            rim.frame = CGRect(x: inset, y: isFlipped ? 1 : bounds.height - 1 - px, width: max(0, bounds.width - inset * 2), height: px)
            rim.backgroundColor = cgColor(Tokens.Chrome.rim)
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
            // A color changing in place: a state change, on the house ease-out.
            animation.timingFunction = Tokens.Motion.easeOut
            add(animation, forKey: "backgroundColor")
        }
        Tokens.Motion.withoutAnimation { backgroundColor = color }
    }

    /// Rounds the corners for a shape of `size`: never more than half its short side, and a capsule's ends true
    /// half-circles, since a continuous curve that big comes to a point.
    func round(_ radius: CGFloat, size: CGSize) {
        let fitted = Self.cornerRadius(radius, size: size)
        cornerRadius = fitted
        cornerCurve = Self.isCapsule(fitted, size: size) ? .circular : .continuous
    }

    nonisolated static func cornerRadius(_ radius: CGFloat, size: CGSize) -> CGFloat {
        max(0, min(radius, min(size.width, size.height) / 2))
    }

    /// A continuous curve needs about 1.53 times its radius on each side; past that, circular.
    nonisolated static func isCapsule(_ radius: CGFloat, size: CGSize) -> Bool {
        radius > 0 && radius * 2 * 1.528 > min(size.width, size.height)
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
            if pressScales { showPress(isPressed) } else if pressSinks { showSink(isPressed) }
            pressChanged?(isPressed)
        }
    }
    /// A press staying down or lifting, for a control that repeats while held.
    var pressChanged: ((Bool) -> Void)?
    /// Buttons and rows give under the finger: `Tokens.Motion.pressScale` while held, easing back on release.
    var pressScales = false
    /// Things that read as objects sink a point instead and settle back with weight (`showSink`).
    var pressSinks = false
    /// How far past its edges a press still counts, for a small control whose parent hands it the clicks around it
    /// (the address's buttons take the field's rim). Its look stays its own size.
    var pressOutset = NSEdgeInsets()
    /// Where a press lands on this control: its bounds, grown by `pressOutset`.
    var pressArea: NSRect {
        NSRect(x: bounds.minX - pressOutset.left, y: bounds.minY - pressOutset.top,
               width: bounds.width + pressOutset.left + pressOutset.right, height: bounds.height + pressOutset.top + pressOutset.bottom)
    }
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
    var onRightClick: ((NSEvent) -> NSMenu?)? { didSet { updateTouchMenu() } }
    /// Called once the mouse moves far enough while pressed. Return true to take over the drag.
    var onDragStart: ((NSEvent) -> Bool)? { didSet { updateTouchMenu() } }
    /// A finger held and moved picks it up too, through `onDragStart`: only for drags run by `CarriedCopy.carry`,
    /// which a finger can drive.
    var dragsByTouch = false { didSet { updateTouchMenu() } }
    /// Only sideways movement starts a drag, for something that moves along a row: a wobble up or down stays a click.
    var dragsHorizontally = false
    /// Fires the click on mouse down instead of mouse up (tabs feel faster this way).
    var clicksOnMouseDown = false
    /// The mouse-down behind the click being handled; nil when the click came from the keyboard or VoiceOver.
    var currentPress: NSEvent? { mouseDownEvent }

    /// Held down, it opens its right-click menu under itself, as Safari's Back and Forward do (#509).
    var holdOpensMenu = false
    /// How long a press is held before that menu opens.
    nonisolated static let holdMenuDelay: TimeInterval = 0.5

    private var trackingArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var dragging = false
    private var holdTimer: Timer?
    /// The menu a held press opened, while that press is still down.
    private weak var heldMenu: MenuPanel?

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
                && !isCoveredByPanel(at: window.mouseLocationOutsideOfEventStream)
            if inside != isHovered { isHovered = inside }
        }
    }

    /// Whether a floating panel this control isn't part of is what's under the pointer: tracking areas fire through
    /// it, so a tab row under Site Controls would otherwise light up as if the pointer were on it (#216).
    private func isCoveredByPanel(at windowPoint: NSPoint) -> Bool {
        guard let frame = window?.contentView?.superview else { return false }
        var view = frame.hitTest(frame.convert(windowPoint, from: nil))
        while let current = view {
            if current === self { return false }
            if current is FloatingPanelView { return !isDescendant(of: current) }
            view = current.superview
        }
        return false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = !isCoveredByPanel(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { isHovered = false; if !dragging { isPressed = false } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Control-click is a right-click.
        if drawsMenu, event.modifierFlags.contains(.control), let onRightClick {
            if let menu = onRightClick(event) { showDrawnMenu(menu, at: event.locationInWindow) }
            return
        }
        // A finger's two taps count too: AppKit's click from each comes as a single click.
        if let onDoubleClick, TouchDoubleTap.clickCount(for: event, on: self) == 2 {
            TouchLog.note("double click on \(type(of: self)) clicks=\(event.clickCount)")
            onDoubleClick()
            return
        }
        isPressed = true
        mouseDownEvent = event
        dragging = false
        heldMenu = nil
        // A finger's hold has its own menu (`TouchHold`).
        if holdOpensMenu, onRightClick != nil, !TouchDoubleTap.isFromFinger(event.timestamp, landedAt: TouchPress.landedAt) {
            startHoldTimer()
        }
        if clicksOnMouseDown { onClick?(event) }
    }

    private func startHoldTimer() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: Self.holdMenuDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// Still pressed on it once the hold is up: its menu opens under it, to choose from by letting go over an item.
    func holdElapsed() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard isEnabled, isPressed, !dragging, let press = mouseDownEvent, let onRightClick, window != nil,
              MenuPanel.current == nil, let menu = onRightClick(press) else { return }
        let entries = MenuPanel.entries(from: menu)
        guard !entries.isEmpty else { return }
        isPressed = false
        heldMenu = MenuPanel.show(entries, from: self, placement: .below)
    }

    override func mouseDragged(with event: NSEvent) {
        if let heldMenu, MenuPanel.current === heldMenu { heldMenu.track(windowPoint: event.locationInWindow); return }
        guard isEnabled, let start = mouseDownEvent, !dragging else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x, dy = event.locationInWindow.y - start.locationInWindow.y
        let distance = dragsHorizontally ? abs(dx) : hypot(dx, dy)
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
            let inside = pressArea.contains(convert(event.locationInWindow, from: nil))
            if inside != isPressed { isPressed = inside }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil; dragging = false; holdTimer?.invalidate(); holdTimer = nil; heldMenu = nil }
        if let heldMenu {
            isPressed = false
            // Let go over an item, it's chosen; anywhere else the menu stays open to click.
            if MenuPanel.current === heldMenu { heldMenu.chooseTracked(windowPoint: event.locationInWindow) }
            return
        }
        guard isEnabled, mouseDownEvent != nil else { isPressed = false; return }
        let inside = pressArea.contains(convert(event.locationInWindow, from: nil))
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

    /// Opens what a right-click opens, for the keyboard and VoiceOver: from the control's middle. A control whose
    /// right-click acts by itself and returns no menu has already done so.
    @discardableResult
    func showContextMenu() -> Bool {
        guard isEnabled, let onRightClick, let window else { return false }
        let middle = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: convert(middle, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return false }
        guard let menu = onRightClick(event) else { return true }
        if drawsMenu { showDrawnMenu(menu, at: event.locationInWindow) } else { menu.popUp(positioning: nil, at: middle, in: self) }
        return true
    }

    /// The right-click menu as Zigzag's own (`MenuPanel`) rather than the system's: the sidebar's rows and buttons.
    var drawsMenu = false { didSet { updateTouchMenu() } }

    /// A finger held on a control with a drawn menu opens it (AppKit already does this for system menus), and held
    /// then moved, drags it (`dragsByTouch`).
    private var touchMenu: TouchPressRecognizer?

    private func updateTouchMenu() {
        let wanted = TouchGestures.isAvailable && ((drawsMenu && onRightClick != nil) || (dragsByTouch && onDragStart != nil))
        if wanted, touchMenu == nil {
            let press = TouchPressRecognizer { [weak self] press in self?.touchHoldChanged(press) }
            press.touchOnly.accepts = { [weak self] point in self?.ownsTouchMenu(at: point) ?? false }
            addGestureRecognizer(press)
            touchMenu = press
        } else if !wanted, let touchMenu {
            removeGestureRecognizer(touchMenu)
            self.touchMenu = nil
        }
        touchMenu?.liftsSooner(dragsByTouch && onDragStart != nil)
    }

    /// The finger's on this control's menu, not a nested control's own.
    private func ownsTouchMenu(at point: NSPoint) -> Bool {
        isEnabled && !TouchGestures.controlHasMenu(at: point, in: self)
    }

    /// A finger held at `point` (own coordinates): the menu a right-click there opens. Not while a menu is open
    /// (AppKit's own right-click from the hold).
    @discardableResult
    func touchHeld(at point: NSPoint) -> Bool {
        guard isEnabled, drawsMenu, let onRightClick, let window, MenuPanel.current == nil else { return false }
        let windowPoint = convert(point, to: nil)
        guard let event = TouchGestures.rightMouseDown(at: windowPoint, in: window) else { return false }
        if let menu = onRightClick(event) { showDrawnMenu(menu, at: windowPoint) }
        return true
    }

    private func touchHoldChanged(_ press: TouchPressRecognizer) {
        let point = press.location(in: nil)
        switch press.state {
        case .began:
            TouchLog.note("hold recognized, needs \(Int(press.minimumPressDuration * 1000)) ms (AppKit's \(Int(press.standardDuration * 1000)))")
            beginTouchHold(at: point)
        case .changed: TouchHold.current?.pressMoved(to: point)
        case .ended: TouchHold.current?.pressLifted(at: point)
        case .cancelled, .failed: TouchHold.current?.pressCancelled()
        default: break
        }
    }

    /// A finger held at `windowPoint`: the menu opens there a moment later, and moving off it picks the control up.
    @discardableResult
    func beginTouchHold(at windowPoint: NSPoint) -> TouchHold? {
        guard isEnabled, window != nil else { return nil }
        let point = convert(windowPoint, from: nil)
        let menu: (() -> MenuPanel?)? = drawsMenu && onRightClick != nil ? { [weak self] in
            guard let self, self.touchHeld(at: point) else { return nil }
            return MenuPanel.current?.anchor === self ? MenuPanel.current : nil
        } : nil
        let drag: ((NSPoint) -> Bool)? = dragsByTouch && onDragStart != nil ? { [weak self] start in
            guard let self, let window = self.window, let onDragStart = self.onDragStart,
                  let event = TouchPress.mouseDown(at: start, in: window) else { return false }
            self.isPressed = false
            return onDragStart(event)
        } : nil
        guard menu != nil || drag != nil else { return nil }
        isPressed = true
        return TouchHold.begin(on: self, at: windowPoint, openMenu: menu, startDrag: drag) { [weak self] in self?.isPressed = false }
    }

    #if DEBUG
    var touchMenuRecognizer: TouchPressRecognizer? { touchMenu }
    #endif

    // MARK: Lifted by a finger

    /// Held by a finger to be dragged: it rises a little off what it's on and follows the finger until picked up.
    private(set) var isTouchLifted = false
    /// How far the finger has moved it meanwhile, in its superview's terms.
    private(set) var touchLiftOffset = CGSize.zero

    func setTouchLifted(_ lifted: Bool, animated: Bool = true) {
        guard lifted != isTouchLifted else { return }
        isTouchLifted = lifted
        touchLiftOffset = .zero
        touchLiftChanged()
        applyTouchLift(animated: animated)
    }

    /// The finger went from `start` to `point` (window coordinates) while it's lifted.
    func followTouchLift(from start: NSPoint, to point: NSPoint) {
        guard isTouchLifted, !Tokens.Motion.reduceMotion, let superview else { return }
        let a = superview.convert(start, from: nil), b = superview.convert(point, from: nil)
        touchLiftOffset = CGSize(width: b.x - a.x, height: b.y - a.y)
        applyTouchLift(animated: false)
    }

    /// What else lifting changes in its look, for a subclass.
    func touchLiftChanged() {}

    /// How much larger it grows lifted: about six points across, at most 8%.
    nonisolated static func touchLiftScale(width: CGFloat) -> CGFloat { 1 + min(0.08, 6 / max(width, 1)) }

    private func applyTouchLift(animated: Bool) {
        guard let layer else { return }
        var target = CATransform3DIdentity
        if isTouchLifted, !Tokens.Motion.reduceMotion {
            let scale = Self.touchLiftScale(width: bounds.width)
            // Grown about its middle, wherever its anchor is.
            let middle = CGPoint(x: bounds.width * (0.5 - layer.anchorPoint.x), y: bounds.height * (0.5 - layer.anchorPoint.y))
            target = CATransform3DMakeTranslation(middle.x + touchLiftOffset.width, middle.y + touchLiftOffset.height, 0)
            target = CATransform3DScale(target, scale, scale, 1)
            target = CATransform3DTranslate(target, -middle.x, -middle.y, 0)
        }
        let from = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: "touchLift")
        Tokens.Motion.withoutAnimation { layer.transform = target }
        guard animated, !Tokens.Motion.reduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = Tokens.Motion.state
        animation.timingFunction = Tokens.Motion.easeOut
        layer.add(animation, forKey: "touchLift")
    }

    private func showDrawnMenu(_ menu: NSMenu, at windowPoint: NSPoint) {
        let entries = MenuPanel.entries(from: menu)
        guard !entries.isEmpty else { return }
        MenuPanel.show(entries, from: self, placement: .at(windowPoint))
    }

    override func accessibilityPerformShowMenu() -> Bool { showContextMenu() }

    /// Whether this control has a menu to show.
    var offersMenu: Bool { onRightClick != nil }

    /// VoiceOver offers Show Menu only on a control that has one.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(NSView.accessibilityPerformShowMenu) { return offersMenu }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    // MARK: Accessibility

    /// Roles VoiceOver treats as one element with role, name and state; its icons and labels aren't read separately (an
    /// icon would read as its symbol name). Plain container views stay out so their controls are reached one by one.
    static let controlRoles: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton,
                                                           .disclosureTriangle, .row, .cell, .slider, .incrementor, .link, .menuItem]
    /// Container roles: an element only when named (a toolbar).
    private static let containerRoles: Set<NSAccessibility.Role> = [.group, .toolbar, .list, .radioGroup, .sheet, .menu]

    /// Set by `setAccessibilityElement`; overrides the role.
    private var elementChoice: Bool?

    override func setAccessibilityElement(_ isElement: Bool) {
        elementChoice = isElement
        super.setAccessibilityElement(isElement)
    }

    /// A control role, or no role but handles clicks.
    var isAccessibilityControl: Bool {
        guard let role = super.accessibilityRole(), role != .unknown else { return onClick != nil }
        return Self.controlRoles.contains(role)
    }

    override func isAccessibilityElement() -> Bool {
        if let elementChoice { return elementChoice }
        if isAccessibilityControl { return true }
        guard let role = super.accessibilityRole(), Self.containerRoles.contains(role) else { return false }
        return !(super.accessibilityLabel() ?? "").isEmpty
    }

    /// A clickable view with no role reads as a button.
    override func accessibilityRole() -> NSAccessibility.Role? {
        let own = super.accessibilityRole()
        guard own == nil || own == .unknown, onClick != nil else { return own }
        return .button
    }

    /// The given label, else the tooltip without its shortcut, else the shown text.
    override func accessibilityLabel() -> String? {
        if let own = super.accessibilityLabel(), !own.isEmpty { return own }
        guard isAccessibilityControl else { return super.accessibilityLabel() }
        if let tip = toolTip, !tip.isEmpty { return IconButton.withoutShortcut(tip) }
        let words = Self.shownWords(in: self)
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    /// Text from the control's own labels, leading to trailing, excluding nested controls.
    private static func shownWords(in view: NSView) -> [String] {
        view.subviews.filter { !$0.isHidden }.flatMap { child -> [String] in
            if child is InteractiveView { return [] }
            if let field = child as? NSTextField, !field.isEditable {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [text]
            }
            return shownWords(in: child)
        }
    }

    /// A control's icons and labels: read via the control, never alone.
    static func isDecoration(_ element: Any) -> Bool {
        // AppKit hands VoiceOver the cell instead of the control.
        if let cell = element as? NSCell { return cell.controlView.map(isDecoration) ?? (cell is NSImageCell) }
        if element is NSImageView { return true }
        if let field = element as? NSTextField, !field.isEditable { return true }
        return false
    }

    /// A control or drawn text line that speaks for its icons and labels. Groups keep their children.
    private var isDrawnControlElement: Bool {
        guard isAccessibilityElement() else { return false }
        return !(super.accessibilityRole().map(Self.containerRoles.contains) ?? false)
    }

    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren()
        guard isDrawnControlElement else { return children }
        return children?.filter { !Self.isDecoration($0) }
    }

    /// VoiceOver under the pointer hits the control, not its icon or text.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var found: Any?
        MainActor.assumeIsolated {
            let hit = super.accessibilityHitTest(point)
            found = isDrawnControlElement && hit.map(Self.isDecoration) == true ? self : hit
        }
        return found
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

    static var keyboardAccess: Bool {
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
        // Control-Return opens the right-click menu, as it does across the Mac with Full Keyboard Access.
        if hasKeyboardFocus, event.modifierFlags.intersection([.command, .option, .control]) == .control,
           [36, 76].contains(event.keyCode), showContextMenu() { return }
        super.keyDown(with: event)
    }

    /// Keyboard focus, drawn as the design has it rather than the system's blue: a ring in the window's accent just
    /// outside the control, following its rounded shape. Only the keyboard brings it; a click never does.
    private var focusRing: CAShapeLayer?
    /// A field's ring: brighter, with a soft glow of the accent around it (the address).
    var focusRingGlows = false

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
            let accent = Brand.Theme.for(self).accent
            ring.strokeColor = cgColor(accent.withAlphaComponent(focusRingGlows ? 0.9 : Tokens.Color.focusAlpha))
            ring.shadowPath = focusRingGlows ? ring.path?.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 0) : nil
            ring.shadowColor = cgColor(accent)
            ring.shadowRadius = Tokens.Material.focusGlow
            ring.shadowOffset = .zero
            ring.shadowOpacity = focusRingGlows ? 0.5 : 0
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

    /// A control's menu always comes from `onRightClick`, so a right-click, Control-Return and VoiceOver's Show Menu
    /// all find the same one. Final, so no control can give a menu that only the mouse reaches.
    override final func menu(for event: NSEvent) -> NSMenu? {
        guard drawsMenu else { return onRightClick?(event) }
        // Drawn menus open from `rightMouseDown` and `mouseDown`, never from AppKit's menu tracking.
        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard drawsMenu, let onRightClick else { return super.rightMouseDown(with: event) }
        if let menu = onRightClick(event) { showDrawnMenu(menu, at: event.locationInWindow) }
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
    /// How big a full-color image is drawn; a site's icon by default.
    var imageSide = Tokens.Metric.favicon { didSet { needsLayout = true } }
    var tint: NSColor = Tokens.Color.icon { didSet { stateDidChange(animated: false) } }
    var radius: CGFloat = Tokens.Radius.control { didSet { layer?.cornerRadius = radius } }
    var showsFillAtRest = false { didSet { stateDidChange(animated: false) } }
    /// The symbol's size; a button that lives on through a change of the sidebar's size takes the new one.
    var symbolSize: CGFloat {
        didSet {
            guard oldValue != symbolSize, image == nil, glyph == nil else { return }
            imageView.image = Tokens.Symbol.image(symbol, size: symbolSize)
            needsLayout = true
        }
    }

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
        // Read the button's label, not the symbol name ("split view horizontally left").
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        self.toolTip = toolTip
        setAccessibilityRole(.button)
    }

    /// The tooltip is the button's name, so VoiceOver reads whatever it says now (Reload or Stop, Mute or Unmute).
    /// The shortcut the tooltip ends with stays out of it: "Back", not "Back (⌘[)".
    override var toolTip: String? {
        didSet { setAccessibilityLabel(toolTip.map(Self.withoutShortcut)) }
    }

    /// "Back (⌘[)" → "Back". Full-width parentheses too, as a translation may set them ("返回（⌘[）").
    static func withoutShortcut(_ tip: String) -> String {
        tip.replacingOccurrences(of: #"\s*[(（][⌃⌥⇧⌘][^()（）]*[)）]\s*$"#, with: "", options: .regularExpression)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if image != nil {
            let side = imageSide
            imageView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        } else if glyph == nil {
            // The symbol's ink, not its image, in the middle.
            let ink = Tokens.Symbol.inkOffset(symbol, size: symbolSize)
            // The image at its own size on the screen's pixels: centered by the image view, it snaps to whole points.
            let size = imageView.image?.size ?? bounds.size
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let x = bounds.midX - size.width / 2 - ink.width, y = bounds.midY - size.height / 2 + (isFlipped ? ink.height : -ink.height)
            imageView.frame = NSRect(x: round(x * scale) / scale, y: round(y * scale) / scale, width: size.width, height: size.height)
        } else {
            // The glyph's own ink goes in the middle (a play triangle leans right in its image).
            let ink = glyphInk
            imageView.frame = bounds.offsetBy(dx: -ink.width, dy: isFlipped ? ink.height : -ink.height)
        }
    }

    /// Where the glyph's ink sits from its image's middle; set with the glyph.
    var glyphInk: CGSize = .zero { didSet { needsLayout = true } }

    /// Chosen, it's the soft card (`applyRowStyle`) rather than the hover fill: a choice among many, like an icon
    /// in a grid.
    var selectsAsCard = false { didSet { stateDidChange(animated: false) } }

    /// The window's own toolbar and bottom bar: a step crisper glyph (`Color.chromeIcon`); the usual quiet hover
    /// and press fills.
    var isChrome = false { didSet { if isChrome { tint = Tokens.Color.chromeIcon } } }
    /// On a page's own color (the bar above the page), not the frame: the neutral hover and press fills, which show
    /// on any color, rather than the frame's white washes.
    var isOnPage = false { didSet { if isOnPage != oldValue { stateDidChange(animated: false) } } }
    /// The page's color under it while `isOnPage`, which its hover and press washes are measured against.
    var ground: NSColor? { didSet { if ground != oldValue { stateDidChange(animated: false) } } }

    /// Over a playing video (the mini player): a white glyph on a soft shadow, a round target, and white washes for
    /// hover and press (`Color.mediaHover`, `mediaPressed`) that show over any picture. The glyph's shadow goes
    /// while the wash is under it, so the wash isn't ringed by it.
    var isOverMedia = false {
        didSet {
            guard isOverMedia != oldValue else { return }
            if isOverMedia {
                tint = .white
                radius = bounds.width / 2
                layer?.shadowColor = .black
                layer?.shadowRadius = 4
                layer?.shadowOffset = .zero
            }
            stateDidChange(animated: false)
        }
    }

    override func stateDidChange(animated: Bool) {
        if isOverMedia {
            let fill: NSColor? = !isEnabled ? nil : isPressed ? Tokens.Color.mediaPressed : isHovered ? Tokens.Color.mediaHover : nil
            layer?.set(backgroundColor: fill?.cgColor, animated: animated && !isHovered)
            Tokens.Motion.withoutAnimation { layer?.shadowOpacity = fill == nil ? 0.6 : 0 }
            imageView.contentTintColor = image == nil ? tint : nil
            imageView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
            return
        }
        if selectsAsCard {
            applyRowStyle(animated: animated)
            imageView.contentTintColor = image == nil ? (isSelected ? Tokens.Color.textPrimary : tint) : nil
            imageView.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
            return
        }
        let grounds = isOnPage ? [ground].compactMap { $0 } : isChrome ? frameGrounds : []
        let pressed = Tokens.Chrome.buttonWash(pressed: true, on: grounds)
        let hover = Tokens.Chrome.buttonWash(pressed: false, on: grounds)
        let fill: NSColor? = !isEnabled ? nil : isPressed ? pressed : (isHovered || isSelected) ? hover : showsFillAtRest ? Tokens.Color.fieldFill : nil
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

    /// Long text fades out at its end instead of "…", with the same cut whether or not a hover button covers it, so it
    /// doesn't shift on hover. The owner calls `fadeTail` after placing it.
    var fadesTail = false {
        didSet { lineBreakMode = fadesTail ? .byClipping : .byTruncatingTail }
    }

    /// Fade length.
    static let tailFade = Tokens.Space.x4

    /// Fades out before `end` (local coordinates; where a button covers it), or at its own end when it doesn't fit. No
    /// fade when it fits uncovered.
    func fadeTail(endingAt end: CGFloat? = nil) {
        #if DEBUG
        fadesAsked += 1
        #endif
        let room = bounds.width - Label.inset * 2
        let stop = end ?? (inkWidth > room + 0.5 ? bounds.width - Label.inset : nil)
        // Called on every row layout: skip when size and stop are unchanged.
        let wanted = Fade(size: bounds.size, stop: stop)
        if wanted == lastFade, (stop == nil || bounds.width <= 0) == (layer?.mask == nil) { return }
        lastFade = wanted
        guard let stop, bounds.width > 0 else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        wantsLayer = true
        guard let layer else { return }
        let fade = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        let start = max(0, stop - Self.tailFade)
        Tokens.Motion.withoutAnimation {
            fade.frame = layer.bounds
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            let width = bounds.width
            fade.locations = [0, NSNumber(value: Double(start / width)), NSNumber(value: Double(max(start, stop) / width)), 1]
        }
        if layer.mask !== fade { layer.mask = fade }
    }

    /// Last drawn fade: size and stop.
    private struct Fade: Equatable {
        var size: NSSize
        var stop: CGFloat?
    }
    private var lastFade: Fade?

    /// New backing scale: `centeredY` was for the old pixels, so the parent relayouts.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        superview?.needsLayout = true
    }

    /// Exact width of the text, plus the cell's own padding.
    var textWidth: CGFloat { inkWidth + Tokens.Space.x2 }

    /// Text width without `textWidth`'s padding, for pill layout. Styled text is measured as drawn, tracking included.
    /// Cached per text, font and tracking since sidebar rows ask on every layout.
    var inkWidth: CGFloat {
        let font = self.font ?? Tokens.Font.body()
        let text = stringValue
        // Invalidated when text or font is set through the label; also checked here for changes made via the cell.
        if let measured = measuredInk, measured.text == text, measured.fontName == font.fontName, measured.pointSize == font.pointSize {
            return measured.width
        }
        let styled = attributedStringValue
        let kern = styled.length > 0 ? styled.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber : nil
        let width = kern != nil ? ceil(styled.size().width) : ceil((text as NSString).size(withAttributes: [.font: font]).width)
        measuredInk = MeasuredInk(text: text, fontName: font.fontName, pointSize: font.pointSize, width: width)
        return width
    }

    /// Cached `inkWidth` and its inputs. Tracking isn't stored: it only comes with styled text set through the label,
    /// which invalidates the cache.
    private struct MeasuredInk: Equatable {
        var text: String
        var fontName: String
        var pointSize: CGFloat
        var width: CGFloat
    }
    private var measuredInk: MeasuredInk? { didSet { if measuredInk == nil { lastFade = nil } } }

    override var stringValue: String { didSet { measuredInk = nil } }
    override var attributedStringValue: NSAttributedString { didSet { measuredInk = nil } }
    override var font: NSFont? { didSet { measuredInk = nil } }

    #if DEBUG
    /// For tests.
    var hasMeasuredInk: Bool { measuredInk != nil }
    /// For tests.
    var fadesAsked = 0
    #endif

    /// The label's built-in inset on each side, so text can sit exactly where it's placed.
    static let inset: CGFloat = 2

    /// Height of one line in this label's font.
    var lineHeight: CGFloat { ceil(intrinsicContentSize.height) }

    private struct CapsKey: Hashable {
        var fontName: String
        var pointSize: CGFloat
        var lineHeight: CGFloat
    }
    private static var capsOffsets: [CapsKey: CGFloat] = [:]

    /// How far below the line's middle the caps' middle sits, measured once per font by drawing capitals (cell insets
    /// and font metrics both affect it).
    static func capsBelowMiddle(of font: NSFont, lineHeight: CGFloat) -> CGFloat {
        let key = CapsKey(fontName: font.fontName, pointSize: font.pointSize, lineHeight: lineHeight)
        if let known = capsOffsets[key] { return known }
        let probe = NSTextField(labelWithString: "HOEX")
        probe.font = font
        probe.frame = NSRect(x: 0, y: 0, width: ceil(probe.intrinsicContentSize.width) + 4, height: lineHeight)
        let scale: CGFloat = 4
        var offset: CGFloat = 0
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(probe.frame.width * scale), pixelsHigh: Int(lineHeight * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = probe.frame.size
            probe.cacheDisplay(in: probe.bounds, to: rep)
            var top = -1, bottom = -1
            for y in 0..<rep.pixelsHigh {
                var inked = false
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked = true; break }
                if inked { if top < 0 { top = y }; bottom = y }
            }
            if top >= 0 { offset = (CGFloat(top) + CGFloat(bottom + 1)) / 2 / scale - lineHeight / 2 }
        }
        capsOffsets[key] = offset
        return offset
    }
}

extension NSTextField {
    /// Y that centers the caps in `height` on pixel boundaries. Centering the line box leaves caps low (the system font
    /// draws caps below the line's middle, more at larger sizes). Fields use the same placement as labels so text
    /// doesn't jump when one replaces the other.
    func centeredY(in height: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineHeight = ceil(intrinsicContentSize.height)
        // Flipped views run y down, so the text moves up by the offset.
        let below = Label.capsBelowMiddle(of: font ?? Tokens.Font.body(), lineHeight: lineHeight)
        let y = (height - lineHeight) / 2 + ((superview?.isFlipped ?? true) ? -below : below)
        return (y * scale).rounded() / scale
    }

    /// The caps' top and bottom (the baseline) inside one line box, top down: for spacing by the ink, not the box.
    var capsSpan: (top: CGFloat, bottom: CGFloat) {
        let font = font ?? Tokens.Font.body()
        let lineHeight = ceil(intrinsicContentSize.height)
        let middle = lineHeight / 2 + Label.capsBelowMiddle(of: font, lineHeight: lineHeight)
        return (middle - font.capHeight / 2, middle + font.capHeight / 2)
    }
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

/// A scroll view whose scrollers lie over what it shows and never take room from it. A Mac with a mouse plugged in
/// prefers scrollers that do, and gives every scroll view that style again whatever it was set to: then what the
/// view shows gets narrower whenever a scroller appears, and a layout can't know its width from its frame.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
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

/// A text button: quiet text that fills under the pointer ("Clear", "Skip"), or with `form` the secondary look
/// (`ButtonLook.secondary`). Kept for the forms that still build on it; new code uses `PillButton`.
final class TextButton: InteractiveView {
    let label: Label
    /// The secondary look (white, a hairline, a faint shadow) rather than text alone.
    var showsFillAtRest = false { didSet { needsLayout = true; stateDidChange(animated: false) } }
    /// Overrides the label color (destructive actions).
    var textColor: NSColor? { didSet { stateDidChange(animated: false) } }
    /// Moves the title off center, to leave room for something beside it (a keycap).
    var labelOffset: CGFloat = 0 { didSet { needsLayout = true } }

    init(title: String, font: NSFont = Tokens.Font.small(.medium)) {
        written = title
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

    private var written = ""
    var title: String {
        get { written }
        set {
            written = newValue
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

    /// Distance from the button edge to its text at fitting width, so text-only buttons align with content above and
    /// below.
    var textInset: CGFloat { (fittingWidth - label.inkWidth) / 2 }

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
        label.frame = NSRect(x: labelOffset, y: label.centeredY(in: bounds.height), width: bounds.width, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let ink = applyButtonLook(showsFillAtRest ? .secondary : .quiet)
        // Text-only buttons use the disabled ink rather than fading.
        if !showsFillAtRest { alphaValue = 1 }
        // Custom-colored text (Back and Skip on the welcome's blue) fades its own color; the neutral gray goes muddy
        // there.
        label.textColor = isEnabled || showsFillAtRest ? textColor ?? ink : textColor.map(Self.disabledInk) ?? Tokens.Color.textDisabled
        label.alphaValue = 1
    }

    /// Share of a custom color kept when disabled: fainter, still 3:1 on its intended background.
    nonisolated static let disabledFade: CGFloat = 0.8

    /// `color` faded for a disabled button, in the current appearance.
    nonisolated static func disabledInk(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var faded = color
            appearance.performAsCurrentDrawingAppearance {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                faded = resolved.withAlphaComponent(resolved.alphaComponent * disabledFade)
            }
            return faded
        }
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

    /// Shows the focus ring as soon as the field takes focus, not on first keystroke; watches the first responder since
    /// the delegate isn't told.
    private var responderWatch: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderWatch = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateColors() }
        }
        updateColors()
    }

    /// The page look: white with a hairline edge and a faint shadow, like the secondary button beside it, where a
    /// panel's field is a soft fill. A page's header sets it for its search.
    var isOutlined = false { didSet { updateColors(); needsLayout = true } }

    /// Invalid content: the border turns the warning color, so a blocked form shows which field holds it up.
    var isInvalid = false { didSet { guard isInvalid != oldValue else { return }; updateColors() } }

    /// On the window's colored frame rather than a panel: the sidebar address's soft fill (`Chrome.field`).
    var isOnFrame = false { didSet { updateColors() } }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isOnFrame ? Tokens.Chrome.field : isOutlined ? Tokens.Color.controlFill : Tokens.Color.fieldFill).cgColor
            let ring = (tint ?? Brand.Theme.for(self).accent).withAlphaComponent(Tokens.Color.focusAlpha)
            layer?.borderColor = (isInvalid ? Tokens.Color.destructive
                                             : isEditing ? ring : isOutlined ? Tokens.Color.controlEdge : .clear).cgColor
            layer?.borderWidth = isInvalid || isEditing ? 1.5 : isOutlined ? Tokens.Metric.hairline : 1.5
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
    /// Its padding is the field's: a press there types, never drags the window.
    override var mouseDownCanMoveWindow: Bool { false }

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
        field.frame = NSRect(x: x, y: field.centeredY(in: bounds.height), width: bounds.width - x - Tokens.Space.x3, height: h)
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
        label = Label(title, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
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
        label.frame = NSRect(x: check.frame.maxX + Tokens.Space.x1 - Label.inset, y: label.centeredY(in: bounds.height), width: label.inkWidth + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        // A check and a word, nothing behind them until the pointer comes: the choice reads from the check alone.
        let tint = tint ?? Brand.Theme.for(self).accent
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        label.textColor = isOn ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        check.image = Tokens.Symbol.image(isOn ? "checkmark" : "plus", size: Tokens.Symbol.inline)
        check.contentTintColor = isOn ? tint : Tokens.Color.textTertiary
    }
}

/// A checkbox and its words, the whole row taking the click. Off, a white box with a hairline like a secondary
/// button; on, the box fills with the accent and shows a bold check. The words wrap to two lines when narrow.
final class Checkbox: InteractiveView {
    private let label: Label
    private let box = NSView()
    private let check = NSImageView()
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { if oldValue != isOn { stateDidChange(animated: false) } } }
    /// Nil takes its window's accent.
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }
    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            needsLayout = true
        }
    }

    static let side: CGFloat = 14
    static let boxRadius: CGFloat = Tokens.Radius.small
    /// Box to words.
    static let gap: CGFloat = Tokens.Space.x2

    init(title: String = "") {
        label = Label(title, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 2
        box.wantsLayer = true
        box.layer?.cornerRadius = Self.boxRadius
        box.layer?.cornerCurve = .continuous
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        check.imageScaling = .scaleNone
        box.addSubview(check)
        [box, label].forEach { addSubview($0) }
        layer?.cornerRadius = Self.boxRadius
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

    private var textX: CGFloat { Self.side + Self.gap }

    /// One line's width: the box, the gap and the words.
    var fittingWidth: CGFloat { ceil(textX + label.inkWidth) }

    /// One line, or two when the words don't fit in `width`.
    func height(for width: CGFloat) -> CGFloat {
        let room = width - textX
        guard label.inkWidth > room else { return max(Self.side, label.lineHeight) }
        let wrapped = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: room + Label.inset * 2, height: 200)).height ?? label.lineHeight
        return max(Self.side, ceil(wrapped))
    }

    override func layout() {
        super.layout()
        let line = label.lineHeight
        // The box sits on the first line's caps.
        let scale = window?.backingScaleFactor ?? 2
        let below = Label.capsBelowMiddle(of: label.font ?? Tokens.Font.body(), lineHeight: line)
        let y = ((line / 2 + below - Self.side / 2) * scale).rounded() / scale
        box.frame = NSRect(x: 0, y: max(0, y), width: Self.side, height: Self.side)
        let size = check.image?.size ?? .zero
        check.frame = NSRect(x: round((Self.side - size.width) / 2), y: round((Self.side - size.height) / 2), width: size.width, height: size.height)
        label.frame = NSRect(x: textX - Label.inset, y: 0, width: bounds.width - textX + Label.inset * 2, height: bounds.height)
    }

    override func stateDidChange(animated: Bool) {
        let accent = tint ?? Brand.Theme.for(self).accent
        let fill: NSColor
        if isOn {
            fill = isPressed ? (accent.shadow(withLevel: 0.15) ?? accent) : isHovered ? (accent.highlight(withLevel: 0.08) ?? accent) : accent
        } else {
            fill = isPressed ? Tokens.Color.controlPressed : isHovered ? Tokens.Color.controlHover : Tokens.Color.controlFill
        }
        box.layer?.set(backgroundColor: cgColor(fill), animated: false)
        Tokens.Motion.withoutAnimation {
            box.layer?.borderWidth = isOn ? 0 : Tokens.Metric.hairline
            box.layer?.borderColor = cgColor(Tokens.Color.controlEdge)
        }
        check.isHidden = !isOn
        check.contentTintColor = tint.map(Brand.ink(on:)) ?? Brand.Theme.for(self).onAccent
        label.textColor = isEnabled ? Tokens.Color.textPrimary : Tokens.Color.textDisabled
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

/// A slide switch, as on a good piece of hardware: a small round knob in a recessed track. Off, a porcelain knob on
/// the left of a neutral track; on, the knob slides right and the track fills with the space's own accent, so on
/// reads at a glance. It stretches a little while held, so a press reads at once; with Reduce Motion it moves at
/// once and only the color fades.
final class Toggle: InteractiveView {
    private let knob = CALayer()
    /// The track's recess: shade under its upper lip.
    private let recess = CAGradientLayer()
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { if oldValue != isOn { update(animated: window != nil) } } }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Tokens.Metric.toggleSize))
        layer?.cornerRadius = Tokens.Metric.toggleSize.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Tokens.Metric.hairline
        layer?.masksToBounds = false
        recess.cornerCurve = .continuous
        layer?.addSublayer(recess)
        knob.cornerRadius = Tokens.Metric.toggleKnob / 2
        knob.cornerCurve = .continuous
        knob.borderWidth = 0.5
        knob.shadowOpacity = 1
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
        Tokens.Motion.withoutAnimation {
            recess.frame = bounds
            recess.cornerRadius = bounds.height / 2
            knob.frame = knobFrame
        }
    }

    private func update(animated: Bool) {
        if animated && !Tokens.Motion.reduceMotion {
            // The knob travels its short way eased out, from wherever it is, like a slider meeting its stop.
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = knob.presentation()?.position.x ?? knob.position.x
            move.toValue = knobFrame.midX
            move.duration = Tokens.Motion.state
            move.timingFunction = Tokens.Motion.easeOut
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
        // Off, the recess: a matte track a step darker than what it's set in, deeper under the pointer (`Switch`).
        // On, the track is the space's accent, a step deeper under the pointer and pressed.
        typealias S = Tokens.Switch
        let accent = Brand.Theme.for(self).accent
        let track = isOn ? (isPressed ? accent.withSystemEffect(.pressed) : isHovered ? accent.withSystemEffect(.rollover) : accent)
            : (isPressed ? S.trackPressed : isHovered ? S.trackHover : S.track)
        layer?.set(backgroundColor: cgColor(track), animated: fading, duration: Tokens.Motion.state)
        knob.set(backgroundColor: cgColor(isOn ? S.knobOn : S.knob), animated: fading, duration: Tokens.Motion.state)
        Tokens.Motion.withoutAnimation {
            layer?.borderColor = cgColor(isOn ? S.edgeOn : S.edge)
            recess.colors = [cgColor(S.recess), cgColor(NSColor.clear)]
            recess.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
            recess.endPoint = CGPoint(x: 0.5, y: isFlipped ? S.recessDepth : 1 - S.recessDepth)
            knob.borderColor = cgColor(S.knobEdge)
            knob.shadowColor = cgColor(S.knobShadow)
            knob.shadowRadius = S.knobShadowRadius
            knob.shadowOffset = CGSize(width: 0, height: isFlipped ? S.knobShadowDrop : -S.knobShadowDrop)
        }
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

/// Dropdown menus in a column (a settings group) share the widest one's width.
final class DropdownWidthGroup {
    private let members = NSHashTable<DropdownButton>.weakObjects()
    private var updating = false

    func add(_ button: DropdownButton) {
        members.add(button)
        button.widthGroup = self
    }

    var width: CGFloat { members.allObjects.filter { !$0.showsPictureOnly }.map(\.naturalWidth).max() ?? 0 }

    /// A member's choices changed: recompute the width.
    func changed() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        for button in members.allObjects {
            button.invalidateIntrinsicContentSize()
            button.superview?.needsLayout = true
        }
    }
}

final class DropdownButton: InteractiveView {
    struct Option {
        var title: String
        var image: NSImage?
        init(title: String, image: NSImage? = nil) { self.title = title; self.image = image }
    }
    private let label = Label("", font: Tokens.Font.control(), color: Tokens.Color.textPrimary)
    private let icon = NSImageView()
    private let chevron = NSImageView()
    /// Something its menu offers to do, after the choices: it runs, and the choice stays what it was.
    struct Action {
        var title: String
        var symbol: String?
        var run: () -> Void
    }
    var options: [Option] = [] { didSet { refresh() } }
    var selectedIndex = 0 { didSet { refresh() } }
    var onSelect: ((Int) -> Void)?
    /// Under the choices, after a line: making a new thing to choose ("New Profile…").
    var actions: [Action] = []
    /// Secondary look, or primary where it stands in for a filled answer. `tint` uses the window's accent as the fill.
    var look: ButtonLook = .secondary { didSet { stateDidChange(animated: false) } }
    /// The menu follows the button's appearance, not the window's (a card in the page's look).
    var menuTakesOwnLook = false
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }
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

    /// Where there's little room, only the choice's picture shows; its name is in the tooltip and for VoiceOver.
    /// For choices that each have a picture.
    var showsPictureOnly = false { didSet { if showsPictureOnly != oldValue { refresh() } } }

    private func refresh() {
        label.stringValue = current?.title ?? ""
        label.isHidden = showsPictureOnly
        if showsPictureOnly { toolTip = current?.title }
        else if isEnabled { toolTip = nil }
        // A neutral globe where a site's icon is missing, so the column of pictures never has a gap.
        let pictured = options.contains { $0.image != nil }
        icon.image = current?.image ?? (pictured ? MenuPanel.placeholder : nil)
        icon.contentTintColor = Tokens.Color.icon
        icon.isHidden = icon.image == nil
        setAccessibilityValue(label.stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        widthGroup?.changed()
    }

    /// Shared width so stacked menus line up.
    weak var widthGroup: DropdownWidthGroup? { didSet { oldValue?.changed(); widthGroup?.changed() } }

    /// Fits the longest choice, like a pop-up button.
    var naturalWidth: CGFloat {
        let widest = options.map { ($0.title as NSString).size(withAttributes: [.font: Tokens.Font.control()]).width }.max() ?? 0
        let iconWidth: CGFloat = options.contains { $0.image != nil } ? Self.iconSide + Tokens.Space.x2 : 0
        if showsPictureOnly { return ceil(Self.textInset + iconWidth + 10 + Self.textInset) }
        return ceil(Self.textInset + iconWidth + widest + Tokens.Space.x3 + 10 + Self.textInset)
    }

    override var intrinsicContentSize: NSSize {
        let shared = showsPictureOnly ? 0 : widthGroup?.width ?? 0
        return NSSize(width: max(naturalWidth, shared), height: Tokens.Page.controlHeight)
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
        label.frame = NSRect(x: x - Label.inset, y: label.centeredY(in: bounds.height), width: max(0, chevron.frame.minX - x - Tokens.Space.x1), height: label.lineHeight)
        // A choice cut short (a long profile name) shows whole under the pointer (#189).
        if !showsPictureOnly, isEnabled { toolTip = label.frame.width < label.textWidth - Tokens.Space.x1 ? current?.title : nil }
    }

    func openMenu() {
        guard isEnabled, !options.isEmpty, MenuPanel.current?.anchor !== self else { return }
        var items: [MenuPanel.Entry] = options.enumerated().map { index, option in
            .item(MenuPanel.Item(title: option.title, image: option.image, isChecked: index == selectedIndex) { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.onSelect?(index)
            })
        }
        if !actions.isEmpty {
            items.append(.separator)
            items += actions.map { action in .item(MenuPanel.Item(title: action.title, symbol: action.symbol, action: action.run)) }
        }
        openedAt = ProcessInfo.processInfo.systemUptime
        menuOpen = true
        MenuPanel.show(items, from: self, placement: .over(selectedIndex, textInset: Self.textInset), minWidth: bounds.width,
                       appearance: menuTakesOwnLook ? effectiveAppearance : nil) { [weak self] in
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

    override var offersMenu: Bool { true }
    override func accessibilityPerformShowMenu() -> Bool { openMenu(); return true }

    override func stateDidChange(animated: Bool) {
        let ink = applyButtonLook(look, tint: look == .primary ? tint : nil)
        // Open menus highlight the control, unless the filled look already does.
        if menuOpen, look == .secondary { layer?.set(backgroundColor: cgColor(Tokens.Color.controlHover), animated: false) }
        label.textColor = ink
        chevron.contentTintColor = look == .primary ? ink : Tokens.Color.textSecondary
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

/// A floating list's one highlight (`Color.highlight`, `Radius.row`): it glides from row to row under the pointer
/// rather than each row lighting on its own. From the keyboard, arriving from nothing or with Reduce Motion it's
/// simply there; leaving every row, it fades. Put it behind the rows.
final class HighlightGlide: ColorView {
    init() {
        super.init(color: Tokens.Color.highlight)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Moves to `target`, or fades for nil. `wasShown`: it was on a row before this change.
    func move(to target: NSRect?, wasShown: Bool) {
        guard let target else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Tokens.Motion.quick
                context.timingFunction = Tokens.Motion.easeOut
                animator().alphaValue = 0
            }
            return
        }
        if !wasShown || alphaValue == 0 || Tokens.Motion.isFromKey || Tokens.Motion.reduceMotion {
            layer?.removeAllAnimations()
            Tokens.Motion.withoutAnimation { frame = target }
            alphaValue = 1
        } else {
            alphaValue = 1
            Tokens.Motion.glide(self, to: target, duration: Tokens.Motion.highlightGlide, timing: Tokens.Motion.easeOut)
        }
    }

    /// Keeps it on its row through a relayout, without a glide.
    func follow(_ target: NSRect) { Tokens.Motion.withoutAnimation { frame = target } }

    /// Pressed, it darkens a step.
    func showPressed(_ pressed: Bool) { color = pressed ? Tokens.Color.pressedFill : Tokens.Color.highlight }
}

/// What an AppKit menu item carries, as its represented object, for its row in a drawn menu: its symbol, and
/// whether it's destructive.
protocol MenuItemStyle: AnyObject {
    var symbol: String? { get }
    var isDestructive: Bool { get }
}

/// Zigzag's own menu, drawn rather than the system's, for choosing from a list (a dropdown's options) or acting on
/// something (a button's few actions): a solid panel with a hairline edge and the panel shadow, 15pt items, a soft gray
/// row under the pointer or the arrow keys, a check at the trailing end of the chosen one. It arrives in a quick fade
/// from a touch smaller and leaves the same way; opened or closed from the keyboard it's simply there.
/// Keys: Up and Down move, Return or Space chooses, Esc closes, and typing a name jumps to it. An item with a submenu
/// opens it beside itself on hover, Right or Return; Left or Esc closes just that. Right-click menus stay the
/// system's, except the sidebar's, which match its +.
final class MenuPanel: FloatingPanelView {
    override var replacesExtensionPopup: Bool { true }
    enum Entry {
        case item(Item)
        /// A quiet heading over the items after it ("Save Downloads To").
        case header(String)
        case separator
        /// Words that explain, wrapped to the menu's width (a help button's few lines).
        case note(NSAttributedString)
    }

    struct Item {
        var title: String
        var image: NSImage?
        var symbol: String?
        var isChecked = false
        var isDestructive = false
        var isEnabled = true
        /// Its keyboard shortcut as the menu bar has it now ("⌘T"), quiet at the trailing end; empty for none.
        var shortcut: String
        /// Items opened beside this one, as a submenu; an item with them has no action of its own.
        var submenu: [Entry]?
        var action: () -> Void

        init(title: String, image: NSImage? = nil, symbol: String? = nil, isChecked: Bool = false, isDestructive: Bool = false,
             isEnabled: Bool = true, shortcut: String = "", submenu: [Entry]? = nil, action: @escaping () -> Void) {
            self.title = title; self.image = image; self.symbol = symbol; self.isChecked = isChecked
            self.isDestructive = isDestructive; self.isEnabled = isEnabled; self.shortcut = shortcut; self.submenu = submenu
            self.action = action
        }
    }

    /// An AppKit menu's items as drawn entries: titles, pictures, checks, dimmed items, shortcuts, headers and
    /// submenus, each item doing what choosing it in the AppKit menu does.
    static func entries(from menu: NSMenu) -> [Entry] {
        var entries: [Entry] = []
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                if let last = entries.last, case .separator = last { continue }
                if !entries.isEmpty { entries.append(.separator) }
                continue
            }
            if item.isSectionHeader { entries.append(.header(item.title)); continue }
            let style = item.representedObject as? MenuItemStyle
            let submenu = item.submenu.map(entries(from:))
            entries.append(.item(Item(title: item.title, image: style?.symbol == nil ? item.image : nil, symbol: style?.symbol,
                                      isChecked: item.state == .on, isDestructive: style?.isDestructive ?? false, isEnabled: item.isEnabled,
                                      shortcut: Shortcuts.caps(item).joined(), submenu: submenu) { [item] in
                guard let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }))
        }
        if let last = entries.last, case .separator = last { entries.removeLast() }
        return entries
    }

    /// Where it opens: with item `index` right over the control, its text `textInset` from the control's edge, as a
    /// pop-up button's menu does (below it when there's no room); under the control, as a button's menu does (its
    /// trailing edge lined up with the control's when the control is in the window's right half); above
    /// it with their trailing edges lined up, for a button at the bottom of the window (the sidebar's +); or with its
    /// top left corner at a point in the window, as a right-click's menu opens under the pointer.
    enum Placement { case over(Int, textInset: CGFloat), below, aboveTrailing, at(NSPoint) }

    /// The menu that's open, if any. Panels that close on Esc or a click elsewhere leave those to it while it's open.
    static weak var current: MenuPanel?
    private(set) weak var anchor: NSView?

    private let entries: [Entry]
    private var rows: [Row] = []
    private var notes: [NSTextField] = []
    /// The width notes wrap to, set once the menu's width is known.
    private var noteWidth: CGFloat = 0
    private let scroll = NSScrollView()
    private let list = FlippedView()
    /// One soft gray pill that glides from row to row under the pointer, rather than each row lighting on its own.
    private let pill = HighlightGlide()
    private var highlighted: Int? {
        didSet {
            rows.enumerated().forEach { $0.element.isHighlighted = $0.offset == highlighted }
            movePill(from: oldValue)
            // VoiceOver follows the arrow keys through the items, as it does in a system menu.
            if oldValue != highlighted { NSAccessibility.post(element: self, notification: .selectedChildrenChanged) }
        }
    }

    /// Its items, straight under the menu for VoiceOver, without the scroll view they're drawn in between.
    override func accessibilityChildren() -> [Any]? { rows }
    override func accessibilitySelectedChildren() -> [Any]? { highlighted.map { [rows[$0]] } }
    /// The neutral picture for an item whose own is missing (a site with no favicon yet).
    static var placeholder: NSImage { Tokens.Symbol.image("globe", size: Tokens.TypeSize.body) }
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?
    private var typed = ""
    private var typedAt: TimeInterval = 0
    /// The menu this one is a submenu of, and the submenu open beside this one with the item it belongs to.
    private weak var parentMenu: MenuPanel?
    private var child: MenuPanel?
    private var childIndex: Int?
    /// Opens or closes a submenu a moment after the pointer settles, so passing over items on the way to it keeps it.
    private var submenuTimer: Timer?
    private static let submenuDelay: TimeInterval = 0.2
    private var root: MenuPanel { parentMenu?.root ?? self }

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
        radius = Tokens.Radius.panel
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.useSlimScroller()
        scroll.documentView = list
        addSubview(scroll)
        list.addSubview(pill)
        let hasImages = entries.contains { if case .item(let item) = $0 { return item.image != nil || item.symbol != nil }; return false }
        for entry in entries {
            switch entry {
            case .item(let item):
                let row = Row(item, reservesIcon: hasImages)
                let index = rows.count
                row.onClick = { [weak self] _ in self?.choose(index) }
                row.hoverChanged = { [weak self] hovered in
                    guard let self else { return }
                    if hovered {
                        self.highlighted = self.rows[index].item.isEnabled ? index : nil
                        self.parentMenu?.keepChild()
                        self.scheduleSubmenu()
                    } else if self.highlighted == index, self.childIndex != index {
                        self.highlighted = nil
                        self.scheduleSubmenu()
                    }
                }
                rows.append(row)
                list.addSubview(row)
                row.setAccessibilityParent(self)
            case .header(let text):
                list.addSubview(Label.section(text))
            case .separator:
                list.addSubview(ColorView(color: Tokens.Color.separator))
            case .note(let text):
                let note = NSTextField.dialogText("")
                note.attributedStringValue = text
                notes.append(note)
                list.addSubview(note)
            }
        }
        setAccessibilityElement(true)
        // Only words to read: a popover, not a menu to choose from.
        setAccessibilityRole(rows.isEmpty && !notes.isEmpty ? .popover : .menu)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var contentHeight: CGFloat {
        var noteIndex = 0
        return Self.pad * 2 + entries.map { entry -> CGFloat in
            switch entry {
            case .item: return Self.rowHeight
            case .header: return Self.headerHeight
            case .separator: return Self.separatorHeight
            case .note:
                defer { noteIndex += 1 }
                return noteHeight(notes[noteIndex])
            }
        }.reduce(0, +)
    }

    private static let noteInset = Tokens.Space.x2

    private func noteHeight(_ note: NSTextField) -> CGFloat { note.wrappedHeight(noteWidth) + Self.noteInset * 2 }

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
            case .note: break
            }
        }
        return y
    }

    private var fittingWidth: CGFloat {
        let font = Tokens.Font.body()
        let widest = rows.map { ceil(($0.item.title as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let icon: CGFloat = rows.first?.reservesIcon == true ? DropdownButton.iconSide + Tokens.Space.x2 : 0
        // The shortcuts share one column at the trailing end, where a check would be.
        let keys = rows.map { $0.item.shortcut.isEmpty ? 0 : ceil(($0.item.shortcut as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        return Self.pad * 2 + Self.rowInset + icon + widest + Tokens.Space.x6 + max(Row.checkSide, keys) + Self.rowInset
    }

    // MARK: Showing

    /// Opens a menu from `anchor`. `closed` runs once it's gone, chosen or not.
    @discardableResult
    /// `appearance`: the menu's light or dark, when it differs from the window's.
    static func show(_ entries: [Entry], from anchor: NSView, placement: Placement = .below, minWidth: CGFloat = 0,
                     appearance: NSAppearance? = nil, closed: (() -> Void)? = nil) -> MenuPanel? {
        current?.close(animated: false)
        guard let window = anchor.window, let host = window.contentView else { closed?(); return nil }
        let menu = MenuPanel(entries: entries)
        menu.appearance = appearance
        menu.anchor = anchor
        menu.onClose = closed

        let width = ceil(max(menu.fittingWidth, minWidth + Self.pad * 2))
        menu.noteWidth = width - (Self.pad + Self.rowInset) * 2
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
            // A button on the right opens its menu inward, so it never hangs past the button's end.
            if a.midX > area.midX { x = a.maxX - width }
            if fits(a.minY - Tokens.Space.x1) {
                maxY = a.minY - Tokens.Space.x1
            } else if fits(a.maxY + Tokens.Space.x1 + height) {
                maxY = a.maxY + Tokens.Space.x1 + height
                growsY = 1
            } else {
                maxY = area.maxY
            }
        case .aboveTrailing:
            x = a.maxX - width
            if fits(a.maxY + Tokens.Space.x1 + height) {
                maxY = a.maxY + Tokens.Space.x1 + height
                growsY = 1
            } else if fits(a.minY - Tokens.Space.x1) {
                maxY = a.minY - Tokens.Space.x1
            } else {
                maxY = area.maxY
            }
        case .at(let point):
            // Under the pointer, as a right-click's menu opens. Short of room below, it slides up only as far as it
            // must, as macOS's does, so its first items stay by the pointer (never flipped whole above it).
            x = point.x
            maxY = min(max(point.y, area.minY + height), area.maxY)
            growsY = min(max((maxY - point.y) / max(height, 1), 0), 1)
        }
        x = min(max(x, area.minX), max(area.minX, area.maxX - width))
        let rect = NSRect(x: x, y: maxY - height, width: width, height: height)
        menu.frame = host.convert(rect, from: nil)
        let from: CGFloat
        if case .at(let point) = placement { from = point.x } else { from = a.midX }
        menu.growsFrom = CGPoint(x: min(max((from - x) / width, 0), 1), y: growsY)
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
            if let note = view as? NSTextField, notes.contains(where: { $0 === note }) {
                let h = noteHeight(note)
                note.frame = NSRect(x: Self.pad + Self.rowInset, y: y + Self.noteInset, width: width - (Self.pad + Self.rowInset) * 2, height: h - Self.noteInset * 2)
                y += h
            } else if let row = view as? Row {
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
        if let highlighted, rows.indices.contains(highlighted) { pill.follow(rows[highlighted].frame) }
    }

    /// The highlight glides from where it was to the row now under the pointer. From the keyboard, or arriving from
    /// nothing, it's simply there; leaving every row, it fades.
    private func movePill(from old: Int?) {
        let target = highlighted.flatMap { rows.indices.contains($0) ? rows[$0].frame : nil }
        pill.move(to: target, wasShown: old != nil)
    }

    /// Pressed, the highlight darkens a step.
    fileprivate func showPressed(_ pressed: Bool) { pill.showPressed(pressed) }

    // MARK: Closing

    private func watch(_ window: NSWindow) {
        monitor = TouchPress.addMonitor(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
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
        // A submenu closes with the menu it opened from.
        if parentMenu != nil { root.close(animated: animated); return }
        closeChild(animated: false)
        guard Self.current === self || monitor != nil else { return }
        if let monitor { TouchPress.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if Self.current === self { Self.current = nil }
        let closed = onClose
        onClose = nil
        if animated { leave() } else { removeFromSuperview() }
        closed?()
    }

    /// Grows out of the control that opened it: from `Motion.enterScale` with a fade, anchored at that control, eased
    /// out, whether a click or a key opened it. With Reduce Motion it only fades.
    private func arrive() {
        Tokens.Motion.present(self, from: .point(growsFrom), entering: true)
    }

    /// Leaves quicker and subtler than it came: a fade as it eases a touch smaller toward its control, from wherever
    /// it is, so a quick open and close never jumps.
    private func leave() {
        dismissing = true
        Tokens.Motion.present(self, from: .point(growsFrom), entering: false) { [weak self] in self?.removeFromSuperview() }
    }

    private func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].item.isEnabled else { return }
        if rows[index].item.submenu != nil {
            openChild(index, fromKey: Tokens.Motion.isFromKey)
            return
        }
        let action = rows[index].item.action
        close()
        action()
    }

    // MARK: Submenus

    /// After the pointer settles: the submenu of the item under it opens, another one closes. A pointer already in
    /// the open submenu keeps it.
    private func scheduleSubmenu() {
        submenuTimer?.invalidate()
        let wanted = highlighted.flatMap { rows[$0].item.submenu == nil ? nil : $0 }
        guard wanted != childIndex else { return }
        let timer = Timer(timeInterval: Self.submenuDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleSubmenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
        submenuTimer = timer
    }

    private func settleSubmenu() {
        submenuTimer = nil
        if let child, let window, child.contains(windowPoint: window.mouseLocationOutsideOfEventStream) { return }
        let wanted = highlighted.flatMap { rows[$0].item.submenu == nil ? nil : $0 }
        guard wanted != childIndex else { return }
        closeChild(animated: true)
        if let wanted { openChild(wanted, fromKey: false) }
    }

    /// The pointer reached the submenu: its item stays lit here, and nothing pending closes it.
    private func keepChild() {
        submenuTimer?.invalidate()
        submenuTimer = nil
        if let childIndex, highlighted != childIndex { highlighted = childIndex }
    }

    private func contains(windowPoint: NSPoint) -> Bool {
        bounds.contains(convert(windowPoint, from: nil)) || child?.contains(windowPoint: windowPoint) == true
    }

    /// The submenu of item `index`, beside it: its first item level with this one, on the right, or on the left
    /// where there's no room. From the keys, its first item is lit.
    private func openChild(_ index: Int, fromKey: Bool) {
        guard rows.indices.contains(index), let entries = rows[index].item.submenu, !entries.isEmpty else { return }
        if childIndex == index {
            if fromKey { child?.move(1) }
            return
        }
        closeChild(animated: false)
        guard window != nil, let host = superview else { return }
        let menu = MenuPanel(entries: entries)
        menu.appearance = appearance
        menu.anchor = anchor
        menu.parentMenu = self
        let width = ceil(menu.fittingWidth)
        let area = host.convert(host.bounds, to: nil).insetBy(dx: Self.margin, dy: Self.margin)
        let height = min(menu.contentHeight, area.height)
        let me = convert(bounds, to: nil)
        let row = rows[index].convert(rows[index].bounds, to: nil)
        let gap = Tokens.Space.x1
        var x = me.maxX + gap
        var growsX: CGFloat = 0
        if x + width > area.maxX, me.minX - gap - width >= area.minX {
            x = me.minX - gap - width
            growsX = 1
        }
        // Room on neither side: over the menu, inside the window.
        x = min(max(x, area.minX), max(area.minX, area.maxX - width))
        let maxY = min(max(row.maxY + Self.pad, area.minY + height), area.maxY)
        menu.frame = host.convert(NSRect(x: x, y: maxY - height, width: width, height: height), from: nil)
        menu.growsFrom = CGPoint(x: growsX, y: 0)
        host.addSubview(menu)
        menu.layoutSubtreeIfNeeded()
        child = menu
        childIndex = index
        highlighted = index
        menu.arrive()
        NSAccessibility.post(element: menu, notification: .created)
        if fromKey { menu.move(1) }
    }

    private func closeChild(animated: Bool) {
        submenuTimer?.invalidate()
        submenuTimer = nil
        guard let child else { return }
        child.closeChild(animated: false)
        self.child = nil
        childIndex = nil
        if animated { child.leave() } else { child.removeFromSuperview() }
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

    // MARK: A held finger

    /// Opened by a finger still held down (`TouchHold`): the clicks AppKit makes from that finger outside the menu
    /// are its own, and neither close nor open a menu, until a moment after it lifts.
    var isHeldByTouch = false
    private var heldUntil: TimeInterval = 0

    /// The finger lifted; a click made from the hold can still arrive a moment later.
    func touchLifted() {
        isHeldByTouch = false
        heldUntil = ProcessInfo.processInfo.systemUptime + 0.3
    }

    func touchContains(_ windowPoint: NSPoint) -> Bool { contains(windowPoint: windowPoint) }

    /// The held finger at `windowPoint`: the item under it lights, with a tap where the hardware gives one, and an
    /// item with a submenu opens it.
    func touchTrack(windowPoint: NSPoint) {
        if let child, child.touchContains(windowPoint) {
            keepChild()
            child.touchTrack(windowPoint: windowPoint)
            return
        }
        let index = row(at: windowPoint)
        // Off this menu toward its open submenu's item, that item stays lit.
        if index == nil, childIndex != nil { return }
        guard index != highlighted else { return }
        highlighted = index
        if let index {
            Haptics.snap()
            if rows[index].item.submenu != nil { openChild(index, fromKey: false) } else { closeChild(animated: true) }
        }
    }

    /// The held finger lifted at `windowPoint`, on the menu: the item there is chosen.
    func touchChoose(windowPoint: NSPoint) {
        if let child, child.touchContains(windowPoint) { child.touchChoose(windowPoint: windowPoint); return }
        if let index = row(at: windowPoint) { choose(index) }
    }

    /// Whether a click outside the menu is one AppKit made from the finger that opened it.
    private var takesHeldClick: Bool {
        root.isHeldByTouch || ProcessInfo.processInfo.systemUptime < root.heldUntil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let inSameWindow = event.window === window
        let inside = inSameWindow && contains(windowPoint: event.locationInWindow)
        if !inside, event.type != .keyDown, event.type != .scrollWheel, takesHeldClick { return nil }
        switch event.type {
        case .keyDown:
            return handleKey(event) ? nil : event
        case .scrollWheel:
            if inside { return event }
            close(animated: false)
            return event
        default:
            if inside { return event }
            // A click elsewhere closes the menu and goes no further in this window, as with any menu; a right-click
            // goes on to open the menu of what it's on.
            close()
            let opensMenu = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return inSameWindow && !opensMenu ? nil : event
        }
    }

    /// The item the pointer or the keys are on.
    var highlightedIndex: Int? { highlighted }
    /// Its items' titles, in order.
    var itemTitles: [String] { rows.map(\.item.title) }
    /// The submenu open beside it, if any.
    var openSubmenu: MenuPanel? { child }

    #if DEBUG
    /// A key typed in the menu, as `handleKey` takes it from the keyboard.
    func debugKey(_ code: UInt16) {
        let chars = code == 36 ? "\r" : code == 53 ? "\u{1b}" : String(UnicodeScalar([123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                                                                      125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey][Int(code)] ?? 0)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        _ = handleKey(event)
    }

    /// The middle of item `index`, in window coordinates.
    func debugItemPoint(_ index: Int) -> NSPoint {
        let row = rows[index]
        return row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    }

    /// Opens the submenu of the item with this title, as hovering it does.
    func debugOpenSubmenu(_ title: String) {
        if let index = rows.firstIndex(where: { $0.item.title == title }) { highlighted = index; openChild(index, fromKey: false) }
    }

    /// Its items, the lit one and its open submenu's, for scripts.
    var debugState: [String: Any] {
        ["items": itemTitles, "highlighted": highlighted.map { rows[$0].item.title } ?? "", "frame": NSStringFromRect(convert(bounds, to: nil)),
         "submenu": child?.debugState ?? [:]]
    }
    #endif

    /// True when the key was the menu's.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty {
            // A shortcut: the menu steps aside and lets it through.
            close(animated: false)
            return false
        }
        // An open submenu takes the keys until Left or Esc closes it.
        if let child, child.highlighted != nil || child.child != nil { return child.handleKey(event) }
        let opensSubmenu = highlighted.map { rows[$0].item.submenu != nil } ?? false
        switch event.keyCode {
        case 53 where parentMenu != nil, 123 where parentMenu != nil:     // Esc, Left in a submenu
            parentMenu?.closeChild(animated: true)
            return true
        case 124:                                                         // Right
            if let highlighted, rows[highlighted].item.submenu != nil { openChild(highlighted, fromKey: true) }
            return true
        case 36 where opensSubmenu, 76 where opensSubmenu:                // Return on a submenu's item
            if let highlighted { openChild(highlighted, fromKey: true) }
            return true
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
        private let keys: Label
        static let checkSide: CGFloat = 12
        var isHighlighted = false { didSet { if oldValue != isHighlighted { stateDidChange(animated: false) } } }

        init(_ item: Item, reservesIcon: Bool) {
            self.item = item
            self.reservesIcon = reservesIcon
            label = Label(item.title, font: Tokens.Font.body(), color: item.isDestructive ? Tokens.Color.destructive : Tokens.Color.textPrimary)
            // The shortcut in quiet type at the trailing end, as the Mac's menus set it.
            keys = Label(item.shortcut, font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
            keys.alignment = .right
            keys.isHidden = item.shortcut.isEmpty
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
            // A submenu's chevron takes the check's place, quiet like the shortcuts.
            check.image = Tokens.Symbol.image(item.submenu == nil ? "checkmark" : "chevron.right", size: Tokens.Symbol.inline)
            check.imageScaling = .scaleNone
            // Its trailing edge on the shortcuts' trailing edge.
            if item.submenu != nil { check.imageAlignment = .alignRight }
            check.isHidden = !item.isChecked && item.submenu == nil
            [icon, label, keys, check].forEach { addSubview($0) }
            isEnabled = item.isEnabled
            setAccessibilityRole(item.submenu == nil ? .menuItem : .menuButton)
            setAccessibilityLabel(item.title)
            if !item.shortcut.isEmpty { setAccessibilityHelp(item.shortcut) }
            setAccessibilityValue(item.isChecked ? String(localized: "selected", comment: "What VoiceOver says after a checked item in one of Zigzag's menus.") : nil)
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
            var end = check.frame.minX
            if !keys.isHidden {
                let width = keys.inkWidth + 2
                keys.frame = NSRect(x: bounds.width - MenuPanel.rowInset - width - Label.inset, y: keys.centeredY(in: bounds.height),
                                    width: width + Label.inset * 2, height: keys.lineHeight)
                end = min(end, keys.frame.minX + Label.inset)
            }
            label.frame = NSRect(x: x - Label.inset, y: label.centeredY(in: bounds.height),
                                 width: max(0, end - Tokens.Space.x2 - x + Label.inset * 2), height: label.lineHeight)
        }

        override func stateDidChange(animated: Bool) {
            // The highlight is the menu's one gliding pill (`MenuPanel.pill`); the chosen item has its check, in the
            // window's accent.
            check.contentTintColor = item.submenu == nil ? Brand.Theme.for(self).accent : Tokens.Color.textTertiary
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
        label.frame = NSRect(x: 16 + Tokens.Space.x2 - Label.inset, y: label.centeredY(in: bounds.height), width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
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
        // One VoiceOver group with radio-button segments.
        setAccessibilityElement(true)
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
            label.frame = NSRect(x: r.minX, y: r.minY + label.centeredY(in: r.height), width: r.width, height: label.lineHeight)
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
        // The same glide as every moving selection: from where it's drawn, eased out; from the keyboard or with
        // Reduce Motion it simply lands (`Motion.glide` skips the movement then).
        if animated && !Tokens.Motion.isFromKey && pill.frame.width > 0 {
            Tokens.Motion.glide(pill, to: target, duration: Tokens.Motion.highlightGlide, timing: Tokens.Motion.easeOut)
        } else {
            pill.layer?.removeAnimation(forKey: "glide")
            Tokens.Motion.withoutAnimation { pill.frame = target }
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

/// Keyboard focus for drawn controls that aren't buttons (the space editor's color wheel, sliders and direction
/// knob): Tab reaches them with Full Keyboard Access on, as it does buttons, and while one has focus it's ringed in
/// the accent, as a button is. A click never gives them focus, so the mouse works as it always has.
final class KeyboardFocus {
    private weak var view: NSView?
    private var ring: CAShapeLayer?

    init(_ view: NSView) { self.view = view }

    var accepts: Bool {
        guard InteractiveView.keyboardAccess else { return false }
        if let type = NSApp.currentEvent?.type, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { return false }
        return true
    }

    /// Shows or hides the ring, drawn along `shape` (in the view's own coordinates) just outside it.
    func show(_ focused: Bool, around shape: CGPath) {
        guard focused, let view, let layer = view.layer else {
            ring?.removeFromSuperlayer()
            ring = nil
            return
        }
        layer.masksToBounds = false
        let ring = self.ring ?? CAShapeLayer()
        Tokens.Motion.withoutAnimation {
            ring.path = shape
            ring.fillColor = nil
            ring.lineWidth = Tokens.Metric.focusRing
            ring.strokeColor = view.cgColor(Brand.Theme.for(view).accent.withAlphaComponent(Tokens.Color.focusAlpha))
            ring.zPosition = 10
            if ring.superlayer == nil { layer.addSublayer(ring) }
        }
        self.ring = ring
    }

    /// Which arrow a key is, if any: -1 for left or down, 1 for right or up, with whether it was up or down.
    static func arrow(_ event: NSEvent) -> (step: Double, vertical: Bool)? {
        switch event.keyCode {
        case 123: (-1, false)
        case 124: (1, false)
        case 125: (-1, true)
        case 126: (1, true)
        default: nil
        }
    }
}

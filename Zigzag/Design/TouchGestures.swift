import AppKit

/// Touch on a Mac with a touch display or a Sidecar iPad (TN3212). Every recognizer made here sees fingers only: a
/// mouse or trackpad never reaches one, so pointer behavior stays exactly as it was.
@MainActor
enum TouchGestures {
    /// The smallest box a finger can hit reliably; smaller targets take touches this far around them.
    nonisolated static let target: CGFloat = 36
    /// A tap moves less than this, in points.
    nonisolated static let tapSlop: CGFloat = 10
    /// A tap lifts within this, in seconds.
    nonisolated static let tapDuration: TimeInterval = 0.5
    /// How long after a tap lifts its emulated click has surely gone through.
    nonisolated static let afterClick: TimeInterval = 0.1

    /// Direct touches reach apps from macOS 27; before that nothing is added at all.
    static var isAvailable: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Makes a recognizer touch-only: no mouse buttons, direct touches, never delays the mouse, gives way to scrolling.
    static func configure(_ recognizer: NSGestureRecognizer, _ delegate: TouchOnly, yieldsToScrolling: Bool = true) {
        // Only the standard recognizers have a button mask; a custom one never sees a mouse event (the delegate).
        switch recognizer {
        case let press as NSPressGestureRecognizer: press.buttonMask = 0
        case let pan as NSPanGestureRecognizer: pan.buttonMask = 0
        case let click as NSClickGestureRecognizer: click.buttonMask = 0
        default: break
        }
        recognizer.allowedTouchTypes = .direct
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delaysSecondaryMouseButtonEvents = false
        recognizer.delaysOtherMouseButtonEvents = false
        recognizer.delaysKeyEvents = false
        recognizer.delaysMagnificationEvents = false
        recognizer.delaysRotationEvents = false
        if #available(macOS 27, *) { recognizer.isCancellableByScrollGesture = yieldsToScrolling }
        recognizer.delegate = delegate
    }

    /// A held finger on `view` opens its drawn menu where no control in it has a menu of its own: `open` gets the
    /// right-click the finger stands for. Not while a menu is already open (AppKit's own right-click from the hold).
    @discardableResult
    static func addMenuPress(to view: NSView, open: @escaping (NSEvent) -> Void) -> TouchPressRecognizer? {
        guard isAvailable else { return nil }
        let press = TouchPressRecognizer { [weak view] press in
            let point = press.location(in: nil)
            switch press.state {
            case .began:
                guard let view else { return }
                TouchHold.begin(on: view, at: point, openMenu: { [weak view] in
                    guard MenuPanel.current == nil, let window = view?.window, let event = rightMouseDown(at: point, in: window) else { return nil }
                    open(event)
                    return MenuPanel.current
                }, startDrag: nil)
            case .changed: TouchHold.current?.pressMoved(to: point)
            case .ended: TouchHold.current?.pressLifted(at: point)
            case .cancelled, .failed: TouchHold.current?.pressCancelled()
            default: break
            }
        }
        press.touchOnly.accepts = { [weak view] point in view.map { !controlHasMenu(at: point, in: $0) } ?? false }
        view.addGestureRecognizer(press)
        return press
    }

    /// Whether a control of ours between the view under `point` (in `view`) and `view` has a menu of its own.
    static func controlHasMenu(at point: NSPoint, in view: NSView) -> Bool {
        guard let window = view.window, let frame = window.contentView?.superview else { return false }
        var hit = frame.hitTest(view.convert(point, to: nil))
        while let current = hit, current !== view {
            if let control = current as? InteractiveView, control.offersMenu { return true }
            hit = current.superview
        }
        return false
    }

    /// The right-click a held finger stands for, at `point` in window coordinates.
    static func rightMouseDown(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
    }

    /// The box a finger may hit for a target: at least `target` each way, centered on it.
    nonisolated static func box(around frame: NSRect, minimum: CGFloat = target) -> NSRect {
        let dx = max(0, minimum - frame.width) / 2, dy = max(0, minimum - frame.height) / 2
        return frame.insetBy(dx: -dx, dy: -dy)
    }

    /// Whether a touch from `start` to `end` over `duration` is a tap.
    nonisolated static func isTap(from start: NSPoint, to end: NSPoint, duration: TimeInterval) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < tapSlop && duration < tapDuration
    }
}

/// The delegate behind every touch recognizer: turns away every mouse and trackpad event, takes touches (only where
/// `accepts` says, when set).
@MainActor
final class TouchOnly: NSObject, NSGestureRecognizerDelegate {
    /// Where a touch may start, in the recognizer's view.
    var accepts: ((NSPoint) -> Bool)?
    /// Whether the recognizer may start once it has seen enough (a pan's direction).
    var shouldBegin: ((NSGestureRecognizer) -> Bool)?
    /// Runs alongside the app's other recognizers.
    var simultaneous = false
    /// Recognizers that wait for this one to fail first (a list's scrolling, for a sideways swipe across it).
    var outranks: ((NSGestureRecognizer) -> Bool)?

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        guard let accepts, let view = gestureRecognizer.view else { return true }
        return accepts(touch.location(in: view))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        shouldBegin?(gestureRecognizer) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { simultaneous }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        outranks?(otherGestureRecognizer) ?? false
    }
}

/// A finger held still: `handler` runs on each state change (began, cancelled, ended).
final class TouchPressRecognizer: NSPressGestureRecognizer {
    let touchOnly = TouchOnly()
    var handler: ((TouchPressRecognizer) -> Void)?

    init(handler: ((TouchPressRecognizer) -> Void)? = nil) {
        self.handler = handler
        super.init(target: nil, action: nil)
        target = self
        action = #selector(fire)
        TouchGestures.configure(self, touchOnly)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?(self) }
}

/// A finger dragged: `handler` runs on each state change.
final class TouchPanRecognizer: NSPanGestureRecognizer {
    let touchOnly = TouchOnly()
    var handler: ((TouchPanRecognizer) -> Void)?

    init(handler: ((TouchPanRecognizer) -> Void)? = nil) {
        self.handler = handler
        super.init(target: nil, action: nil)
        target = self
        action = #selector(fire)
        TouchGestures.configure(self, touchOnly, yieldsToScrolling: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?(self) }
}

/// Two fingers pinched: `handler` runs on each state change. Alongside the page's own pinch zoom.
final class TouchPinchRecognizer: NSMagnificationGestureRecognizer {
    let touchOnly = TouchOnly()
    var handler: ((TouchPinchRecognizer) -> Void)?

    init(handler: ((TouchPinchRecognizer) -> Void)? = nil) {
        self.handler = handler
        super.init(target: nil, action: nil)
        target = self
        action = #selector(fire)
        TouchGestures.configure(self, touchOnly, yieldsToScrolling: false)
        touchOnly.simultaneous = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?(self) }
}

/// Watches fingers land and lift without ever recognizing, so it never takes a touch from anything under it: what a
/// mouse-down tells `sendEvent` and the event monitors, which touches skip.
final class TouchWatch: NSGestureRecognizer {
    let touchOnly = TouchOnly()
    /// A finger landed, in window coordinates.
    var onDown: ((NSPoint) -> Void)?
    /// A tap, in window coordinates, once it lifted and the click AppKit makes from it has gone through.
    var onTap: ((NSPoint) -> Void)?
    private var start: (point: NSPoint, time: TimeInterval)?
    private var last = NSPoint.zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        TouchGestures.configure(self, touchOnly)
        touchOnly.simultaneous = true
    }

    convenience init() { self.init(target: nil, action: nil) }

    required init?(coder: NSCoder) { fatalError() }

    private func windowPoint(_ event: NSEvent, _ phase: NSTouch.Phase) -> NSPoint? {
        guard let view, let touch = event.touches(matching: phase, in: view).first else { return nil }
        return view.convert(touch.location(in: view), to: nil)
    }

    override func touchesBegan(with event: NSEvent) {
        guard start == nil, let point = windowPoint(event, .began) else { return }
        start = (point, event.timestamp)
        last = point
        touchDown(at: point)
        if onTap == nil { state = .failed }
    }

    override func touchesMoved(with event: NSEvent) {
        guard let start, let point = windowPoint(event, .moved) else { return }
        last = point
        if !TouchGestures.isTap(from: start.point, to: point, duration: 0) { state = .failed }
    }

    override func touchesEnded(with event: NSEvent) {
        if let start, TouchGestures.isTap(from: start.point, to: windowPoint(event, .ended) ?? last, duration: event.timestamp - start.time) {
            let point = start.point
            DispatchQueue.main.asyncAfter(deadline: .now() + TouchGestures.afterClick) { [weak self] in
                MainActor.assumeIsolated { self?.touchTapped(at: point) }
            }
        }
        state = .failed
    }

    override func touchesCancelled(with event: NSEvent) { state = .failed }

    override func reset() {
        super.reset()
        start = nil
        last = .zero
    }

    override func location(in view: NSView?) -> NSPoint {
        let point = start?.point ?? last
        guard let view else { return point }
        return view.convert(point, from: nil)
    }

    /// What a finger landing does, also for tests.
    func touchDown(at windowPoint: NSPoint) { onDown?(windowPoint) }
    /// What a tap does, also for tests.
    func touchTapped(at windowPoint: NSPoint) { onTap?(windowPoint) }
}

/// Every finger landing in a window, told the way a mouse-down is: pop-ups count it as a click in the page, the window
/// gets its press hooks, and the panels that close on a click elsewhere hear it through `addMonitor`.
@MainActor
enum TouchPress {
    /// A window's hooks for a finger landing, which its `sendEvent` runs for a mouse-down.
    protocol Handling: NSWindow {
        func touchPressed(_ event: NSEvent)
        func touchTapped(_ event: NSEvent, downAt time: TimeInterval)
    }

    private static var listeners: [Int: (NSEvent) -> Void] = [:]
    private static var nextID = 0
    /// The views watched, so each gets one watch.
    private static let watched = NSHashTable<NSView>.weakObjects()

    /// Watches a window's whole frame, title bar included. Again for the same window does nothing.
    static func watch(_ window: NSWindow) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        watch(view: view)
    }

    /// Watches one view and what's in it, for a popover's content.
    static func watch(view: NSView) {
        guard TouchGestures.isAvailable, !watched.contains(view) else { return }
        watched.add(view)
        let watch = TouchWatch()
        var downAt: TimeInterval = 0
        watch.onDown = { [weak view] point in
            downAt = ProcessInfo.processInfo.systemUptime
            if let window = view?.window { pressed(at: point, in: window) }
        }
        watch.onTap = { [weak view] point in
            guard let window = view?.window as? Handling, let event = mouseDown(at: point, in: window) else { return }
            window.touchTapped(event, downAt: downAt)
        }
        view.addGestureRecognizer(watch)
    }

    /// When a finger last landed, and whether one is down now (`TouchFollow`).
    static var landedAt: TimeInterval?
    static var fingerDown = false

    /// A finger landed at `point` (window coordinates): the same hooks a mouse-down runs.
    static func pressed(at point: NSPoint, in window: NSWindow) {
        guard let event = mouseDown(at: point, in: window) else { return }
        PopupNotice.noteInput(event)
        (window as? Handling)?.touchPressed(event)
        for listener in listeners.values { listener(event) }
    }

    /// The mouse-down a finger landing stands for.
    static func mouseDown(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// Hears every finger landing, as a mouse-down; returns a token for `stopListening`.
    static func listen(_ listener: @escaping (NSEvent) -> Void) -> Int {
        nextID += 1
        listeners[nextID] = listener
        return nextID
    }

    static func stopListening(_ id: Int) { listeners[id] = nil }

    /// `NSEvent.addLocalMonitorForEvents`, and when it watches mouse-downs, finger landings too. Remove with
    /// `removeMonitor`.
    static func addMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        guard mask.contains(.leftMouseDown) else { return token }
        return Monitor(token: token, listener: listen { _ = handler($0) })
    }

    /// Removes a monitor from `addMonitor`, or a plain one from `NSEvent`.
    static func removeMonitor(_ monitor: Any) {
        if let monitor = monitor as? Monitor { monitor.remove() } else { NSEvent.removeMonitor(monitor) }
    }

    @MainActor
    final class Monitor {
        private var token: Any?
        private var listener: Int?

        init(token: Any?, listener: Int) {
            self.token = token
            self.listener = listener
        }

        func remove() {
            if let token { NSEvent.removeMonitor(token) }
            if let listener { TouchPress.stopListening(listener) }
            token = nil
            listener = nil
        }

        var isActive: Bool { listener != nil }
    }
}

/// Hover-only controls a tap shows, as hovering would (HIG, touch support for hidden controls): one view at a time,
/// until a finger lands outside its area or the pointer moves over it.
@MainActor
enum TouchReveal {
    private static weak var current: NSView?
    /// Where a finger keeps it showing (the sidebar, for a row).
    private static weak var area: NSView?
    private static var ends: (() -> Void)?
    private static var listener: Int?

    /// `view` shows what hovering shows until `end` runs. Whatever showed before ends first.
    static func reveal(_ view: NSView, keptWithin area: NSView? = nil, end: @escaping () -> Void) {
        if current !== view { finish() }
        current = view
        self.area = area ?? view
        ends = end
        if listener == nil { listener = TouchPress.listen { touchLanded($0) } }
    }

    static func isRevealed(_ view: NSView) -> Bool { current === view }

    /// The pointer moved over `view`: hover takes over.
    static func pointerMoved(over view: NSView) {
        if current === view { finish() }
    }

    /// A finger landed: outside the area it ends.
    static func touchLanded(_ event: NSEvent) {
        guard current != nil else { return }
        guard let area else { finish(); return }
        let inside = area.bounds.contains(area.convert(event.locationInWindow, from: nil))
        if !keeps(touchInArea: inside, sameWindow: area.window === event.window) { finish() }
    }

    nonisolated static func keeps(touchInArea: Bool, sameWindow: Bool) -> Bool { touchInArea && sameWindow }

    static func finish() {
        let end = ends
        current = nil
        area = nil
        ends = nil
        end?()
    }
}

/// A tap where a hidden control sits shows it without pressing it: the click AppKit makes from that tap is dropped.
struct TouchSwallow {
    private var until: TimeInterval = 0

    /// The next click within a moment is the tap's.
    mutating func arm(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { until = now + 1 }
    mutating func disarm() { until = 0 }

    /// Whether this click is the tap's, which it then drops.
    mutating func takes(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now < until else { return false }
        until = 0
        return true
    }
}

/// Follows the first finger in a window until it lifts, never recognizing, so it takes nothing from what's under it:
/// a held finger's moves and lift still arrive here after the view it was held on has gone (a row, when the list
/// changes space under a drag).
final class TouchFollow: NSGestureRecognizer {
    let touchOnly = TouchOnly()
    private var finger: (any NSCopying & NSObjectProtocol)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        TouchGestures.configure(self, touchOnly, yieldsToScrolling: false)
        touchOnly.simultaneous = true
    }

    convenience init() { self.init(target: nil, action: nil) }

    required init?(coder: NSCoder) { fatalError() }

    private func windowPoint(_ event: NSEvent, _ phase: NSTouch.Phase) -> NSPoint? {
        guard let view, let finger else { return nil }
        guard let touch = event.touches(matching: phase, in: view).first(where: { $0.identity.isEqual(finger) }) else { return nil }
        return view.convert(touch.location(in: view), to: nil)
    }

    override func touchesBegan(with event: NSEvent) {
        guard finger == nil, let view, let touch = event.touches(matching: .began, in: view).first else { return }
        finger = touch.identity
        TouchPress.landedAt = event.timestamp
        TouchPress.fingerDown = true
    }

    override func touchesMoved(with event: NSEvent) {
        guard let point = windowPoint(event, .moved), let window = view?.window else { return }
        TouchHold.current?.fingerMoved(to: point, in: window)
    }

    override func touchesEnded(with event: NSEvent) {
        guard let point = windowPoint(event, .ended) else { return }
        if let window = view?.window { TouchHold.current?.fingerLifted(at: point, in: window) }
        state = .failed
    }

    override func touchesCancelled(with event: NSEvent) {
        if let window = view?.window { TouchHold.current?.fingerCancelled(in: window) }
        state = .failed
    }

    override func reset() {
        super.reset()
        finger = nil
        TouchPress.fingerDown = false
    }

    /// Whether `view` or a view it's in has one.
    static func follows(_ view: NSView?) -> Bool {
        sequence(first: view, next: { $0?.superview }).contains { $0?.gestureRecognizers.contains { $0 is TouchFollow } == true }
    }
}

/// A carried drag (`CarriedCopy.carry`) a finger moves, in place of the mouse's tracking loop: each step and the
/// release reach the drag as the mouse events they stand for.
@MainActor
final class TouchCarry {
    /// Set while a hold asks a view to start its drag: the drag it starts follows this finger.
    static var starting: TouchCarry?
    private weak var window: NSWindow?
    private var moved: ((NSEvent) -> Void)?
    private var ended: ((NSEvent?) -> Void)?

    var isAttached: Bool { moved != nil }

    func attach(to window: NSWindow, moved: @escaping (NSEvent) -> Void, ended: @escaping (NSEvent?) -> Void) {
        self.window = window
        self.moved = moved
        self.ended = ended
    }

    func move(to windowPoint: NSPoint) {
        guard let event = event(.leftMouseDragged, at: windowPoint) else { return }
        moved?(event)
    }

    /// Let go at `windowPoint`: the last step, then the drop, as the mouse's release.
    func release(at windowPoint: NSPoint) {
        let event = event(.leftMouseUp, at: windowPoint)
        if let event { moved?(event) }
        finish(event)
    }

    /// Called off: nothing changes.
    func cancel() { finish(nil) }

    private func finish(_ event: NSEvent?) {
        let ended = self.ended
        moved = nil
        self.ended = nil
        ended?(event)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }
}

/// Touch and hold, as an iPhone's menus work, in one motion: the drawn menu opens at the finger; sliding onto it lights
/// the item under the finger and lifting there chooses it; lifting anywhere else leaves it open, to be tapped. Moving
/// away from the menu instead, or before it shows, picks the item up and drags it as the mouse does.
@MainActor
final class TouchHold {
    /// How far from where it was held the finger moves, off the menu, before the item is picked up.
    nonisolated static let dragDistance: CGFloat = 16
    /// Held this much longer after the hold is recognized, the menu opens; moving before then drags straight away.
    nonisolated static let menuDelay: TimeInterval = 0.15

    enum Step: Equatable { case wait, highlight, drag }
    enum Lift: Equatable { case choose, keepOpen, drop, nothing }

    /// What a finger at `point`, held at `start` (window coordinates), does: on the menu it lights an item; once it has
    /// been on the menu it never drags; otherwise, far enough off, it picks the item up.
    nonisolated static func step(from start: NSPoint, to point: NSPoint, onMenu: Bool, wasOnMenu: Bool, canDrag: Bool) -> Step {
        if onMenu { return .highlight }
        guard canDrag, !wasOnMenu, hypot(point.x - start.x, point.y - start.y) >= dragDistance else { return .wait }
        return .drag
    }

    /// What lifting does: drops what's carried, chooses the item under the finger, or leaves the menu open.
    nonisolated static func lift(menuShown: Bool, onMenu: Bool, dragging: Bool) -> Lift {
        if dragging { return .drop }
        guard menuShown else { return .nothing }
        return onMenu ? .choose : .keepOpen
    }

    /// The hold in progress; one at a time.
    private(set) static var current: TouchHold?

    private weak var window: NSWindow?
    private let start: NSPoint
    private var point: NSPoint
    private let openMenu: (() -> MenuPanel?)?
    private let startDrag: ((NSPoint) -> Bool)?
    private let ended: (() -> Void)?
    private(set) weak var menu: MenuPanel?
    private var menuWork: DispatchWorkItem?
    private var wasOnMenu = false
    private var dragFailed = false
    private(set) var carry: TouchCarry?
    private(set) var isFinished = false
    /// The list under the finger doesn't scroll while it's held, so moving drags rather than scrolls.
    private weak var frozen: NSScrollView?
    /// Moves and the lift come from the window's `TouchFollow`, not the recognizer that saw the hold.
    let followed: Bool

    init(at windowPoint: NSPoint, in window: NSWindow?, followed: Bool, scroll: NSScrollView?,
         openMenu: (() -> MenuPanel?)?, startDrag: ((NSPoint) -> Bool)?, ended: (() -> Void)? = nil) {
        self.window = window
        start = windowPoint
        point = windowPoint
        self.followed = followed
        self.openMenu = openMenu
        self.startDrag = startDrag
        self.ended = ended
        if #available(macOS 27, *), let scroll, scroll.isTouchScrollingEnabled {
            scroll.isTouchScrollingEnabled = false
            frozen = scroll
        }
    }

    /// A hold recognized on `view` at `windowPoint`: the one in progress from now. The menu opens after `menuDelay`.
    @discardableResult
    static func begin(on view: NSView, at windowPoint: NSPoint, openMenu: (() -> MenuPanel?)?, startDrag: ((NSPoint) -> Bool)?,
                      ended: (() -> Void)? = nil) -> TouchHold {
        current?.cancelled()
        let hold = TouchHold(at: windowPoint, in: view.window, followed: TouchFollow.follows(view), scroll: view.enclosingScrollView,
                             openMenu: openMenu, startDrag: startDrag, ended: ended)
        current = hold
        if openMenu != nil {
            let work = DispatchWorkItem { [weak hold] in MainActor.assumeIsolated { hold?.showMenu() } }
            hold.menuWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + menuDelay, execute: work)
        }
        return hold
    }

    /// Opens the menu where the finger was held, unless the item is already carried.
    func showMenu() {
        menuWork?.cancel()
        menuWork = nil
        guard !isFinished, carry == nil, menu == nil, let openMenu else { return }
        menu = openMenu()
        menu?.isHeldByTouch = true
        // Opened under the finger (slid up for room): the item there lights at once.
        if let menu, menu.touchContains(point) { moved(to: point) }
    }

    // MARK: The finger

    /// From the recognizer that saw the hold; only when the window has no `TouchFollow`.
    func pressMoved(to windowPoint: NSPoint) { if !followed { moved(to: windowPoint) } }
    func pressLifted(at windowPoint: NSPoint) { if !followed { lifted(at: windowPoint) } }
    func pressCancelled() { if !followed { cancelled() } }

    /// From the window's `TouchFollow`.
    func fingerMoved(to windowPoint: NSPoint, in window: NSWindow) { if followed, window === self.window { moved(to: windowPoint) } }
    func fingerLifted(at windowPoint: NSPoint, in window: NSWindow) { if followed, window === self.window { lifted(at: windowPoint) } }
    func fingerCancelled(in window: NSWindow) { if followed, window === self.window { cancelled() } }

    func moved(to windowPoint: NSPoint) {
        guard !isFinished else { return }
        point = windowPoint
        if let carry { carry.move(to: windowPoint); return }
        let onMenu = menu?.touchContains(windowPoint) ?? false
        switch Self.step(from: start, to: windowPoint, onMenu: onMenu, wasOnMenu: wasOnMenu, canDrag: startDrag != nil && !dragFailed) {
        case .highlight:
            menu?.touchTrack(windowPoint: windowPoint)
            // On an item, not just the menu's corner the finger opened it at.
            if menu?.highlightedIndex != nil || menu?.openSubmenu != nil { wasOnMenu = true }
        case .drag:
            beginDrag()
        case .wait:
            menu?.touchTrack(windowPoint: windowPoint)
        }
    }

    func lifted(at windowPoint: NSPoint) {
        guard !isFinished else { return }
        point = windowPoint
        // Held and let go before the menu came: it opens now and stays, as a held finger's menu does.
        if menu == nil, carry == nil { showMenu() }
        let onMenu = menu?.touchContains(windowPoint) ?? false
        switch Self.lift(menuShown: menu != nil, onMenu: onMenu, dragging: carry != nil) {
        case .drop: carry?.release(at: windowPoint)
        case .choose: menu?.touchChoose(windowPoint: windowPoint)
        case .keepOpen, .nothing: break
        }
        finish()
    }

    func cancelled() {
        guard !isFinished else { return }
        carry?.cancel()
        finish()
    }

    private func beginDrag() {
        menuWork?.cancel()
        menuWork = nil
        menu?.close()
        menu = nil
        guard let startDrag else { return }
        let carry = TouchCarry()
        TouchCarry.starting = carry
        let started = startDrag(start)
        TouchCarry.starting = nil
        guard started, carry.isAttached else { dragFailed = true; return }
        self.carry = carry
        carry.move(to: point)
    }

    private func finish() {
        isFinished = true
        menuWork?.cancel()
        menuWork = nil
        menu?.touchLifted()
        if #available(macOS 27, *) { frozen?.isTouchScrollingEnabled = true }
        frozen = nil
        if Self.current === self { Self.current = nil }
        ended?()
    }
}

/// Which way a finger across something goes: sideways once it has moved mostly sideways, the few points
/// `SpaceSwipe.axisLock` a trackpad swipe takes to decide.
enum TouchSwipe {
    nonisolated static func isSideways(_ translation: NSPoint) -> Bool {
        abs(translation.x) >= 4 && abs(translation.x) > abs(translation.y) * 1.2
    }
}


/// Two fingers pinched in on a page at its usual size open Show All Tabs, as on an iPad; pinched out on a card there,
/// it opens.
enum TouchPinch {
    /// How far in or out the fingers pinch, as the recognizer's magnification, before it counts.
    nonisolated static let threshold: CGFloat = 0.2

    /// Whether a pinch that began with the page at `startZoom` (its magnification) has gone far enough in to open the
    /// overview. Zoomed in, the pinch is the page's, to zoom back out.
    nonisolated static func opensOverview(magnification: CGFloat, startZoom: CGFloat) -> Bool {
        startZoom <= 1.01 && magnification <= -threshold
    }

    nonisolated static func opensCard(magnification: CGFloat) -> Bool { magnification >= threshold }
}

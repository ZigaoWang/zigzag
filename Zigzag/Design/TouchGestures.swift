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

    /// The box a finger may hit for a target: at least `target` each way (`minimumHeight` up and down, when given),
    /// centered on it.
    nonisolated static func box(around frame: NSRect, minimum: CGFloat = target, minimumHeight: CGFloat? = nil) -> NSRect {
        let dx = max(0, minimum - frame.width) / 2, dy = max(0, (minimumHeight ?? minimum) - frame.height) / 2
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
    /// Debug builds note why a finger wasn't a tap: the window's own watch only.
    var logsMisses = false
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
        if !TouchGestures.isTap(from: start.point, to: point, duration: 0), state == .possible {
            if logsMisses { TouchLog.note("not a tap: moved \(Int(hypot(point.x - start.point.x, point.y - start.point.y))) pt") }
            state = .failed
        }
    }

    override func touchesEnded(with event: NSEvent) {
        if let start, logsMisses, event.timestamp - start.time >= TouchGestures.tapDuration {
            TouchLog.note("not a tap: held \(Int((event.timestamp - start.time) * 1000)) ms")
        }
        if let start, TouchGestures.isTap(from: start.point, to: windowPoint(event, .ended) ?? last, duration: event.timestamp - start.time) {
            let point = start.point
            DispatchQueue.main.asyncAfter(deadline: .now() + TouchGestures.afterClick) { [weak self] in
                MainActor.assumeIsolated { self?.touchTapped(at: point) }
            }
        }
        state = .failed
    }

    override func touchesCancelled(with event: NSEvent) {
        if start != nil, logsMisses { TouchLog.note("not a tap: cancelled") }
        state = .failed
    }

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
        watch.logsMisses = true
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
        // A held finger's moves and lift, wherever in the window it goes (`TouchHold`).
        view.addGestureRecognizer(TouchFollow())
    }

    /// When a finger last landed, and whether one is down now (`TouchFollow`).
    static var landedAt: TimeInterval?
    static var fingerDown = false

    /// Whether a scroll starting at `time` comes from a finger on the screen rather than the trackpad: one is down, or
    /// landed a moment ago. A finger left down longer than any pan is taken to be gone.
    nonisolated static func isTouchScroll(at time: TimeInterval, landedAt: TimeInterval?, fingerDown: Bool) -> Bool {
        guard let landedAt, time >= landedAt else { return false }
        return time - landedAt < (fingerDown ? 30 : 0.8)
    }

    static func isTouchScroll(at time: TimeInterval) -> Bool { isTouchScroll(at: time, landedAt: landedAt, fingerDown: fingerDown) }

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
    /// Where the tap's finger was, in window coordinates; empty takes a click anywhere.
    private var points: [NSPoint] = []

    /// The next click within a moment is the tap's: anywhere, or near one of `points`.
    mutating func arm(at points: [NSPoint] = [], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        until = now + 1
        self.points = points
    }
    mutating func disarm() { until = 0 }

    /// Whether this click, at `point` when given, is the tap's, which it then drops.
    mutating func takes(at point: NSPoint? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now < until else { return false }
        if let point, !points.isEmpty, !points.contains(where: { hypot($0.x - point.x, $0.y - point.y) <= TouchGestures.target }) { return false }
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
        // Esc calls it off, as it does the mouse's; the finger's further moves and its lift then change nothing.
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isAttached else { return event }
            self.cancel()
            return nil
        }
    }

    private var escape: Any?

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
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
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
    /// been on the menu it doesn't drag, unless it has gone on out of the list it was held in (`leftHome`: onto the
    /// page, past a menu that lay in the way); otherwise, far enough off, it picks the item up.
    nonisolated static func step(from start: NSPoint, to point: NSPoint, onMenu: Bool, wasOnMenu: Bool, canDrag: Bool,
                                 leftHome: Bool = false) -> Step {
        if onMenu { return .highlight }
        guard canDrag, !wasOnMenu || leftHome, hypot(point.x - start.x, point.y - start.y) >= dragDistance else { return .wait }
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
    /// The window has a `TouchFollow`: once it reports this finger, its moves and lift are the ones taken, as the
    /// recognizer that saw the hold may stop hearing the finger once it leaves that view, or the view goes.
    let followed: Bool
    /// The follower has reported this finger moving.
    private(set) var followSeen = false
    /// The list it was held in (the sidebar's): off the menu and out of it, the finger is taking it somewhere to drop,
    /// and picks it up even after passing over the menu.
    private weak var home: NSView?
    /// The view the hold was recognized on.
    private weak var source: NSView?

    init(at windowPoint: NSPoint, in window: NSWindow?, followed: Bool, scroll: NSScrollView?,
         openMenu: (() -> MenuPanel?)?, startDrag: ((NSPoint) -> Bool)?, ended: (() -> Void)? = nil) {
        self.window = window
        start = windowPoint
        point = windowPoint
        self.followed = followed
        self.openMenu = openMenu
        self.startDrag = startDrag
        self.ended = ended
        home = scroll
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
        hold.source = view
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

    /// From the recognizer that saw the hold, until the window's `TouchFollow` has reported the finger.
    func pressMoved(to windowPoint: NSPoint) { if !followSeen { moved(to: windowPoint) } }
    func pressLifted(at windowPoint: NSPoint) { if !followSeen { lifted(at: windowPoint) } }
    func pressCancelled() { if !followSeen { cancelled() } }

    /// From the window's `TouchFollow`, which hears the finger anywhere in the window, over the page too.
    func fingerMoved(to windowPoint: NSPoint, in window: NSWindow) {
        guard followed, window === self.window else { return }
        followSeen = true
        moved(to: windowPoint)
    }
    func fingerLifted(at windowPoint: NSPoint, in window: NSWindow) { if takesFollower(in: window) { lifted(at: windowPoint) } }
    func fingerCancelled(in window: NSWindow) { if takesFollower(in: window) { cancelled() } }

    /// The follower's lift ends the hold once it has reported the finger, or once the view held has gone, whose
    /// recognizer then never hears the lift.
    private func takesFollower(in window: NSWindow) -> Bool {
        followed && window === self.window && (followSeen || source?.window == nil)
    }

    func moved(to windowPoint: NSPoint) {
        guard !isFinished else { return }
        point = windowPoint
        if let carry { carry.move(to: windowPoint); return }
        let onMenu = menu?.touchContains(windowPoint) ?? false
        switch Self.step(from: start, to: windowPoint, onMenu: onMenu, wasOnMenu: wasOnMenu, canDrag: startDrag != nil && !dragFailed,
                         leftHome: hasLeftHome(windowPoint)) {
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

    /// Whether `windowPoint` is out of the list the finger was held in.
    private func hasLeftHome(_ windowPoint: NSPoint) -> Bool {
        guard let home, home.window != nil else { return false }
        return !home.bounds.contains(home.convert(windowPoint, from: nil))
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
        abs(translation.x) >= SpaceSwipe.axisLock && abs(translation.x) > abs(translation.y) * 1.2
    }

    /// Across the sidebar, where up and down is a steep flick: a swipe up to about 55° off level counts, as a thumb's
    /// arc rarely starts flat.
    nonisolated static func isAcrossSidebar(_ translation: NSPoint) -> Bool {
        abs(translation.x) >= SpaceSwipe.axisLock && abs(translation.x) >= abs(translation.y) * 0.7
    }

    /// How far the fingers go before a touch swipe decides which way it goes, for all of it: past the jitter of a
    /// finger landing, so the angle is the hand's and not noise.
    nonisolated static let decision: CGFloat = 10

    nonisolated enum Verdict: Equatable { case undecided, sideways, other }

    /// Which way fingers that have moved by `translation` go, once they have gone `decision` points. `forgiving`: up
    /// to about 55° off level counts as sideways (`isAcrossSidebar`), else about 40° (`isSideways`).
    nonisolated static func verdict(_ translation: NSPoint, forgiving: Bool) -> Verdict {
        guard hypot(translation.x, translation.y) >= decision else { return .undecided }
        return (forgiving ? isAcrossSidebar(translation) : isSideways(translation)) ? .sideways : .other
    }

    /// For `fingers` on a page that moved by `translation` and spread apart by `spread`: two go back or forward as on
    /// the trackpad unless they pinch. One is the page's own (it scrolls); macOS takes three for switching desktops.
    nonisolated static func goesBackOrForward(fingers: Int, translation: NSPoint, spread: CGFloat) -> Bool {
        fingers == 2 && verdict(translation, forgiving: false) == .sideways && abs(spread) < abs(translation.x) / 2
    }

    /// A lone finger is let go once it has moved this far, so one-finger scrolling starts at once.
    nonisolated static let loneFingerMove: CGFloat = 3
    /// Or this long after it landed: a second finger of a two-finger swipe lands within a few milliseconds.
    nonisolated static let loneFingerWait: TimeInterval = 0.04

    /// Whether a single finger, `moved` points from where it landed `sinceLanding` seconds ago, is a scroll and not
    /// the start of a two-finger swipe.
    nonisolated static func isLoneFinger(fingers: Int, moved: CGFloat, sinceLanding: TimeInterval) -> Bool {
        fingers == 1 && (moved >= loneFingerMove || sinceLanding >= loneFingerWait)
    }

    /// Whether fingers on a page can no longer be a back or forward swipe: neither way is open, a lone finger, more
    /// than two, or a pinch. WebKit's scrolling waits on the swipe only until then.
    nonisolated static func ruledOutOnPage(fingers: Int, spread: CGFloat, moved: CGFloat, sinceLanding: TimeInterval,
                                           canGoEitherWay: Bool) -> Bool {
        !canGoEitherWay || fingers > 2 || abs(spread) >= decision || isLoneFinger(fingers: fingers, moved: moved, sinceLanding: sinceLanding)
    }
}

/// Fingers moved across something, decided once: it stays undecided until they have gone `TouchSwipe.decision`
/// points, then begins if `decides` takes the swipe, with the travel so far, or fails, so what waits on it (a list's
/// scrolling) waits only that long. Ends as the first finger lifts.
final class TouchSwipeRecognizer: NSGestureRecognizer {
    let touchOnly = TouchOnly()
    var handler: ((TouchSwipeRecognizer) -> Void)?
    /// Whether the swipe is this one's, asked once the fingers have gone far enough.
    var decides: ((TouchSwipeRecognizer) -> Bool)?
    /// Not ready to decide yet (waiting on the page's answer): asked again on the next move.
    var waits: ((TouchSwipeRecognizer) -> Bool)?
    /// Can't be this swipe whatever the fingers do next: fails at once, so what waits on it goes now.
    var ruledOut: ((TouchSwipeRecognizer) -> Bool)?
    /// The first finger landed.
    var landed: ((TouchSwipeRecognizer) -> Void)?
    /// More fingers than this down and it isn't this swipe.
    var maxFingers = 1
    /// The fingers turned out not to be this swipe: a tap, another way, or more of them.
    var failed: (() -> Void)?
    /// The fingers down so far, or when it decided.
    private(set) var fingers = 0
    /// How far the fingers have moved together since they landed, in the view's terms.
    private(set) var translation = NSPoint.zero
    /// Where the fingers landed, in the view's terms.
    private(set) var start = NSPoint.zero
    /// How much further apart the fingers are than when they landed.
    private(set) var spread: CGFloat = 0
    /// When the first finger landed, and when the latest touch event came.
    private(set) var landedAt: TimeInterval = 0
    private(set) var eventAt: TimeInterval = 0
    private var touches: [(id: any NSCopying & NSObjectProtocol, start: NSPoint, last: NSPoint)] = []
    private var samples: [(time: TimeInterval, point: NSPoint)] = []
    private var following = false

    /// How many of these are following fingers now: the scrolls those fingers make aren't the page's meanwhile.
    private(set) static var followingCount = 0
    static var isFollowing: Bool { followingCount > 0 }

    /// Whether a scroll comes from fingers one of these is following, so it isn't the page's to scroll by. Its end
    /// still goes through, so what saw it begin sees it end.
    static func claims(_ event: NSEvent) -> Bool {
        guard isFollowing, TouchPress.isTouchScroll(at: event.timestamp) else { return false }
        return event.phase != .ended && event.phase != .cancelled && event.momentumPhase.isEmpty
    }

    init(handler: ((TouchSwipeRecognizer) -> Void)? = nil) {
        self.handler = handler
        super.init(target: nil, action: nil)
        target = self
        action = #selector(fire)
        TouchGestures.configure(self, touchOnly, yieldsToScrolling: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?(self) }

    /// Points a second, over the last moment before the fingers lifted (or the last move, while they're down).
    var velocity: NSPoint { Self.velocity(samples, at: endedAt ?? samples.last?.time ?? 0) }
    private var endedAt: TimeInterval?
    /// How much recent movement counts toward the speed, as for a trackpad swipe (`SpaceSwipe.velocityWindow`).
    nonisolated static let velocityWindow = SpaceSwipe.velocityWindow

    /// From `samples` of the translation, over the moment before `now`: still for that long, nothing.
    nonisolated static func velocity(_ samples: [(time: TimeInterval, point: NSPoint)], at now: TimeInterval) -> NSPoint {
        let recent = samples.filter { now - $0.time <= velocityWindow && $0.time <= now }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return .zero }
        let dt = CGFloat(last.time - first.time)
        return NSPoint(x: (last.point.x - first.point.x) / dt, y: (last.point.y - first.point.y) / dt)
    }

    private func centroid(_ points: [NSPoint]) -> NSPoint {
        guard !points.isEmpty else { return .zero }
        let n = CGFloat(points.count)
        return NSPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// The fingers' shared movement and spread, from where each landed to where it is.
    private func measure() {
        let from = centroid(touches.map(\.start)), to = centroid(touches.map(\.last))
        translation = NSPoint(x: to.x - from.x, y: to.y - from.y)
        guard touches.count > 1 else { spread = 0; return }
        let before = touches.map { hypot($0.start.x - from.x, $0.start.y - from.y) }.reduce(0, +)
        let now = touches.map { hypot($0.last.x - to.x, $0.last.y - to.y) }.reduce(0, +)
        spread = (now - before) / CGFloat(touches.count)
    }

    override func touchesBegan(with event: NSEvent) {
        guard let view, state == .possible else { return }
        eventAt = event.timestamp
        if fingers == 0 { landedAt = event.timestamp }
        for touch in event.touches(matching: .began, in: view) {
            let point = touch.location(in: view)
            touches.append((touch.identity, point, point))
        }
        let first = fingers == 0
        if first { start = centroid(touches.map(\.start)) }
        fingers = touches.count
        measure()
        if first { landed?(self) }
        if fingers > maxFingers || ruledOut?(self) == true { fail() }
    }

    override func touchesMoved(with event: NSEvent) {
        guard let view else { return }
        for touch in event.touches(matching: .moved, in: view) {
            guard let i = touches.firstIndex(where: { $0.id.isEqual(touch.identity) }) else { continue }
            touches[i].last = touch.location(in: view)
        }
        measure()
        samples.append((event.timestamp, translation))
        eventAt = event.timestamp
        samples.removeAll { event.timestamp - $0.time > 0.2 }
        switch state {
        case .possible:
            if ruledOut?(self) == true { fail(); return }
            guard hypot(translation.x, translation.y) >= TouchSwipe.decision, waits?(self) != true else { return }
            if decides?(self) == true {
                following = true
                Self.followingCount += 1
                state = .began
            } else {
                fail()
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(with event: NSEvent) {
        endedAt = event.timestamp
        switch state {
        case .began, .changed:
            stopFollowing()
            state = .ended
        case .possible: fail()
        default: break
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        switch state {
        case .began, .changed:
            stopFollowing()
            state = .cancelled
        case .possible: fail()
        default: break
        }
    }

    /// It isn't this swipe: `failed` hears.
    private func fail() {
        state = .failed
        failed?()
    }

    private func stopFollowing() {
        if following { Self.followingCount -= 1 }
        following = false
    }

    isolated deinit { stopFollowing() }

    override func reset() {
        super.reset()
        stopFollowing()
        touches = []
        fingers = 0
        translation = .zero
        start = .zero
        spread = 0
        samples = []
        endedAt = nil
        landedAt = 0
        eventAt = 0
    }

    override func location(in view: NSView?) -> NSPoint {
        guard let own = self.view else { return .zero }
        let point = NSPoint(x: start.x + translation.x, y: start.y + translation.y)
        guard let view else { return own.convert(point, to: nil) }
        return view.convert(point, from: own)
    }
}

/// Two taps on chrome that stands in for the title bar count as a double-click, as two clicks do: AppKit's click
/// from each tap comes as a single click.
@MainActor
enum TouchDoubleTap {
    /// The last tap's click: when, where in the window, and the control it pressed.
    private static var last: (time: TimeInterval, point: NSPoint, window: Int, target: ObjectIdentifier?)?

    /// The click count for a press on `target` (nil: the chrome standing in for the title bar): a mouse's own, or 2
    /// for a finger's second tap close enough to its first on the same target.
    static func clickCount(for event: NSEvent, on target: AnyObject? = nil) -> Int {
        guard event.clickCount < 2, isFromFinger(event.timestamp, landedAt: TouchPress.landedAt) else {
            last = nil
            return event.clickCount
        }
        let id = target.map(ObjectIdentifier.init)
        let previous = last.flatMap { $0.window == event.windowNumber && $0.target == id ? ($0.time, $0.point) : nil }
        if isSecondTap(after: previous, at: event.timestamp, point: event.locationInWindow, interval: NSEvent.doubleClickInterval) {
            last = nil
            return 2
        }
        last = (event.timestamp, event.locationInWindow, event.windowNumber, id)
        return 1
    }

    /// Whether a click at `time` is AppKit's click from a finger that landed at `landedAt`.
    nonisolated static func isFromFinger(_ time: TimeInterval, landedAt: TimeInterval?) -> Bool {
        guard let landedAt else { return false }
        return time >= landedAt - 0.05 && time - landedAt < TouchGestures.tapDuration
    }

    /// Whether a tap at `point` and `time` is the second of a double tap after `previous`.
    nonisolated static func isSecondTap(after previous: (time: TimeInterval, point: NSPoint)?, at time: TimeInterval, point: NSPoint,
                                        interval: TimeInterval) -> Bool {
        guard let previous, time > previous.time, time - previous.time <= interval else { return false }
        return hypot(point.x - previous.point.x, point.y - previous.point.y) <= TouchGestures.target
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

/// The hidden sidebar pulled out by a finger from the window's edge, as on an iPad, and pushed back the same way.
/// Distances are from the window's edge on the sidebar's side, to the card's far edge (its reach).
enum TouchSidebarPull {
    /// How far in from the page's edge a finger may land to pull the sidebar out.
    nonisolated static let edge: CGFloat = 40
    /// The window's outer band, where macOS takes a finger to resize the window: a finger landing there is left to it.
    nonisolated static let resizeBand: CGFloat = 12
    /// Past all the way out the card gives at most this much more, slowing as it goes.
    nonisolated static let overshoot: CGFloat = 24
    /// A flick at least this fast (points a second) keeps it out, or sends it back, however far it went.
    nonisolated static let flickSpeed = SpaceSwipe.flickSpeed

    /// Pulls it out from hidden, or pushes it back in.
    nonisolated enum Take: Equatable { case pull, push }

    /// What a finger landing `x` points in from the window's edge does, the page starting `pageEdge` in: with the
    /// sidebar hidden, at the page's edge it pulls it out; held out by touch, anywhere off it (`onCard`) it pushes it
    /// back, or sends it back if it doesn't swipe that way.
    nonisolated static func take(atX x: CGFloat, pageEdge: CGFloat, revealed: Bool, held: Bool, onCard: Bool) -> Take? {
        if !revealed { return x >= resizeBand && x <= pageEdge + edge ? .pull : nil }
        return held && !onCard ? .push : nil
    }

    /// Whether fingers that let go without deciding were a tap: one, barely moved.
    nonisolated static func isTap(fingers: Int, translation: NSPoint) -> Bool {
        fingers == 1 && hypot(translation.x, translation.y) < TouchGestures.tapSlop
    }

    /// Whether a finger that moved by `translation`, positive away from the window's edge, goes `take`'s way.
    nonisolated static func goes(_ take: Take, _ translation: NSPoint) -> Bool {
        TouchSwipe.verdict(translation, forgiving: true) == .sideways && (take == .pull ? translation.x > 0 : translation.x < 0)
    }

    /// Where the card's far edge is for a finger `travel` points out from where it took the card at `base`: with
    /// the finger one to one, never in past `hidden`, held back past `out`.
    nonisolated static func reach(base: CGFloat, travel: CGFloat, hidden: CGFloat, out: CGFloat) -> CGFloat {
        let reach = base + travel
        guard reach > out else { return max(hidden, reach) }
        return out + overshoot * (1 - exp(-(reach - out) / (overshoot * 2)))
    }

    /// Whether letting go at `reach`, going `velocity` points a second outward, leaves it out: a third of the way
    /// out from hidden, or a third of the way back in from out (`wasOut`), or a flick either way.
    nonisolated static func keeps(reach: CGFloat, out: CGFloat, velocity: CGFloat, wasOut: Bool) -> Bool {
        if velocity >= flickSpeed { return true }
        if velocity <= -flickSpeed { return false }
        return reach >= out * (wasOut ? 2.0 / 3 : 1.0 / 3)
    }
}

/// A sidebar toggle while the sidebar is hidden and a finger has been used in the window lately: in the top pane's
/// strip while the strips run along the page's top, otherwise with the traffic lights, hidden until a tap where they
/// sit shows them (HIG, touch support for hidden controls). A tap brings the sidebar out, a finger dragged from it
/// pulls it out.
enum TouchSidebarGrabber {
    /// Where it shows.
    enum Place: Equatable {
        /// A button in the strip on top of a split's pane.
        case strip
        /// With the traffic lights, on one backing, where the docked sidebar has them and its toggle.
        case lights
    }

    /// The least a finger's target around it is, each way.
    static let fingerTarget: CGFloat = 44

    /// The finger's target around the toggle at `toggle`, kept clear of the traffic lights ending at `lightsMaxX`.
    static func target(around toggle: NSRect, clearOf lightsMaxX: CGFloat? = nil) -> NSRect {
        var box = TouchGestures.box(around: toggle, minimum: fingerTarget)
        if let lightsMaxX, box.minX < lightsMaxX { box.origin.x = lightsMaxX }
        return box
    }

    /// In a strip while a pane's strip is at the top of the page area, otherwise with the lights.
    static func place(stripOnTop: Bool) -> Place { stripOnTop ? .strip : .lights }

    /// Which pane's strip takes it, of panes at `frames` (bottom-up, as AppKit's): the top one on the sidebar's side.
    static func stripPane(_ frames: [NSRect], onRight: Bool) -> Int? {
        guard let top = frames.map(\.maxY).max() else { return nil }
        let row = frames.indices.filter { frames[$0].maxY >= top - 0.5 }
        return onRight ? row.max { frames[$0].maxX < frames[$1].maxX } : row.min { frames[$0].minX < frames[$1].minX }
    }

    /// The backing's inset around the toggle.
    static let inset: CGFloat = 3
    /// The backing's room before the lights: as much as from the toggle's glyph to its trailing edge.
    static var lightsMargin: CGFloat { inset + (Tokens.Sidebar.button - Tokens.Sidebar.glyph) / 2 }

    /// The group's frame, top-down: around the toggle at `toggle`, reaching back over the lights from `lightsMinX`.
    static func groupFrame(toggle: NSRect, lightsMinX: CGFloat?) -> NSRect {
        let around = toggle.insetBy(dx: -inset, dy: -inset)
        guard let lightsMinX else { return around }
        let minX = lightsMinX - lightsMargin
        return NSRect(x: minX, y: around.minY, width: around.maxX - minX, height: around.height)
    }

    /// A finger landed in the window this recently: it shows.
    nonisolated static let recent: TimeInterval = 15 * 60

    /// Whether it shows: the sidebar hidden, no bar above the page (which has a toggle of its own), a finger landed
    /// at `touchedAt` within `recent` of `now`, and the pointer hasn't moved since.
    nonisolated static func shows(sidebarShown: Bool, barShown: Bool = false, touchedAt: TimeInterval?, pointerMovedAt: TimeInterval?,
                                  now: TimeInterval) -> Bool {
        guard !sidebarShown, !barShown, let touchedAt, now >= touchedAt, now - touchedAt < recent else { return false }
        return pointerMovedAt.map { $0 < touchedAt } ?? true
    }

    /// Shown by a tap with the lights, it goes this long after the last finger in its zone.
    nonisolated static let revealFor: TimeInterval = 3
    /// Shown this long right after the sidebar hides while a finger is in use, so it can be found.
    nonisolated static let hintFor: TimeInterval = 2
    /// How far the zone that shows it reaches past the group, toward the page, and down from the window's top.
    static let zonePadding: CGFloat = 16
    static let zoneHeight: CGFloat = 52

    /// The zone a tap shows it from, top-down: from the window's edge on the sidebar's side to past the group at `group`.
    static func revealZone(group: NSRect, width: CGFloat, onRight: Bool) -> NSRect {
        let height = max(zoneHeight, group.maxY)
        guard onRight else { return NSRect(x: 0, y: 0, width: group.maxX + zonePadding, height: height) }
        let minX = group.minX - zonePadding
        return NSRect(x: minX, y: 0, width: width - minX, height: height)
    }

    /// What a finger landing does to it with the lights.
    enum Landing: Equatable {
        /// Hidden, in its zone: it shows, and the tap does nothing else.
        case reveal
        /// Shown, in its zone: it stays a while longer.
        case keep
        /// Shown, elsewhere: it goes, and the tap is the page's.
        case hide
        case none
    }

    /// For a finger landing in its zone (`inZone`) or not, while it can show with the lights (`available`).
    nonisolated static func landing(inZone: Bool, revealed: Bool, available: Bool) -> Landing {
        guard available else { return revealed ? .hide : .none }
        if revealed { return inZone ? .keep : .hide }
        return inZone ? .reveal : .none
    }

    /// Where its toggle goes with the lights, top-down from the window's top left: where the docked sidebar, starting
    /// `sidebarMinX` in, has its toggle (`toggle`, in the sidebar).
    nonisolated static func frame(toggle: NSRect, sidebarMinX: CGFloat) -> NSRect { toggle.offsetBy(dx: sidebarMinX, dy: 0) }
}

/// Debug builds: the last touch decisions on pages and in the sidebar, for `touchlog` and debug.log.
@MainActor
enum TouchLog {
    private(set) static var lines: [String] = []

    static func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        let text = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line()
        lines.append(text)
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        debugLog("touch " + text)
        #endif
    }

    /// The touch recognizers on `view` and its ancestors that are under way or done, and every pan and swipe, with
    /// their states (0 possible, 1 began, 2 changed, 3 ended, 4 cancelled, 5 failed).
    static func recognizers(from view: NSView?) -> String {
        sequence(first: view, next: { $0?.superview }).compactMap { $0 }.flatMap { view in
            view.gestureRecognizers.filter {
                $0.allowedTouchTypes.contains(.direct) && ($0.state != .possible || $0 is NSPanGestureRecognizer || $0 is TouchSwipeRecognizer)
            }.map { "\(type(of: view)).\(label($0))=\($0.state.rawValue)" }
        }.joined(separator: " ")
    }

    private static func label(_ recognizer: NSGestureRecognizer) -> String {
        if #available(macOS 26, *), let name = recognizer.name { return name }
        return String(describing: type(of: recognizer))
    }
}

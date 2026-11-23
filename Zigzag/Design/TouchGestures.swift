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
            guard press.state == .began, MenuPanel.current == nil, let window = view?.window,
                  let event = rightMouseDown(at: press.location(in: nil), in: window) else { return }
            open(event)
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

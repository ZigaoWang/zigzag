import AppKit
import WebKit

/// Two fingers sideways on a page goes back or forward, the way Arc and Chrome do it: a round arrow slides in from
/// the page's edge as you swipe, fills once you've gone far enough, and letting go moves at once, with no slow
/// slide of the whole page. A page that can scroll sideways where you are (a carousel, a map, a wide table) keeps
/// the swipe for itself, and so does one that handles the scroll itself (Canva, Figma, Google Maps pan with their own
/// code) or asks for no overscroll (`overscroll-behavior-x`), in whichever frame the swipe lands (Excel's sheet is in
/// one): as in Safari and Chrome, the page sees the swipe's first steps and answers before anything moves. The
/// system's "Swipe between pages" setting is respected, and Settings › Tabs can turn swiping off in Zigzag alone.
@MainActor
final class SwipeNavigator {
    private static let key = "SwipeBetweenPages"
    /// Two fingers sideways go back and forward. On unless turned off in Settings; then every swipe is the page's.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private weak var webView: BrowserWebView?
    private var arrow: SwipeArrowView?

    /// `leaning`: the arrow shows while the page, with nothing sideways under the pointer, still gets the scroll until it answers.
    private enum State { case idle, deciding, leaning, tracking, ignoring, finishing }
    private var state = State.idle
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    /// Fingers on the screen rather than the trackpad: their distance is real travel, not scrolled points.
    private var byTouch = false
    /// -1: back, 1: forward, once the swipe has a direction.
    private var direction = 0
    /// What the page can scroll sideways under the pointer, once the page has answered.
    private var pageScrolls: (left: Bool, right: Bool)?
    /// The pointer is over a frame: only the page inside can say whether it keeps the swipe.
    private var overFrame = false
    /// Whether the page kept this gesture's sideways scrolls for itself (SwipeAnswers), once it has said.
    private var page = SwipeDecision.Page.unknown
    /// When the gesture began, to wait a moment for the page's answer and no longer.
    private var began: TimeInterval = 0
    /// The same moment as wall-clock milliseconds, the time the page's answers carry: one about an earlier gesture's
    /// scrolls (its momentum) arriving now isn't about this one.
    private var beganAt: Double = 0
    /// Counts gestures, so the probe's answer for one that's over is dropped.
    private var gesture = 0
    /// Something covering the page has this gesture (a zoomed-in PDF), and says what room it has.
    private var covered = false
    /// Where the pointer was as the gesture began, to match an answer to a probe sent as the fingers touched down.
    private var beganPoint = NSPoint.zero
    /// The probe sent as the fingers touched down, before the scroll began: where, when, and its answer once back.
    private var early: (point: NSPoint, time: TimeInterval, answer: [Bool]?)?
    /// The page that cancelled sideways scrolls with its own code (a canvas): its swipes wait for its answer again.
    private var keptOn: URL?
    /// The page was asked to listen to this gesture's scrolls (`SwipeAnswers.listen`) and hasn't been told to stop.
    private(set) var pageListens = false
    private var arming = SwipeArming()
    /// Recent finger movement, to tell a quick flick from a slow drag.
    private var samples: [(time: TimeInterval, dx: CGFloat)] = []
    /// Clears the arrow if the gesture's end never arrives (macOS sometimes drops it between quick swipes).
    private var watchdog: DispatchWorkItem?
    /// While the fingers rest mid-swipe no events come at all, which looks the same as a lost end. A rest keeps the
    /// swipe where it is; only doing something else (moving the pointer, a click, a key) shows the fingers are gone.
    private var restMonitor: Any?
    private var restObservers: [NSObjectProtocol] = []
    private var restTimer: Timer?
    /// Where the pointer is on screen.
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    /// Gone back or forward: the page carries on the swipe's way until the next one arrives, or this runs out.
    private var arrival: DispatchWorkItem?
    /// The card that carried the page on, if it moved in one.
    private weak var carried: PageCardView?

    /// How far to swipe before letting go navigates: a third of the page, as in Safari (#377).
    private var threshold: CGFloat {
        let width = webView?.bounds.width ?? 0
        return byTouch ? SwipeDecision.touchDistance(forWidth: width) : SwipeDecision.distance(forWidth: width)
    }

    init(webView: BrowserWebView) {
        self.webView = webView
    }

    isolated deinit {
        watchdog?.cancel()
        stopWatchingRest()
    }

    /// The page left its window (another tab came to the front mid-swipe): its gesture's end will never come here,
    /// so the swipe is dropped now rather than holding over a page that isn't shown.
    func leftWindow() {
        pageArrived()
        watchdog?.cancel()
        stopWatchingRest()
        if state == .tracking || state == .leaning { cancel() }
        state = .idle
        stopPageListening()
    }

    /// Returns true when it took the event, so the page doesn't also scroll with it. `room`, from something
    /// covering the page (a zoomed-in PDF), is which way it can still scroll sideways, in place of asking the page.
    func handle(_ event: NSEvent, room: (left: Bool, right: Bool)? = nil) -> Bool {
        // Fingers touching down: the page is asked about the spot now, so it has answered by the time they move.
        if event.phase == .mayBegin, room == nil, state != .tracking, state != .leaning { probeEarly(event); return false }
        if event.phase == .ended || event.phase == .cancelled { stopPageListening() }
        // Mid-scroll with no swipe under way: nothing to decide, so no settings are read for it.
        if state == .idle || state == .ignoring, Self.isMidGesture(event.phase) { return false }
        // A video in full screen keeps every swipe: going back there would leave the page from under it.
        guard let webView, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled, Self.isOn,
              webView.fullscreenState == .notInFullscreen else { return false }
        // Momentum after a swipe that navigated (or was abandoned) is part of it, not a scroll.
        if !event.momentumPhase.isEmpty {
            // Still tracking: the fingers lifted and the gesture's end was lost, so this is the release.
            if state == .tracking || state == .leaning { release(at: event.timestamp, ended: true) }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { if state == .finishing { state = .idle } }
            return state == .finishing
        }
        switch event.phase {
        case .began:
            // A new gesture: anything left from the last one goes now, a page left shifted included.
            if state == .tracking || state == .leaning { cancel() }
            if let arrow { arrow.removeFromSuperview(); self.arrow = nil }
            stopPageListening()
            pageArrived()
            watchdog?.cancel()
            stopWatchingRest()
            guard webView.window != nil else { state = .idle; stopPageListening(); return false }
            // Fingers dragging the page on the screen scroll it; their own swipe goes back (PageHolder).
            if TouchPress.isTouchScroll(at: event.timestamp) { state = .ignoring; stopPageListening(); return false }
            state = .deciding
            // The first step's movement counts toward deciding.
            dx = event.scrollingDeltaX; dy = event.scrollingDeltaY
            direction = 0; arming = SwipeArming(); pageScrolls = nil; overFrame = false; samples = []
            byTouch = false
            began = event.timestamp
            beganAt = (Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - event.timestamp)) * 1000
            gesture += 1
            // Something covering the page has the scroll, not the page: what it says is its room.
            covered = room != nil
            page = covered ? .left : .unknown
            beganPoint = webView.convert(event.locationInWindow, from: nil)
            log(at: event.timestamp, "began")
            if let room { pageScrolls = room } else {
                // What the page said as the fingers touched down holds until the fresh answer comes.
                if let early, let answer = early.answer, Self.sameSpot(early.point, beganPoint), event.timestamp - early.time < 1 {
                    heard(answer, early: true)
                }
                probe(at: beganPoint)
                listenIfSideways()
            }
            return false
        case .changed:
            // What covers the page knows its room as it scrolls: it's kept up to date through the gesture.
            if let room { pageScrolls = room }
            // Back is a scroll toward the page's left edge, as in Safari: fingers to the right with natural
            // scrolling, to the left without it.
            dx += event.scrollingDeltaX
            dy += event.scrollingDeltaY
            samples.append((event.timestamp, dx))
            if samples.count > 8 { samples.removeFirst(samples.count - 8) }
            switch state {
            case .deciding, .leaning:
                if room == nil { listenIfSideways() }
                let decision = SwipeDecision.decide(dx: dx, dy: dy, canGoBack: canGo.back, canGoForward: canGo.forward, pageScrolls: pageScrolls, page: page,
                                                    waited: event.timestamp - began, overFrame: overFrame,
                                                    leans: keptOn == nil || webView.url != keptOn)
                switch decision {
                case .undecided:
                    if state == .leaning { update(); armWatchdog() }
                    return false
                case .ignore:
                    if state == .leaning { cancel() }
                    log(at: event.timestamp, "ignored dx=\(Int(dx)) dy=\(Int(dy)) page=\(page) scrolls=\(String(describing: pageScrolls))")
                    state = .ignoring
                    stopPageListening()
                    return false
                case .lean(let wanted), .track(let wanted):
                    // Already leaning the same way: the arrow carries on from where it is.
                    if state != .leaning || direction != wanted {
                        if state == .leaning { cancel() }
                        direction = wanted
                        showArrow()
                    }
                    let tracks = decision == .track(wanted)
                    if tracks || state != .leaning {
                        log(at: event.timestamp, "\(tracks ? "tracking" : "leaning") dx=\(Int(dx)) dy=\(Int(dy)) page=\(page) probed=\(pageScrolls != nil)")
                    }
                    state = tracks ? .tracking : .leaning
                    // Tracking, the page gets no more of the gesture to answer about.
                    if tracks { stopPageListening() }
                    update()
                    armWatchdog()
                    // Leaning, the page still gets the scroll, so it can answer that it keeps it.
                    return tracks
                }
            case .tracking:
                // The page answered late that it scrolls this way: hand the swipe back.
                if page == .took || pageTakes(direction) { cancel(); state = .ignoring; return false }
                update()
                armWatchdog()
                return true
            default:
                return false
            }
        case .ended, .cancelled:
            release(at: event.timestamp, ended: event.phase == .ended)
            // The page saw the gesture begin, so it sees it end too (an end carries no movement to scroll by).
            return false
        default:
            return state == .tracking
        }
    }

    /// The fingers lifted (`ended`) or the gesture was called off: it goes or springs back, and nothing is left over.
    private func release(at time: TimeInterval, ended: Bool) {
        let wasTracking = state == .tracking
        watchdog?.cancel()
        watchdog = nil
        stopWatchingRest()
        stopPageListening()
        // Let go before the page answered: it never navigates, as before the arrow showed this early.
        if state == .leaning { cancel() }
        if wasTracking {
            // Letting go goes when the arrow is filled, or with a flick still moving as the fingers lift.
            if ended, arming.release(progress: progress, speed: speed(at: time)) { go() } else { cancel() }
            state = .finishing
        } else {
            state = .idle
        }
    }

    /// What the page gets of `event`: while the arrow leans in, its sideways part only, so the page doesn't move up
    /// or down under a swipe that's under way.
    func forPage(_ event: NSEvent) -> NSEvent {
        guard state == .leaning, event.scrollingDeltaY != 0, let copy = event.cgEvent?.copy() else { return event }
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: copy) ?? event
    }

    /// A scroll that neither begins nor ends a gesture: a step, the glide after it, or a wheel's turn.
    nonisolated static func isMidGesture(_ phase: NSEvent.Phase) -> Bool {
        phase != .began && phase != .ended && phase != .cancelled
    }

    /// The page's answer for one of this gesture's sideways scrolls, from the frame it landed in: whether it keeps
    /// them (`kept`). `at` is when that scroll came, in wall-clock milliseconds.
    func pageAnswered(kept: Bool, at: Double) {
        // Covered by something else (a zoomed-in PDF), the page isn't what's scrolling.
        guard !covered, state == .deciding || state == .leaning || state == .tracking else { return }
        let was = page
        page = SwipeDecision.page(page, answered: kept, at: at, began: beganAt)
        guard page != was else { return }
        log(at: ProcessInfo.processInfo.systemUptime, "page answered kept=\(kept)")
        // Kept with no room to scroll there: it pans with its own code, so its next swipes wait for it again.
        if page == .took, at.isFinite, state == .leaning || pageScrolls.map({ !$0.left && !$0.right }) == true { keptOn = webView?.url }
        // It took it after all, answering after the swipe had started: the arrow goes and the page has the rest.
        if page == .took, state == .tracking || state == .leaning { cancel(); state = .ignoring }
        // Kept, it's the page's for the rest of the gesture: nothing more to hear.
        if page == .took { stopPageListening() }
    }

    // MARK: Two fingers on the screen

    /// Whether two fingers swiping sideways on the page may go `wanted`'s way (-1 back, 1 forward): the system's
    /// setting for touch swipes and Zigzag's own allow it, and there's somewhere to go.
    func takesTouchSwipe(_ wanted: Int) -> Bool {
        guard let webView, Self.isOn, webView.fullscreenState == .notInFullscreen, webView.window != nil else { return false }
        guard #available(macOS 27, *), NSEvent.isTouchSwipeNavigationEnabled else { return false }
        return wanted < 0 ? webView.owner?.canGoBackOrReturn ?? webView.canGoBack : webView.canGoForward
    }

    /// Fingers on the screen are swiping `wanted`'s way: the arrow comes, as for two fingers on the trackpad.
    func touchBegan(direction wanted: Int) {
        if state == .tracking || state == .leaning { cancel() }
        if let arrow { arrow.removeFromSuperview(); self.arrow = nil }
        pageArrived()
        watchdog?.cancel()
        stopWatchingRest()
        direction = wanted
        dx = 0; dy = 0; arming = SwipeArming(); samples = []
        byTouch = true
        state = .tracking
        showArrow()
        update()
    }

    /// The fingers are `dx` points from where they landed (positive to the right) at `time`.
    func touchMoved(dx moved: CGFloat, at time: TimeInterval) {
        guard state == .tracking else { return }
        dx = moved
        samples.append((time, moved))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        update()
    }

    /// Lifted at `time`: goes when the arrow is filled or with a flick, as letting go of the trackpad does.
    func touchEnded(at time: TimeInterval, cancelled: Bool) {
        guard state == .tracking else { return }
        if !cancelled, arming.release(progress: progress, touchSpeed: speed(at: time)) { go() } else { cancel() }
        state = .idle
    }

    #if DEBUG
    var isTracking: Bool { state == .tracking }
    /// Showing the arrow, tracking or leaning.
    var isShowing: Bool { arrow != nil || state == .tracking || state == .leaning }
    /// Nothing of a gesture left: no arrow, no page shifted, no listener, no timer.
    var isClean: Bool {
        arrow == nil && state != .tracking && state != .leaning && state != .deciding && !pageListens && watchdog == nil
            && restMonitor == nil && (webView?.layer?.affineTransform() ?? .identity) == .identity
    }
    /// Where the page could go, in place of its history.
    var debugCanGo: (back: Bool, forward: Bool)?
    /// The probe's answer, as if the page had said it.
    func debugHeard(left: Bool, right: Bool, frame: Bool = false, still: Bool = false) { heard([left, right, frame, still], early: false) }
    /// Runs the watchdog's timer now, as if the fingers had been still that long.
    func debugRest() { watchdog?.perform() }
    /// Gone, with the page carried on and waiting for the next one.
    var isCarryingOn: Bool { arrival != nil }
    #endif

    /// The page gone to has arrived (or failed to): the web view is back in place, at once.
    func pageArrived() {
        guard let arrival else { return }
        arrival.cancel()
        self.arrival = nil
        if let carried { carried.endSwipe() } else if let layer = webView?.layer { SwipeExit.rest(layer) }
        carried = nil
    }

    private var canGo: (back: Bool, forward: Bool) {
        #if DEBUG
        if let debugCanGo { return debugCanGo }
        #endif
        guard let webView else { return (false, false) }
        return (webView.owner?.canGoBackOrReturn ?? webView.canGoBack, webView.canGoForward)
    }

    private var progress: CGFloat { max(0, CGFloat(-direction) * dx) / threshold }

    private func speed(at now: TimeInterval) -> CGFloat {
        SwipeDecision.speed(samples, at: now, direction: direction)
    }

    private func armWatchdog() {
        watchdog?.cancel()
        stopWatchingRest()
        // Still for a moment: the fingers may be resting (to read a little more before going back), so the swipe
        // holds. Anything else the hand does means the gesture ended without saying so, and it's dropped then.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .tracking || self.state == .leaning else { return }
            // Not shown any more: there's no resting on a page that's gone.
            guard self.webView?.window != nil else { self.abandonRest(); return }
            let gone: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
                                               .magnify, .rotate, .swipe, .smartMagnify, .scrollWheel]
            self.restMonitor = NSEvent.addLocalMonitorForEvents(matching: gone) { [weak self] event in
                // This gesture's own steps carry on; only a new gesture or a wheel's turn shows it ended.
                if event.type != .scrollWheel || SwipeNavigator.startsAnother(event) {
                    MainActor.assumeIsolated { self?.abandonRest() }
                }
                return event
            }
            // Pointer moves reach a window only when it tracks them (a Zigzag Mini that isn't key doesn't), so it's watched.
            let pointer = self.pointer()
            self.restTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let now = self?.pointer() else { return }
                    if hypot(now.x - pointer.x, now.y - pointer.y) > 2 { self?.abandonRest() }
                }
            }
            // The window or the app going to the back ends it too.
            let center = NotificationCenter.default
            self.restObservers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: self.webView?.window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.abandonRest() }
                },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.abandonRest() }
                },
            ]
            // A rest that long is a lost gesture, not a pause.
            let lost = DispatchWorkItem { [weak self] in self?.abandonRest() }
            self.watchdog = lost
            DispatchQueue.main.asyncAfter(deadline: .now() + SwipeDecision.lostAfter, execute: lost)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func abandonRest() {
        stopWatchingRest()
        watchdog?.cancel()
        watchdog = nil
        stopPageListening()
        guard state == .tracking || state == .leaning else { return }
        cancel()
        state = .idle
    }

    private func stopWatchingRest() {
        if let restMonitor { NSEvent.removeMonitor(restMonitor) }
        restMonitor = nil
        restObservers.forEach(NotificationCenter.default.removeObserver)
        restObservers = []
        restTimer?.invalidate()
        restTimer = nil
    }

    /// A scroll that isn't a step of a gesture under way: a new one touching down or starting, or a wheel's turn.
    nonisolated static func startsAnother(_ event: NSEvent) -> Bool {
        event.phase == .mayBegin || event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty)
    }

    private func pageTakes(_ direction: Int) -> Bool {
        guard let pageScrolls else { return false }
        return direction < 0 ? pageScrolls.left : pageScrolls.right
    }

    /// Asks the page, before the gesture's first scroll reaches it, whether anything under the pointer (or the page
    /// itself) can scroll sideways and which way, whether it asked for no overscroll, and whether the pointer is over
    /// a frame, which only the frame's own answer can speak for.
    private func probe(at point: NSPoint) {
        guard let webView else { return }
        let gesture = gesture
        webView.evaluateJavaScript(probeScript(at: point, in: webView), in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.gesture == gesture, !self.covered,
                  case .success(let value) = result, let answer = value as? [Bool], answer.count >= 4 else { return }
            self.heard(answer, early: false)
        }
    }

    /// Fingers touched down at `event`'s spot: the same probe, ahead of the gesture it may begin.
    private func probeEarly(_ event: NSEvent) {
        guard let webView, webView.window != nil, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              Self.isOn, webView.fullscreenState == .notInFullscreen else { return }
        let point = webView.convert(event.locationInWindow, from: nil), time = event.timestamp
        early = (point, time, nil)
        webView.evaluateJavaScript(probeScript(at: point, in: webView), in: nil, in: .defaultClient) { [weak self] result in
            guard let self, let early = self.early, early.time == time,
                  case .success(let value) = result, let answer = value as? [Bool], answer.count >= 4 else { return }
            self.early?.answer = answer
            // The gesture began before this came back, at the same spot, and its own probe hasn't answered yet.
            if self.state == .deciding || self.state == .leaning, !self.covered, self.pageScrolls == nil,
               Self.sameSpot(point, self.beganPoint), self.began - time < 1 {
                self.heard(answer, early: true)
            }
        }
    }

    /// The probe's answer for this gesture: room left and right, a frame, no overscroll.
    private func heard(_ answer: [Bool], early: Bool) {
        pageScrolls = (answer[0], answer[1])
        overFrame = answer[2]
        log(at: ProcessInfo.processInfo.systemUptime, "probe\(early ? " (touch-down)" : "") left=\(answer[0]) right=\(answer[1]) frame=\(answer[2]) still=\(answer[3])")
        // The page asked for no overscroll: like a page that cancels the scrolls, it keeps the gesture.
        if answer[3] { pageAnswered(kept: true, at: .infinity) }
    }

    /// The gesture so far is more sideways than up and down: the page starts listening to its scrolls, to say whether
    /// it keeps them. A page that cancels them has wheel listeners of its own, so it hears the next step at once.
    /// Up and down never starts it: a listener coming and going costs the page a slow frame.
    private func listenIfSideways() {
        guard !pageListens, dx != 0, abs(dx) >= abs(dy), let webView else { return }
        pageListens = true
        webView.evaluateJavaScript("if (typeof window.\(SwipeAnswers.listen) === 'function') window.\(SwipeAnswers.listen)(true);",
                                   in: nil, in: .defaultClient) { _ in }
    }

    /// The gesture is decided, or over: the page stops listening to its scrolls.
    private func stopPageListening() {
        guard pageListens else { return }
        pageListens = false
        webView?.evaluateJavaScript("if (typeof window.\(SwipeAnswers.listen) === 'function') window.\(SwipeAnswers.listen)(false);",
                                    in: nil, in: .defaultClient) { _ in }
    }

    /// Two-finger scrolls leave the pointer where it is, so a touch-down and the gesture after it share a spot.
    nonisolated static func sameSpot(_ a: NSPoint, _ b: NSPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 2 }

    /// Debug builds: a line with the milliseconds since the gesture began, to see what a swipe waited for.
    private func log(at time: TimeInterval, _ line: @autoclosure () -> String) {
        #if DEBUG
        debugLog(String(format: "swipe +%.0f ms ", (time - began) * 1000) + line())
        #endif
    }

    /// What's under `point`: its room left and right, whether it's a frame, whether it asked for no overscroll, and
    /// whether it pans sideways under a finger itself (`touch-action`).
    private func probeScript(at point: NSPoint, in webView: WKWebView) -> String {
        // Pinched in, the page's points are bigger still.
        let zoom = webView.pageZoom * webView.magnification
        let x = point.x / zoom, y = (webView.isFlipped ? point.y : webView.bounds.height - point.y) / zoom
        return """
        (() => {
          // Pinched in, the visible part starts that far into the page.
          const v = window.visualViewport, el = document.elementFromPoint(\(x) + (v ? v.offsetLeft : 0), \(y) + (v ? v.offsetTop : 0));
          const room = (\(SwipeAnswers.sideways))(el, getComputedStyle, document.scrollingElement, [document.documentElement, document.body], window.visualViewport);
          return [room.left, room.right, !!el && /^(IFRAME|FRAME|EMBED|OBJECT)$/.test(el.tagName), room.still, (\(SwipeAnswers.pansItself))(el, getComputedStyle)];
        })()
        """
    }

    /// When the first finger landed on the page, and what the page said about the spot since.
    private var touchLandedAt: TimeInterval = 0
    private(set) var touchRoom: SwipeDecision.TouchRoom?

    /// A finger landed at `point` (the web view's terms): the page is asked about the spot, as a trackpad swipe's
    /// first scroll asks it, so it has answered by the time the fingers have gone far enough to decide.
    func touchLanded(at point: NSPoint, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        touchLandedAt = time
        touchRoom = nil
        guard let webView, webView.window != nil else { return }
        gesture += 1
        let gesture = gesture
        webView.evaluateJavaScript(probeScript(at: point, in: webView), in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.gesture == gesture, case .success(let value) = result, let a = value as? [Bool], a.count == 5 else { return }
            self.touchRoom = SwipeDecision.TouchRoom(left: a[0], right: a[1], frame: a[2], still: a[3], pansItself: a[4])
            TouchLog.note("page answered left=\(a[0]) right=\(a[1]) frame=\(a[2]) still=\(a[3]) pansItself=\(a[4])")
        }
    }

    /// Whether the page leaves fingers going `wanted`'s way to go back or forward (nil: it hasn't said yet).
    func touchPageLeaves(_ wanted: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool? {
        SwipeDecision.touch(wanted, room: touchRoom, waited: time - touchLandedAt)
    }

    #if DEBUG
    func debugSetTouchRoom(_ room: SwipeDecision.TouchRoom?, landedAt: TimeInterval) {
        touchRoom = room
        touchLandedAt = landedAt
    }

    /// Debug builds: holds a swipe at `progress` toward navigating (1 arms it), so a test copy can show it without a
    /// trackpad (`swipestep back 0.5`). `nil` releases without navigating.
    func debugHold(direction wanted: Int, progress value: CGFloat?) {
        guard let value else {
            if state == .tracking { cancel() }
            state = .idle
            return
        }
        if state != .tracking || direction != wanted {
            if state == .tracking { cancel() }
            pageArrived()
            direction = wanted
            arming = SwipeArming()
            state = .tracking
            showArrow()
        }
        dx = CGFloat(-wanted) * value * threshold
        update()
    }
    #endif

    // MARK: The arrow

    private func showArrow() {
        guard let webView, let overlay = (webView.window?.windowController as? SwipeArrowHost)?.swipeArrowLayer else { return }
        arrow?.removeFromSuperview()
        let arrow = SwipeArrowView(back: direction < 0)
        overlay.addSubview(arrow)
        self.arrow = arrow
    }

    /// The card that slides this page aside over its own backdrop; nil when the page moves by itself.
    private var card: PageCardView? {
        var view = webView?.superview
        while let current = view, !(current is PageCardView) { view = current.superview }
        guard let card = view as? PageCardView, card.webView === webView else { return nil }
        return card
    }

    /// How far the page has moved with the fingers, at most `maxShift`, with resistance so it slows as it goes.
    private var shift: CGFloat {
        // Reduce Motion: the page stays put and the arrow alone shows the swipe.
        guard !Tokens.Motion.reduceMotion else { return 0 }
        let pulled = max(0, CGFloat(-direction) * dx)
        return Self.maxShift * (1 - exp(-pulled / (Self.maxShift * 1.6)))
    }
    private static let maxShift: CGFloat = 72

    private func update() {
        guard let webView, let arrow, let overlay = arrow.superview else { return }
        // The page follows the fingers a little, and the arrow waits in the gap that opens at its edge.
        let offset = shift * CGFloat(-direction)
        if let card {
            card.setSwipeOffset(offset)
        } else {
            Tokens.Motion.withoutAnimation { webView.layer?.setAffineTransform(CGAffineTransform(translationX: offset, y: 0)) }
        }
        let page = overlay.convert(webView.bounds, from: webView)
        arrow.frame = SwipeArrowView.frame(in: page, offset: offset, back: direction < 0)
        // Ring and fill follow the distance only, so fingers resting keep both where they are (#377).
        // One tap as it arms; hovering at the line doesn't arm it again.
        if arming.step(progress: progress) { Haptics.snap() }
        arrow.progress = min(progress, 1)
        if arrow.isArmed != arming.armed { arrow.isArmed = arming.armed }
    }

    /// Let go too soon: the page springs back into place.
    private func settlePage() {
        if let card { card.settleSwipe(); return }
        guard let layer = webView?.layer else { return }
        let from = layer.presentation()?.affineTransform() ?? layer.affineTransform()
        Tokens.Motion.withoutAnimation { layer.setAffineTransform(.identity) }
        guard from != .identity, !Tokens.Motion.reduceMotion else { return }
        // The app's critically damped spring, as stiff as before (a perceptual 0.35 s).
        let back = Tokens.Motion.springAnimation(keyPath: "transform", duration: Tokens.Motion.large)
        back.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(from))
        back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(back, forKey: "swipe.settle")
    }

    private func go() {
        watchdog?.cancel()
        watchdog = nil
        stopWatchingRest()
        // Let go after its tab went to the back: it isn't where you're looking, so it doesn't move.
        guard let webView, webView.window != nil else { cancel(); return }
        // Its tab closing as it goes back to its opener doesn't call the swipe off.
        state = .finishing
        // In a split, the page swiped is the one that goes, and the one you're in from now on (#170).
        if let owner = webView.owner { owner.host?.tabWantsFocus(owner) }
        let arrow = arrow
        self.arrow = nil
        // Back to the opener closes the tab, so no page arrives here: it goes back in place now.
        let closes = direction < 0 && webView.owner.map { !$0.canGoBack && $0.returnsToOpener } == true
        if closes || Tokens.Motion.reduceMotion { restPage() } else { carryOn() }
        if direction < 0 { if let owner = webView.owner { owner.goBack() } else { webView.goBack() } } else if let owner = webView.owner { owner.goForward() } else { webView.goForward() }
        arrow?.leave(toward: direction, navigated: true)
    }

    /// The page slides on a little and dims, rather than springing back, until the next one arrives (#508).
    private func carryOn() {
        guard let webView else { return }
        let to = SwipeExit.offset(from: shift * CGFloat(-direction), direction: direction)
        if let card {
            card.carrySwipe(to: to)
            carried = card
        } else if let layer = webView.layer {
            SwipeExit.carry(layer, to: to)
        }
        arrival?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pageArrived() }
        arrival = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SwipeExit.wait, execute: work)
    }

    /// The page straight back in place, with no animation.
    private func restPage() {
        arrival?.cancel()
        arrival = nil
        if let card { card.endSwipe() } else if let layer = webView?.layer { SwipeExit.rest(layer, undims: false) }
    }

    private func cancel() {
        watchdog?.cancel()
        watchdog = nil
        stopWatchingRest()
        pageArrived()
        settlePage()
        arrow?.leave(toward: -direction, navigated: false)
        arrow = nil
    }
}

/// How a page leaves after a swipe that went back or forward, until the next one takes its place (#508).
enum SwipeExit {
    /// How much further the page goes after letting go.
    static let travel: CGFloat = 44
    /// How dim it gets meanwhile.
    static let dim: Float = 0.85
    static let duration: TimeInterval = 0.18
    /// The longest the page waits shifted for the next one to arrive.
    static let wait: TimeInterval = 0.4

    /// Where a page shifted `offset` goes after a swipe going `direction` (-1 back, 1 forward).
    static func offset(from offset: CGFloat, direction: Int) -> CGFloat {
        offset + travel * CGFloat(-direction)
    }

    /// Slides `layer` on to `offset` and dims it, eased out.
    @MainActor static func carry(_ layer: CALayer, to offset: CGFloat, dims: Bool = true) {
        let from = layer.presentation()?.affineTransform() ?? layer.affineTransform()
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        Tokens.Motion.withoutAnimation {
            layer.removeAnimation(forKey: "swipe.settle")
            layer.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
            if dims { layer.opacity = dim }
        }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(from))
        move.toValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(layer.affineTransform()))
        move.duration = duration
        move.timingFunction = Tokens.Motion.easeOut
        layer.add(move, forKey: "swipe.settle")
        guard dims else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = dim
        fade.duration = duration
        fade.timingFunction = Tokens.Motion.easeOut
        layer.add(fade, forKey: "swipe.dim")
    }

    /// `layer` back in place, and fully there again if `carry` dimmed it, with no animation.
    @MainActor static func rest(_ layer: CALayer, undims: Bool = true) {
        Tokens.Motion.withoutAnimation {
            layer.removeAnimation(forKey: "swipe.settle")
            layer.setAffineTransform(.identity)
            guard undims else { return }
            layer.removeAnimation(forKey: "swipe.dim")
            layer.opacity = 1
        }
    }
}

/// Whether the arrow is filled, step by step while the fingers are down: it fills at the full distance and stays filled
/// until `holds` no longer does. Speed counts only at the release, since nothing says when resting fingers stopped (#377).
struct SwipeArming {
    private(set) var armed = false

    /// Returns true when this step armed it, the one moment for a tap.
    mutating func step(progress: CGFloat) -> Bool {
        let was = armed
        armed = was ? SwipeDecision.holds(progress: progress) : progress >= 1
        return armed && !was
    }

    /// Whether letting go now navigates: filled at this distance, or a flick still going as the fingers lift.
    mutating func release(progress: CGFloat, speed: CGFloat) -> Bool {
        _ = step(progress: progress)
        return armed || SwipeDecision.commits(progress: progress, speed: speed)
    }

    /// The same, for fingers on the screen, whose flick is slower in points than a trackpad's scroll.
    mutating func release(progress: CGFloat, touchSpeed speed: CGFloat) -> Bool {
        _ = step(progress: progress)
        return armed || SwipeDecision.commits(progress: progress, touchSpeed: speed)
    }
}

/// Whether a two-finger swipe on a page goes back or forward, from how far the fingers have gone and what the page
/// said about it.
enum SwipeDecision: Equatable {
    /// Not sure yet: the page keeps getting the swipe meanwhile, as if nothing were deciding.
    case undecided
    /// Back (-1) or forward (1): the arrow comes and the page gets no more of the gesture.
    case track(Int)
    /// Back (-1) or forward (1) unless the page says otherwise: the arrow comes with the fingers while the page, which
    /// has nothing sideways under the pointer, still gets the scroll until it answers or the wait is up.
    case lean(Int)
    /// The page's, or a scroll: it gets the whole gesture.
    case ignore

    /// What the page did with the gesture's sideways scrolls, as SwipeAnswers hears it.
    enum Page { case unknown, left, took }

    /// How far a swipe on a page `width` wide goes before letting go navigates: a third of a narrow page, and no
    /// more than 180 scrolled points on a wide one, since the fingers travel the same trackpad whatever the window's size.
    static func distance(forWidth width: CGFloat) -> CGFloat { min(max(width / 3, 120), 180) }

    /// Whether letting go navigates, `progress` along `distance` and the fingers going at `speed` points a second
    /// the swipe's way: all the way, or a flick that got started. Pulled back, it doesn't.
    static func commits(progress: CGFloat, speed: CGFloat) -> Bool {
        progress >= 1 || (progress >= 0.3 && speed > 450)
    }

    /// How far fingers on the screen travel before letting go navigates: about the 2 cm the trackpad's distance
    /// takes the fingers there, since a trackpad scrolls further than the fingers move.
    static let touchDistance: CGFloat = 100

    /// `touchDistance`, and no more than a third of a narrow page (a split pane, Zigzag Mini), as on the trackpad.
    static func touchDistance(forWidth width: CGFloat) -> CGFloat { min(touchDistance, max(width / 3, 60)) }

    /// `commits` for fingers on the screen: a flick is measured in the points the fingers actually travel.
    static func commits(progress: CGFloat, touchSpeed speed: CGFloat) -> Bool {
        progress >= 1 || (progress >= 0.3 && speed > 300)
    }

    /// Fingers still this long mid-swipe with nothing else happening: the gesture's end was lost.
    static let lostAfter: TimeInterval = 3

    /// Whether a swipe already armed stays armed: a little short of the distance still counts, so fingers hovering at
    /// the line don't flip it back and forth (#377).
    static func holds(progress: CGFloat) -> Bool { progress >= 0.85 }

    /// How far back a flick's speed is measured.
    static let flickWindow: TimeInterval = 0.1

    /// How fast the fingers were going `direction`'s way (-1 back, 1 forward) over the last `flickWindow` before
    /// `now`, points a second, from `samples` of the scroll so far. Still for that long, they aren't going at all.
    static func speed(_ samples: [(time: TimeInterval, dx: CGFloat)], at now: TimeInterval, direction: Int) -> CGFloat {
        let recent = samples.filter { now - $0.time < flickWindow }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return 0 }
        return CGFloat(-direction) * (last.dx - first.dx) / CGFloat(last.time - first.time)
    }

    /// How long a swipe waits for the page to answer before going on without it. Pages answer well within this,
    /// so on most a swipe never waits; one too busy to answer can still take it back late.
    static let answerWait: TimeInterval = 0.05
    /// Over a frame (a web app's sheet or editor) only the frame can answer, and a busy app takes longer: Chrome
    /// doesn't go back before it has. Also while it's not yet known what's under the pointer.
    static let frameWait: TimeInterval = 0.12

    /// What the page did with the gesture once a frame answers that it kept (`kept`) or left a scroll that came at
    /// `at`, for a gesture that began at `began` (both wall-clock milliseconds).
    static func page(_ page: Page, answered kept: Bool, at: Double, began: Double) -> Page {
        // About an earlier gesture (its momentum, answered late): not this one's.
        guard at >= began - 1, page != .took else { return page }
        // Kept once, it's the page's for the rest of the gesture: a sheet that had room when the gesture started
        // stays the page's after this same gesture scrolls it to its edge, as in Chrome.
        return kept ? .took : .left
    }

    /// What the page said about where fingers landed on it.
    struct TouchRoom: Equatable {
        var left: Bool
        var right: Bool
        var frame: Bool
        var still: Bool
        var pansItself: Bool
    }

    /// For fingers on the screen going `wanted`'s way (-1 back, 1 forward) `waited` after they landed: whether the
    /// page leaves them the swipe, or nil while it hasn't answered and may still. A frame (which only its own page
    /// can speak for), a page that pans sideways under a finger itself, scrolls that way there, or asked for no
    /// overscroll keeps it.
    static func touch(_ wanted: Int, room: TouchRoom?, waited: TimeInterval) -> Bool? {
        guard let room else { return waited < frameWait ? nil : true }
        if room.frame || room.still || room.pansItself { return false }
        return !(wanted < 0 ? room.left : room.right)
    }

    /// `pageScrolls` is the room the page (or what covers it) can still scroll sideways under the pointer, once known;
    /// `waited`, the time since the gesture began; `overFrame`, that the pointer is over a frame in the page. `dx` is
    /// the scroll, not the fingers: positive is toward the page's left edge, whichever way the Mac scrolls. `leans`:
    /// the arrow may show while waiting, unless the page has cancelled sideways scrolls with its own code before.
    static func decide(dx: CGFloat, dy: CGFloat, canGoBack: Bool, canGoForward: Bool,
                       pageScrolls: (left: Bool, right: Bool)?, page: Page, waited: TimeInterval,
                       overFrame: Bool = false, leans: Bool = false) -> SwipeDecision {
        // A page that pans with its own code (a canvas, a map), scrolls there, or asked for no overscroll has the
        // gesture, as in Safari and Chrome.
        if page == .took { return .ignore }
        guard abs(dx) > 10 || abs(dy) > 10 else { return .undecided }
        // Mostly sideways is enough: a natural swipe is rarely dead level.
        let sideways = abs(dx) > abs(dy) * 1.2
        let wanted = dx > 0 ? -1 : 1
        let canGo = wanted < 0 ? canGoBack : canGoForward
        // Swiping toward "back" scrolls toward the page's left edge, so it's the room there that matters.
        let pageTakes = pageScrolls.map { wanted < 0 ? $0.left : $0.right } ?? false
        guard sideways, canGo, !pageTakes else { return .ignore }
        if page == .unknown, waited < (overFrame || pageScrolls == nil ? frameWait : answerWait) {
            // Known to have nothing sideways here and not a frame: the arrow needn't wait for the page to say so.
            return leans && pageScrolls != nil && !overFrame ? .lean(wanted) : .undecided
        }
        return .track(wanted)
    }
}

/// The page's side of a swipe, from inside whichever frame it lands in (Excel's sheet is in one, which the page
/// around it can't see into): whether the page keeps the gesture's sideways scrolls, as Safari and Chrome would let
/// it. It does when it calls preventDefault() on them, as Canva, Figma, Google Maps and Sheets do to pan or scroll
/// with their own code, when something under the pointer can still scroll that way, or when it asked for no
/// overscroll (`overscroll-behavior-x: none` or `contain`). Zigzag's own script world sees the page's events (and
/// when they're cancelled) while the page can't see it or speak for it; it says so for sideways scrolls only.
final class SwipeAnswers: NSObject, WKScriptMessageHandler {
    static let shared = SwipeAnswers()
    static let messageName = "zigzagWheelTaken"

    /// A function of the element under the pointer: which way it, the things around it, or the page itself can
    /// still scroll sideways (`left`, `right`), and whether one asked not to pass its overscroll on (`still`).
    /// `style` is getComputedStyle; `root`, the page's scrolling element; `ends`, its root and body; `view`, the
    /// page's visualViewport, which pans inside the page once it's pinched in.
    static let sideways = """
    (el, style, root, ends, view) => {
      let left = false, right = false, still = false;
      // Room past `behind` toward where the box starts and past `ahead` toward its end: a box a few pixels too wide,
      // or nudged a pixel or two by a diagonal scroll, is usually by accident (#377).
      const room = (box, rtl, behind, ahead) => {
        const max = box.scrollWidth - box.clientWidth;
        if (!(max > 0)) return;
        // Right to left, WebKit counts scrollLeft from 0 at the start down to -max; older engines from max down to 0.
        const x = box.scrollLeft || 0, done = rtl ? (x > 0 ? max - x : -x) : x;
        const back = done > behind, on = max > ahead && done < max - 1;
        // The start is on the left, or on the right of a right-to-left box.
        if (rtl) { right = right || back; left = left || on; } else { left = left || back; right = right || on; }
      };
      const [top, body] = ends;
      const rootX = top ? style(top).overflowX : 'visible';
      // The body's overflow is the page's when the root leaves its own visible.
      const pageX = rootX === 'visible' && body ? style(body).overflowX : rootX;
      for (; el; el = el.parentElement || (el.parentNode && el.parentNode.host) || null) {
        if (el.nodeType === 3) continue;
        const s = style(el);
        const scrollsX = /(auto|scroll|overlay)/.test(s.overflowX) && el.scrollWidth > el.clientWidth;
        const scrollsY = /(auto|scroll|overlay)/.test(s.overflowY) && el.scrollHeight > el.clientHeight;
        // The page's own scrolling is counted once, below.
        const isPage = el === root || (el === body && rootX === 'visible');
        if (scrollsX && !isPage) room(el, s.direction === 'rtl', 8, 24);
        // Something that scrolls and asked to keep its overscroll: the gesture never goes past it.
        if ((scrollsX || scrollsY) && /(none|contain)/.test(s.overscrollBehaviorX)) still = true;
      }
      // Pinched in, the visible part pans across the page: its room counts, however wide the page is (#377).
      if (root && view && view.scale > 1.01) {
        left = left || view.pageLeft > 0.5;
        right = right || view.pageLeft + view.width < root.scrollWidth - 1;
      } else if (root && !/(hidden|clip)/.test(pageX)) room(root, style(root).direction === 'rtl', 8, 80);
      // The page's own setting is what turns off going back and forward.
      for (const end of ends) if (end && /(none|contain)/.test(style(end).overscrollBehaviorX)) still = true;
      return { left, right, still };
    }
    """

    /// A function of the element under a finger: whether it or anything around it pans sideways itself instead of
    /// letting the finger scroll (`touch-action` without `pan-x`, as maps and carousels set).
    static let pansItself = """
    (el, style) => {
      for (; el; el = el.parentElement || (el.parentNode && el.parentNode.host) || null) {
        if (el.nodeType !== 1) continue;
        const t = style(el).touchAction;
        if (t && !/(auto|manipulation|pan-x|pan-left|pan-right)/.test(t)) return true;
      }
      return false;
    }
    """

    /// Whether the page keeps a sideways scroll of `deltaX` (the page's sign: negative moves toward its left edge),
    /// given its room and whether it cancelled it.
    static let keeps = """
    (room, deltaX, prevented) => prevented || !!room && (room.still || (deltaX < 0 ? room.left : room.right))
    """

    /// The page's function, in Zigzag's world, that starts (true) or stops (false) listening to its scrolls and
    /// returns whether it listens. A wheel listener makes WebKit hand every scroll step to the page, so the page
    /// listens only while a gesture may be a swipe: from its first sideways step until Zigzag has decided.
    static let listen = "__zigzagSwipeListen"

    static let script = WKUserScript(source: """
    (() => {
      const sideways = \(sideways), keeps = \(keeps);
      let sent = null, sentAt = -1e9, lastAt = -1e9, on = false, off = 0;
      const heard = (e) => {
        if (!e.isTrusted || e.ctrlKey || e.deltaX === 0 || Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;
        const now = performance.now(), fresh = now - lastAt > 80;
        lastAt = now;
        // The room there is now, before the page's listeners or the scroll itself have moved anything.
        let room = null;
        try { room = sideways(e.composedPath()[0] || e.target, getComputedStyle, document.scrollingElement, [document.documentElement, document.body], window.visualViewport); } catch (_) {}
        // When the scroll came, in wall-clock time: Zigzag drops answers about an earlier gesture.
        const age = now - e.timeStamp, at = Date.now() - (age >= 0 && age < 2000 ? age : 0);
        // Once the page's own listeners have all had it.
        setTimeout(() => {
          const kept = keeps(room, e.deltaX, e.defaultPrevented), later = performance.now();
          // The first of a gesture always; then on a change, or every 40 ms.
          if (!fresh && kept === sent && later - sentAt < 40) return;
          sent = kept; sentAt = later;
          try { window.webkit.messageHandlers.\(messageName).postMessage({ kept, at }); } catch (_) {}
        }, 0);
      };
      const set = (yes) => {
        if (yes === on) return;
        on = yes;
        if (yes) addEventListener('wheel', heard, { capture: true, passive: true }); else removeEventListener('wheel', heard, true);
      };
      // Should Zigzag never say the gesture is decided, it stops by itself.
      window.\(listen) = (yes) => {
        if (yes !== undefined) { clearTimeout(off); set(yes); if (yes) off = setTimeout(() => set(false), 10000); }
        return on;
      };
      // A frame, which Zigzag can't reach: it listens while the pointer is in it.
      if (window !== window.top) {
        set(true);
        addEventListener('mouseover', () => set(true), { capture: true, passive: true });
        addEventListener('mouseout', (e) => { if (!e.relatedTarget) set(false); }, { capture: true, passive: true });
      }
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // From any frame: one in a frame is the page's answer as much as one from the page around it.
        guard message.name == Self.messageName, let body = message.body as? [String: Any], let kept = body["kept"] as? Bool,
              let at = body["at"] as? Double, let webView = message.webView as? BrowserWebView else { return }
        webView.pageAnsweredSwipe(kept: kept, at: at)
    }
}

/// A window whose page can be swiped back or forward: where the arrow floats while it does, over the page and the
/// frame around it, so a browser window and Zigzag Mini show the same one.
@MainActor
protocol SwipeArrowHost: AnyObject {
    var swipeArrowLayer: NSView { get }
}

/// The round arrow at the page's edge during a swipe: a small floating button in the panel's surface whose accent ring
/// closes as you swipe, filled in the accent once letting go will navigate.
final class SwipeArrowView: NSView {
    static let size = Tokens.Metric.floatingButton
    /// The panel's surface at rest; the accent once armed.
    private let fill = ColorView()
    private let symbol = NSImageView()
    /// How far along the swipe is, drawn around the edge.
    private let ring = CAShapeLayer()
    var progress: CGFloat = 0 { didSet { refresh() } }
    var isArmed = false { didSet { refresh(animated: true) } }

    /// The arrow, for a page at `page` shifted `offset` points: centered in the gap at its edge, at least a margin
    /// from that edge so it never overlaps the sidebar, the next pane or the window edge. Floats over the page while
    /// the gap is narrower than the arrow.
    static func frame(in page: NSRect, offset: CGFloat, back: Bool) -> NSRect {
        let margin = Tokens.Space.x2
        let edge = back ? page.minX : page.maxX
        let middle = edge + offset / 2 - size / 2
        let x = back ? max(middle, edge + margin) : min(middle, edge - margin - size)
        return NSRect(x: round(x), y: round(page.midY - size / 2), width: size, height: size)
    }

    init(back: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Self.size / 2
        fill.layer?.borderWidth = Tokens.Metric.hairline
        addSubview(fill)
        ring.fillColor = nil
        ring.lineWidth = Tokens.Metric.focusRing
        ring.lineCap = .round
        fill.layer?.addSublayer(ring)
        symbol.image = Tokens.Symbol.image(back ? "arrow.left" : "arrow.right", size: Tokens.Symbol.glyph)
        symbol.imageScaling = .scaleNone
        addSubview(symbol)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fill.frame = bounds
        symbol.frame = bounds
        // From the top, clockwise.
        let inset = bounds.insetBy(dx: ring.lineWidth / 2, dy: ring.lineWidth / 2)
        let path = CGMutablePath()
        let top = fill.isFlipped ? -CGFloat.pi / 2 : CGFloat.pi / 2
        path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2, startAngle: top,
                    endAngle: top + (fill.isFlipped ? 2 : -2) * .pi, clockwise: !fill.isFlipped)
        Tokens.Motion.withoutAnimation { ring.frame = bounds; ring.path = path }
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh(animated: Bool = false) {
        let theme = Brand.Theme.for(self)
        let apply = {
            self.fill.layer?.backgroundColor = self.cgColor(self.isArmed ? theme.accent : theme.panel)
            self.fill.layer?.borderColor = self.cgColor(self.isArmed ? .clear : Tokens.Color.panelEdge)
            self.ring.strokeColor = self.cgColor(theme.accent)
            // The one panel shadow, as every floating thing has.
            self.layer?.shadowColor = self.cgColor(Tokens.Color.panelShadow)
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
            self.layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: self.isFlipped)
        }
        if animated, !Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.snap.duration)
            CATransaction.setAnimationTimingFunction(Tokens.Motion.snap.timing)
            apply()
            CATransaction.commit()
        } else {
            Tokens.Motion.withoutAnimation(apply)
        }
        symbol.contentTintColor = isArmed ? theme.onAccent : Tokens.Color.icon
        Tokens.Motion.withoutAnimation { ring.strokeEnd = min(max(progress, 0), 1) }
        alphaValue = Self.opacity(progress: progress, armed: isArmed)
    }

    /// Shows at once as the swipe starts and is fully there a fifth of the way; once letting go will move, it fills.
    static func opacity(progress: CGFloat, armed: Bool) -> CGFloat {
        armed ? 1 : min(1, 0.4 + max(0, progress) * 3)
    }

    /// Fades as the page settles back or goes on. Navigated, it shows filled first, however fast the swipe was.
    func leave(toward direction: Int, navigated: Bool) {
        if navigated {
            progress = 1
            isArmed = true
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = navigated ? Tokens.Motion.Role.large.duration() : Tokens.Motion.Role.present.duration(entering: false)
            context.timingFunction = Tokens.Motion.easeOut
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }
}

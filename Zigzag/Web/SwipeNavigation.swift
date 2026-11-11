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

    private enum State { case idle, deciding, tracking, ignoring, finishing }
    private var state = State.idle
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
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
    private var armed = false
    /// Recent finger movement, to tell a quick flick from a slow drag.
    private var samples: [(time: TimeInterval, dx: CGFloat)] = []
    /// Clears the arrow if the gesture's end never arrives (macOS sometimes drops it between quick swipes).
    private var watchdog: DispatchWorkItem?
    /// While the fingers rest mid-swipe no events come at all, which looks the same as a lost end. A rest keeps the
    /// swipe where it is; only doing something else (moving the pointer, a click, a key) shows the fingers are gone.
    private var restMonitor: Any?

    /// How far to swipe before letting go navigates.
    private static let threshold: CGFloat = 85

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
        watchdog?.cancel()
        stopWatchingRest()
        if state == .tracking { cancel() }
        state = .idle
    }

    /// Returns true when it took the event, so the page doesn't also scroll with it. `room`, from something
    /// covering the page (a zoomed-in PDF), is which way it can still scroll sideways, in place of asking the page.
    func handle(_ event: NSEvent, room: (left: Bool, right: Bool)? = nil) -> Bool {
        // A video in full screen keeps every swipe: going back there would leave the page from under it.
        guard let webView, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled, Self.isOn,
              webView.fullscreenState == .notInFullscreen else { return false }
        // Momentum after a swipe that navigated (or was abandoned) is part of it, not a scroll.
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { if state == .finishing { state = .idle } }
            return state == .finishing
        }
        switch event.phase {
        case .began:
            // A new gesture: anything left from the last one goes now.
            if let arrow { arrow.removeFromSuperview(); self.arrow = nil }
            watchdog?.cancel()
            stopWatchingRest()
            guard webView.window != nil else { state = .idle; return false }
            state = .deciding
            dx = 0; dy = 0; direction = 0; armed = false; pageScrolls = nil; overFrame = false; samples = []
            began = event.timestamp
            beganAt = (Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - event.timestamp)) * 1000
            gesture += 1
            // Something covering the page has the scroll, not the page: what it says is its room.
            covered = room != nil
            page = covered ? .left : .unknown
            if let room { pageScrolls = room } else { probe(at: webView.convert(event.locationInWindow, from: nil)) }
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
            case .deciding:
                switch SwipeDecision.decide(dx: dx, dy: dy, canGoBack: webView.owner?.canGoBackOrReturn ?? webView.canGoBack,
                                            canGoForward: webView.canGoForward, pageScrolls: pageScrolls, page: page,
                                            waited: event.timestamp - began, overFrame: overFrame) {
                case .undecided:
                    return false
                case .ignore:
                    state = .ignoring
                    return false
                case .track(let wanted):
                    direction = wanted
                    state = .tracking
                    showArrow()
                    update()
                    armWatchdog()
                    return true
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
            let wasTracking = state == .tracking
            watchdog?.cancel()
            stopWatchingRest()
            if wasTracking {
                if event.phase == .ended, progress >= 1 || isFlick { go() } else { cancel() }
                state = .finishing
            } else {
                state = .idle
            }
            // The page saw the gesture begin, so it sees it end too (an end carries no movement to scroll by).
            return false
        default:
            return state == .tracking
        }
    }

    /// The page's answer for one of this gesture's sideways scrolls, from the frame it landed in: whether it keeps
    /// them (`kept`). `at` is when that scroll came, in wall-clock milliseconds.
    func pageAnswered(kept: Bool, at: Double) {
        // Covered by something else (a zoomed-in PDF), the page isn't what's scrolling.
        guard !covered, state == .deciding || state == .tracking else { return }
        page = SwipeDecision.page(page, answered: kept, at: at, began: beganAt)
        // It took it after all, answering after the swipe had started: the arrow goes and the page has the rest.
        if page == .took, state == .tracking { cancel(); state = .ignoring }
    }

    private var progress: CGFloat { max(0, CGFloat(-direction) * dx) / Self.threshold }

    /// A quick flick the right way counts even if it's short, as in Safari.
    private var isFlick: Bool {
        guard progress > 0.25, let last = samples.last,
              let first = samples.first(where: { last.time - $0.time < 0.1 }), last.time > first.time else { return false }
        let speed = CGFloat(-direction) * (last.dx - first.dx) / CGFloat(last.time - first.time)
        return speed > 450
    }

    private func armWatchdog() {
        watchdog?.cancel()
        stopWatchingRest()
        // Still for a moment: the fingers may be resting (to read a little more before going back), so the swipe
        // holds. Anything else the hand does means the gesture ended without saying so, and it's dropped then.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .tracking else { return }
            // Not shown any more: there's no resting on a page that's gone.
            guard self.webView?.window != nil else { self.abandonRest(); return }
            self.restMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.abandonRest() }
                return event
            }
            // A rest that long is a lost gesture, not a pause.
            let lost = DispatchWorkItem { [weak self] in self?.abandonRest() }
            self.watchdog = lost
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: lost)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func abandonRest() {
        stopWatchingRest()
        guard state == .tracking else { return }
        cancel()
        state = .idle
    }

    private func stopWatchingRest() {
        if let restMonitor { NSEvent.removeMonitor(restMonitor) }
        restMonitor = nil
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
        let zoom = webView.pageZoom
        let x = point.x / zoom, y = (webView.isFlipped ? point.y : webView.bounds.height - point.y) / zoom
        let script = """
        (() => {
          const el = document.elementFromPoint(\(x), \(y));
          const room = (\(SwipeAnswers.sideways))(el, getComputedStyle, document.scrollingElement, [document.documentElement, document.body]);
          return [room.left, room.right, !!el && /^(IFRAME|FRAME|EMBED|OBJECT)$/.test(el.tagName), room.still];
        })()
        """
        let gesture = gesture
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.gesture == gesture, !self.covered,
                  case .success(let value) = result, let answer = value as? [Bool], answer.count == 4 else { return }
            self.pageScrolls = (answer[0], answer[1])
            self.overFrame = answer[2]
            // The page asked for no overscroll: like a page that cancels the scrolls, it keeps the gesture.
            if answer[3] { self.pageAnswered(kept: true, at: .infinity) }
        }
    }

    // MARK: The arrow

    private func showArrow() {
        guard let webView, let overlay = (webView.window?.windowController as? SwipeArrowHost)?.swipeArrowLayer else { return }
        arrow?.removeFromSuperview()
        let arrow = SwipeArrowView(back: direction < 0)
        overlay.addSubview(arrow)
        self.arrow = arrow
    }

    /// How far the page has moved with the fingers, at most `maxShift`, with resistance so it slows as it goes.
    private var shift: CGFloat {
        let pulled = max(0, CGFloat(-direction) * dx)
        return Self.maxShift * (1 - exp(-pulled / (Self.maxShift * 1.6)))
    }
    private static let maxShift: CGFloat = 72

    private func update() {
        guard let webView, let arrow, let overlay = arrow.superview else { return }
        // The page follows the fingers a little, and the arrow waits in the gap that opens at its edge.
        let offset = shift * CGFloat(-direction)
        Tokens.Motion.withoutAnimation { webView.layer?.setAffineTransform(CGAffineTransform(translationX: offset, y: 0)) }
        let page = overlay.convert(webView.bounds, from: webView)
        let size = SwipeArrowView.size
        let gapMid = (direction < 0 ? page.minX : page.maxX) + offset / 2
        arrow.frame = NSRect(x: round(gapMid - size / 2), y: round(page.midY - size / 2), width: size, height: size)
        arrow.progress = min(progress, 1)
        let nowArmed = progress >= 1
        if nowArmed != armed {
            armed = nowArmed
            arrow.isArmed = nowArmed
            if nowArmed { Haptics.snap() }
        }
    }

    /// The page settles back into place: with the page it went to, or without, if let go too soon.
    private func settlePage() {
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
        stopWatchingRest()
        // Let go after its tab went to the back: it isn't where you're looking, so it doesn't move.
        guard let webView, webView.window != nil else { cancel(); return }
        if direction < 0 { if let owner = webView.owner { owner.goBack() } else { webView.goBack() } } else if let owner = webView.owner { owner.goForward() } else { webView.goForward() }
        settlePage()
        arrow?.leave(toward: direction, navigated: true)
        arrow = nil
    }

    private func cancel() {
        watchdog?.cancel()
        stopWatchingRest()
        settlePage()
        arrow?.leave(toward: -direction, navigated: false)
        arrow = nil
    }
}

/// Whether a two-finger swipe on a page goes back or forward, from how far the fingers have gone and what the page
/// said about it.
enum SwipeDecision: Equatable {
    /// Not sure yet: the page keeps getting the swipe meanwhile, as if nothing were deciding.
    case undecided
    /// Back (-1) or forward (1): the arrow comes and the page gets no more of the gesture.
    case track(Int)
    /// The page's, or a scroll: it gets the whole gesture.
    case ignore

    /// What the page did with the gesture's sideways scrolls, as SwipeAnswers hears it.
    enum Page { case unknown, left, took }

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

    /// `pageScrolls` is the room the page (or what covers it) can still scroll sideways under the pointer, once known;
    /// `waited`, the time since the gesture began; `overFrame`, that the pointer is over a frame in the page. `dx` is
    /// the scroll, not the fingers: positive is toward the page's left edge, whichever way the Mac scrolls.
    static func decide(dx: CGFloat, dy: CGFloat, canGoBack: Bool, canGoForward: Bool,
                       pageScrolls: (left: Bool, right: Bool)?, page: Page, waited: TimeInterval,
                       overFrame: Bool = false) -> SwipeDecision {
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
        if page == .unknown, waited < (overFrame || pageScrolls == nil ? frameWait : answerWait) { return .undecided }
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
    /// `style` is getComputedStyle; `root`, the page's scrolling element; `ends`, its root and body.
    static let sideways = """
    (el, style, root, ends) => {
      let left = false, right = false, still = false;
      const room = (box, rtl) => {
        const max = box.scrollWidth - box.clientWidth, at = rtl ? max + box.scrollLeft : box.scrollLeft;
        left = left || at > 0.5; right = right || at < max - 1;
      };
      for (; el; el = el.parentElement || (el.parentNode && el.parentNode.host) || null) {
        if (el.nodeType === 3) continue;
        const s = style(el);
        const scrollsX = /(auto|scroll|overlay)/.test(s.overflowX) && el.scrollWidth > el.clientWidth;
        const scrollsY = /(auto|scroll|overlay)/.test(s.overflowY) && el.scrollHeight > el.clientHeight;
        // A few pixels too wide is usually by accident.
        if (scrollsX && el.scrollWidth > el.clientWidth + 24) room(el, s.direction === 'rtl');
        // Something that scrolls and asked to keep its overscroll: the gesture never goes past it.
        if ((scrollsX || scrollsY) && /(none|contain)/.test(s.overscrollBehaviorX)) still = true;
      }
      // The page itself only counts when it's really wide: many are a few pixels too wide by accident.
      if (root && root.scrollWidth > root.clientWidth + 80) room(root, style(root).direction === 'rtl');
      // The page's own setting is what turns off going back and forward.
      for (const end of ends) if (end && /(none|contain)/.test(style(end).overscrollBehaviorX)) still = true;
      return { left, right, still };
    }
    """

    /// Whether the page keeps a sideways scroll of `deltaX` (the page's sign: negative moves toward its left edge),
    /// given its room and whether it cancelled it.
    static let keeps = """
    (room, deltaX, prevented) => prevented || !!room && (room.still || (deltaX < 0 ? room.left : room.right))
    """

    static let script = WKUserScript(source: """
    (() => {
      const sideways = \(sideways), keeps = \(keeps);
      let sent = null, sentAt = -1e9, lastAt = -1e9;
      window.addEventListener('wheel', (e) => {
        if (!e.isTrusted || e.ctrlKey || e.deltaX === 0 || Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;
        const now = performance.now(), fresh = now - lastAt > 80;
        lastAt = now;
        // The room there is now, before the page's listeners or the scroll itself have moved anything.
        let room = null;
        try { room = sideways(e.composedPath()[0] || e.target, getComputedStyle, document.scrollingElement, [document.documentElement, document.body]); } catch (_) {}
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
      }, { capture: true, passive: true });
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

/// The round arrow at the page's edge during a swipe: a small floating button in the panel's surface while you swipe,
/// filled in the accent once letting go will navigate.
final class SwipeArrowView: NSView {
    static let size = Tokens.Metric.floatingButton
    /// The panel's surface at rest; the accent once armed.
    private let fill = ColorView()
    private let symbol = NSImageView()
    var progress: CGFloat = 0 { didSet { refresh() } }
    var isArmed = false { didSet { refresh(animated: true) } }

    init(back: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Self.size / 2
        fill.layer?.borderWidth = Tokens.Metric.hairline
        addSubview(fill)
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
        // Fades in as you swipe; once letting go will move, it fills.
        alphaValue = min(1, max(0, (progress - 0.1) * 2))
    }

    /// Fades as the page settles back. Navigated, it shows filled first, however fast the swipe was.
    func leave(toward direction: Int, navigated: Bool) {
        if navigated {
            progress = 1
            isArmed = true
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.reduceMotion ? 0 : navigated ? 0.3 : 0.18
            context.timingFunction = Tokens.Motion.easeOut
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }
}

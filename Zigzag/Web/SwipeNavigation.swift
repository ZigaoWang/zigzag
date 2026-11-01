import AppKit
import WebKit

/// Two fingers sideways on a page goes back or forward, the way Arc and Chrome do it: a round arrow slides in from
/// the page's edge as you swipe, fills once you've gone far enough, and letting go moves at once, with no slow
/// slide of the whole page. A page that can scroll sideways where you are (a carousel, a map, a wide table) keeps
/// the swipe for itself, and the system's "Swipe between pages" setting is respected.
@MainActor
final class SwipeNavigator {
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
        guard let webView, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return false }
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
            dx = 0; dy = 0; direction = 0; armed = false; pageScrolls = nil; samples = []
            if let room { pageScrolls = room } else { probe(at: webView.convert(event.locationInWindow, from: nil)) }
            return false
        case .changed:
            // What covers the page knows its room as it scrolls: it's kept up to date through the gesture.
            if let room { pageScrolls = room }
            // Fingers to the right go back; scrolling direction settings don't change that.
            let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            dx += fingerX
            dy += event.scrollingDeltaY
            samples.append((event.timestamp, dx))
            if samples.count > 8 { samples.removeFirst(samples.count - 8) }
            switch state {
            case .deciding:
                guard abs(dx) > 10 || abs(dy) > 10 else { return false }
                // Mostly sideways is enough: a natural swipe is rarely dead level.
                let sideways = abs(dx) > abs(dy) * 1.2
                let wanted = dx > 0 ? -1 : 1
                let canGo = wanted < 0 ? (webView.owner?.canGoBackOrReturn ?? webView.canGoBack) : webView.canGoForward
                if sideways, canGo, !pageTakes(wanted) {
                    direction = wanted
                    state = .tracking
                    showArrow()
                    update()
                    armWatchdog()
                    return true
                }
                state = .ignoring
                return false
            case .tracking:
                // The page answered late that it scrolls this way: hand the swipe back.
                if pageTakes(direction) { cancel(); state = .ignoring; return false }
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

    /// Asks the page whether anything under the pointer (or the page itself) can scroll sideways, and which way.
    private func probe(at point: NSPoint) {
        guard let webView else { return }
        let zoom = webView.pageZoom
        let x = point.x / zoom, y = (webView.isFlipped ? point.y : webView.bounds.height - point.y) / zoom
        let script = """
        (() => {
          let left = false, right = false;
          for (let el = document.elementFromPoint(\(x), \(y)); el; el = el.parentElement) {
            const style = getComputedStyle(el);
            const scrolls = /(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth + 24;
            if (scrolls) { left = left || el.scrollLeft > 0; right = right || el.scrollLeft + el.clientWidth < el.scrollWidth - 1; }
          }
          // The page itself only counts when it's really wide: many are a few pixels too wide by accident.
          const root = document.scrollingElement;
          if (root && root.scrollWidth > root.clientWidth + 80) { left = left || root.scrollLeft > 0; right = right || root.scrollLeft + root.clientWidth < root.scrollWidth - 1; }
          return [left, right];
        })()
        """
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard case .success(let value) = result, let pair = value as? [Bool], pair.count == 2 else { return }
            // Swiping toward "back" moves the view left, so it's the page's room to the left that matters.
            self?.pageScrolls = (pair[0], pair[1])
        }
    }

    // MARK: The arrow

    private func showArrow() {
        guard let webView, let overlay = (webView.window?.windowController as? BrowserWindowController)?.root.overlay else { return }
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
        let back = Tokens.Motion.springAnimation(keyPath: "transform", duration: 0.35)
        back.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(from))
        back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(back, forKey: "swipe.settle")
    }

    private func go() {
        watchdog?.cancel()
        stopWatchingRest()
        // Let go after its tab went to the back: it isn't where you're looking, so it doesn't move.
        guard let webView, webView.window != nil else { cancel(); return }
        if direction < 0 { if let owner = webView.owner { owner.goBack() } else { webView.goBack() } } else { webView.goForward() }
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

/// The round arrow at the page's edge during a swipe: a small glass button while you swipe, filled in the accent
/// once letting go will navigate.
final class SwipeArrowView: NSView {
    static let size = Tokens.Metric.floatingButton
    private let material = PanelMaterial.make(radius: Tokens.Metric.floatingButton / 2)
    /// The panel wash over the glass at rest; the accent once armed.
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
        [material, fill].forEach { addSubview($0) }
        symbol.image = Tokens.Symbol.image(back ? "arrow.left" : "arrow.right", size: Tokens.Symbol.glyph)
        symbol.imageScaling = .scaleNone
        addSubview(symbol)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        material.frame = bounds
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
            self.fill.layer?.backgroundColor = self.cgColor(self.isArmed ? theme.accent : Tokens.Color.panelWash)
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

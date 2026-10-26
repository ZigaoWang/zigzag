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

    /// How far to swipe before letting go navigates.
    private static let threshold: CGFloat = 110

    init(webView: BrowserWebView) {
        self.webView = webView
    }

    /// Returns true when it took the event, so the page doesn't also scroll with it.
    func handle(_ event: NSEvent) -> Bool {
        guard let webView, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return false }
        // Momentum after a swipe that navigated (or was abandoned) is part of it, not a scroll.
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { if state == .finishing { state = .idle } }
            return state == .finishing
        }
        switch event.phase {
        case .began:
            state = .deciding
            dx = 0; dy = 0; direction = 0; armed = false; pageScrolls = nil
            probe(at: webView.convert(event.locationInWindow, from: nil))
            return false
        case .changed:
            // Fingers to the right go back; scrolling direction settings don't change that.
            let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            dx += fingerX
            dy += event.scrollingDeltaY
            switch state {
            case .deciding:
                guard abs(dx) > 8 || abs(dy) > 8 else { return false }
                let sideways = abs(dx) > abs(dy) * 1.6
                let wanted = dx > 0 ? -1 : 1
                let canGo = wanted < 0 ? webView.canGoBack : webView.canGoForward
                if sideways, canGo, !pageTakes(wanted) {
                    direction = wanted
                    state = .tracking
                    showArrow()
                    update()
                    return true
                }
                state = .ignoring
                return false
            case .tracking:
                // The page answered late that it scrolls this way: hand the swipe back.
                if pageTakes(direction) { cancel(); state = .ignoring; return false }
                update()
                return true
            default:
                return false
            }
        case .ended, .cancelled:
            let wasTracking = state == .tracking
            if wasTracking {
                if event.phase == .ended, progress >= 1 { go() } else { cancel() }
                state = .finishing
            } else {
                state = .idle
            }
            return wasTracking
        default:
            return state == .tracking
        }
    }

    private var progress: CGFloat { max(0, CGFloat(-direction) * dx) / Self.threshold }

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
            const scrolls = /(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth + 4;
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

    private func update() {
        guard let webView, let arrow, let overlay = arrow.superview else { return }
        let page = overlay.convert(webView.bounds, from: webView)
        let p = min(progress, 1.25)
        let size = SwipeArrowView.size
        // It comes in from the edge it points away from, and stops a little in from it.
        let travel = size + Tokens.Space.x4
        let shown = travel * min(p, 1) + Tokens.Space.x2 * max(0, p - 1)
        let x = direction < 0 ? page.minX - size + shown : page.maxX - shown
        arrow.frame = NSRect(x: x, y: page.midY - size / 2, width: size, height: size)
        arrow.progress = min(p, 1)
        let nowArmed = p >= 1
        if nowArmed != armed {
            armed = nowArmed
            arrow.isArmed = nowArmed
            if nowArmed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    private func go() {
        guard let webView else { return }
        if direction < 0 { webView.goBack() } else { webView.goForward() }
        arrow?.leave(toward: direction, navigated: true)
        arrow = nil
    }

    private func cancel() {
        arrow?.leave(toward: -direction, navigated: false)
        arrow = nil
    }
}

/// The round arrow at the page's edge during a swipe: quiet while you swipe, filled in the accent once letting go
/// will navigate.
final class SwipeArrowView: NSView {
    static let size: CGFloat = 44
    private let circle = CALayer()
    private let symbol = NSImageView()
    var progress: CGFloat = 0 { didSet { refresh() } }
    var isArmed = false { didSet { refresh(animated: true) } }

    init(back: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        circle.cornerRadius = Self.size / 2
        circle.shadowOpacity = 1
        circle.shadowRadius = 8
        circle.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(circle)
        symbol.image = Tokens.Symbol.image(back ? "arrow.left" : "arrow.right", size: 17)
        symbol.imageScaling = .scaleNone
        addSubview(symbol)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation { circle.frame = bounds }
        symbol.frame = bounds
    }

    private func refresh(animated: Bool = false) {
        let accent = Brand.Theme.for(self).accent
        let apply = {
            self.circle.backgroundColor = self.cgColor(self.isArmed ? accent : Tokens.Color.panelBackground)
            self.circle.shadowColor = self.cgColor(Tokens.Color.panelShadow)
            self.circle.borderWidth = self.isArmed ? 0 : 1
            self.circle.borderColor = self.cgColor(Tokens.Color.separator)
        }
        if animated { CATransaction.begin(); CATransaction.setAnimationDuration(0.15); apply(); CATransaction.commit() } else { Tokens.Motion.withoutAnimation(apply) }
        symbol.contentTintColor = isArmed ? .white : Tokens.Color.textSecondary
        // Out of sight at the very start, when it's still mostly past the page's edge.
        alphaValue = min(1, max(0, (progress - 0.12) * 2.2))
    }

    /// Goes: on with the swipe after navigating, back to the edge when let go too soon.
    func leave(toward direction: Int, navigated: Bool) {
        let shift = CGFloat(navigated ? -direction : direction) * Self.size * (navigated ? 0.3 : 1)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = navigated ? 0.22 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().alphaValue = 0
            animator().setFrameOrigin(NSPoint(x: frame.minX + shift, y: frame.minY))
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }
}

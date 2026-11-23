import AppKit
import WebKit

/// A page's own parent, holding the web view and nothing else. WebKit docks the Web Inspector beside the page, in
/// the page's parent and as large as it. A tab keeps its own (`Tab.pageHolder`) and whatever shows the tab borrows
/// it, so the inspector goes where its page goes.
final class PageHolder: NSView {
    /// The page it holds.
    private(set) weak var page: WKWebView?
    private var pageObserver: NSObjectProtocol?
    private var lastDocked = NSSize.zero
    /// The page's full screen, watched so the page is settled back in here once WebKit is done with it.
    private var fullScreenWatch: NSKeyValueObservation?
    /// The room what's docked beside the page takes changed: whoever sizes the holder for the page's sake hears.
    var onDockedRoomChange: (() -> Void)?

    /// The room what's docked beside the page (the Web Inspector) takes of the holder: its width at a side, its
    /// height at the bottom. WebKit lays the two out in the holder and keeps the inspector's own size whatever the
    /// holder's is, so a holder made a page's size plus this leaves the page exactly that size. None with nothing
    /// docked.
    var dockedRoom: NSSize {
        guard let page, subviews.contains(where: { $0 !== page && $0 !== expandButton && !$0.isHidden }) else { return .zero }
        return NSSize(width: max(0, bounds.width - page.frame.width), height: max(0, bounds.height - page.frame.height))
    }

    isolated deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

    /// A holder the size of the page, with the page in it.
    convenience init(holding webView: WKWebView) {
        self.init(frame: webView.frame)
        hold(webView)
    }

    /// Takes the page in, filling the holder.
    func hold(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        page = webView
        if TouchGestures.isAvailable, pageSwipe == nil { addTouchGestures() }
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        // WebKit moves the page as the inspector docks, leaves or is dragged wider: said once the room really changed.
        // WebKit takes the page to a window of its own for an element's full screen, and puts it back here after.
        fullScreenWatch = webView.observe(\.fullscreenState) { [weak self] page, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, page === self.page, page.fullscreenState == .notInFullscreen else { return }
                    self.settlePage(relayout: true)
                }
            }
        }
        webView.postsFrameChangedNotifications = true
        pageObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: webView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteDockedRoom() }
        }
    }

    /// Says the docked room changed, if it did.
    private func noteDockedRoom() {
        guard dockedRoom != lastDocked else { return }
        lastDocked = dockedRoom
        onDockedRoomChange?()
    }

    /// The inspector comes into the holder after WebKit has made room for it, with no move of the page to say so:
    /// looked at again as it comes in. (Its leaving moves the page, which says it.)
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Only WebKit puts the page back in here (`hold` adds it before it's the page): its full screen is ending.
        if subview === page { settlePage(relayout: false); return }
        noteDockedRoom()
    }

    /// The page back from its full screen (#204). WebKit puts it back at the frame it kept for it, which is only
    /// right if nothing moved meanwhile, and lays the page out for it only as it finishes: a page that went full
    /// screen by itself could be left laid out for the screen, with a band along its top and running past the card's
    /// edge, until the window was resized. So the page is kept within its holder (filling it unless the Web Inspector
    /// is docked beside it), the card lays out again, and once WebKit is done (`relayout`) the page is given its size
    /// afresh, as resizing the window would.
    func settlePage(relayout: Bool) {
        guard let page, page.superview === self else { return }
        if !bounds.contains(page.frame) || page.frame.isEmpty { page.frame = bounds }
        page.autoresizingMask = [.width, .height]
        superview?.needsLayout = true
        guard relayout else { return }
        let size = page.frame.size
        guard size.width > 1, size.height > 1 else { return }
        page.setFrameSize(NSSize(width: size.width, height: size.height - 1))
        page.setFrameSize(size)
    }

    // MARK: Touch

    /// Two fingers sideways go back or forward, three switch spaces; one is the page's own.
    private(set) var pageSwipe: TouchSwipeRecognizer?
    /// Two fingers pinched in on the page at its usual size open Show All Tabs; the page still zooms as before.
    private(set) var overviewPinch: TouchPinchRecognizer?
    /// What the fingers on the page are doing, once decided.
    private var swiping: TouchSwipe.OnPage?
    private var swipeX: CGFloat = 0
    private var pinchStartZoom: CGFloat = 1
    private var pinchFired = false

    private func addTouchGestures() {
        let swipe = TouchSwipeRecognizer { [weak self] swipe in self?.pageSwipeChanged(swipe) }
        swipe.maxFingers = 3
        swipe.decides = { [weak self] swipe in
            guard let self, let kind = TouchSwipe.onPage(fingers: swipe.fingers, translation: swipe.translation, spread: swipe.spread),
                  self.takes(kind, dx: swipe.translation.x) else { return false }
            self.swiping = kind
            return true
        }
        addGestureRecognizer(swipe)
        pageSwipe = swipe

        let pinch = TouchPinchRecognizer { [weak self] pinch in self?.pinchChanged(pinch) }
        addGestureRecognizer(pinch)
        overviewPinch = pinch
    }

    /// The browser window this page is in, with the sidebar that switches its spaces.
    private var browser: BrowserWindowController? { window?.windowController as? BrowserWindowController }

    /// Whether fingers going `dx` this way may do `kind`: back or forward when the Mac's touch setting, Zigzag's
    /// and the page's history allow; spaces in a browser window, outside Show All Tabs.
    func takes(_ kind: TouchSwipe.OnPage, dx: CGFloat) -> Bool {
        switch kind {
        case .backForward:
            return (page as? BrowserWebView)?.swipeNavigator.takesTouchSwipe(dx > 0 ? -1 : 1) == true
        case .spaces:
            guard let browser else { return false }
            return !browser.desk.isVisible
        }
    }

    private func pageSwipeChanged(_ swipe: TouchSwipeRecognizer) {
        let x = swipe.translation.x
        switch swipe.state {
        case .began:
            guard let swiping else { return }
            touchSwipeBegan(swiping, dx: x)
        case .changed:
            touchSwipeMoved(dx: x)
        case .ended:
            touchSwipeEnded(velocity: swipe.velocity.x, cancelled: false)
        case .cancelled, .failed:
            touchSwipeEnded(velocity: 0, cancelled: true)
        default:
            break
        }
    }

    /// The fingers decided on `kind`, `dx` points sideways so far (positive to the right): the arrow comes, as for
    /// two fingers on the trackpad, or the spaces slide as under a finger across the sidebar.
    func touchSwipeBegan(_ kind: TouchSwipe.OnPage, dx: CGFloat) {
        swiping = kind
        let now = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .backForward:
            guard let swipe = (page as? BrowserWebView)?.swipeNavigator else { return }
            swipe.touchBegan(direction: dx > 0 ? -1 : 1)
            swipe.touchMoved(dx: dx, at: now)
        case .spaces:
            swipeX = dx
            browser?.sidebar.touchSwipeBegan()
            browser?.sidebar.touchSwipeMoved(by: dx, at: now)
        }
    }

    /// The fingers are `dx` points sideways from where they landed.
    func touchSwipeMoved(dx: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        switch swiping {
        case .backForward: (page as? BrowserWebView)?.swipeNavigator.touchMoved(dx: dx, at: now)
        case .spaces:
            browser?.sidebar.touchSwipeMoved(by: dx - swipeX, at: now)
            swipeX = dx
        case nil: break
        }
    }

    /// Lifted going `velocity` points a second sideways, or called off.
    func touchSwipeEnded(velocity: CGFloat, cancelled: Bool) {
        let kind = swiping
        swiping = nil
        switch kind {
        case .backForward: (page as? BrowserWebView)?.swipeNavigator.touchEnded(at: ProcessInfo.processInfo.systemUptime, cancelled: cancelled)
        case .spaces: browser?.sidebar.touchSwipeEnded(velocity: velocity, cancelled: cancelled)
        case nil: break
        }
    }

    private func pinchChanged(_ pinch: TouchPinchRecognizer) {
        switch pinch.state {
        case .began:
            pinchStartZoom = page?.magnification ?? 1
            pinchFired = false
        case .changed:
            guard !pinchFired, TouchPinch.opensOverview(magnification: pinch.magnification, startZoom: pinchStartZoom) else { return }
            pinchFired = true
            touchPinchedIn()
        default: break
        }
    }

    /// Pinched in far enough: Show All Tabs, in a browser window.
    func touchPinchedIn() {
        guard let controller = window?.windowController as? BrowserWindowController, !controller.desk.isVisible else { return }
        controller.desk.show()
    }

    // MARK: Into real full screen

    /// On a page-filled video (Full screen videos fill: The Page), a top-corner button that sends it to real full
    /// screen (#257). Shows on pointer movement and hides after a moment, like player controls.
    var showsExpand = false {
        didSet {
            guard showsExpand != oldValue else { return }
            if showsExpand { revealExpand() } else { removeExpand() }
        }
    }
    var onExpand: (() -> Void)?
    private var expandButton: IconButton?
    private var expandIdle: DispatchWorkItem?
    private var expandTracking: NSTrackingArea?
    private static let expandSide: CGFloat = 32
    private static let expandIdleHide: TimeInterval = 2.5

    private func revealExpand() {
        let button = expandButton ?? makeExpandButton()
        placeExpand()
        button.animator().alphaValue = 1
        expandIdle?.cancel()
        let idle = DispatchWorkItem { [weak self] in
            guard let self, let button = self.expandButton, !button.isHovered else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = Tokens.Motion.exit; button.animator().alphaValue = 0 }
        }
        expandIdle = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandIdleHide, execute: idle)
    }

    private func makeExpandButton() -> IconButton {
        let tip = String(localized: "Enter Full Screen", comment: "Tooltip of the button over a video that fills the page: puts it in the screen's own full screen.")
        let button = MiniPlayerView.overlayButton("arrow.up.left.and.arrow.down.right", side: Self.expandSide, glyph: 15, tip: tip)
        button.alphaValue = 0
        button.onClick = { [weak self] _ in
            guard let self, !self.touchSwallow.takes() else { return }
            self.onExpand?()
        }
        addSubview(button)
        expandButton = button
        if TouchGestures.isAvailable, touchWatch == nil {
            let watch = TouchWatch()
            watch.onDown = { [weak self] point in self?.touchDown(at: point) }
            watch.onTap = { [weak self] point in self?.touchTapped(at: point) }
            addGestureRecognizer(watch)
            touchWatch = watch
        }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        expandTracking = tracking
        return button
    }

    private func removeExpand() {
        expandIdle?.cancel()
        expandButton?.removeFromSuperview()
        expandButton = nil
        if let expandTracking { removeTrackingArea(expandTracking) }
        expandTracking = nil
    }

    private func placeExpand() {
        guard let button = expandButton else { return }
        let inset = Tokens.Space.x3
        button.frame = NSRect(x: bounds.maxX - inset - Self.expandSide, y: isFlipped ? inset : bounds.maxY - inset - Self.expandSide,
                              width: Self.expandSide, height: Self.expandSide)
        // Keep it on top.
        if subviews.last !== button { addSubview(button, positioned: .above, relativeTo: nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if showsExpand { revealExpand() }
    }

    private var touchWatch: TouchWatch?
    /// The click from a tap on the faded-out button: the tap only shows it.
    private var touchSwallow = TouchSwallow()

    func touchDown(at windowPoint: NSPoint) {
        guard showsExpand, let button = expandButton, button.alphaValue < 0.5,
              button.frame.contains(convert(windowPoint, from: nil)) else { return }
        touchSwallow.arm()
    }

    /// A tap on the page brings the button back, as moving the pointer does.
    func touchTapped(at windowPoint: NSPoint) {
        touchSwallow.disarm()
        if showsExpand { revealExpand() }
    }

    override func layout() {
        super.layout()
        placeExpand()
    }
}

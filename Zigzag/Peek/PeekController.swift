import AppKit
import WebKit

/// The peek's top strip, on the panel's glass: the site, then "Open as Tab" and close.
final class PeekHeaderView: NSView {
    let icon = FaviconView()
    let host = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    let expandButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", toolTip: String(localized: "Open Peek as Tab", comment: "Tooltip of the button in Peek's top strip that keeps the page as a tab."))
    let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Close Peek", comment: "Tooltip of the close button in Peek's top strip."))

    override init(frame: NSRect) {
        super.init(frame: frame)
        [icon, host, expandButton, closeButton].forEach { addSubview($0) }
        // Out of the strip, "Close" alone doesn't say what closes.
        expandButton.setAccessibilityLabel(String(localized: "Open Peek as Tab", comment: "Tooltip of the button in Peek's top strip that keeps the page as a tab."))
        closeButton.setAccessibilityLabel(String(localized: "Close Peek", comment: "Tooltip of the close button in Peek's top strip."))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Peek", comment: "Accessibility label of Peek's top strip. Peek shows a link's page in a panel over the current one."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Close sits as far from the panel's top and side as the page below sits from its sides, so its corner runs
        // with the panel's (`FloatingPanelView` fits it).
        let edge = PeekController.inset + 2
        let b = Tokens.Metric.iconButton
        let y = (bounds.height - b) / 2
        closeButton.frame = NSRect(x: bounds.width - edge - b, y: y, width: b, height: b)
        expandButton.frame = NSRect(x: closeButton.frame.minX - b, y: y, width: b, height: b)
        [expandButton, closeButton].forEach { $0.radius = max(Tokens.Radius.control, Tokens.Radius.large - max(edge, y)) }
        let iconSize = Tokens.Metric.favicon
        icon.frame = NSRect(x: PeekController.inset + CardRow.inset, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let x = icon.frame.maxX + Tokens.Space.x2 - Label.inset
        let h = host.lineHeight
        host.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, expandButton.frame.minX - x - Tokens.Space.x2), height: h)
    }
}

/// Peek: a page in a floating card over the current one. Close it and it's gone; one click makes it a real tab.
final class PeekController {
    private weak var controller: BrowserWindowController?
    private let scrim = ScrimView()
    private let panel = FloatingPanelView()
    /// Clips the strip and the page to the card's rounded corners.
    private let clip = FlippedView()
    /// Where the peek came from (the link you clicked), in the overlay: it grows out of there and goes back.
    private var origin: NSPoint?
    /// The peek's window, for pointing at it (the Getting started guide).
    var panelView: NSView { panel }
    private let header = PeekHeaderView()
    private let content = NSView()
    private(set) var tab: Tab?
    private var token: SignalToken?
    private(set) var isVisible = false {
        didSet {
            guard !isVisible else { return }
            stopEsc()
            // Getting started's Peek step is done once a peek closes again, in whichever window it was.
            if oldValue { Tutorial.complete("peek") }
        }
    }
    private var escMonitor: Any?

    private func stopEsc() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    init(controller: BrowserWindowController) {
        self.controller = controller
        // A big floating surface holding a rounded page: the large radius, the page inset in it concentrically.
        panel.radius = Tokens.Radius.large
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        clip.addSubview(header)
        clip.addSubview(content)
        panel.addSubview(clip)
        // A firmer dim than other panels: the peek is a layer above the page, and should read as one.
        scrim.color = Tokens.Color.peekScrim
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        scrim.onClick = { [weak self] in self?.close() }
        header.closeButton.onClick = { [weak self] _ in self?.close() }
        header.expandButton.onClick = { [weak self] _ in self?.openAsTab() }
    }

    private var headerHeight: CGFloat { Tokens.Metric.peekHeaderHeight }
    /// From the glass's edge to the page in it, at the sides and bottom.
    static let inset = Tokens.Space.x1

    private func panelFrame() -> NSRect {
        guard let controller else { return .zero }
        let card = controller.root.cardFrame
        let dx = max(Tokens.Space.x8, Tokens.Space.snap(card.width * Tokens.Metric.peekInsetRatio))
        let dy = max(Tokens.Space.x6, Tokens.Space.snap(card.height * Tokens.Metric.peekInsetRatio * 0.6))
        return card.insetBy(dx: dx, dy: dy)
    }

    private func layoutPanel() {
        clip.frame = panel.bounds
        header.frame = NSRect(x: 0, y: 0, width: panel.bounds.width, height: headerHeight)
        let inset = Self.inset
        content.frame = NSRect(x: inset, y: headerHeight, width: panel.bounds.width - inset * 2, height: panel.bounds.height - headerHeight - inset)
        content.layer?.cornerRadius = panel.radius - inset
        // Not while a video of the page is in full screen: WebKit has the page in its own window then, and sizes it.
        if let webView = tab?.webView, webView.superview === content { webView.frame = content.bounds }
    }

    /// Shows a URL in peek. With a configuration (from window.open), the page keeps its opener.
    @discardableResult
    func show(url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?) -> WKWebView? {
        guard let controller else { return nil }
        // A new peek replaces the old one rather than stacking.
        if let existing = tab { existing.close() }
        let spaceID = controller.tabManager.currentSpaceID
        let tab = Tab(url: url, spaceID: spaceID, configuration: configuration)
        // A peek in a private window is private too: its own store, nothing written down.
        tab.privateStore = controller.tabManager.privateStore
        tab.host = controller
        tab.opener = opener
        tab.isPeek = true
        self.tab = tab
        token = tab.changed.observe { [weak self] change in self?.tabChanged(change) }
        let webView = tab.ensureWebView()
        // Until the new page paints, show the colour of the page you came from, not a flash of white.
        let behind = opener?.webView.flatMap { $0.themeColor ?? $0.underPageBackgroundColor }
        content.layer?.backgroundColor = behind?.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(webView)
        refreshHeader()

        if !isVisible {
            isVisible = true
            scrim.frame = controller.root.cardFrame
            controller.root.overlay.addSubview(scrim)
            controller.root.overlay.addSubview(panel)
            panel.frame = panelFrame()
            scrim.show()
            grow()
            // Esc puts the peek away, the way it does a sheet; other keys go to the page as usual.
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible, event.keyCode == 53, event.window === self.controller?.window,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                self.close()
                return nil
            }
        }
        controller.window?.makeFirstResponder(webView)
        return webView
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .favicon, .title, .loading: refreshHeader()
        default: break
        }
        // Painted: pages that leave their background to the browser get white again.
        if change == .loading, let tab, !tab.isLoading, let webView = tab.webView {
            webView.setValue(true, forKey: "drawsBackground")
            content.layer?.backgroundColor = nil
            // A full-width scroll track looks heavy in a small card: a slim one that floats over the page instead.
            webView.evaluateJavaScript(Self.slimScrollbars, completionHandler: nil)
        }
    }

    private func refreshHeader() {
        guard let tab else { return }
        header.host.stringValue = tab.url.map(HistoryStore.normalizedHost) ?? tab.displayTitle
        header.icon.image = tab.favicon
        header.icon.isLoading = tab.isLoading
    }

    /// The link you clicked, if the pointer is over the page: the peek opens from there.
    private func clickPoint() -> NSPoint? {
        guard let controller, let window = controller.window else { return nil }
        let point = controller.root.overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controller.root.cardFrame.contains(point) ? point : nil
    }

    /// The card at a fraction of its size, centred on where it came from.
    private func shrunk(toward point: NSPoint, scale: CGFloat) -> CATransform3D {
        let local = panel.convert(point, from: panel.superview)
        let center = NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)
        // Layers scale from their corner; move so the centre lands on the click.
        let dx = local.x - center.x * scale, dy = local.y - center.y * scale
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(dx, dy, 0))
    }

    /// Opens out of the link with a little spring, so you see where it came from.
    private func grow() {
        // Peeked again while the last one was still leaving: start from a clean, opaque card.
        panel.layer?.removeAnimation(forKey: "shrink")
        panel.layer?.opacity = 1
        panel.alphaValue = 1
        panel.layoutSubtreeIfNeeded()
        origin = clickPoint()
        guard let layer = panel.layer, !Tokens.Motion.isKeyboardDriven, !Tokens.Motion.reduceMotion else {
            panel.present()
            return
        }
        // From a little smaller, toward where you clicked, never from nothing; over in 220ms.
        let start = shrunk(toward: origin ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY), scale: 0.95)
        let spring = CABasicAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: origin == nil ? CATransform3DMakeScale(0.97, 0.97, 1) : start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = Tokens.Motion.standard
        spring.timingFunction = Tokens.Motion.easeOut
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Tokens.Motion.enter
        fade.timingFunction = Tokens.Motion.easeOut
        layer.add(spring, forKey: "grow")
        layer.add(fade, forKey: "fade")
    }

    /// Steps back and fades.
    private func shrink(_ done: @escaping () -> Void) {
        // Esc puts it away at once, the way a key closes any panel; Reduce Motion just fades it.
        guard let layer = panel.layer, !Tokens.Motion.isFromKey, !Tokens.Motion.reduceMotion else {
            panel.dismiss(completion: done)
            return
        }
        // Settles back a touch, in place, and fades: quick and quiet, nothing flying across the page.
        let end = shrunk(toward: NSPoint(x: panel.frame.midX, y: panel.frame.midY), scale: 0.96)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            // Peeked again meanwhile: the card is in use, so it stays.
            if !self.isVisible { self.panel.removeFromSuperview() }
            layer.removeAnimation(forKey: "shrink")
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            done()
        }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        move.toValue = NSValue(caTransform3D: end)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [move, fade]
        both.duration = Tokens.Motion.enter
        both.timingFunction = Tokens.Motion.easeOut
        both.fillMode = .forwards
        both.isRemovedOnCompletion = false
        layer.add(both, forKey: "shrink")
        CATransaction.commit()
    }

    func reposition() {
        guard isVisible, let controller else { return }
        scrim.frame = controller.root.cardFrame
        panel.frame = panelFrame()
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        token = nil
        if Tokens.Motion.isFromKey { scrim.removeFromSuperview() } else { scrim.hide() }
        let closing = tab
        tab = nil
        shrink { closing?.close() }
        if let controller, let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }

    /// Promotes the peeked page to a real tab, without reloading it.
    func openAsTab() {
        guard isVisible, let controller, let tab else { return }
        isVisible = false
        token = nil
        self.tab = nil
        tab.isPeek = false
        // Promoted before it finished loading: it never gets the peek's "painted" step, so it draws its own
        // background from here on, like any tab.
        tab.webView?.setValue(true, forKey: "drawsBackground")
        content.layer?.backgroundColor = nil
        let target = controller.root.cardFrame
        scrim.hide()
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true, {
            self.panel.animator().frame = target
        }, completion: {
            if !self.isVisible { self.panel.removeFromSuperview() }
            self.panel.alphaValue = 1
            // The window closed while it grew: the page goes with it, rather than living on with no window.
            guard WindowManager.shared.controllers.contains(where: { $0 === controller }) else { tab.close(); return }
            controller.tabManager.insert(tab)
        })
    }

    private static let slimScrollbars = """
    (() => {
      if (document.getElementById('zigzag-peek-scrollbars')) return;
      const style = document.createElement('style');
      style.id = 'zigzag-peek-scrollbars';
      style.textContent = '::-webkit-scrollbar{width:10px;height:10px;background:transparent}' +
        '::-webkit-scrollbar-track{background:transparent}' +
        '::-webkit-scrollbar-thumb{background:rgba(128,128,128,.45);border-radius:6px;border:3px solid transparent;background-clip:content-box}' +
        '::-webkit-scrollbar-thumb:hover{background-color:rgba(128,128,128,.7)}';
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    var contentFrame: NSRect { panel.frame }

    func goBack() { tab?.goBack() }
    func goForward() { tab?.goForward() }
}

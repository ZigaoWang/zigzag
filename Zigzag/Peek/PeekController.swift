import AppKit
import WebKit

/// The peek card's top strip: site, then "Open as Tab" and close.
final class PeekHeaderView: NSView {
    let icon = FaviconView()
    let host = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    let expandButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", toolTip: "Open as Tab")
    let closeButton = IconButton(symbol: "xmark", toolTip: "Close")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        [icon, host, expandButton, closeButton].forEach { addSubview($0) }
    }

    /// Takes the page's own color, so the strip reads as the top of that page, with text that stands out on it.
    func tint(with color: NSColor?) {
        guard let color = color?.usingColorSpace(.sRGB) else {
            layer?.backgroundColor = nil
            host.textColor = Tokens.Color.textPrimary
            expandButton.tint = Tokens.Color.icon
            closeButton.tint = Tokens.Color.icon
            return
        }
        layer?.backgroundColor = color.cgColor
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        let ink: NSColor = luminance < 0.55 ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.82)
        host.textColor = ink
        expandButton.tint = ink.withAlphaComponent(0.75)
        closeButton.tint = ink.withAlphaComponent(0.75)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let iconSize = Tokens.Metric.favicon
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let b = Tokens.Metric.iconButton
        closeButton.frame = NSRect(x: bounds.width - Tokens.Space.x2 - b, y: (bounds.height - b) / 2, width: b, height: b)
        expandButton.frame = NSRect(x: closeButton.frame.minX - b, y: closeButton.frame.minY, width: b, height: b)
        let x = icon.frame.maxX + Tokens.Space.x2
        let h = host.lineHeight
        host.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: expandButton.frame.minX - x - Tokens.Space.x2, height: h)
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
    private(set) var isVisible = false { didSet { if !isVisible { stopEsc() } } }
    private var escMonitor: Any?

    private func stopEsc() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    init(controller: BrowserWindowController) {
        self.controller = controller
        panel.radius = Tokens.Radius.panel
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        clip.addSubview(header)
        clip.addSubview(content)
        panel.addSubview(clip)
        // A firmer dim than other panels: the peek is a layer above the page, and should read as one.
        scrim.color = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.22) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        scrim.onClick = { [weak self] in self?.close() }
        header.closeButton.onClick = { [weak self] _ in self?.close() }
        header.expandButton.onClick = { [weak self] _ in self?.openAsTab() }
    }

    private var headerHeight: CGFloat { Tokens.Space.x10 }

    private func panelFrame() -> NSRect {
        guard let controller else { return .zero }
        let card = controller.root.cardFrame
        let dx = max(Tokens.Space.x8, Tokens.Space.snap(card.width * Tokens.Metric.peekInsetRatio))
        let dy = max(Tokens.Space.x6, Tokens.Space.snap(card.height * Tokens.Metric.peekInsetRatio * 0.6))
        return card.insetBy(dx: dx, dy: dy)
    }

    private func layoutPanel() {
        clip.frame = panel.bounds
        clip.layer?.cornerRadius = panel.radius
        header.frame = NSRect(x: 0, y: 0, width: panel.bounds.width, height: headerHeight)
        content.frame = NSRect(x: 0, y: headerHeight, width: panel.bounds.width, height: panel.bounds.height - headerHeight)
        tab?.webView?.frame = content.bounds
    }

    /// Shows a URL in peek. With a configuration (from window.open), the page keeps its opener.
    @discardableResult
    func show(url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?) -> WKWebView? {
        guard let controller else { return nil }
        // A new peek replaces the old one rather than stacking.
        if let existing = tab { existing.close() }
        let spaceID = controller.tabManager.currentSpaceID
        let tab = Tab(url: url, spaceID: spaceID, configuration: configuration)
        tab.host = controller
        tab.opener = opener
        tab.isPeek = true
        self.tab = tab
        token = tab.changed.observe { [weak self] change in self?.tabChanged(change) }
        let webView = tab.ensureWebView()
        // Until the new page paints, show the colour of the page you came from, not a flash of white.
        let behind = opener?.webView.flatMap { $0.themeColor ?? $0.underPageBackgroundColor }
        content.layer?.backgroundColor = behind?.cgColor
        header.tint(with: behind)
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
        // Once the page has its own colour; until then it keeps the one it opened with.
        if !tab.isLoading || tab.webView?.themeColor != nil {
            header.tint(with: tab.webView.flatMap { $0.themeColor ?? $0.underPageBackgroundColor })
        }
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
        panel.alphaValue = 1
        panel.layoutSubtreeIfNeeded()
        origin = clickPoint()
        guard let layer = panel.layer, !Tokens.Motion.isKeyboardDriven, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.present()
            return
        }
        let start = shrunk(toward: origin ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY), scale: 0.86)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: origin == nil ? CATransform3DMakeScale(0.97, 0.97, 1) : start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 28
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(spring, forKey: "grow")
        layer.add(fade, forKey: "fade")
    }

    /// Steps back and fades.
    private func shrink(_ done: @escaping () -> Void) {
        guard let layer = panel.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.dismiss(completion: done)
            return
        }
        // Settles back a touch, in place, and fades: quick and quiet, nothing flying across the page.
        let end = shrunk(toward: NSPoint(x: panel.frame.midX, y: panel.frame.midY), scale: 0.96)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.panel.removeFromSuperview()
            layer.removeAllAnimations()
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
        both.duration = 0.16
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        scrim.hide()
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
        let target = controller.root.cardFrame
        scrim.hide()
        Tokens.Motion.animate(Tokens.Motion.snappy, {
            self.panel.animator().frame = target
        }, completion: {
            self.panel.removeFromSuperview()
            self.panel.alphaValue = 1
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

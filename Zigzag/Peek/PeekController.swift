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
        [icon, host, expandButton, closeButton].forEach { addSubview($0) }
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
    private let header = PeekHeaderView()
    private let content = NSView()
    private(set) var tab: Tab?
    private var token: SignalToken?
    private(set) var isVisible = false

    init(controller: BrowserWindowController) {
        self.controller = controller
        panel.radius = Tokens.Radius.panel
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        panel.addSubview(header)
        panel.addSubview(content)
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
            panel.present()
        }
        controller.window?.makeFirstResponder(webView)
        return webView
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .favicon, .title, .loading: refreshHeader()
        default: break
        }
    }

    private func refreshHeader() {
        guard let tab else { return }
        header.host.stringValue = tab.url.map(HistoryStore.normalizedHost) ?? tab.displayTitle
        header.icon.image = tab.favicon
        header.icon.isLoading = tab.isLoading
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
        panel.dismiss { closing?.close() }
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

    var contentFrame: NSRect { panel.frame }

    func goBack() { tab?.goBack() }
    func goForward() { tab?.goForward() }
}

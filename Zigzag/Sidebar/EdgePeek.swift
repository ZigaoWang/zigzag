import AppKit
import WebKit

/// Where the edge Peek's card sits on a screen: the window Peek's proportions, on the screen's visible frame instead
/// of a browser card.
enum EdgePeekLayout {
    static func frame(in screen: NSRect) -> NSRect {
        let dx = max(Tokens.Space.x8, Tokens.Space.snap(screen.width * Tokens.Metric.peekInsetRatio))
        let dy = max(Tokens.Space.x6, Tokens.Space.snap(screen.height * Tokens.Metric.peekInsetRatio * 0.6))
        return screen.insetBy(dx: dx, dy: dy)
    }
}

/// The edge sidebar's Peek: the tab you picked, in a card over the app in front, not in the browser window.
///
/// The page is the tab's own `pageHolder`, moved out of its pane and put back on close, so its state carries: the
/// same page, not a second load. Close gives it back; Open as Tab gives it back and brings the browser forward.
final class EdgePeek {
    static let shared = EdgePeek()

    private var panel: EdgeSidebarPanel?
    private var card: FloatingPanelView?
    private var clip: FlippedView?
    private let header = PeekHeaderView(frame: .zero)
    private let content = NSView()
    private weak var controller: BrowserWindowController?
    private(set) var tab: Tab?
    private(set) var isVisible = false
    /// Where the page came from, so closing puts it back there.
    private weak var origin: NSView?
    private var originFrame: NSRect = .zero
    private var token: Any?
    private var escMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    private var headerHeight: CGFloat { Tokens.Metric.peekHeaderHeight }
    private static let inset = Tokens.Metric.peekInset

    private init() {
        header.closeButton.onClick = { [weak self] _ in self?.close() }
        header.expandButton.onClick = { [weak self] _ in self?.openAsTab() }
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
    }

    // MARK: Showing

    func show(tab: Tab, from controller: BrowserWindowController) {
        if isVisible { close() }
        makePanel()
        guard let panel, let card else { return }
        self.controller = controller
        self.tab = tab
        _ = tab.ensureWebView()
        guard let holder = tab.pageHolder else { return }
        // The page moves, not a copy: the same holder the pane has, so form state, scroll and media carry.
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()
        content.subviews.forEach { $0.removeFromSuperview() }
        holder.frame = content.bounds
        holder.autoresizingMask = [.width, .height]
        content.addSubview(holder)

        refreshHeader()
        refreshGround()
        token = tab.changed.observe { [weak self] _ in self?.refreshHeader() }

        let screen = NSScreen.screens.first { $0.visibleFrame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        panel.setFrame(EdgePeekLayout.frame(in: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)),
                       display: false)
        card.layoutSubtreeIfNeeded()
        layout()
        isVisible = true
        panel.orderFrontRegardless()
        panel.makeKey()
        if let webView = tab.webView { panel.makeFirstResponder(webView) }

        // The browser coming forward, or going away, takes the page back with it.
        if let window = controller.window {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func makePanel() {
        guard panel == nil else { return }
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let card = FloatingPanelView()
        // A window of its own over another app: the material shows what is behind it, not Its own window.
        card.showsDesktop = true
        card.radius = Tokens.Radius.large
        card.onLayout = { [weak self] in self?.layout() }
        let clip = FlippedView()
        clip.addSubview(header)
        clip.addSubview(content)
        card.addSubview(clip)
        panel.contentView = card
        self.panel = panel
        self.card = card
        self.clip = clip
    }

    private func layout() {
        guard let card, let clip else { return }
        clip.frame = card.bounds
        header.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: headerHeight)
        content.frame = NSRect(x: Self.inset, y: headerHeight,
                               width: max(0, card.bounds.width - Self.inset * 2),
                               height: max(0, card.bounds.height - headerHeight - Self.inset))
        content.layer?.cornerRadius = card.radius - Self.inset
        if let holder = tab?.pageHolder, holder.superview === content { holder.frame = content.bounds }
    }

    // MARK: Header

    private func refreshHeader() {
        guard let tab else { return }
        header.host.stringValue = tab.url.map(HistoryStore.normalizedHost) ?? tab.displayTitle
        header.host.lineBreakMode = AddressView.lineBreak(forName: header.host.stringValue)
        header.icon.image = tab.favicon
        header.icon.isLoading = tab.isLoading
    }

    private func refreshGround() {
        let color = tab?.pageColor
        card?.tintStrength = color == nil ? nil : 1
        card?.surfaceTint = color
        header.ground = color
    }

    // MARK: Closing

    /// Puts the page back and takes the card away.
    func close() {
        guard isVisible else { return }
        let tab = self.tab
        let origin = self.origin
        let originFrame = self.originFrame
        let controller = self.controller
        teardown()
        if let holder = tab?.pageHolder {
            holder.removeFromSuperview()
            if let origin {
                holder.frame = originFrame
                origin.addSubview(holder)
                origin.needsLayout = true
            }
        }
        if let controller, let webView = controller.selectedWebView {
            controller.window?.makeFirstResponder(webView)
        }
    }

    /// The browser window is going: the page goes with it, not held by a card.
    private func dismiss() {
        guard isVisible else { return }
        tab?.pageHolder?.removeFromSuperview()
        teardown()
    }

    private func teardown() {
        isVisible = false
        token = nil
        self.tab = nil
        controller = nil
        origin = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel?.orderOut(nil)
    }

    /// Opens the page as the browser's tab: same holder, same page, now in its pane and the window in front.
    func openAsTab() {
        guard let tab, let controller else { return }
        close()
        controller.tabManager.select(tab)
        controller.bringForwardForEdge(keepingPanel: true)
    }
}

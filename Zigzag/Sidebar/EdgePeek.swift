import AppKit
import WebKit

/// Where the edge Peek's page sits: the rest of the screen beside the sidebar, its top and bottom the sidebar card's.
enum EdgePeekLayout {
    static func frame(attachedTo sidebar: NSRect, in screen: NSRect, onRight: Bool) -> NSRect {
        let gap = Tokens.Space.x2
        let inset = Tokens.Space.x2
        let bottom = max(sidebar.minY, screen.minY + inset)
        let top = min(sidebar.maxY, screen.maxY - inset)
        let height = max(0, top - bottom)
        if onRight {
            let x = screen.minX + inset
            return NSRect(x: x, y: bottom, width: max(0, sidebar.minX - gap - x), height: height)
        }
        let x = sidebar.maxX + gap
        return NSRect(x: x, y: bottom, width: max(0, screen.maxX - inset - x), height: height)
    }
}

/// The edge sidebar's Peek: the tab you picked, filling the screen beside the sidebar over the app in front. The
/// app behind is dimmed while it is out; the sidebar stays as it was, so another tab can be picked in place.
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
    /// The app behind, dimmed while the page is out beside the sidebar.
    private var dimPanel: NSPanel?
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
    private var outsideMonitor: Any?
    private var outsideLocal: Any?
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

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
        if isVisible {
            if self.controller === controller {
                if self.tab === tab { return }
                swap(to: tab)
                return
            }
            close()
        }
        makePanel()
        guard let panel, let card else { return }
        self.controller = controller
        self.tab = tab
        _ = tab.ensureWebView()
        guard let holder = tab.pageHolder, let sidebarFrame = EdgeSidebar.shared.sidebarCardScreenFrame else { return }
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

        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(sidebarFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let dim = dimPanel ?? makeDim()
        dim.setFrame(visible, display: false)
        dim.orderFrontRegardless()
        panel.setFrame(EdgePeekLayout.frame(attachedTo: sidebarFrame, in: visible,
                                           onRight: EdgeSidebar.shared.panelOnRight), display: false)
        // The panel keeps the sidebar out while the page is attached, whatever the pointer does.
        EdgeSidebar.shared.holdForPeek(true)
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
        // A click outside, in this app or another, puts it away as Esc does. The sidebar is not outside: picking
        // another tab there swaps the page, and picking this one again is the toggle.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, MenuPanel.current == nil else { return }
                if self.panel?.frame.contains(NSEvent.mouseLocation) != true { self.close() }
            }
        }
        outsideLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if MenuPanel.current != nil { return event }
            if event.window === self.dimPanel {
                // The dimmed ground is the click that puts it away; it does not reach the app behind.
                self.close()
                return nil
            }
            if event.window !== self.panel && event.window !== EdgeSidebar.shared.panelWindow { self.close() }
            return event
        }
        // Moving to another app or desktop is moving away: the page goes back rather than following the focus.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                        object: nil, queue: .main) { [weak self] note in
            // The pid, not the application: the note is not sendable, and the main actor only needs to know whose it was.
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.isVisible,
                      pid != NSRunningApplication.current.processIdentifier else { return }
                self.close()
            }
        }
    }

    /// Another tab picked in the sidebar while the page is out: the old page goes back and the new one takes its place,
    /// with the panel and the dim staying put.
    private func swap(to newTab: Tab) {
        if let tab { restore(tab) }
        token = nil
        tab = newTab
        _ = newTab.ensureWebView()
        guard let holder = newTab.pageHolder else { close(); return }
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()
        holder.frame = content.bounds
        holder.autoresizingMask = [.width, .height]
        content.addSubview(holder)
        refreshHeader()
        refreshGround()
        token = newTab.changed.observe { [weak self] _ in self?.refreshHeader() }
        layout()
        if let webView = newTab.webView { panel?.makeFirstResponder(webView) }
    }

    private func restore(_ tab: Tab) {
        guard let holder = tab.pageHolder, let origin else { return }
        holder.removeFromSuperview()
        holder.frame = originFrame
        origin.addSubview(holder)
        origin.needsLayout = true
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

    private func makeDim() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let dim = ColorView(color: NSColor.black.withAlphaComponent(0.3))
        dim.autoresizingMask = [.width, .height]
        panel.contentView = dim
        dimPanel = panel
        return panel
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

    /// Puts the page back and takes the card and the dim away.
    func close() {
        guard isVisible else { return }
        let tab = self.tab
        let controller = self.controller
        if let tab { restore(tab) }
        teardown()
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
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        if let outsideLocal { NSEvent.removeMonitor(outsideLocal) }
        outsideLocal = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        EdgeSidebar.shared.holdForPeek(false)
        dimPanel?.orderOut(nil)
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

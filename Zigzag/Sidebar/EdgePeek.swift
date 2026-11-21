import AppKit
import WebKit

/// Where the edge Peek's page sits: the rest of the screen beside the sidebar, its top and bottom the sidebar card's.
/// What keeps the popout out when it loses key: the sidebar itself (to pick another tab) and our own menus or
/// sheets. Everything else, including a third-party switcher that takes key without activating an app, closes it.
enum EdgePeekFocusPolicy {
    enum NewKey { case none, sidebar, owned, other }

    static func keepsOpen(newKey: NewKey, menuOpen: Bool) -> Bool {
        if menuOpen { return true }
        switch newKey {
        case .sidebar, .owned: return true
        case .none, .other: return false
        }
    }
}

/// Whether a page can go back where it came from: never into a closed tab, and not at all when it had no home.
enum EdgePeekRestorePolicy {
    static func canRestore(isClosed: Bool, hasOrigin: Bool) -> Bool { !isClosed && hasOrigin }
}

/// What the peek does when the browser's context changes under it: a space switch ends it, and a page opened from
/// it stays in it.
enum EdgePeekRouting {
    enum NewPage { case peek, browser }

    static func closesOnSpaceChange(peekVisible: Bool) -> Bool { peekVisible }
    static func newPage(peekVisible: Bool) -> NewPage { peekVisible ? .peek : .browser }
}

enum EdgePeekLayout {
    /// The page area beside the sidebar, inside the screen's own margins.
    static func pageFrame(beside sidebar: NSRect, in screen: NSRect, onRight: Bool) -> NSRect {
        let margin = Tokens.Space.x2
        let bottom = screen.minY + margin
        let height = max(0, screen.height - margin * 2)
        if onRight {
            let x = screen.minX + margin
            return NSRect(x: x, y: bottom, width: max(0, sidebar.minX - margin - x), height: height)
        }
        let x = sidebar.maxX + margin
        return NSRect(x: x, y: bottom, width: max(0, screen.maxX - margin - x), height: height)
    }

    static func expandedFrame(in screen: NSRect, onRight: Bool) -> NSRect {
        screen.insetBy(dx: Tokens.Space.x2, dy: Tokens.Space.x2)
    }
}

/// The edge sidebar's peek popout: the tab you picked, filling the screen beside the sidebar over the app in front.
/// The sidebar stays as it was, so another tab can be picked in place.
///
/// The page is the tab's own `pageHolder`, moved out of its pane and put back on close, so its state carries: the
/// same page, not a second load. Close gives it back; Expand gives it back and brings the browser window over.
final class EdgePeek {
    static let shared = EdgePeek()

    private var panel: EdgeSidebarPanel?
    private var card: FloatingPanelView?
    private var clip: FlippedView?
    private let toolbar = EdgePeekToolbar(frame: .zero)
    private let content = NSView()
    private weak var controller: BrowserWindowController?
    private(set) var tab: Tab?
    private(set) var isVisible = false
    /// Where the page came from, so closing puts it back there.
    private weak var origin: NSView?
    private var originFrame: NSRect = .zero
    private var token: Any?
    private var managerObserver: Any?
    private var escMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var outsideLocal: Any?
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var keyLostObserver: NSObjectProtocol?
    /// The row the popout came from, on screen: it grows from it and shrinks back into it.
    private var sourceFrame: NSRect?
    private var isClosing = false

    private var headerHeight: CGFloat { Tokens.Pane.height }
    private static let inset = Tokens.Metric.peekInset

    private init() {
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
        EdgePeekPreview.shared.hide()
        makePanel()
        guard let panel, let card else { return }
        self.controller = controller
        self.tab = tab
        _ = tab.ensureWebView()
        guard let holder = tab.pageHolder, let sidebarFrame = EdgeSidebar.shared.sidebarCardScreenFrame else {
            self.controller = nil
            self.tab = nil
            return
        }
        controller.setEdgePeek(tab.id)
        // The page moves, not a copy: the same holder the pane has, so form state, scroll and media carry.
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()
        content.subviews.forEach { $0.removeFromSuperview() }
        holder.frame = content.bounds
        holder.autoresizingMask = [.width, .height]
        content.addSubview(holder)

        refreshToolbar()
        refreshGround()
        token = tab.changed.observe { [weak self] _ in self?.refreshToolbar() }

        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(sidebarFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pageFrame = EdgePeekLayout.pageFrame(beside: sidebarFrame, in: visible,
                                                 onRight: EdgeSidebar.shared.panelOnRight)
        sourceFrame = controller.edgeSidebarForDisplay().sidebar.list.lastPickedRowFrame
        panel.setFrame(sourceFrame ?? pageFrame, display: false)
        // The panel keeps the sidebar out while the page is attached, whatever the pointer does.
        EdgeSidebar.shared.holdForPeek(true)
        card.layoutSubtreeIfNeeded()
        layout()
        isVisible = true
        isClosing = false
        managerObserver = controller.tabManager.changed.observe { [weak self] change in
            MainActor.assumeIsolated { self?.managerChanged(change) }
        }
        controller.prepareEdgeSidebar()
        panel.orderFrontRegardless()
        panel.makeKey()
        if let sourceFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = Tokens.Motion.easeOut
                panel.animator().setFrame(pageFrame, display: true)
            }
        }
        if let webView = tab.webView { panel.makeFirstResponder(webView) }

        // The browser coming forward, or going away, takes the page back with it.
        if let window = controller.window {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(duration: 0.15) }
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        keyLostObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                  object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.focusChanged() } }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods == .command, let characters = event.charactersIgnoringModifiers?.lowercased() {
                switch characters {
                case "l":
                    self.toolbar.focusAddress()
                    return nil
                case "r":
                    self.tab?.webView?.reload()
                    return nil
                case "t":
                    EdgeSidebar.shared.newTabInPlace()
                    return nil
                case "w":
                    if let tab = self.tab, let controller = self.controller {
                        controller.tabManager.close(tab)
                        self.close()
                    }
                    return nil
                default:
                    break
                }
            }
            return event
        }
        // A click outside, in this app or another, puts it away as Esc does. The sidebar is not outside: picking
        // another tab there swaps the page, and picking this one again is the toggle.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, MenuPanel.current == nil else { return }
                if self.panel?.frame.contains(NSEvent.mouseLocation) != true { self.close(duration: 0.15) }
            }
        }
        outsideLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if MenuPanel.current != nil || RunLoop.current.currentMode == .eventTracking { return event }
            if event.window is EdgeCommandBarPopup || event.window is NSSavePanel || event.window?.sheetParent != nil { return event }
            if event.window !== self.panel && event.window !== EdgeSidebar.shared.panelWindow { self.close(duration: 0.15) }
            return event
        }
        // Moving to another app or desktop is moving away: the page goes back rather than following the focus.
        // Becoming active is only leaving when the key is not ours: the panel, the sidebar, the command bar or a
        // sheet of ours keeps the page out. A browser window taking key is handled by the key observer above.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, !self.isClosing else { return }
                    let key = NSApp.keyWindow
                    if key === self.panel || key === EdgeSidebar.shared.panelWindow || key is EdgeCommandBarPopup
                        || key is NSSavePanel || key?.sheetParent != nil { return }
                    self.close(duration: 0.15)
                }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(duration: 0.15) }
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
    /// with the panel staying put.
    private func swap(to newTab: Tab) {
        if let tab { restore(tab) }
        token = nil
        tab = newTab
        controller?.setEdgePeek(newTab.id)
        panel?.makeKey()
        _ = newTab.ensureWebView()
        guard let holder = newTab.pageHolder else { close(); return }
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()
        holder.frame = content.bounds
        holder.autoresizingMask = [.width, .height]
        content.addSubview(holder)
        panel?.makeFirstResponder(nil)
        refreshToolbar()
        refreshGround()
        token = newTab.changed.observe { [weak self] _ in self?.refreshToolbar() }
        sourceFrame = controller?.edgeSidebarForDisplay().sidebar.list.lastPickedRowFrame
        layout()
        controller?.prepareEdgeSidebar()
        panel?.makeKey()
        if let webView = newTab.webView { panel?.makeFirstResponder(webView) }
    }

    private func restore(_ tab: Tab) {
        guard let holder = tab.pageHolder else { return }
        let canRestore = EdgePeekRestorePolicy.canRestore(isClosed: tab.isClosed, hasOrigin: origin != nil)
        holder.removeFromSuperview()
        if canRestore, let origin {
            holder.frame = originFrame
            origin.addSubview(holder)
            origin.needsLayout = true
        }
        origin = nil
    }

    private func makePanel() {
        guard panel == nil else { return }
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.level = .floating
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
        configureToolbar()
        let clip = FlippedView()
        clip.addSubview(toolbar)
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
        toolbar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: headerHeight)
        content.frame = NSRect(x: Self.inset, y: headerHeight,
                               width: max(0, card.bounds.width - Self.inset * 2),
                               height: max(0, card.bounds.height - headerHeight - Self.inset))
        content.layer?.cornerRadius = card.radius - Self.inset
        if let holder = tab?.pageHolder, holder.superview === content { holder.frame = content.bounds }
    }

    // MARK: Header

    private func configureToolbar() {
        toolbar.onBack = { [weak self] in self?.tab?.webView?.goBack() }
        toolbar.onForward = { [weak self] in self?.tab?.webView?.goForward() }
        toolbar.onReload = { [weak self] in
            guard let tab = self?.tab else { return }
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
        }
        toolbar.onAddress = { [weak self] text in self?.navigate(to: text) }
        toolbar.onExtensions = { [weak self] button in self?.showExtensions(from: button) }
        toolbar.onExpand = { [weak self] in self?.expand() }
    }

    private func refreshToolbar() {
        guard let tab else { return }
        if tab.isClosed {
            close()
            return
        }
        controller?.updateEdgeSidebarForPeek(tab)
        toolbar.update(state: EdgePeekToolbarState(
            address: tab.url?.absoluteString ?? "",
            canGoBack: tab.webView?.canGoBack ?? false,
            canGoForward: tab.webView?.canGoForward ?? false,
            isLoading: tab.isLoading))
    }

    private func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        tab?.load(url)
    }

    private func showExtensions(from button: IconButton) {
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Extensions", comment: "The peek's extensions menu title."),
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.minY), in: button)
    }

    private func refreshGround() {
        let color = tab?.pageColor
        card?.tintStrength = color == nil ? nil : 1
        card?.surfaceTint = color
    }

    // MARK: Closing

    /// Puts the page back and takes the card away, shrinking into the row it came from.
    func close(duration: TimeInterval = 0.26) {
        guard isVisible, !isClosing else { return }
        let controller = self.controller
        guard duration > 0, let panel, let source = sourceFrame else {
            if let tab { restore(tab) }
            teardown()
            if let controller, let webView = controller.selectedWebView {
                controller.window?.makeFirstResponder(webView)
            }
            return
        }
        isClosing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().setFrame(source, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isClosing else { return }
                self.isClosing = false
                let controller = controller
                if let tab = self.tab { self.restore(tab) }
                self.teardown()
                if let controller, let webView = controller.selectedWebView {
                    controller.window?.makeFirstResponder(webView)
                }
            }
        }
    }

    /// The sidebar's address, clicked while the popout is out, types in the popout instead of bringing the browser.
    func focusAddress() {
        guard isVisible else { return }
        panel?.makeKey()
        toolbar.focusAddress()
    }

    /// The command bar or another of our popups has finished: the page takes the keyboard back.
    func makeKey() {
        guard isVisible else { return }
        panel?.makeKey()
        if let webView = tab?.webView { panel?.makeFirstResponder(webView) }
    }

    /// A space change or the peeked tab closing under the page: both end the popout rather than leave a page with
    /// no row to come from or go back to.
    private func managerChanged(_ change: TabManager.Change) {
        guard isVisible else { return }
        switch change {
        case .space:
            if EdgePeekRouting.closesOnSpaceChange(peekVisible: isVisible) { close(duration: 0.15) }
        case .structure:
            if tab?.isClosed == true { close() }
        case .selection:
            // The browser moved to another page under the popout: the page has no card of its own to go back to,
            // and restoring it would paint it over the page now in that card. The next show puts the new page out.
            if tab?.isClosed == true { close() }
            else if let tab, controller?.tabManager.selectedTab !== tab { dismiss() }
        case .content:
            break
        }
    }

    /// The popout is no longer the key window: keep it only for the sidebar or our own menus and sheets.
    private func focusChanged() {
        guard isVisible, !isClosing else { return }
        let key = NSApp.keyWindow
        if key === panel { return }
        let newKey: EdgePeekFocusPolicy.NewKey
        if key == nil {
            newKey = .none
        } else if key === EdgeSidebar.shared.panelWindow {
            newKey = .sidebar
        } else if key is EdgeCommandBarPopup || key is NSSavePanel || key?.sheetParent != nil {
            newKey = .owned
        } else {
            newKey = .other
        }
        guard !EdgePeekFocusPolicy.keepsOpen(newKey: newKey, menuOpen: MenuPanel.current != nil) else { return }
        EdgeSidebar.shared.hide(animated: false)
        close(duration: 0.15)
    }

    /// The browser window is going: the page goes with it, not held by a card.
    private func dismiss() {
        guard isVisible else { return }
        tab?.pageHolder?.removeFromSuperview()
        teardown()
    }

    private func teardown() {
        controller?.setEdgePeek(nil)
        isVisible = false
        isClosing = false
        sourceFrame = nil
        token = nil
        managerObserver = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        self.tab = nil
        controller = nil
        origin = nil
        if let keyLostObserver { NotificationCenter.default.removeObserver(keyLostObserver) }
        keyLostObserver = nil
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
        panel?.orderOut(nil)
    }

    /// Hands the page to its tab and gives the browser the display: Expand accepts the browser for this screen, so
    /// it takes the whole screen and the app that was underneath keeps its own Space beside it.
    func expand() {
        guard let tab, let controller, let window = controller.window else { return }
        controller.tabManager.select(tab)
        if window.isMiniaturized { window.deminiaturize(nil) }
        close(duration: 0)
        EdgeSidebar.shared.hide(animated: false)
        controller.takeOverFromEdgeOverlay()
        window.makeFirstResponder(tab.webView)
    }
}

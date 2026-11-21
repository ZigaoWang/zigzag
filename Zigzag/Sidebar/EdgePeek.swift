import AppKit
import WebKit

/// Where the edge lens's page sits: the rest of the screen beside the sidebar, its top and bottom the sidebar card's.
/// What keeps the lens out when it loses key: the sidebar itself (to pick another tab) and our own menus or sheets.
/// Everything else, including a third-party switcher that takes key without activating an app, closes it.
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
    static func canRestore(isClosed: Bool, hasOrigin: Bool, reason: EdgeLensReason = .escape) -> Bool {
        !isClosed && hasOrigin && reason != .selection
    }
}

/// What the lens does when the browser's context changes under it: a space switch ends it, and a page opened from
/// it stays in it.
enum EdgePeekRouting {
    enum NewPage { case peek, browser }

    static func closesOnSpaceChange(peekVisible: Bool) -> Bool { peekVisible }
    static func newPage(peekVisible: Bool) -> NewPage { peekVisible ? .peek : .browser }
    /// A page opened from the lens replaces it; selecting any other tab is leaving the lens.
    static func selectionKeepsLens(lensTab: Tab?, selected: Tab?) -> Bool {
        guard let lensTab, let selected, selected !== lensTab else { return false }
        return selected.opener === lensTab
    }
}

/// The edge lens (#365): the sidebar's preview, opened. The tab's own page fills the preview card beside the sidebar,
/// its caption carries the page's controls, and the sidebar and the lens live and close as one session.
///
/// The page is the tab's own `pageHolder`, moved out of its pane and put straight back on close, so its state carries:
/// the same page, not a second load. Nothing in the close path waits on WebKit.
final class EdgePeek {
    static let shared = EdgePeek()

    private var panel: EdgeSidebarPanel?
    private var card: TabPreviewView?
    private var overlay: PassthroughView?
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
    private var screenObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var siteHost: EdgeSitePanelHost?
    /// The preview frame the lens grew from; the collapse goes back to it.
    private var sourceFrame: NSRect?
    private var isCollapsing = false
    private var collapseDeadline: DispatchWorkItem?

    private init() {}

    // MARK: Opening

    /// The preview or a row was clicked: the lens opens from the preview's frame, or closes first if it is already
    /// out. One action never opens a second lens. A page opened from the lens replaces its page instead.
    func show(tab: Tab, from controller: BrowserWindowController, replacing: Bool = false) {
        if isVisible {
            switch EdgeLensPolicy.openAction(isVisible: true, replacing: replacing) {
            case .replace:
                swap(to: tab, from: controller)
            case .close:
                dismiss(self.tab === tab ? .sameTab : .sidebarClick)
            case .open:
                break
            }
            return
        }
        guard !isCollapsing else { return }
        // The lens and the sidebar are one session: a lens with no panel would float over another app with nothing
        // to put its page back into.
        guard EdgeSidebar.isOn, EdgeSidebar.shared.isShowing else {
            EdgePeekPreview.shared.hide()
            return
        }
        EdgePeekPreview.shared.hide()
        makePanel()
        guard let panel, let card, let sidebarFrame = EdgeSidebar.shared.sidebarCardScreenFrame else { return }
        self.controller = controller
        self.tab = tab
        _ = tab.ensureWebView()
        guard let holder = tab.pageHolder else {
            self.controller = nil
            self.tab = nil
            return
        }
        controller.setEdgePeek(tab.id)
        controller.prepareEdgeSidebar()
        // The page moves, not a copy: the same holder the pane has, so form state, scroll and media carry.
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()

        card.showsLensControls = true
        card.show(tab: tab, bookmark: nil)
        card.showLive(holder: holder)
        card.layoutSubtreeIfNeeded()

        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(sidebarFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        sourceFrame = EdgePeekPreview.shared.currentFrame
            ?? controller.edgeSidebarForDisplay().sidebar.list.lastPickedRowFrame
        let frame = EdgeLensLayout.frame(beside: sidebarFrame, in: visible, pageAspect: card.pageAspect,
                                         caption: card.lensCaptionHeight,
                                         onRight: EdgeSidebar.shared.panelOnRight,
                                         rowMidY: sourceFrame?.midY ?? sidebarFrame.midY)
        panel.setFrame(sourceFrame ?? frame, display: false)
        panel.ignoresMouseEvents = false
        isVisible = true
        isCollapsing = false
        EdgeSidebar.shared.holdForPeek(true)
        panel.orderFrontRegardless()
        panel.makeKey()
        if let source = sourceFrame, source != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = Tokens.Motion.easeOut
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        card.layoutSubtreeIfNeeded()
        if let webView = tab.webView { panel.makeFirstResponder(webView) }

        token = tab.changed.observe { [weak self] _ in self?.refreshLens() }
        managerObserver = controller.tabManager.changed.observe { [weak self] change in
            MainActor.assumeIsolated { self?.managerChanged(change) }
        }
        installLensObservers(for: controller)
        refreshLens()
    }

    /// A page opened from the lens takes the card over: the old page goes back to its tab, and the new page's holder
    /// moves into the same card. The panel, its frame and the sidebar stay.
    private func swap(to tab: Tab, from controller: BrowserWindowController) {
        guard controller === self.controller, tab !== self.tab, !tab.isClosed, tab.url != nil else { return }
        _ = tab.ensureWebView()
        guard let holder = tab.pageHolder, let card, let panel else { return }
        card.endLive()
        if let old = self.tab, let oldHolder = old.pageHolder, let origin {
            oldHolder.removeFromSuperview()
            oldHolder.frame = originFrame
            origin.addSubview(oldHolder)
            origin.needsLayout = true
        }
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()
        self.tab = tab
        card.showsLensControls = true
        card.show(tab: tab, bookmark: nil)
        card.showLive(holder: holder)
        card.layoutSubtreeIfNeeded()
        controller.setEdgePeek(tab.id)
        token = tab.changed.observe { [weak self] _ in self?.refreshLens() }
        if let webView = tab.webView { panel.makeFirstResponder(webView) }
        refreshLens()
    }

    private func makePanel() {
        guard panel == nil else { return }
        let panel = EdgeSidebarPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                     styleMask: [.borderless, .nonactivatingPanel],
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
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // A window of its own over another app: the material shows what is behind it, not its own window.
        card.showsDesktop = true
        card.radius = Tokens.Radius.large
        let overlay = PassthroughView(frame: card.bounds)
        overlay.autoresizingMask = [.width, .height]
        card.addSubview(overlay)
        panel.contentView = card
        self.panel = panel
        self.card = card
        self.overlay = overlay
        configureCaption()
    }

    // MARK: Caption

    private func configureCaption() {
        guard let card else { return }
        card.onLensBack = { [weak self] in self?.tab?.webView?.goBack() }
        card.onLensForward = { [weak self] in self?.tab?.webView?.goForward() }
        card.onLensReload = { [weak self] in
            guard let tab = self?.tab else { return }
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
        }
        card.onLensAddress = { [weak self] text in self?.navigate(to: text) }
        card.onLensSiteControls = { [weak self] button in self?.showSiteControls(from: button) }
    }

    private func refreshLens() {
        guard let tab else { return }
        if tab.isClosed {
            dismiss(.sameTab)
            return
        }
        controller?.updateEdgeSidebarForPeek(tab)
        card?.updateLens(address: tab.url?.absoluteString ?? "",
                         canGoBack: tab.webView?.canGoBack ?? false,
                         canGoForward: tab.webView?.canGoForward ?? false,
                         isLoading: tab.isLoading)
    }

    private func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        tab?.load(url)
    }

    /// Site Controls from the lens's caption: the page's own panel, over the lens, in the lens's window.
    private func showSiteControls(from button: IconButton) {
        guard let tab, let overlay, let panel else { return }
        if SitePanel.isOpen(in: panel) {
            SitePanel.closeCurrent()
            return
        }
        let host = EdgeSitePanelHost(tab: tab, overlay: overlay, window: panel)
        siteHost = host
        SitePanel.toggle(in: host, from: button)
    }

    /// The sidebar's address, clicked while the lens is out, types in the lens instead of bringing the browser.
    func focusAddress() {
        guard isVisible else { return }
        panel?.makeKey()
        card?.focusLensAddress()
    }

    /// The command bar or another of our popups has finished: the page takes the keyboard back.
    func makeKey() {
        guard isVisible else { return }
        panel?.makeKey()
        if let webView = tab?.webView { panel?.makeFirstResponder(webView) }
    }

    // MARK: Dismissing

    /// Ends the lens for `reason`, as the policy says. State goes first: the page is back in its tab before the card
    /// moves, the observers are gone, and no path here asks WebKit anything. The card then collapses to the preview;
    /// a deadline forces the panel out if the animation is interrupted. The sidebar follows only after that.
    func dismiss(_ reason: EdgeLensReason = .escape) {
        guard isVisible, !isCollapsing else { return }
        let controller = self.controller
        let tab = self.tab
        let origin = self.origin
        let originFrame = self.originFrame
        let panel = self.panel
        let card = self.card
        let hideSidebar = EdgeLensPolicy.hidesSidebar(after: reason,
                                                      pointerInEdgeZone: EdgeSidebar.shared.pointerInEdgeZone,
                                                      panelCanShow: EdgeSidebar.shared.canStayOut)
        isCollapsing = true
        EdgeSidebar.shared.holdForPeek(false)
        controller?.setEdgePeek(nil)
        if let tab, let holder = tab.pageHolder {
            holder.removeFromSuperview()
            if EdgePeekRestorePolicy.canRestore(isClosed: tab.isClosed, hasOrigin: origin != nil, reason: reason),
               let origin {
                holder.frame = originFrame
                origin.addSubview(holder)
                origin.needsLayout = true
            }
        }
        releaseLensObservers()
        if let panel, SitePanel.isOpen(in: panel) { SitePanel.closeCurrent() }
        siteHost = nil
        self.tab = nil
        self.controller = nil
        self.origin = nil
        // The collapse is the preview's picture, not the live page.
        card?.endLive()
        card?.showsLensControls = false
        panel?.makeFirstResponder(nil)
        panel?.ignoresMouseEvents = true
        guard let panel else {
            finishCollapse(hideSidebar: hideSidebar, reason: reason)
            return
        }
        let source = EdgePeekPreview.shared.currentFrame ?? sourceFrame ?? panel.frame
        sourceFrame = nil
        let duration = 0.22
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().setFrame(source, display: true)
        }
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isCollapsing else { return }
                self.finishCollapse(hideSidebar: hideSidebar, reason: reason)
            }
        }
        collapseDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: deadline)
    }

    private func finishCollapse(hideSidebar: Bool, reason: EdgeLensReason) {
        collapseDeadline?.cancel()
        collapseDeadline = nil
        isCollapsing = false
        isVisible = false
        card?.endLive()
        card?.showsLensControls = false
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = false
        if hideSidebar {
            EdgeSidebar.shared.hide(animated: true)
        } else if EdgeLensPolicy.keepsKey(after: reason), !EdgeSidebar.shared.isCommandBarOpen {
            // A lens action leaves the keyboard in the sidebar. A context change leaves it where the user put it.
            EdgeSidebar.shared.makeKey()
        }
    }

    // MARK: Context

    private func installLensObservers(for controller: BrowserWindowController) {
        if let window = controller.window {
            // The browser coming forward, or going away, ends the lens: it is not the browser's window.
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(.browserFront) }
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(.windowClose) }
            }
        }
        keyLostObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                  object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.focusChanged() } }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            if event.keyCode == 53 {
                // Our own pieces take their Esc first: the address's edit, the site panel, an open menu.
                if self.isEditingAddress || SitePanel.isOpen(in: self.panel) || MenuPanel.current != nil {
                    return event
                }
                self.dismiss(.escape)
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods == .command, let characters = event.charactersIgnoringModifiers?.lowercased() {
                switch characters {
                case "l":
                    self.focusAddress()
                    return nil
                case "r":
                    guard let tab = self.tab else { return nil }
                    if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
                    return nil
                default:
                    break
                }
            }
            return event
        }
        // A click outside, in this app or another, ends the lens. A click on the sidebar is a sidebar action: the
        // lens goes and the sidebar stays, in that one click.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, !self.isCollapsing, MenuPanel.current == nil else { return }
                let point = NSEvent.mouseLocation
                guard self.panel?.frame.contains(point) != true,
                      EdgeSidebar.shared.panelWindow?.frame.contains(point) != true else { return }
                self.dismiss(.outsideClick)
            }
        }
        outsideLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible, !self.isCollapsing else { return event }
            if MenuPanel.current != nil || RunLoop.current.currentMode == .eventTracking { return event }
            if event.window is EdgeCommandBarPopup || event.window is NSSavePanel || event.window?.sheetParent != nil {
                return event
            }
            if event.window === self.panel { return event }
            if event.window === EdgeSidebar.shared.panelWindow {
                // A row, New Tab or blank click is a sidebar action; the sidebar's own controls (back, reload, the
                // address) act on the lens and leave it open.
                if EdgeSidebar.shared.clickClosesLens(at: event.locationInWindow) {
                    self.dismiss(.sidebarClick)
                }
                return event
            }
            if event.window === self.controller?.window {
                self.dismiss(.browserFront)
                return event
            }
            self.dismiss(.outsideClick)
            return event
        }
        // Moving to another app or desktop is moving away. Becoming active is only leaving when the key is not ours.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, !self.isCollapsing else { return }
                    let key = NSApp.keyWindow
                    if key === self.panel || key === EdgeSidebar.shared.panelWindow || key is EdgeCommandBarPopup
                        || key is NSSavePanel || key?.sheetParent != nil { return }
                    self.dismiss(key === self.controller?.window ? .browserFront : .altTab)
                }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.spaceChange) }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The pid, not the application: the note is not sendable, and the main actor only needs to know whose it was.
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid != NSRunningApplication.current.processIdentifier else { return }
                self.dismiss(.altTab)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.spaceChange) }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: EdgeSidebar.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !EdgeSidebar.isOn else { return }
                self.dismiss(.featureOff)
            }
        }
    }

    private var isEditingAddress: Bool {
        guard let field = card?.lensAddress, let editor = field.currentEditor() else { return false }
        return panel?.firstResponder === editor
    }

    /// A space change or the page's tab changing under the lens: both end it rather than leave a page with no row to
    /// come from or go back to.
    private func managerChanged(_ change: TabManager.Change) {
        guard isVisible, !isCollapsing else { return }
        switch change {
        case .space:
            if EdgePeekRouting.closesOnSpaceChange(peekVisible: isVisible) { dismiss(.spaceChange) }
        case .structure:
            if tab?.isClosed == true { dismiss(.sameTab) }
        case .selection:
            if tab?.isClosed == true {
                dismiss(.selection)
                return
            }
            if let tab, let selected = controller?.tabManager.selectedTab, selected !== tab {
                // A page opened from the lens is a replacement, not a selection away from it: the show that follows
                // swaps the page in. Anything else is leaving the lens, and the page must not be put back over the
                // card that now owns its place.
                if EdgePeekRouting.selectionKeepsLens(lensTab: tab, selected: selected) { return }
                dismiss(.selection)
            }
        case .content:
            break
        }
    }

    /// The lens is no longer the key window: keep it only for the sidebar or our own menus and sheets.
    private func focusChanged() {
        guard isVisible, !isCollapsing else { return }
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
        dismiss(key === controller?.window ? .browserFront : .altTab)
    }

    private func releaseLensObservers() {
        token = nil
        managerObserver = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        if let outsideLocal { NSEvent.removeMonitor(outsideLocal) }
        outsideLocal = nil
        for observer in [keyObserver, closeObserver, keyLostObserver, activationObserver, screenObserver, settingsObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        keyObserver = nil
        closeObserver = nil
        keyLostObserver = nil
        activationObserver = nil
        screenObserver = nil
        settingsObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
    }
}

import AppKit
import WebKit

/// One browser window: its tabs, its sidebar, its page card, and everything floating above them.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let tabManager: TabManager
    let sidebar = SidebarView()
    let root: BrowserRootView
    var browserWindow: BrowserWindow { window as! BrowserWindow }

    private var tokens: [SignalToken] = []
    private var selectedTabToken: SignalToken?
    private weak var shownTab: Tab?
    private var fadeTimer: Timer?
    var onClose: ((BrowserWindowController) -> Void)?
    var onStateChange: (() -> Void)?

    lazy var commandBar = CommandBarController(window: self)
    lazy var findBar = FindBarController(window: self)
    lazy var desk = DeskController(window: self)
    lazy var previews = TabPreviewController(controller: self)
    lazy var switcher = TabSwitcher(controller: self)
    /// ⌘Z for sidebar actions; also the window's undo manager, so page text editing shares it.
    let sidebarUndo = UndoManager()
    lazy var linkStatus = LinkStatusController(overlay: root.overlay)
    lazy var peek = PeekController(controller: self)
    var peekController: PeekController? { peek }

    init(tabManager: TabManager, frame: NSRect?, sidebarVisible: Bool = true, sidebarWidth: CGFloat = Tokens.Metric.sidebarWidth) {
        self.tabManager = tabManager
        root = BrowserRootView(sidebar: sidebar)
        let rect = frame ?? BrowserWindowController.defaultFrame()
        let window = BrowserWindow(contentRect: rect)
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.setFrame(rect, display: false)
        root.sidebarVisible = sidebarVisible
        root.sidebarWidth = sidebarWidth
        root.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.layoutTrafficLights()
            self.commandBar.reposition()
            self.findBar.reposition()
            self.peek.reposition()
        }
        root.onSidebarWidthChange = { [weak self] _ in self?.onStateChange?() }
        root.onSlide = { [weak self] duration in self?.sidebarSliding(duration) }

        sidebar.delegate = self
        sidebar.onEditSpace = { [weak self] id in self?.openSpaceEditor(id) }
        sidebar.onSwipeSpace = { [weak self] offset in
            guard let self else { return false }
            let before = self.tabManager.currentSpaceID
            self.tabManager.switchSpace(by: offset)
            return before != self.tabManager.currentSpaceID
        }
        sidebar.backButton.onClick = { [weak self] _ in self?.goBack(nil) }
        sidebar.sidebarButton.onClick = { [weak self] _ in self?.toggleBrowserSidebar(nil) }
        sidebar.forwardButton.onClick = { [weak self] _ in self?.goForward(nil) }
        sidebar.address.captureButton.onClick = { [weak self] _ in
            guard let self, let tab = self.tabManager.selectedTab, let host = tab.url?.host() else { return }
            let menu = NSMenu()
            menu.addItem(SidebarMenus.Item("Stop Camera and Microphone") { tab.stopCapture() })
            menu.addItem(SidebarMenus.Item("Ask Again Next Time") { SitePermissions.forget(host: host) })
            let button = self.sidebar.address.captureButton
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        sidebar.nowPlaying.onClick = { [weak self] _ in
            if let tab = self?.nowPlayingTab { self?.tabManager.select(tab) }
        }
        sidebar.nowPlaying.playButton.onClick = { [weak self] _ in
            guard let tab = self?.nowPlayingTab else { return }
            tab.setPlaybackPaused(!tab.isPlaybackPaused)
        }
        sidebar.nowPlaying.muteButton.onClick = { [weak self] _ in
            guard let tab = self?.nowPlayingTab else { return }
            tab.setMuted(!tab.isMuted)
        }
        sidebar.reloadButton.onClick = { [weak self] _ in
            guard let tab = self?.tabManager.selectedTab else { return }
            tab.isLoading ? tab.stopLoading() : tab.reload()
        }

        tabManager.host = self
        tokens.append(tabManager.changed.observe { [weak self] change in self?.tabManagerChanged(change) })
        tokens.append(Library.shared.changed.observe { [weak self] in self?.libraryChanged() })
        tokens.append(DownloadManager.shared.changed.observe { [weak self] _ in self?.downloadsChanged() })
        if #available(macOS 15.4, *) {
            tokens.append(ExtensionHost.shared.changed.observe { [weak self] in self?.refreshExtensionActions() })
        }

        // Fading is slow; checking once a minute is plenty.
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebar.list.refreshRows() }
        }

        if tabManager.isPrivate {
            // Private windows are always dark and say so, so you never wonder which one you're in.
            window.appearance = NSAppearance(named: .darkAqua)
            sidebar.list.privateLabel = true
        }
        applySpaceColor(animated: false)
        sidebar.reloadSpaces(current: tabManager.currentSpaceID)
        sidebar.currentSpaceID = tabManager.currentSpaceID
        sidebar.list.reload(animated: false)
        showSelectedTab()
        downloadsChanged()
        window.eventInterceptor = { [weak self] event in self?.intercept(event) ?? false }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(Tokens.Metric.windowDefaultSize.width, screen.width - Tokens.Space.x16),
                          height: min(Tokens.Metric.windowDefaultSize.height, screen.height - Tokens.Space.x16))
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Model changes

    private func tabManagerChanged(_ change: TabManager.Change) {
        switch change {
        case .structure:
            sidebar.list.reload(animated: window?.isVisible == true)
        case .selection:
            showSelectedTab()
        case .space:
            spaceChanged()
        case .content:
            updateNowPlaying()
        }
        onStateChange?()
    }

    private var lastSpaceID: UUID?

    private func spaceChanged() {
        let spaces = Library.shared.spaces
        let oldIndex = lastSpaceID.flatMap { id in spaces.firstIndex { $0.id == id } } ?? 0
        let newIndex = spaces.firstIndex { $0.id == tabManager.currentSpaceID } ?? 0
        let snapshot = sidebar.listSnapshot()
        lastSpaceID = tabManager.currentSpaceID
        sidebar.currentSpaceID = tabManager.currentSpaceID
        applySpaceColor(animated: true)
        sidebar.reloadSpaces(current: tabManager.currentSpaceID)
        sidebar.transitionList(direction: CGFloat((newIndex - oldIndex).signum()), from: snapshot)
    }

    private func libraryChanged() {
        applySpaceColor(animated: true)
        sidebar.reloadSpaces(current: tabManager.currentSpaceID)
        sidebar.list.reload(animated: true)
    }

    /// Live preview while dragging the hue slider: recolors without saving.
    func previewSpaceColor(background: NSColor, swatch: NSColor, for spaceID: UUID) {
        if spaceID == tabManager.currentSpaceID {
            root.setColor(background, animated: false)
            root.sidebarContainer.tint = background
        }
        sidebar.previewDotColor(swatch, for: spaceID)
    }

    /// Opens the editor for a space next to the sidebar, aligned with the row that asked.
    func openSpaceEditor(_ spaceID: UUID, anchor: NSView? = nil) {
        // The editor always rises from the space dots, whichever control opened it.
        if !root.sidebarVisible && !root.isSidebarFloatingVisible { root.reveal(true) }
        let dots = sidebar.dotsAnchor
        let rect = dots.convert(dots.bounds, to: root.overlay)
        SpaceEditorPanel.open(spaceID: spaceID, above: rect, sidebarFrame: root.sidebarContainer.frame, in: self)
    }

    private func applySpaceColor(animated: Bool) {
        lastSpaceID = tabManager.currentSpaceID
        let color = tabManager.isPrivate ? SpaceColor.graphite.background : tabManager.currentSpace.background
        root.setColor(color, animated: animated && !Tokens.Motion.isKeyboardDriven)
        root.sidebarContainer.tint = color
    }

    private func showSelectedTab() {
        previews.hide()
        let tab = tabManager.selectedTab
        if tab != nil { dismissWelcome() }
        if tab !== shownTab {
            shownTab = tab
            selectedTabToken = tab?.changed.observe { [weak self] change in self?.selectedTabChanged(change) }
            let webView = tab?.ensureWebView()
            root.card.show(webView, placeholderImage: nil)
            if let webView, window?.isKeyWindow == true, !commandBar.isVisible {
                window?.makeFirstResponder(webView)
            }
        }
        sidebar.update(tab: tab)
        sidebar.list.refreshRows()
        sidebar.address.setCapture(camera: tab?.isUsingCamera ?? false, microphone: tab?.isUsingMicrophone ?? false)
        updateWindowTitle()
        refreshExtensionActions()
        updateNowPlaying()
    }

    private weak var nowPlayingTab: Tab?

    /// The control shows the most recent tab making sound (or paused by it) that you aren't looking at.
    private func updateNowPlaying() {
        let selected = tabManager.selectedTab
        let candidates = tabManager.recentTabs.filter { ($0.isPlayingAudio || $0.isPlaybackPaused) && $0 !== selected }
        let tab = candidates.first
        nowPlayingTab = tab
        sidebar.setNowPlaying(tab, paused: tab?.isPlaybackPaused ?? false)
    }

    func refreshExtensionActions() {
        guard #available(macOS 15.4, *) else { return }
        let tab = tabManager.selectedTab
        let items = ExtensionHost.shared.actions(for: tab).map { item in
            (image: item.icon, label: item.label, action: { (anchor: NSView) in
                ExtensionHost.shared.performAction(item, tab: tab, anchor: anchor)
            })
        }
        sidebar.address.setActions(items)
    }

    private func selectedTabChanged(_ change: Tab.Change) {
        guard let tab = shownTab else { return }
        switch change {
        case .url, .navigation, .loading:
            sidebar.update(tab: tab)
            updateWindowTitle()
        case .title:
            updateWindowTitle()
        case .webView:
            if let webView = tab.webView, root.card.webView !== webView { root.card.show(webView) }
        case .capture:
            sidebar.address.setCapture(camera: tab.isUsingCamera, microphone: tab.isUsingMicrophone)
        default:
            break
        }
    }

    private func updateWindowTitle() {
        let tab = tabManager.selectedTab
        window?.title = tab?.displayTitle ?? "Zigzag"
        // Lets accessibility clients (1Password, Raycast, Shortcuts) know which page is showing.
        window?.representedURL = nil
        window?.setAccessibilityDocument(tab?.url?.absoluteString)
    }

    private func downloadsChanged() {
        let manager = DownloadManager.shared
        sidebar.updateDownloads(active: manager.activeCount, hasAny: !manager.items.isEmpty)
    }

    // MARK: Traffic lights

    private var trafficLightsPicture: NSImage?
    /// Until this moment the sidebar is visually sliding, and the real traffic lights stay hidden.
    private var slideEndsAt = Date.distantPast
    private var isSliding: Bool { Date() < slideEndsAt }

    /// While the sidebar slides, the real buttons hide and their picture moves with the sidebar.
    /// Visibility is recomputed from the clock, so nothing can leave the buttons stuck hidden.
    private func sidebarSliding(_ duration: TimeInterval) {
        if !browserWindow.trafficLightsHidden, let image = browserWindow.trafficLightsImage() { trafficLightsPicture = image }
        guard duration > 0 else { slideEndsAt = .distantPast; layoutTrafficLights(); return }
        slideEndsAt = Date().addingTimeInterval(duration)
        layoutTrafficLights()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { [weak self] in self?.layoutTrafficLights() }
    }

    private func layoutTrafficLights() {
        let window = browserWindow
        let floating = root.isSidebarFloatingVisible
        let docked = root.sidebarVisible
        let sliding = isSliding
        // The picture shows only mid-slide, and only when the sidebar is (or is becoming) visible.
        sidebar.showTrafficLightsPicture(sliding ? trafficLightsPicture : nil)
        window.trafficLightsHidden = sliding || !(docked || floating)
        let container = root.sidebarContainer.frame
        let lightHeight = window.trafficLightHeight
        let x = (docked ? 0 : container.minX) + Tokens.Metric.sidebarPadding + Tokens.Space.x2
        let y = (docked ? 0 : container.minY) + sidebar.trafficLightCenterY - lightHeight / 2
        window.trafficLightOrigin = NSPoint(x: x, y: y)
        if !sliding, docked || floating, let image = window.trafficLightsImage() { trafficLightsPicture = image }
        sidebar.trafficLightsWidth = window.trafficLightsWidth
        sidebar.sidebarButton.toolTip = docked ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)"
        sidebar.sidebarButton.isSelected = false
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights(); onStateChange?() }
    func windowDidMove(_ notification: Notification) { onStateChange?() }
    func windowDidEndLiveResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) {
        layoutTrafficLights()
        WindowManager.shared.windowBecameKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        fadeTimer?.invalidate()
        onClose?(self)
    }

    // MARK: Opening pages

    /// Opens a URL the way the user asked, switching to an existing tab when the page is already open.
    func open(_ url: URL, disposition: OpenDisposition = .foregroundTab, opener: Tab? = nil, allowSwitch: Bool = true) {
        if allowSwitch, disposition == .foregroundTab, let existing = tabManager.existingTab(for: url) {
            tabManager.select(existing)
            return
        }
        switch disposition {
        case .currentTab:
            if let tab = tabManager.selectedTab { tab.load(url) } else { tabManager.newTab(url: url) }
        case .foregroundTab:
            tabManager.newTab(url: url, opener: opener)
        case .backgroundTab:
            tabManager.newTab(url: url, select: false, opener: opener)
        case .peek:
            showPeek(url: url, configuration: nil)
        case .newWindow:
            WindowManager.shared.newWindow(url: url)
        }
    }

    @discardableResult
    func showPeek(url: URL?, configuration: WKWebViewConfiguration?) -> WKWebView? {
        commandBar.dismiss(restoringFocus: false)
        return peek.show(url: url, configuration: configuration, opener: tabManager.selectedTab)
    }

    private var welcome: WelcomeView?

    /// First launch on a Mac with Arc: offer the one-step import inside the empty page.
    func showWelcome() {
        let view = WelcomeView()
        view.frame = root.card.bounds
        view.autoresizingMask = [.width, .height]
        root.card.addSubview(view)
        welcome = view
        view.onImport = { [weak self] in
            self?.dismissWelcome()
            ArcImporter.runInteractive()
        }
        view.onSkip = { [weak self] in
            UserDefaults.standard.set(true, forKey: "ArcOfferDismissed")
            self?.dismissWelcome()
            self?.commandBar.show(mode: .newTab)
        }
    }

    private func dismissWelcome() {
        guard let welcome else { return }
        self.welcome = nil
        Tokens.Motion.animate(Tokens.Motion.feedback, { welcome.animator().alphaValue = 0 }, completion: { welcome.removeFromSuperview() })
    }

    private func sidebarContains(_ event: NSEvent) -> Bool {
        let container = root.sidebarContainer
        guard root.sidebarVisible || root.isSidebarFloatingVisible else { return false }
        return container.bounds.contains(container.convert(event.locationInWindow, from: nil))
    }

    /// Closes peek, find, previews: whatever floats above the page. Returns true if something closed.
    func dismissFloatingContent() -> Bool {
        if peek.isVisible { peek.close(); return true }
        if findBar.isVisible { findBar.hide(); return true }
        return false
    }

    // MARK: Event interception

    private func intercept(_ event: NSEvent) -> Bool {
        if (event.type == .keyDown || event.type == .flagsChanged), switcher.handle(event) { return true }
        #if DEBUG
        if event.type == .scrollWheel, sidebarContains(event) { DebugBridge.recordScroll(event) }
        #endif
        if event.type == .scrollWheel, !desk.isVisible, sidebarContains(event), sidebar.handleSwipe(event) { return true }
        if event.type == .magnify || event.type == .gesture, desk.handleMagnify(event) { return true }
        if event.type == .keyDown, #available(macOS 15.4, *), !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           ExtensionHost.shared.performCommand(for: event) {
            return true
        }
        return false
    }
}

// MARK: - TabHost

extension BrowserWindowController: TabHost {
    var hostWindow: NSWindow? { window }

    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition) {
        // Inside peek, another peek just navigates the card.
        if tab.isPeek, disposition == .peek { tab.load(url); return }
        // A result opened from a search page keeps the search one Back away.
        if disposition == .backgroundTab || disposition == .foregroundTab, let current = tab.url, SearchFolding.isSearchResultsPage(current),
           let history = tab.interactionStateForSaving {
            let newTab = tabManager.newTab(url: nil, select: disposition == .foregroundTab, opener: tab, title: url.host())
            newTab.restoreHistory(history, thenLoad: url)
            return
        }
        open(url, disposition: disposition, opener: tab, allowSwitch: false)
    }

    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView? {
        if let pending = BrowserWebView.pendingDisposition {
            BrowserWebView.pendingDisposition = nil
            if pending == .peek { return showPeek(url: nil, configuration: configuration) }
            let newTab = tabManager.newTab(url: action.request.url, select: false, configuration: configuration, opener: tab)
            return newTab.ensureWebView()
        }
        // Peeked pages open their links in the card itself.
        if tab.isPeek, features.width == nil, features.height == nil, let url = action.request.url {
            tab.load(url)
            return nil
        }
        // Search folding: a result that wants a new tab replaces the search instead, so Back returns to it.
        if action.navigationType == .linkActivated, action.modifierFlags.intersection([.command, .shift, .option]).isEmpty,
           features.width == nil, features.height == nil,
           let current = tab.url, SearchFolding.isSearchResultsPage(current), let url = action.request.url {
            tab.load(url)
            return nil
        }
        // Sized window.open() calls are sign-in and payment popups: give them a real small window.
        if features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false {
            return PopupWindowController.open(configuration: configuration, features: features, parent: window)
        }
        let flags = action.modifierFlags
        let background = flags.contains(.command) && !flags.contains(.shift)
        let newTab = tabManager.newTab(url: action.request.url, select: !background, configuration: configuration, opener: tab)
        return newTab.ensureWebView()
    }

    func tabDidRequestClose(_ tab: Tab) {
        tabManager.close(tab)
    }

    func tabDidChangeFullscreen(_ tab: Tab, isFullscreen: Bool) {}

    func tab(_ tab: Tab, hoveringLink url: URL?) {
        guard tab === tabManager.selectedTab || tab.isPeek else { return }
        linkStatus.show(url, in: tab.isPeek ? peek.contentFrame : root.cardFrame)
    }
}

// MARK: - SidebarDelegate

extension BrowserWindowController: SidebarDelegate {
    func listSelect(_ tab: Tab) { tabManager.select(tab) }
    func listOpenBookmark(_ bookmark: Bookmark) { tabManager.openBookmark(bookmark) }
    func listClose(_ tab: Tab) { closeWithUndo(tab) }

    // MARK: Undo (⌘Z) for sidebar actions

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { sidebarUndo }

    /// Closes a tab; ⌘Z brings it back with its history, ⇧⌘Z closes it again.
    func closeWithUndo(_ tab: Tab) {
        let wasBookmark = tab.bookmarkID != nil
        tabManager.close(tab)
        guard !wasBookmark else { return }
        sidebarUndo.registerUndo(withTarget: self) { controller in
            guard let reopened = controller.tabManager.reopenClosedTab() else { return }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.closeWithUndo(reopened) }
            controller.sidebarUndo.setActionName("Close Tab")
        }
        sidebarUndo.setActionName("Close Tab")
    }

    /// Moves a tab within or between spaces, undoably.
    func moveWithUndo(_ tab: Tab, to index: Int, in spaceID: UUID) {
        let oldSpace = tab.spaceID
        let oldIndex = tabManager.tabs(in: oldSpace).firstIndex { $0 === tab } ?? 0
        if spaceID == oldSpace { tabManager.move(tab, to: index) } else { tabManager.moveTabToSpace(tab, spaceID: spaceID) }
        sidebarUndo.registerUndo(withTarget: self) { $0.moveWithUndo(tab, to: oldIndex, in: oldSpace) }
        sidebarUndo.setActionName(spaceID == oldSpace ? "Move Tab" : "Move to Space")
    }

    /// Turns a tab into a bookmark, undoably.
    func bookmarkWithUndo(_ tab: Tab, at index: Int?, in spaceID: UUID) {
        let oldIndex = tabManager.tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0
        tabManager.bookmarkTab(tab, at: index, in: spaceID)
        guard let bookmarkID = tab.bookmarkID else { return }
        sidebarUndo.registerUndo(withTarget: self) { $0.unbookmarkWithUndo(bookmarkID, to: oldIndex) }
        sidebarUndo.setActionName("Bookmark")
    }

    /// Turns a bookmark back into a tab, undoably.
    func unbookmarkWithUndo(_ bookmarkID: UUID, to index: Int?) {
        let spaceID = Library.shared.spaceID(ofBookmark: bookmarkID) ?? tabManager.currentSpaceID
        let oldIndex = Library.shared.bookmarks(in: spaceID).firstIndex { $0.id == bookmarkID }
        let liveTab = tabManager.bookmarkTab(for: bookmarkID)
        tabManager.unbookmark(bookmarkID, toIndex: index)
        if let liveTab {
            sidebarUndo.registerUndo(withTarget: self) { $0.bookmarkWithUndo(liveTab, at: oldIndex, in: spaceID) }
            sidebarUndo.setActionName("Remove Bookmark")
        }
    }
    func listNewTab() { commandBar.show(mode: .newTab) }
    func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {
        previews.hover(tab, row: row, bookmark: bookmark)
    }
    func listRenameSpace() { renameSpace(nil) }
    func listEditSpace(anchor: NSView) { openSpaceEditor(tabManager.currentSpaceID, anchor: anchor) }
    func listDragHoverSpace(at windowPoint: NSPoint) -> UUID? { sidebar.spaceDot(at: windowPoint) }
    func listDragEnded() { sidebar.clearDropTargets() }
    func listMove(_ tab: Tab, to index: Int, in spaceID: UUID) { moveWithUndo(tab, to: index, in: spaceID) }
    func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID) { bookmarkWithUndo(tab, at: index, in: spaceID) }
    func listUnbookmark(_ bookmarkID: UUID, to index: Int) { unbookmarkWithUndo(bookmarkID, to: index) }

    func listMenu(for item: SidebarItem) -> NSMenu? {
        switch item {
        case .header: return sidebarSpaceMenu(for: tabManager.currentSpaceID)
        case .tab(let id): return tabManager.tab(with: id).map { SidebarMenus.tabMenu(for: $0, controller: self) }
        case .bookmark(let id): return Library.shared.bookmark(id).map { SidebarMenus.bookmarkMenu(for: $0, controller: self) }
        default: return nil
        }
    }

    func sidebarOpenCommandBar() { commandBar.show(mode: .editCurrent) }
    func sidebarSwitchSpace(_ id: UUID) { tabManager.switchToSpace(id) }
    func sidebarNewSpace() { newSpace(nil) }
    func sidebarShowDownloads(from view: NSView) { DownloadsPanel.show(from: view, in: self) }
    func sidebarSpaceMenu(for id: UUID) -> NSMenu? { SidebarMenus.spaceMenu(for: id, controller: self) }
}

// MARK: - Debug hooks

extension BrowserWindowController {
    func debugHover(index: Int) {
        let tabs = tabManager.currentTabs
        guard tabs.indices.contains(index), let row = sidebar.list.row(for: tabs[index]) else { return }
        previews.hover(tabs[index], row: row, bookmark: nil)
    }
    func debugSwitcher() {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                    context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        _ = switcher.handle(down)
    }
}

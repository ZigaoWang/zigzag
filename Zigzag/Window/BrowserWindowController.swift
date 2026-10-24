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
        root.onSplitRatioChange = { [weak self] ratio, final in
            guard let self, final, let tab = self.tabManager.selectedTab else { return }
            self.tabManager.setSplitRatio(Double(ratio), for: tab)
            self.onStateChange?()
        }

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
        sidebar.address.onRightClick = { [weak self] _ in self?.siteMenu() }
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

        UndoClock.start()
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
        sidebar.favorites.onOpen = { [weak self] favorite in self?.tabManager.openBookmark(favorite) }
        sidebar.favorites.onMenu = { [weak self] favorite in
            guard let self else { return nil }
            return SidebarMenus.favoriteMenu(for: favorite, controller: self)
        }
        sidebar.favorites.onDragMove = { [weak self] _, point in
            guard let self else { return }
            self.sidebar.list.externalHover(at: self.isOverList(point) ? point : nil)
        }
        sidebar.favorites.onDrop = { [weak self] favorite, point in
            guard let self else { return false }
            let overList = self.isOverList(point)
            let index = self.sidebar.list.dropIndex(at: point)
            self.sidebar.list.externalHover(at: nil)
            guard overList else { return false }
            // Dragged down into the list: it's a regular tab again, right where it was dropped.
            self.unfavoriteWithUndo(favorite.id, to: index)
            return true
        }
        sidebar.favorites.onReorder = { [weak self] favorite, index in
            self?.libraryChange("Move Favorite") { Library.shared.moveFavorite(favorite.id, to: index) }
        }
        reloadFavorites()
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

    private func isOverList(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let list = sidebar.list.enclosingScrollView ?? sidebar.list
        return list.convert(list.bounds, to: nil).contains(window.convertPoint(fromScreen: screenPoint))
    }

    private func reloadFavorites() {
        let favorites = Library.shared.favorites
        let open = Set(favorites.map(\.id).filter { tabManager.bookmarkTab(for: $0) != nil })
        sidebar.favorites.reload(favorites: favorites, openIDs: open, selectedID: tabManager.selectedTab?.isFavorite == true ? tabManager.selectedTab?.bookmarkID : nil)
        sidebar.needsLayout = true
    }

    private func libraryChanged() {
        reloadFavorites()
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

    /// Opens the space panel beside the sidebar (or closes it, if it's already showing that space).
    func openSpaceEditor(_ spaceID: UUID, anchor: NSView? = nil) {
        if !root.sidebarVisible && !root.isSidebarFloatingVisible { root.reveal(true) }
        previews.hide()
        SpaceEditorPanel.toggle(spaceID: spaceID, in: self)
    }

    private func applySpaceColor(animated: Bool) {
        lastSpaceID = tabManager.currentSpaceID
        if !tabManager.isPrivate {
            switch tabManager.currentSpace.appearance {
            case "light": window?.appearance = NSAppearance(named: .aqua)
            case "dark": window?.appearance = NSAppearance(named: .darkAqua)
            default: window?.appearance = nil
            }
        }
        let color = tabManager.isPrivate ? SpaceColor.graphite.background : tabManager.currentSpace.background
        root.setColor(color, animated: animated)
        root.sidebarContainer.tint = color
    }

    private func showSelectedTab() {
        previews.hide()
        let tab = tabManager.selectedTab
        if tab != nil { dismissWelcome() }
        if tab !== shownTab {
            shownTab = tab
            selectedTabToken = tab?.changed.observe { [weak self] change in self?.selectedTabChanged(change) }
            if let webView = tab?.ensureWebView(), window?.isKeyWindow == true, !commandBar.isVisible {
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(webView) }
            }
        }
        showPages()
        sidebar.update(tab: tab)
        sidebar.list.refreshRows()
        reloadFavorites()
        sidebar.address.setCapture(camera: tab?.isUsingCamera ?? false, microphone: tab?.isUsingMicrophone ?? false)
        updateWindowTitle()
        refreshExtensionActions()
        updateNowPlaying()
        offerWebStoreExtension()
    }

    /// Where an extension may read and change pages, Chrome's three choices.
    private func siteAccessItem(for id: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Site Access", action: nil, keyEquivalent: "")
        item.image = Tokens.Symbol.image("globe")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let access = ExtensionStore.siteAccess(id)
        let tab = tabManager.selectedTab
        let site = ContentBlocker.site(of: tab?.url)
        let all = SidebarMenus.Item("On All Sites") { ExtensionStore.setSiteAccess(id, .all); tab?.reload() }
        all.state = access == .all ? .on : .off
        let click = SidebarMenus.Item("When You Click It") { ExtensionStore.setSiteAccess(id, .click, sites: []); tab?.reload() }
        click.state = access == .click ? .on : .off
        menu.addItem(all)
        menu.addItem(click)
        if let site {
            let sites = access == .sites ? ExtensionStore.accessSites(id) : []
            let listed = sites.contains(site)
            let only = SidebarMenus.Item(access == .sites ? "On \(site)" : "Only on \(site)") {
                let next = listed ? sites.filter { $0 != site } : sites + [site]
                ExtensionStore.setSiteAccess(id, .sites, sites: next)
                tab?.reload()
            }
            only.state = listed ? .on : .off
            menu.addItem(.separator())
            menu.addItem(only)
            if access == .sites {
                for other in sites where other != site {
                    let entry = SidebarMenus.Item("On \(other)") { ExtensionStore.setSiteAccess(id, .sites, sites: sites.filter { $0 != other }) }
                    entry.state = .on
                    menu.addItem(entry)
                }
            }
        }
        item.submenu = menu
        return item
    }

    /// What you can change for the site you're on: right-click the address.
    private func siteMenu() -> NSMenu? {
        guard let tab = tabManager.selectedTab, let url = tab.url, let site = ContentBlocker.site(of: url),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: site, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if ContentBlocker.isEnabled {
            let allowed = ContentBlocker.isAllowed(on: url)
            let item = SidebarMenus.Item(allowed ? "Block Ads on This Site" : "Allow Ads on This Site", symbol: allowed ? "hand.raised" : "hand.raised.slash") {
                ContentBlocker.setAllowed(!allowed, on: url)
                tab.reload()
            }
            menu.addItem(item)
        } else {
            menu.addItem(SidebarMenus.Item("Ad Blocking Is Off…", symbol: "hand.raised.slash") { SettingsWindowController.shared.show() })
        }
        if #available(macOS 15.4, *), !ExtensionHost.shared.contexts.isEmpty {
            let off = ExtensionStore.extensionsOffSites.contains(site)
            let item = SidebarMenus.Item("Turn Off Extensions on This Site", symbol: "puzzlepiece.extension") {
                var sites = ExtensionStore.extensionsOffSites
                if off { sites.remove(site) } else { sites.insert(site) }
                ExtensionStore.extensionsOffSites = sites
                tab.reload()
            }
            item.state = off ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(SidebarMenus.Item("Copy Link", symbol: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
        return menu
    }

    private var offeredExtensionID: String?

    /// On an extension's Chrome Web Store page, offers to add it to Zigzag (the store's own button only works in Chrome).
    private func offerWebStoreExtension() {
        guard #available(macOS 15.4, *) else { return }
        let id = ExtensionStore.webStoreID(from: tabManager.selectedTab?.url)
        guard id != offeredExtensionID else { return }
        if offeredExtensionID != nil { Toast.hide(in: self) }
        offeredExtensionID = id
        guard let id, !ExtensionStore.isInstalled(id) else { return }
        Toast.show("Use this extension in Zigzag", symbol: "puzzlepiece.extension", action: (title: "Add to Zigzag", run: { [weak self] in
            self?.installExtension(id)
        }), duration: 3600, in: self)
    }

    /// Adding from the store: verify the package, show what it can do, install only once confirmed.
    func installExtension(_ id: String) {
        guard #available(macOS 15.4, *) else { return }
        Toast.show("Checking extension…", symbol: "arrow.down.circle", duration: 3600, in: self)
        Task { [weak self] in
            let result = await ExtensionStore.prepareInstall(id)
            guard let self else { return }
            switch result {
            case .failure(let error):
                Toast.show(error.message, symbol: "exclamationmark.triangle", duration: 4, in: self)
            case .success(let prepared):
                Toast.hide(in: self)
                let info = prepared.extensionInfo
                let content = ExtensionSheet.Content(
                    icon: info.icon(for: NSSize(width: 40, height: 40)),
                    title: "Add \(info.displayName ?? "this extension")?",
                    subtitle: "Chrome Web Store · Version \(prepared.version)",
                    heading: "It will be able to",
                    report: prepared.report,
                    confirm: "Add Extension", cancel: "Cancel")
                ExtensionSheet.present(content, in: self, onConfirm: { [weak self] in
                    Task { [weak self] in
                        let installed = await ExtensionStore.finishInstall(prepared)
                        guard let self else { return }
                        switch installed {
                        case .success(let name): Toast.show("Added \(name)", symbol: "checkmark.circle", duration: 2, in: self)
                        case .failure(let error): Toast.show(error.message, symbol: "exclamationmark.triangle", duration: 4, in: self)
                        }
                    }
                }, onCancel: { ExtensionStore.discard(prepared) })
            }
        }
    }

    /// An update that wants more access waits for this.
    func reviewExtensionUpdate(_ id: String) {
        guard #available(macOS 15.4, *) else { return }
        Task { [weak self] in
            guard let (info, report) = await ExtensionStore.pendingUpdateReport(id), let self else { return }
            let name = info.displayName ?? "This extension"
            let content = ExtensionSheet.Content(
                icon: info.icon(for: NSSize(width: 40, height: 40)),
                title: "\(name) wants more access",
                subtitle: "Version \(info.version ?? "") is ready. Until you allow it, the current version keeps running.",
                heading: "It would also be able to",
                report: report,
                confirm: "Allow and Update", cancel: "Not Now")
            ExtensionSheet.present(content, in: self, onConfirm: {
                Task { await ExtensionStore.approvePendingUpdate(id) }
            })
        }
    }

    private weak var nowPlayingTab: Tab?

    /// Puts the selected tab in the page card, or both halves of its split side by side.
    private func showPages() {
        let tab = tabManager.selectedTab
        if let tab, let pair = tabManager.split(for: tab),
           let left = tabManager.tab(with: pair.left), let right = tabManager.tab(with: pair.right) {
            root.setSplit(ratio: CGFloat(pair.ratio), vertical: pair.vertical, animated: true)
            for card in [root.card, root.secondCard] {
                card.header.setVertical(pair.vertical)
                card.header.orientation.onClick = { [weak self] _ in self?.tabManager.toggleSplitOrientation(for: left) }
            }
            root.card.show(left.ensureWebView())
            root.secondCard.show(right.ensureWebView())
            root.card.isFocusedPane = left === tab
            root.secondCard.isFocusedPane = right === tab
            root.card.showsHeader = true
            root.secondCard.showsHeader = true
            root.card.header.show(left)
            root.secondCard.header.show(right)
            root.card.header.close.onClick = { [weak self] _ in self?.unsplitWithUndo(left, keep: right) }
            root.secondCard.header.close.onClick = { [weak self] _ in self?.unsplitWithUndo(right, keep: left) }
        } else {
            root.setSplit(ratio: nil, vertical: false, animated: true)
            root.card.show(tab?.ensureWebView())
            root.secondCard.show(nil)
            root.card.isFocusedPane = false
            root.secondCard.isFocusedPane = false
            root.card.showsHeader = false
            root.secondCard.showsHeader = false
        }
    }

    /// In split view, clicking a pane makes its tab the one you're working in.
    func focusPane(at windowPoint: NSPoint) {
        guard let tab = tabManager.selectedTab, let partner = tabManager.partner(of: tab), let pair = tabManager.split(for: tab) else { return }
        let panes = root.paneFrames
        let point = root.convert(windowPoint, from: nil)
        let clickedLeft = panes.left.contains(point)
        let clickedRight = panes.right?.contains(point) ?? false
        guard clickedLeft || clickedRight else { return }
        let clickedID = clickedLeft ? pair.left : pair.right
        if clickedID == partner.id { tabManager.select(partner) }
    }

    /// The control shows the most recent tab making sound (or paused by it) that you aren't looking at.
    private func updateNowPlaying() {
        let selected = tabManager.selectedTab
        let candidates = tabManager.recentTabs.filter { ($0.isPlayingAudio || $0.isPlaybackPaused) && $0 !== selected }
        let tab = candidates.first
        nowPlayingTab = tab
        sidebar.setNowPlaying(tab, paused: tab?.isPlaybackPaused ?? false)
    }

    /// Pinned extensions show as buttons by the address (two at most, so the address stays readable);
    /// the rest wait behind one button.
    func refreshExtensionActions() {
        guard #available(macOS 15.4, *) else { return }
        let tab = tabManager.selectedTab
        let all = ExtensionHost.shared.actions(for: tab)
        let pinned = all.filter { ExtensionStore.isPinned($0.id) }
        let shown = Array(pinned.prefix(2))
        var items = shown.map { item in
            AddressView.ActionButton(image: item.icon, label: item.label, badge: item.badge, needsAttention: item.attention != nil,
                action: { anchor in ExtensionHost.shared.performAction(item, tab: tab, anchor: anchor) },
                menu: { [weak self] in self?.extensionMenu(for: item.context) })
        }
        if all.count > shown.count {
            let waiting = all.filter { item in !shown.contains { $0.id == item.id } }
            items.append(AddressView.ActionButton(label: "Extensions", needsAttention: waiting.contains { $0.attention != nil },
                action: { [weak self] anchor in self?.showExtensionsMenu(all, tab: tab, anchor: anchor) },
                menu: { [weak self] in self?.extensionsFooterMenu() }))
        }
        sidebar.address.setActions(items)
    }

    @available(macOS 15.4, *)
    private func showExtensionsMenu(_ all: [ExtensionHost.ActionItem], tab: Tab?, anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in all {
            let title = item.attention != nil ? "\(item.label)  ·  needs attention" : item.badge.isEmpty ? item.label : "\(item.label)  ·  \(item.badge)"
            let entry = SidebarMenus.Item(title) { ExtensionHost.shared.performAction(item, tab: tab, anchor: anchor) }
            entry.image = item.icon
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let pins = NSMenuItem(title: "Show by the Address", action: nil, keyEquivalent: "")
        let pinsMenu = NSMenu()
        pinsMenu.autoenablesItems = false
        for item in all {
            let pinned = ExtensionStore.isPinned(item.id)
            let entry = SidebarMenus.Item(item.label) { ExtensionStore.setPinned(item.id, !pinned) }
            entry.state = pinned ? .on : .off
            pinsMenu.addItem(entry)
        }
        pins.submenu = pinsMenu
        menu.addItem(pins)
        extensionsFooterMenu().items.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + Tokens.Space.x1), in: anchor)
    }

    private func extensionsFooterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarMenus.Item("Manage Extensions…", symbol: "puzzlepiece.extension") { SettingsWindowController.shared.show() })
        menu.addItem(SidebarMenus.Item("Get Extensions…", symbol: "bag") { [weak self] in
            self?.tabManager.newTab(url: ExtensionStore.webStoreURL)
        })
        return menu
    }

    @available(macOS 15.4, *)
    private func extensionMenu(for context: WKWebExtensionContext) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let id = context.uniqueIdentifier
        let title = NSMenuItem(title: context.webExtension.displayName ?? "Extension", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let options = context.optionsPageURL {
            menu.addItem(SidebarMenus.Item("Settings", symbol: "gearshape") { [weak self] in
                self?.tabManager.newTab(url: options, title: context.webExtension.displayName)
            })
        }
        menu.addItem(siteAccessItem(for: id))
        let pinned = ExtensionStore.isPinned(id)
        menu.addItem(SidebarMenus.Item(pinned ? "Hide from the Address" : "Show by the Address", symbol: pinned ? "pin.slash" : "pin") { ExtensionStore.setPinned(id, !pinned) })
        menu.addItem(SidebarMenus.Item("Turn Off", symbol: "pause.circle") { ExtensionStore.setEnabled(id, false) })
        menu.addItem(SidebarMenus.Item("Remove from Zigzag", symbol: "trash") { ExtensionStore.uninstall(id) })
        menu.addItem(.separator())
        extensionsFooterMenu().items.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
        return menu
    }

    private func selectedTabChanged(_ change: Tab.Change) {
        guard let tab = shownTab else { return }
        switch change {
        case .url, .navigation, .loading:
            sidebar.update(tab: tab)
            updateWindowTitle()
            offerWebStoreExtension()
        case .title:
            updateWindowTitle()
        case .webView:
            showPages()
        case .capture:
            sidebar.address.setCapture(camera: tab.isUsingCamera, microphone: tab.isUsingMicrophone)
        default:
            break
        }
    }

    private func updateWindowTitle() {
        let tab = tabManager.selectedTab
        // Each title change makes AppKit relay out the title bar; skip the ones that change nothing.
        let title = tab?.displayTitle ?? "Zigzag"
        if window?.title != title { window?.title = title }
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
        if event.type == .leftMouseDown, root.splitRatio != nil { focusPane(at: event.locationInWindow) }
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
    func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool) { splitWithUndo(tab, with: other, otherOnRight: otherOnRight) }
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID) {
        libraryChange("Move Bookmark") { Library.shared.moveBookmark(id, to: index, in: spaceID) }
    }
    func listMove(_ tab: Tab, to index: Int, in spaceID: UUID) { moveWithUndo(tab, to: index, in: spaceID) }
    func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID) { bookmarkWithUndo(tab, at: index, in: spaceID) }
    func listUnbookmark(_ bookmarkID: UUID, to index: Int) { unbookmarkWithUndo(bookmarkID, to: index) }
    func listDropOutside(_ tab: Tab, at screenPoint: NSPoint) -> Bool {
        guard !tabManager.isPrivate else { return false }
        let others = WindowManager.shared.controllers.filter { $0 !== self && !$0.tabManager.isPrivate }
        let target: BrowserWindowController
        if let existing = others.first(where: { $0.window?.frame.contains(screenPoint) == true }) {
            target = existing
        } else {
            // A new window, roughly where the tab was let go.
            target = WindowManager.shared.newWindow(spaceID: tab.spaceID, showCommandBar: false)
            if let window = target.window {
                var frame = window.frame
                frame.origin = NSPoint(x: screenPoint.x - 120, y: screenPoint.y - frame.height + 40)
                window.setFrame(frame, display: true)
            }
        }
        tabManager.detach(tab)
        target.tabManager.insert(tab)
        target.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func listDragOverFavorites(at windowPoint: NSPoint) -> Bool {
        let favorites = sidebar.favorites
        // An empty grid still takes drops in the band under the address.
        var zone = favorites.convert(favorites.bounds, to: nil)
        if favorites.isHidden {
            let address = sidebar.address.convert(sidebar.address.bounds, to: nil)
            zone = NSRect(x: address.minX, y: address.minY - Tokens.Space.x10, width: address.width, height: Tokens.Space.x10)
        }
        let over = zone.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(windowPoint)
        favorites.isDropTarget = over
        return over
    }

    func listDropOnFavorites(_ tab: Tab) -> Bool {
        guard sidebar.favorites.isDropTarget else { return false }
        sidebar.favorites.isDropTarget = false
        favoriteWithUndo(tab)
        return true
    }

    func listDragOverPage(at windowPoint: NSPoint, tab: Tab) {
        // Only another tab can open beside the current page.
        guard let current = tabManager.selectedTab, current !== tab else { root.splitDropHint.show(nil); return }
        root.splitDropHint.show(root.splitDropHint.side(at: windowPoint))
    }

    func listDropOnPage(_ tab: Tab) -> Bool {
        let side = root.splitDropHint.side
        root.splitDropHint.show(nil)
        guard let side, let current = tabManager.selectedTab, current !== tab else { return false }
        splitWithUndo(current, with: tab, otherOnRight: side == .right)
        return true
    }

    func listMoveToWindow(_ tab: Tab, controller: BrowserWindowController, index: Int) -> Bool {
        guard !tabManager.isPrivate, !controller.tabManager.isPrivate else { return false }
        tabManager.detach(tab)
        controller.tabManager.insert(tab, at: index)
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func listSwitchSpaceDuringDrag(_ spaceID: UUID) {
        // Switch without changing the selected tab, so the page doesn't jump while you drag.
        tabManager.showSpaceKeepingPage(spaceID)
    }

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

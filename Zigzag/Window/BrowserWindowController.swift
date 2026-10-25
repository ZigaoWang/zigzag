import AppKit
import UniformTypeIdentifiers
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
        sidebar.onEditSpace = { [weak self] id in self?.openSpaceEditor(id, anchor: self?.sidebar.dot(for: id)) }

        sidebar.onSwipeSpace = { [weak self] offset in
            guard let self else { return false }
            let before = self.tabManager.currentSpaceID
            self.tabManager.switchSpace(by: offset)
            return before != self.tabManager.currentSpaceID
        }
        sidebar.backButton.onClick = { [weak self] _ in self?.goBack(nil) }
        sidebar.sidebarButton.onClick = { [weak self] _ in self?.toggleBrowserSidebar(nil) }
        sidebar.forwardButton.onClick = { [weak self] _ in self?.goForward(nil) }
        sidebar.address.onRightClick = { [weak self] _ in
            if let self { SitePanel.toggle(in: self, from: self.sidebar.address) }
            return nil
        }
        sidebar.address.readerButton.onClick = { [weak self] _ in self?.toggleReader() }
        sidebar.address.captureButton.onClick = { [weak self] _ in
            guard let self, let tab = self.tabManager.selectedTab, let host = tab.url?.host() else { return }
            let menu = NSMenu()
            menu.addItem(SidebarMenus.Item("Stop Camera and Microphone", symbol: "stop.circle") { tab.stopCapture() })
            menu.addItem(SidebarMenus.Item("Ask Again Next Time", symbol: "arrow.counterclockwise") { SitePermissions.forget(host: host) })
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
        tokens.append(DownloadManager.shared.started.observe { [weak self] item, window in
            guard let self, window == nil || window === self.window else { return }
            self.flyDownload(item)
        })
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
        sidebar.favorites.onClose = { [weak self] favorite in
            guard let self, let live = self.tabManager.bookmarkTab(for: favorite.id) else { return }
            self.tabManager.close(live)
        }
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
            // A favorite opened or closed: its tile shows it.
            reloadFavorites()
            desk.tabsChanged()
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
        let tabs = Dictionary(uniqueKeysWithValues: favorites.compactMap { favorite in tabManager.bookmarkTab(for: favorite.id).map { (favorite.id, $0) } })
        sidebar.favorites.reload(favorites: favorites, openIDs: open, selectedID: tabManager.selectedTab?.isFavorite == true ? tabManager.selectedTab?.bookmarkID : nil, tabs: tabs)
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
        SpaceEditorPanel.toggle(spaceID: spaceID, anchor: anchor, in: self)
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
        if tab !== shownTab {
            closeReader()
            floatVideoOnSwitch(from: shownTab, to: tab)
            shownTab = tab
            selectedTabToken = tab?.changed.observe { [weak self] change in self?.selectedTabChanged(change) }
            root.card.setLoading(false, progress: 1)
            if let tab, tab.isLoading { root.card.setLoading(true, progress: tab.progress) }
            if let webView = tab?.ensureWebView(), window?.isKeyWindow == true, !commandBar.isVisible {
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(webView) }
            }
        }
        showPages()
        sidebar.update(tab: tab)
        // A collapsed pinned section shows the pinned page you're on, so it changes with the selection.
        if SidebarListView.isCollapsed(tabManager.currentSpaceID) { sidebar.list.reload(animated: true) } else { sidebar.list.refreshRows() }
        reloadFavorites()
        sidebar.address.setCapture(camera: tab?.isUsingCamera ?? false, microphone: tab?.isUsingMicrophone ?? false)
        updateWindowTitle()
        refreshExtensionActions()
        updateNowPlaying()
        offerWebStoreExtension()
        updateReaderButton()
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
    /// Signing out of every site is a big step, so it asks first.
    func confirmClearCookies() {
        ConfirmSheet.show(in: root.overlay, title: "Clear cookies for every site?",
                          message: "You’ll be signed out of every website. Your passwords, bookmarks and history stay.",
                          confirmTitle: "Clear Cookies", destructive: true) { [weak self] confirmed in
            guard confirmed else { return }
            Task { @MainActor in
                await WebsiteData.clear(.cookies)
                self?.tabManager.selectedTab?.reload()
                if let self { Toast.show("Cookies cleared. You’re signed out everywhere.", symbol: "trash", duration: 2.4, in: self) }
            }
        }
    }

    private var offeredExtensionID: String?

    /// On an extension's Chrome Web Store page, offers to add it to Zigzag (the store's own button only works in Chrome).
    private func offerWebStoreExtension() {
        guard #available(macOS 15.4, *) else { return }
        let id = ExtensionStore.webStoreID(from: tabManager.selectedTab?.url)
        guard id != offeredExtensionID else { return }
        if offeredExtensionID != nil { WebStoreOffer.hide() }
        offeredExtensionID = id
        guard let id, !ExtensionStore.isInstalled(id) else { return }
        // Shown once the page has its title, so the bar can name the extension.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.offeredExtensionID == id else { return }
            WebStoreOffer.show(id, in: self)
        }
    }

    /// Adding from the store: verify the package, show what it can do, install only once confirmed.
    enum InstallStage {
        case downloading, reviewing, adding, added(String), failed(String), cancelled
        var isReviewing: Bool { if case .reviewing = self { true } else { false } }
    }

    /// Adding from the store: verify the package, show what it can do, install only once confirmed. `progress`
    /// hears each stage (the store bar shows them); without it, toasts do.
    func installExtension(_ id: String, progress: ((InstallStage) -> Void)? = nil) {
        guard #available(macOS 15.4, *) else { return }
        let report: (InstallStage) -> Void = { [weak self] stage in
            if let progress { progress(stage); return }
            guard let self else { return }
            switch stage {
            case .downloading: Toast.show("Downloading extension…", symbol: "arrow.down.circle", duration: 3600, in: self)
            case .reviewing, .cancelled: Toast.hide(in: self)
            case .adding: Toast.show("Adding…", symbol: "arrow.down.circle", duration: 3600, in: self)
            case .added(let name): Toast.show("Added \(name)", symbol: "checkmark.circle", duration: 2, in: self)
            case .failed(let message): Toast.show(message, symbol: "exclamationmark.triangle", duration: 4, in: self)
            }
        }
        report(.downloading)
        Task { [weak self] in
            let result = await ExtensionStore.prepareInstall(id)
            guard let self else { return }
            switch result {
            case .failure(let error):
                report(.failed(error.message))
            case .success(let prepared):
                report(.reviewing)
                let info = prepared.extensionInfo
                let content = ExtensionSheet.Content(
                    icon: info.icon(for: NSSize(width: 40, height: 40)),
                    title: "Add \(info.displayName ?? "this extension")?",
                    subtitle: "Version \(prepared.version), from the Chrome Web Store",
                    heading: "It will be able to",
                    report: prepared.report,
                    confirm: "Add Extension", cancel: "Cancel")
                ExtensionSheet.present(content, in: self, onConfirm: {
                    report(.adding)
                    Task {
                        switch await ExtensionStore.finishInstall(prepared) {
                        case .success(let name): report(.added(name))
                        case .failure(let error): report(.failed(error.message))
                        }
                    }
                }, onCancel: {
                    ExtensionStore.discard(prepared)
                    report(.cancelled)
                })
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

    /// Leaving a tab while its video plays keeps the video with you, floating; coming back puts it in the page.
    private func floatVideoOnSwitch(from old: Tab?, to new: Tab?) {
        guard PictureInPicture.followsTabs else { return }
        if let webView = new?.webView, webView.isPictureInPictureActive, new?.floatedOnSwitch == true {
            webView.togglePictureInPicture()
            new?.floatedOnSwitch = false
        }
        if let old, old.isPlayingAudio, let webView = old.webView, webView.canTogglePictureInPicture, !webView.isPictureInPictureActive {
            webView.togglePictureInPicture()
            old.floatedOnSwitch = true
        }
    }

    /// Puts the selected tab in the page card, or both halves of its split side by side.
    private func showPages() {
        // A link address belongs to the page it was pointed at in: a different page, a different space, it goes.
        linkStatus.show(nil, in: root.cardFrame)
        let tab = tabManager.selectedTab
        if let tab, let pair = tabManager.split(for: tab),
           let left = tabManager.tab(with: pair.left), let right = tabManager.tab(with: pair.right) {
            root.setSplit(ratio: CGFloat(pair.ratio), vertical: pair.vertical, animated: true)
            for card in [root.card, root.secondCard] {
                card.header.setVertical(pair.vertical)
                card.header.orientation.onClick = { [weak self] _ in self?.tabManager.toggleSplitOrientation(for: left) }
                card.header.swap.onClick = { [weak self] _ in self?.tabManager.swapSplit(for: left) }
            }
            root.card.show(left.ensureWebView())
            root.secondCard.show(right.ensureWebView())
            // Either half may have crashed while out of sight (a space switch brings it back, not only selecting it).
            left.reloadIfItStopped()
            right.reloadIfItStopped()
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
            tab?.reloadIfItStopped()
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

    /// One button by the address, for everything about this page: quick actions, extensions, the site's own
    /// settings, and clearing its data. It shows a dot when an extension needs attention.
    func refreshExtensionActions() {
        let tab = tabManager.selectedTab
        // Always there, even on a new tab: it's also where your extensions live.
        _ = tab?.url
        var attention = false
        if #available(macOS 15.4, *) { attention = ExtensionHost.shared.actions(for: tab).contains { $0.attention != nil } }
        sidebar.address.setActions([AddressView.ActionButton(symbol: "slider.horizontal.3", label: "Site Controls", needsAttention: attention,
            action: { [weak self] anchor in if let self { SitePanel.toggle(in: self, from: self.sidebar.address) } },
            menu: { [weak self] in
                if let self { SitePanel.toggle(in: self, from: self.sidebar.address) }
                return nil
            })])
    }

    var isShowingReader: Bool { reader != nil }

    private func extensionsFooterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarMenus.Item("Manage Extensions…", symbol: "puzzlepiece.extension") {
            SettingsWindowController.shared.show()
            SettingsWindowController.shared.show(.extensions)
        })
        menu.addItem(SidebarMenus.Item("Get Extensions…", symbol: "bag") { [weak self] in
            self?.tabManager.newTab(url: ExtensionStore.webStoreURL)
        })
        return menu
    }

    @available(macOS 15.4, *)
    func extensionMenu(for context: WKWebExtensionContext, footer: Bool = true) -> NSMenu {
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
        menu.addItem(SidebarMenus.Item("Turn Off", symbol: "pause.circle") { ExtensionStore.setEnabled(id, false) })
        menu.addItem(SidebarMenus.Item("Remove from Zigzag", symbol: "trash") { ExtensionStore.uninstall(id) })
        guard footer else { return menu }
        menu.addItem(.separator())
        extensionsFooterMenu().items.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
        return menu
    }

    private func selectedTabChanged(_ change: Tab.Change) {
        guard let tab = shownTab else { return }
        switch change {
        case .progress:
            root.card.setLoading(tab.isLoading, progress: tab.progress)
        case .url, .navigation, .loading:
            root.card.setLoading(tab.isLoading, progress: tab.progress)
            if change == .url {
                refreshExtensionActions()
                // A pinned tab that moved on shows it right away.
                if tab.bookmarkID != nil { sidebar.list.refreshRows() }
            }
            sidebar.update(tab: tab)
            updateWindowTitle()
            offerWebStoreExtension()
        case .title:
            updateWindowTitle()
        case .webView:
            showPages()
        case .capture:
            sidebar.address.setCapture(camera: tab.isUsingCamera, microphone: tab.isUsingMicrophone)
        case .reader:
            updateReaderButton()
        case .language:
            offerTranslation()
        default:
            break
        }
        // Reader belongs to the page it was opened on.
        if change == .url, readerTab === tab, tab.url != readerURL { closeReader() }
    }

    // MARK: Translation

    private lazy var translator: TranslationHost = {
        let host = TranslationHost()
        root.overlay.addSubview(host.view)
        return host
    }()
    /// Sites already offered this session, so browsing a site in another language doesn't ask on every page.
    private var translationOffered: Set<String> = []
    /// Sites the person translated this session: their other pages translate as they open.
    private var translatedSites: Set<String> = []

    private func offerTranslation() {
        guard let tab = tabManager.selectedTab, let language = tab.foreignLanguage, !tab.isTranslated,
              let site = ContentBlocker.site(of: tab.url) else { return }
        // Languages you always translate, and sites you translated a moment ago, translate on their own.
        if translatedSites.contains(site) || PageTranslator.translatesAlways(language) { translatePage(); return }
        guard PageTranslator.offers, !translationOffered.contains(site) else { return }
        translationOffered.insert(site)
        Toast.show("This page is in \(PageTranslator.name(of: language))", symbol: "translate",
                   action: (title: "Translate", run: { [weak self] in self?.translatePage() }), duration: 6, in: self)
    }

    func translatePage() {
        guard let tab = tabManager.selectedTab, let webView = tab.webView else { return }
        let site = ContentBlocker.site(of: tab.url)
        if tab.isTranslated {
            PageTranslator.restore(in: webView)
            tab.isTranslated = false
            if let site { translatedSites.remove(site) }
            Toast.hide(in: self)
            return
        }
        guard let language = tab.foreignLanguage else {
            Toast.show("This page is already in \(PageTranslator.name(of: PageTranslator.readerLanguage))", symbol: "translate", duration: 2, in: self)
            return
        }
        let name = PageTranslator.name(of: language)
        Toast.show("Translating from \(name)…", symbol: "translate", duration: 3600, in: self)
        let page = webView.url
        translator.translate(webView, from: language, progress: { _ in }, completion: { [weak self] result in
            guard let self else { return }
            // Left for another page meanwhile: that page isn't translated, and there's nothing to say.
            if case .failure(let error) = result, error is TranslationHost.Cancelled { Toast.hide(in: self); return }
            guard tab.webView?.url == page else { Toast.hide(in: self); return }
            switch result {
            case .success:
                tab.isTranslated = true
                if let site { self.translatedSites.insert(site) }
                Toast.show("Translated from \(name)", symbol: "translate",
                           action: (title: "Show Original", run: { [weak self] in self?.translatePage() }), duration: 4, in: self)
            case .failure:
                Toast.show("Couldn’t translate this page. Try again in a moment.", symbol: "exclamationmark.triangle", duration: 3, in: self)
            }
        })
    }

    // MARK: Reader

    private var reader: ReaderView?
    #if DEBUG
    var debugReaderWebView: WKWebView? { reader?.webView }
    #endif
    private weak var readerTab: Tab?
    /// The pane the reading page covers: in a split, the one its tab is in.
    private weak var readerCard: PageCardView?
    private var readerURL: URL?
    private var readerKeyMonitor: Any?

    func toggleReader() {
        if reader != nil { closeReader(); return }
        guard let tab = tabManager.selectedTab, let webView = tab.webView, let url = tab.url else { return }
        Task { [weak self] in
            guard let article = await Reader.article(in: webView), let self else {
                if let self { Toast.show("This page doesn’t have an article to read", symbol: "doc.plaintext", duration: 2, in: self) }
                return
            }
            guard self.tabManager.selectedTab === tab, self.reader == nil else { return }
            let view = ReaderView()
            view.onClose = { [weak self] in self?.closeReader() }
            view.onOpenLink = { [weak self] link in self?.closeReader(); tab.load(link) }
            view.onPeekLink = { [weak self] link in self?.open(link, disposition: .peek, opener: tab) }
            view.onBackgroundLink = { [weak self] link in self?.open(link, disposition: .backgroundTab, opener: tab) }
            view.show(article, from: url)
            self.reader = view
            self.readerTab = tab
            self.readerURL = url
            let card = self.tabManager.split(for: tab)?.right == tab.id ? self.root.secondCard : self.root.card
            self.readerCard = card
            card.setOverlay(view)
            // Visible from the start (WebKit doesn't paint into a hidden view); the article is local and draws
            // within a few frames, well inside the fade.
            Self.readerTransition(view, entering: true)
            self.window?.makeFirstResponder(view.webView)
            // Opened again quickly: one listener, never two.
            if let old = self.readerKeyMonitor { NSEvent.removeMonitor(old) }
            self.readerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // A peek opened from the article is in front: Esc closes that first, and Reader stays.
                guard event.keyCode == 53, event.window === self?.window, self?.reader != nil, self?.peek.isVisible == false else { return event }
                self?.closeReader()
                return nil
            }
            self.updateReaderButton()
        }
    }

    private func closeReader() {
        guard let view = reader else { return }
        reader = nil
        readerTab = nil
        readerURL = nil
        let card = readerCard ?? root.card
        readerCard = nil
        if let monitor = readerKeyMonitor { NSEvent.removeMonitor(monitor) }
        readerKeyMonitor = nil
        Self.readerTransition(view, entering: false) {
            guard card.overlay === view else { view.removeFromSuperview(); return }
            card.setOverlay(nil)
        }
        if let webView = tabManager.selectedTab?.webView { window?.makeFirstResponder(webView) }
        updateReaderButton()
    }

    /// Reader fades over the page while its text rises into place (that part is the reading page's own CSS);
    /// leaving is a quicker fade. Only opacity is animated here: moving or transforming a view that hosts web
    /// content stops WebKit drawing into it, and so does a fully transparent start (hence 0.01).
    private static func readerTransition(_ view: NSView, entering: Bool, completion: (() -> Void)? = nil) {
        if entering { view.alphaValue = 0.01 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = (entering ? 0.3 : 0.18) * Tokens.Motion.debugSlowdown
            ctx.timingFunction = entering ? CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                                          : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
            view.animator().alphaValue = entering ? 1 : 0.01
        }, completionHandler: completion)
    }

    private func updateReaderButton() {
        let tab = tabManager.selectedTab
        sidebar.address.setReader(available: tab?.isArticle ?? false, active: reader != nil && readerTab === tab)
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
        let mine = manager.items(isPrivate: tabManager.isPrivate)
        let active = mine.filter { $0.state == .downloading }
        let progress = active.isEmpty ? 1 : active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
        sidebar.updateDownloads(active: active.count, hasAny: !mine.isEmpty, progress: progress)
    }

    /// The file's own icon lifts off where you clicked and arcs into the Downloads button, which answers with a
    /// small pulse: you see where it went without a word. With the sidebar hidden, just the pulse is skipped.
    #if DEBUG
    func debugFlyDownload(_ name: String) {
        sidebar.updateDownloads(active: 1, hasAny: true, progress: 0.35)
        flyDownload(DownloadItem(filename: name, sourceURL: nil, isPrivate: false), refresh: false)
    }
    #endif

    private func flyDownload(_ item: DownloadItem, refresh: Bool = true) {
        if refresh { downloadsChanged() }
        sidebar.layoutSubtreeIfNeeded()
        let overlay = root.overlay
        guard let host = overlay.layer, let window, !Tokens.Motion.reduceMotion else { return }
        let anchor = sidebar.downloadsAnchor
        let sidebarShown = root.sidebarVisible || root.isSidebarFloatingVisible
        let card = root.cardFrame
        // From the pointer if it's over the page, otherwise the middle of the page.
        let mouse = overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let start = card.contains(mouse) ? mouse : NSPoint(x: card.midX, y: card.midY)
        let end: NSPoint = sidebarShown && !anchor.isHiddenOrHasHiddenAncestor
            ? overlay.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), from: anchor)
            : NSPoint(x: card.minX + 24, y: card.maxY - 24)
        let ext = (item.filename as NSString).pathExtension
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        let size: CGFloat = 56
        let flyer = CALayer()
        flyer.contents = icon
        flyer.contentsGravity = .resizeAspect
        flyer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        flyer.position = end
        flyer.zPosition = 2000
        flyer.shadowColor = NSColor.black.cgColor
        flyer.shadowOpacity = 0.18
        flyer.shadowRadius = 6
        flyer.shadowOffset = CGSize(width: 0, height: 3)
        flyer.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(flyer)
        CATransaction.commit()
        // An arc: up a little first, then down into the button.
        let path = CGMutablePath()
        path.move(to: start)
        let lift = max(80, abs(end.x - start.x) * 0.35)
        path.addQuadCurve(to: end, control: NSPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - lift))
        let duration = 0.62 * Tokens.Motion.debugSlowdown
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.25, 1)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.6, 1.08, 1, 0.32]
        scale.keyTimes = [0, 0.18, 0.4, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0.85]
        fade.keyTimes = [0, 0.12, 0.85, 1]
        let group = CAAnimationGroup()
        group.animations = [move, scale, fade]
        group.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            flyer.removeFromSuperlayer()
            if sidebarShown { self?.sidebar.pulseDownloads() }
        }
        flyer.add(group, forKey: "fly")
        CATransaction.commit()
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

    func layoutTrafficLights() {
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
        sidebar.trafficLightsWidth = window.styleMask.contains(.fullScreen) ? 0 : window.trafficLightsWidth
        sidebar.sidebarButton.toolTip = (docked ? "Hide Sidebar" : "Show Sidebar") + Shortcuts.hint(for: #selector(toggleBrowserSidebar(_:)))
        sidebar.backButton.toolTip = "Back" + Shortcuts.hint(for: #selector(goBack(_:)))
        sidebar.forwardButton.toolTip = "Forward" + Shortcuts.hint(for: #selector(goForward(_:)))
        sidebar.reloadButton.toolTip = "Reload" + Shortcuts.hint(for: #selector(reloadPage(_:)))
        sidebar.sidebarButton.isSelected = false
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights(); onStateChange?() }
    func windowDidMove(_ notification: Notification) { onStateChange?() }
    func windowDidEndLiveResize(_ notification: Notification) { layoutTrafficLights() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        layoutTrafficLights()
        root.needsLayout = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutTrafficLights()
        root.needsLayout = true
    }
    func windowDidResignKey(_ notification: Notification) { switcher.windowResignedKey() }

    func windowDidBecomeKey(_ notification: Notification) {
        // Brand moments in other windows (Settings, Passwords) follow the space in front.
        Brand.themeChanged.send(())
        layoutTrafficLights()
        WindowManager.shared.windowBecameKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        fadeTimer?.invalidate()
        // The peeked page isn't one of the window's tabs: it goes with the window, not whenever this is freed.
        peek.close()
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
        // Nothing about the page while a panel is over it.
        linkStatus.show(hasFloatingPanel ? nil : url, in: tab.isPeek ? peek.contentFrame : root.cardFrame)
    }

    /// One floating thing at a time: the command bar, site panel, downloads and space editor each close the
    /// others when they open, and previews and the link bubble stay away while any of them is up.
    var hasFloatingPanel: Bool { commandBar.isVisible || SitePanel.isOpen || DownloadsPanel.isOpen || SpaceEditorPanel.current != nil }

    func closeFloatingPanels() {
        if commandBar.isVisible { commandBar.dismiss(restoringFocus: false) }
        SitePanel.closeCurrent()
        DownloadsPanel.closeCurrent()
        SpaceEditorPanel.current?.close()
        previews.hide()
        linkStatus.show(nil, in: root.cardFrame)
    }
}

// MARK: - SidebarDelegate

extension BrowserWindowController: SidebarDelegate {
    func listSelect(_ tab: Tab) { tabManager.select(tab) }
    func listOpenBookmark(_ bookmark: Bookmark) { tabManager.openBookmark(bookmark) }
    func listClose(_ tab: Tab) { closeWithUndo(tab) }

    func listRenameBookmark(_ id: UUID, to name: String) {
        libraryChange("Rename") { Library.shared.updateBookmark(id, title: name) }
    }

    // MARK: Undo (⌘Z) for sidebar actions

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { sidebarUndo }

    /// Closes a tab; ⌘Z brings it back with its history, ⇧⌘Z closes it again.
    func closeWithUndo(_ tab: Tab) {
        let wasBookmark = tab.bookmarkID != nil
        let id = tab.id
        tabManager.close(tab)
        guard !wasBookmark else { return }
        sidebarUndo.registerUndo(withTarget: self) { controller in
            guard let reopened = controller.tabManager.reopenClosedTab(id) else { return }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.closeWithUndo(reopened) }
            controller.sidebarUndo.setActionName("Close Tab")
        }
        sidebarUndo.setActionName("Close Tab")
    }

    /// Moves a tab within or between spaces, undoably.
    func moveWithUndo(_ tab: Tab, to index: Int, in spaceID: UUID) {
        let oldSpace = tab.spaceID
        let oldIndex = tabManager.tabs(in: oldSpace).firstIndex { $0 === tab } ?? 0
        if spaceID == oldSpace { tabManager.move(tab, to: index) } else { tabManager.moveTabToSpace(tab, spaceID: spaceID, at: index) }
        // Dropped into the space a drag opened, with the old page still showing: you're there now, so it's this tab.
        if spaceID != oldSpace, spaceID == tabManager.currentSpaceID, shownTab !== tabManager.selectedTab { tabManager.select(tab) }
        sidebarUndo.registerUndo(withTarget: self) { $0.moveWithUndo(tab, to: oldIndex, in: oldSpace) }
        sidebarUndo.setActionName(spaceID == oldSpace ? "Move Tab" : "Move to Space")
    }

    /// Turns a tab into a bookmark, undoably.
    func bookmarkWithUndo(_ tab: Tab, at index: Int?, in spaceID: UUID) {
        Tutorial.complete("pin")
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
        // Unloaded, it comes back as a new tab: ⌘Z pins that one again.
        if let tab = tabManager.unbookmark(bookmarkID, toIndex: index) {
            sidebarUndo.registerUndo(withTarget: self) { $0.bookmarkWithUndo(tab, at: oldIndex, in: spaceID) }
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
    /// A drag that opened another space kept the page on screen. However it ended, the selection matches what's
    /// showing again, so ⌘W closes the page you see.
    func listDropFinished() {
        guard shownTab !== tabManager.selectedTab else { return }
        if let shown = shownTab, tabManager.tab(with: shown.id) != nil { tabManager.select(shown) } else { showSelectedTab() }
    }
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
        guard let current = tabManager.selectedTab, tabManager.canSplit(current, with: tab) else { root.splitDropHint.show(nil); return }
        root.splitDropHint.show(root.splitDropHint.side(at: windowPoint))
    }

    func listDropOnPage(_ tab: Tab) -> Bool {
        let side = root.splitDropHint.side
        root.splitDropHint.show(nil)
        guard let side, let current = tabManager.selectedTab, tabManager.canSplit(current, with: tab) else { return false }
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

#if DEBUG
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
#endif

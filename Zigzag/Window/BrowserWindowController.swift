import AppKit
import UniformTypeIdentifiers
import WebKit

/// One browser window: its tabs, its sidebar, its page card, and everything floating above them.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    /// Where tabs moved out of this window go back to on ⌘Z (#167): this window, or once it has closed, the window ⌘Z
    /// opened in its place.
    final class MoveHome {
        weak var window: BrowserWindowController?
        var frame: NSRect?
        var space = UUID()
    }
    var moveHome = MoveHome()

    /// The last to be asked about a key: one nothing took goes by quietly (`QuietKeys`).
    override func noResponder(for eventSelector: Selector) {
        if QuietKeys.passQuietly(eventSelector, NSApp.currentEvent) { return }
        super.noResponder(for: eventSelector)
    }

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

    lazy var commandBar = CommandBarController(host: self)
    lazy var findBar = FindBarController(window: self)
    lazy var desk = DeskController(window: self)
    lazy var previews = TabPreviewController(controller: self)
    lazy var switcher = TabSwitcher(controller: self)
    lazy var spaceSwitcher = SpaceSwitcher(controller: self)
    /// Holding ⌘ a moment: the number on each favorite and row that ⌘ goes to.
    private(set) var numberHints: NumberHints?
    /// ⌘Z for sidebar actions; also the window's undo manager, so page text editing shares it.
    /// Each step it remembers holds on to the tabs it can bring back, closed ones too, so it keeps the last hundred
    /// rather than a whole day's worth.
    let sidebarUndo: UndoManager = {
        let undo = UndoManager()
        undo.levelsOfUndo = 100
        return undo
    }()
    /// Inside a `pageChange`: the steps it's made of (pin, then into a folder) are its own, one ⌘Z and one redo.
    var isInPageChange = false
    lazy var linkStatus = LinkStatusController(overlay: root.overlay)
    lazy var peek = PeekController(controller: self)
    /// A playing video you've left, in a small card over the page.
    lazy var miniPlayer = MiniPlayer(controller: self)
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
        // A width saved before the toolbar's buttons grew can be narrower than they now need.
        root.sidebarWidth = min(max(sidebarWidth, Tokens.Metric.sidebarMinWidth), Tokens.Metric.sidebarMaxWidth)
        root.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.layoutTrafficLights()
            self.commandBar.reposition()
            self.findBar.reposition()
            self.peek.reposition()
            self.miniPlayer.place()
            PermissionPrompt.reposition(in: self)
            Toast.reposition(in: self)
            AgentControl.shared.reposition(in: self)
            if self.floatingDownloads.superview != nil {
                if self.root.sidebarVisible { self.hideFloatingDownloads() } else { self.showFloatingDownloads() }
            }
        }
        root.onSidebarWidthChange = { [weak self] _ in self?.onStateChange?() }
        root.onSlide = { [weak self] duration in
            guard let self else { return }
            self.sidebarSliding(duration)
            PermissionPrompt.reposition(in: self, slide: duration)
            Toast.reposition(in: self, slide: duration)
            AgentControl.shared.reposition(in: self)
        }
        // A panel opened from the slid-out sidebar keeps it out until the panel closes, so it's never left floating alone.
        // So does the guide while it points at something in it.
        root.keepsRevealed = { [weak self] in
            SitePanel.isOpen(in: self?.window) || DownloadsPanel.isOpen(in: self?.window) || GuidedTour.holdsSidebar(in: self?.window)
                || self?.popupHoldsSidebar == true
        }
        // One floating thing at a time, the sidebar that slides out included: while the command bar is up, or a panel
        // opened from the bar above the page, the pointer at the window's edge leaves it hidden. It would slide in
        // under them, and under a panel it would then be held there.
        root.blocksEdgeReveal = { [weak self] in
            self?.commandBar.isVisible == true || SitePanel.isOpen(in: self?.window) || DownloadsPanel.isOpen(in: self?.window)
        }
        // A click beside a zoomed pane puts it back, as one beside Peek puts it away.
        root.zoomScrim.onClick = { [weak self] in self?.unzoomPane() }
        root.onTilesChange = { [weak self] shape, final in
            guard let self, final, let tab = self.tabManager.selectedTab else { return }
            self.tabManager.setTileRatios(column: shape.column, row: shape.row, for: tab)
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
        // Right-click Back or Forward: the pages that way, to jump several at once.
        sidebar.backButton.onRightClick = { [weak self] _ in self?.historyMenu(back: true) }
        sidebar.forwardButton.onRightClick = { [weak self] _ in self?.historyMenu(back: false) }
        sidebar.sidebarButton.onClick = { [weak self] _ in self?.toggleBrowserSidebar(nil) }
        root.topBar.sidebarButton.onClick = { [weak self] _ in self?.toggleBrowserSidebar(nil) }
        sidebar.forwardButton.onClick = { [weak self] _ in self?.goForward(nil) }
        sidebar.address.onRightClick = { [weak self] _ in
            if let self { SitePanel.toggle(in: self, from: self.sidebar.address) }
            return nil
        }
        sidebar.address.readerButton.onClick = { [weak self] _ in self?.toggleReader() }
        // The address stands for the tab you're on: a middle-click closes it, as on the tab's own row.
        sidebar.address.onMiddleClick = { [weak self] in self?.closeTab(nil) }
        sidebar.address.onPinsMoved = { [weak self] in
            if #available(macOS 15.4, *), let self { ExtensionCenter.repositionPinPopups(of: self) }
        }
        sidebar.address.onPinDragBegan = { [weak self] in
            if #available(macOS 15.4, *) { ExtensionCenter.closePopups(in: self?.window) }
        }
        sidebar.address.onPinsReordered = { [weak self] in self?.installs.reorderPins(visible: $0) }
        sidebar.address.siteControlsButton.onClick = { [weak self] _ in
            if let self { SitePanel.toggle(in: self, from: self.sidebar.address) }
        }
        sidebar.address.siteControlsButton.onRightClick = { [weak self] _ in
            if let self { SitePanel.toggle(in: self, from: self.sidebar.address) }
            return nil
        }
        sidebar.address.captureButton.onClick = { [weak self] _ in
            guard let self, let tab = self.tabManager.selectedTab, let origin = SiteOrigin.of(tab.url) else { return }
            MenuPanel.show([
                .item(.init(title: String(localized: "Stop Camera and Microphone", comment: "Menu item of the address bar's camera button: stops the page using the camera and microphone."), symbol: "stop.circle") { tab.stopCapture() }),
                .item(.init(title: String(localized: "Ask Again Next Time", comment: "Menu item of the address bar's camera button: forgets the site's camera and microphone answer."), symbol: "arrow.counterclockwise") { SitePermissions.forget(origin: origin) }),
            ], from: self.sidebar.address.captureButton)
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
        // Tools above the page turned on or off (Settings › Developer): the page you're on gains or loses them.
        tokens.append(DeveloperTools.changed.observe { [weak self] in self?.showDeveloperBarTools() })
        // Reduce Transparency turned on or off while Zigzag is open: the window follows at once.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // Plugged in or on battery, Low Power Mode on or off: clear glass comes and goes with it.
        PowerSaving.start()
        NotificationCenter.default.addObserver(self, selector: #selector(displayOptionsChanged), name: PowerSaving.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(placeAddress), name: BrowserRootView.addressPlaceChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(placeSidebarSide), name: BrowserRootView.sidebarSideChanged, object: nil)
        placeAddress()
        tokens.append(DownloadManager.shared.changed.observe { [weak self] _ in self?.downloadsChanged() })
        tokens.append(DownloadManager.shared.started.observe { [weak self] item, window in
            guard let self, window == nil || window === self.window else { return }
            self.flyDownload(item)
        })
        if #available(macOS 15.4, *) {
            tokens.append(ExtensionCenter.changed.observe { [weak self] in self?.scheduleExtensionActions() })
            tokens.append(ExtensionCenter.popupsChanged.observe { [weak self] in self?.scheduleExtensionActions() })
            // Badges tick for every request an ad blocker stops, in every tab: only the tab shown here is drawn
            // again, and no more than ten times a second.
            tokens.append(ExtensionCenter.actionUpdated.observe { [weak self] tab in
                guard let self, ExtensionCenter.update(for: tab, concerns: self.tabManager.selectedTab) else { return }
                self.scheduleExtensionActions(after: 0.1)
            })
        }

        // Fading is slow; checking once a minute is plenty.
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebar.list.refreshRows() }
        }
        fadeTimer?.tolerance = 10

        if tabManager.isPrivate {
            // Private windows are always dark and say so, so you never wonder which one you're in.
            window.appearance = NSAppearance(named: .darkAqua)
            sidebar.list.privateLabel = true
            sidebar.isPrivate = true
        }
        applySpaceColor(animated: false)
        sidebar.reloadSpaces(current: tabManager.currentSpaceID)
        sidebar.onMoveSpace = { [weak self] id, index in
            guard let self, !self.tabManager.isPrivate else { return }
            self.libraryChange(String(localized: "Move Space", comment: "What Edit › Undo undoes after a space is dragged to a new place.")) {
                Library.shared.moveSpace(id, to: index)
            }
        }
        sidebar.favorites.onOpen = { [weak self] favorite in self?.tabManager.openBookmark(favorite) }
        // A split favorite unloads both its pages, as its Unload Pages does.
        sidebar.favorites.onClose = { [weak self] favorite in
            guard let self else { return }
            let ids = Library.shared.pinnedSplit(containing: favorite.id).map { [$0.left, $0.right] } ?? [favorite.id]
            let pages = ids.compactMap(self.tabManager.bookmarkTab(for:))
            if !pages.isEmpty { self.tabManager.close(pages) }
        }
        sidebar.favorites.onMenu = { [weak self] favorite in
            guard let self else { return nil }
            return SidebarMenus.favoriteMenu(for: favorite, controller: self)
        }
        sidebar.favorites.onDragMove = { [weak self] _, point in
            guard let self, let window = self.window else { return false }
            if self.favoriteDragOrigin == nil { self.favoriteDragOrigin = self.tabManager.currentSpaceID }
            // Over another window's list, the line shows there instead.
            let other = self.otherWindowForFavorite(at: point)
            if self.favoriteDropWindow !== other { self.favoriteDropWindow?.sidebar.list.externalHover(at: nil) }
            self.favoriteDropWindow = other
            other?.sidebar.list.externalHover(at: point, allowsPinned: true)
            let over = other == nil && !self.tabManager.isPrivate && self.isOverList(point)
            self.sidebar.list.externalHover(at: over ? point : nil, allowsPinned: true)
            self.favoriteSpring(at: other == nil ? window.convertPoint(fromScreen: point) : nil)
            self.sidebar.list.carryToEdge(at: other == nil ? point : nil)
            return over || other != nil
        }
        sidebar.favorites.onDrop = { [weak self] favorite, point in
            guard let self, !self.tabManager.isPrivate, let window = self.window else { return (false, nil) }
            if let other = self.otherWindowForFavorite(at: point) {
                return (true, other.takeFavorite(favorite, from: self, at: point))
            }
            // Let go on a space's dot: it becomes a tab there, at the top, whichever space is showing.
            if let dot = self.sidebar.spaceDot(at: window.convertPoint(fromScreen: point)) {
                self.unfavoriteWithUndo(favorite.id, to: 0, in: dot)
                return (true, nil)
            }
            guard self.isOverList(point) else { return (false, nil) }
            return (true, self.dropFavorite(favorite, at: point))
        }
        sidebar.favorites.onDragEnd = { [weak self] cancelled in
            guard let self else { return }
            self.favoriteDropWindow?.sidebar.list.externalHover(at: nil)
            self.favoriteDropWindow = nil
            self.sidebar.list.externalHover(at: nil)
            self.favoriteSpring(at: nil)
            self.sidebar.list.carryToEdge(at: nil)
            self.sidebar.clearDropTargets()
            // Called off: back to the space it started in, as if it had never moved.
            if cancelled, let origin = self.favoriteDragOrigin { self.tabManager.showSpaceKeepingPage(origin) }
            self.favoriteDragOrigin = nil
            self.listDropFinished()
        }
        sidebar.favorites.onJoin = { [weak self] favorite, targetID, onRight in
            guard let self, !self.tabManager.isPrivate else { return }
            self.pageChange(String(localized: "Split View", comment: "Undo action name, shown in the Edit menu as Undo Split View.")) { [tabManager = self.tabManager] in
                Library.shared.joinFavorite(favorite, onto: targetID, onRight: onRight)
                tabManager.openBookmark(favorite)
            }
        }
        sidebar.favorites.onReorder = { [weak self] favorite, index in
            guard let self, !self.tabManager.isPrivate else { return }
            self.pageChange(String(localized: "Move Favorite", comment: "Undo action name, shown in the Edit menu as Undo Move Favorite.")) { Library.shared.moveFavorite(favorite.id, to: index) }
        }
        reloadFavorites()
        sidebar.currentSpaceID = tabManager.currentSpaceID
        sidebar.list.reload(animated: false)
        showSelectedTab()
        downloadsChanged()
        window.eventInterceptor = { [weak self] event in self?.intercept(event) ?? false }
        numberHints = NumberHints(controller: self)
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
            // Many at once (`TabManager.together`): once, when they're all done.
            if tabManager.isBatching { break }
            sidebar.list.reload(animated: window?.isVisible == true)
            // A favorite opened or closed: its tile shows it.
            reloadFavorites()
            numberHints?.placesChanged()
            desk.tabsChanged()
            // A playing tab closed in the background: Now Playing lets it go, and so does the mini player.
            updateNowPlaying()
            miniPlayer.tabsChanged()
        case .selection:
            showSelectedTab()
            // An AI app's bar goes with the tab it's using.
            AgentControl.shared.refresh(self)
            // "Translating…" belongs to its tab; the translation goes on there, quietly.
            if let translating = translatingTab, translating !== tabManager.selectedTab { translatingTab = nil; Toast.hide(in: self) }
        case .space:
            spaceChanged()
        case .content:
            updateNowPlaying()
        }
        onStateChange?()
    }

    private var lastSpaceID: UUID?
    private var handoff: NSUserActivity?

    private func spaceChanged() {
        let spaces = Library.shared.spaces
        let old = lastSpaceID
        let oldIndex = old.flatMap { id in spaces.firstIndex { $0.id == id } } ?? 0
        let newIndex = spaces.firstIndex { $0.id == tabManager.currentSpaceID } ?? 0
        // Only a drag needs a picture of the list: otherwise the old list itself slides away.
        let snapshot = sidebar.list.isDragging ? sidebar.listSnapshot() : nil
        lastSpaceID = tabManager.currentSpaceID
        sidebar.currentSpaceID = tabManager.currentSpaceID
        sidebar.reloadSpaces(current: tabManager.currentSpaceID)
        sidebar.transitionList(direction: CGFloat((newIndex - oldIndex).signum()), from: old, snapshot: snapshot)
        // The slide goes to Core Animation first, so it carries on from the fingers at once: the new color (and with
        // it light or dark, which restyles everything) follows a moment later, and the page after that (tens of
        // milliseconds of WebKit work). From here they run on their own, so a swipe never catches on that work.
        CATransaction.flush()
        // No window-wide cross-fade on a switch: the list is already sliding in, and a fade through a picture of the
        // window would freeze that slide and ghost the traffic lights.
        applySpaceColor(animated: true, crossFadesMode: false)
        desk.spaceChanged()
        CATransaction.flush()
    }

    /// A favorite held over another space's dot opens that space after a beat, so it can be dropped among that
    /// space's tabs, as a tab can. Nil: the drag is over.
    private var favoriteSpringTarget: (space: UUID, work: DispatchWorkItem)?
    /// The space a favorite's drag started in, to go back to if it's called off.
    private var favoriteDragOrigin: UUID?
    private func favoriteSpring(at windowPoint: NSPoint?) {
        let hovered = windowPoint.flatMap { sidebar.spaceDot(at: $0) }
        guard hovered != favoriteSpringTarget?.space else { return }
        favoriteSpringTarget?.work.cancel()
        favoriteSpringTarget = nil
        guard let hovered else { return }
        Haptics.snap()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tabManager.showSpaceKeepingPage(hovered) }
        }
        favoriteSpringTarget = (hovered, work)
        if hovered != tabManager.currentSpaceID { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work) }
    }

    private func isOverList(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let list = sidebar.list.enclosingScrollView ?? sidebar.list
        return list.convert(list.bounds, to: nil).contains(window.convertPoint(fromScreen: screenPoint))
    }

    /// The window showing where a favorite carried from here would land, when that's another window's list.
    private weak var favoriteDropWindow: BrowserWindowController?

    /// Another window whose list is in front at a screen point, to take a favorite carried from here. Never to or
    /// from a private window: its pages stay in it.
    private func otherWindowForFavorite(at screenPoint: NSPoint) -> BrowserWindowController? {
        guard !tabManager.isPrivate, let (controller, _) = SidebarListView.list(at: screenPoint), controller !== self,
              !controller.tabManager.isPrivate else { return nil }
        return controller
    }

    /// A favorite let go over this window's list: a pinned tab among the pinned ones (in a folder, if it's let go
    /// among a folder's pages), or a regular tab among the tabs, right where it was dropped. Returns its new row.
    func dropFavorite(_ favorite: Bookmark, at screenPoint: NSPoint) -> NSView? {
        let landing = sidebar.list.dropTarget(at: screenPoint, allowsPinned: true)
        let space = tabManager.currentSpaceID
        if landing.section == .bookmarks {
            pageChange(String(localized: "Pin Tab", comment: "Undo action name, shown in the Edit menu as Undo Pin Tab.")) {
                Library.shared.pinFavorite(favorite.id, in: space, at: landing.index)
                if let folder = landing.folder { Library.shared.moveBookmark(favorite.id, to: landing.index, in: space, folder: .some(folder)) }
            }
            return sidebar.list.row(forBookmark: favorite.id)
        }
        unfavoriteWithUndo(favorite.id, to: landing.index)
        let tabs = tabManager.tabs(in: space)
        return tabs.indices.contains(landing.index) ? sidebar.list.row(for: tabs[landing.index]) : nil
    }

    /// A pinned page carried over from another window's list: its open pages come along (one already open here stays
    /// instead), it lands among the pinned tabs or the tabs right where it was dropped, and this window comes forward.
    func takePinned(_ bookmarkID: UUID, from source: BrowserWindowController, at screenPoint: NSPoint) -> NSView? {
        let ids = Library.shared.pinnedSplit(containing: bookmarkID).map { [$0.left, $0.right] } ?? [bookmarkID]
        for id in ids {
            if tabManager.bookmarkTab(for: id) != nil {
                if let live = source.tabManager.bookmarkTab(for: id) { source.tabManager.close(live) }
            } else if let live = source.tabManager.detachBookmarkTab(id) {
                tabManager.insertBookmarkTab(live, bookmarkID: id)
            }
        }
        let landing = sidebar.list.dropTarget(at: screenPoint, allowsPinned: true)
        let space = tabManager.currentSpaceID
        window?.makeKeyAndOrderFront(nil)
        if landing.section == .bookmarks {
            pageChange(String(localized: "Move Pinned Tab", comment: "Undo action name, shown in the Edit menu as Undo Move Pinned Tab.")) { Library.shared.moveBookmark(bookmarkID, to: landing.index, in: space, folder: .some(landing.folder)) }
            return sidebar.list.row(forBookmark: bookmarkID)
        }
        pageChange(String(localized: "Unpin Tab", comment: "Undo action name, shown in the Edit menu as Undo Unpin Tab.")) { [tabManager] in
            // Into this space first, so it comes down among the tabs you're looking at.
            Library.shared.moveBookmark(bookmarkID, to: Int.max, in: space)
            tabManager.unbookmark(bookmarkID, toIndex: landing.index)
        }
        let tabs = tabManager.tabs(in: space)
        return tabs.indices.contains(landing.index) ? sidebar.list.row(for: tabs[landing.index]) : nil
    }

    /// A favorite carried over from another window's Favorites: its open pages come along (one already open here
    /// stays instead), it lands as it would from this window's own, and this window comes forward.
    func takeFavorite(_ favorite: Bookmark, from source: BrowserWindowController, at screenPoint: NSPoint) -> NSView? {
        let ids = Library.shared.favoriteSplits.first { $0.contains(favorite.id) }.map { [$0.left, $0.right] } ?? [favorite.id]
        for id in ids {
            if tabManager.bookmarkTab(for: id) != nil {
                if let live = source.tabManager.bookmarkTab(for: id) { source.tabManager.close(live) }
            } else if let live = source.tabManager.detachBookmarkTab(id) {
                tabManager.insertBookmarkTab(live, bookmarkID: id)
            }
        }
        let row = dropFavorite(favorite, at: screenPoint)
        window?.makeKeyAndOrderFront(nil)
        return row
    }

    private func reloadFavorites() {
        // The tiles are the profile's of the space you're in.
        let favorites = Library.shared.favorites(in: tabManager.profile.id)
        let open = Set(favorites.map(\.id).filter { tabManager.bookmarkTab(for: $0) != nil })
        let tabs = Dictionary(uniqueKeysWithValues: favorites.compactMap { favorite in tabManager.bookmarkTab(for: favorite.id).map { (favorite.id, $0) } })
        sidebar.favorites.reload(favorites: Library.shared.favoriteTiles(in: tabManager.profile.id), openIDs: open, selectedID: tabManager.selectedTab?.isFavorite == true ? tabManager.selectedTab?.bookmarkID : nil, tabs: tabs)
        sidebar.needsLayout = true
    }

    private func libraryChanged() {
        // The list and favorites reload once already: the tab manager hears the same change first and sends
        // `.structure` (`tabManagerChanged`).
        applySpaceColor(animated: true)
        sidebar.reloadSpaces(current: tabManager.currentSpaceID)
    }

    private func historyMenu(back: Bool) -> NSMenu? {
        guard let webView = selectedWebView else { return nil }
        let list = webView.backForwardList
        let items = back ? Array(list.backList.reversed()) : list.forwardList
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items.prefix(15) {
            let title = item.title?.isEmpty == false ? item.title! : (item.url.host() ?? item.url.absoluteString)
            let entry = SidebarMenus.Item(String(title.prefix(60))) { [weak webView] in
                if let owner = (webView as? BrowserWebView)?.owner { owner.go(to: item) } else { webView?.go(to: item) }
            }
            if let icon = FaviconStore.shared.cachedIcon(for: item.url) {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                entry.image = small
            }
            menu.addItem(entry)
        }
        return menu
    }

    /// Opens the space panel beside the sidebar (or closes it, if it's already showing that space).
    func openSpaceEditor(_ spaceID: UUID, anchor: NSView? = nil) {
        if !root.sidebarVisible && !root.isSidebarFloatingVisible { root.reveal(true) }
        previews.hide()
        SpaceEditorPanel.toggle(spaceID: spaceID, anchor: anchor, in: self)
    }

    /// While anything is being dragged in the space editor: the window shows that version of the space, unsaved.
    func previewSpace(_ draft: SpaceInfo) {
        sidebar.previewDotColor(draft.swatch, for: draft.id)
        guard draft.id == tabManager.currentSpaceID, !tabManager.isPrivate else { return }
        render(draft, animated: false)
    }

    @objc private func displayOptionsChanged() { applySpaceColor(animated: false) }

    /// Settings › Appearance › Address bar above the page: the sidebar's own back, forward, reload and address move
    /// to the bar above the page, or back. The same views, so everything that hangs from them follows; what was open
    /// from them is put away first. At once: a setting you change, not a layout you watch.
    @objc func placeAddress() {
        let above = BrowserRootView.addressAbovePage
        guard sidebar.holdsAddress == above else { return }
        if window?.isVisible == true { closeFloatingPanels() }
        sidebar.holdsAddress = !above
        if above { root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address) }
        root.barHoldsAddress = above
        showTopBar()
    }

    /// Settings › Appearance › Sidebar on the right, or View › Move Sidebar to Right: the sidebar slides over to the
    /// other edge and the pages glide the other way. What was open beside the sidebar is put away first.
    @objc func placeSidebarSide() {
        let onRight = BrowserRootView.sidebarOnRight
        guard root.sidebarOnRight != onRight else { return }
        let shown = window?.isVisible == true
        if shown { closeFloatingPanels() }
        previews.hide()
        hideFloatingDownloads()
        switchingSides = true
        root.setSidebarOnRight(onRight, animated: shown)
        switchingSides = false
        layoutTrafficLights()
    }

    /// While the sidebar changes sides: the lights' room in its row follows at once, with no picture riding over.
    private var switchingSides = false

    /// Handoff, as in Safari: the web page you're on, offered to your iPhone, iPad or other Mac. Never a private
    /// window's, and never Zigzag's own pages or a local file.
    private func updateHandoff() {
        guard !tabManager.isPrivate, let url = tabManager.selectedTab?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            handoff?.invalidate()
            handoff = nil
            return
        }
        if handoff == nil { handoff = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb) }
        handoff?.webpageURL = url
        handoff?.title = tabManager.selectedTab?.displayTitle
        if window?.isKeyWindow == true { handoff?.becomeCurrent() }
    }

    private func applySpaceColor(animated: Bool, crossFadesMode: Bool = true) {
        lastSpaceID = tabManager.currentSpaceID
        render(tabManager.currentSpace, animated: animated, crossFadesMode: crossFadesMode)
    }

    /// Draws the window for a space: its mode, color, gradient, how see-through it is, and grain.
    private func render(_ space: SpaceInfo, animated: Bool, crossFadesMode: Bool = true) {
        let (color, end) = root.paint(space, isPrivate: tabManager.isPrivate, animated: animated, crossFadesMode: crossFadesMode)
        root.sidebarContainer.tint = color
        root.sidebarContainer.gradient = end.map { ($0, space.gradientAngle) }
        root.sidebarContainer.grain = tabManager.isPrivate ? 0 : space.grain ?? 0
    }

    private func showSelectedTab() {
        previews.hide()
        let tab = tabManager.selectedTab
        // The site panel describes one page; another tab coming forward takes it away.
        if SitePanel.isOpen(in: window), SitePanel.shown?.describes(tab) == false { SitePanel.closeCurrent() }
        updateHandoff()
        if tab !== shownTab {
            // A peek is a look from the page you were on: going to another tab or space puts it away.
            peek.close()
            // Reader stays over its pane when you click into the other half of the split; anywhere else, it goes.
            let readerStillShown = readerTab != nil && (tab.map { tabManager.partners(of: $0) } ?? []).contains { $0 === readerTab }
            if !readerStillShown { closeReader() }
            // A video playing in a page you're leaving follows you in the mini player; coming back puts it in its page.
            let before = root.paneCards.enumerated().compactMap { i, card in i == 0 || !card.isHidden ? card.webView : nil }
                .compactMap { ($0 as? BrowserWebView)?.owner }
            miniPlayer.switched(from: before, to: tab.map { tabManager.panes(of: $0) } ?? [])
            shownTab = tab
            selectedTabToken = tab?.changed.observe { [weak self] change in self?.selectedTabChanged(change) }
            if let webView = tab?.ensureWebView(), window?.isKeyWindow == true, !commandBar.isVisible {
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(webView) }
            }
        }
        showPages()
        // Shown in a pane some other way (split beside the page you're on): the mini player lets it go.
        miniPlayer.tabsChanged()
        sidebar.update(tab: tab)
        paintTopBar()
        // A collapsed pinned section shows the pinned page you're on, so it changes with the selection.
        if SidebarListView.isCollapsed(tabManager.currentSpaceID) { sidebar.list.reload(animated: true) } else { sidebar.list.refreshRows() }
        reloadFavorites()
        sidebar.address.setCapture(camera: tab?.isUsingCamera ?? false, microphone: tab?.isUsingMicrophone ?? false)
        updateWindowTitle()
        refreshExtensionActions()
        updateNowPlaying()
        offerWebStoreExtension()
        updateReaderButton()
        findBar.pageChanged()
    }

    /// What the profile you're in decided about its extensions: the menus and the pins by the address are about those.
    private var installs: ExtensionInstalls { tabManager.profile.installs }

    /// Where an extension may read and change pages, Chrome's three choices.
    private func siteAccessItem(for id: String) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Site Access", comment: "Submenu of an extension's menu: which sites the extension may read and change."), action: nil, keyEquivalent: "")
        item.image = Tokens.Symbol.image("globe")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let installs = installs
        let access = installs.siteAccess(id)
        let tab = tabManager.selectedTab
        let site = ContentBlocker.site(of: tab?.url)
        let all = SidebarMenus.Item(String(localized: "On All Sites", comment: "Site Access choice: the extension works on every site.")) { installs.setSiteAccess(id, .all); tab?.reload() }
        all.state = access == .all ? .on : .off
        let click = SidebarMenus.Item(String(localized: "When You Click It", comment: "Site Access choice: the extension works on a site only after its button is clicked.")) { installs.setSiteAccess(id, .click, sites: []); tab?.reload() }
        click.state = access == .click ? .on : .off
        menu.addItem(all)
        menu.addItem(click)
        if let site {
            let sites = access == .sites ? installs.accessSites(id) : []
            let listed = sites.contains(site)
            let only = SidebarMenus.Item(access == .sites ? String(localized: "On \(site)", comment: "Site Access choice: the extension works on this site, one of the sites listed for it. The site is a domain.")
                                                                 : String(localized: "Only on \(site)", comment: "Site Access choice: the extension works only on this site. The site is a domain.")) {
                let next = listed ? sites.filter { $0 != site } : sites + [site]
                installs.setSiteAccess(id, .sites, sites: next)
                tab?.reload()
            }
            only.state = listed ? .on : .off
            menu.addItem(.separator())
            menu.addItem(only)
            if access == .sites {
                for other in sites where other != site {
                    let entry = SidebarMenus.Item(String(localized: "On \(other)", comment: "Site Access choice: the extension works on this site, one of the sites listed for it. The site is a domain.")) { installs.setSiteAccess(id, .sites, sites: sites.filter { $0 != other }) }
                    entry.state = .on
                    menu.addItem(entry)
                }
            }
        }
        item.submenu = menu
        return item
    }

    /// What you can change for the site you're on: right-click the address.
    /// Clearing can't be taken back, so it asks first, even for the cache, which only costs a slower first load.
    func confirmClearCache() {
        // The profile you're in when you ask; a private window's own store.
        let store = tabManager.privateStore ?? tabManager.profile.store
        let only = ProfileSheets.onlyNote(tabManager.isPrivate ? nil : tabManager.profile.id)
        ConfirmSheet.show(in: root.overlay, title: String(localized: "Clear the cache for every site?", comment: "Title of the sheet that asks before clearing every site's cache."),
                          message: Words.sentences(String(localized: "Pages load a little slower the first time you open them again. You stay signed in.", comment: "Message of the sheet that asks before clearing every site's cache."), only),
                          confirmTitle: String(localized: "Clear Cache", comment: "Button that clears the cache, in the sheet that asks first."), destructive: false) { [weak self] confirmed in
            guard confirmed else { return }
            Task { @MainActor in
                await WebsiteData.clear(.cache, in: store)
                if let self { Toast.show(String(localized: "Cache cleared", comment: "Toast after every site's cache is cleared."), symbol: "arrow.clockwise", duration: 2, in: self) }
            }
        }
    }

    /// Signing out of every site is a big step, so it asks first.
    func confirmClearCookies() {
        // The profile you're in when you ask; a private window's own store.
        let store = tabManager.privateStore ?? tabManager.profile.store
        let only = ProfileSheets.onlyNote(tabManager.isPrivate ? nil : tabManager.profile.id)
        ConfirmSheet.show(in: root.overlay, title: String(localized: "Clear cookies for every site?", comment: "Title of the sheet that asks before clearing every site's cookies."),
                          message: Words.sentences(String(localized: "You’ll be signed out of every site. Your passwords, pinned tabs and history stay.", comment: "Message of the sheet that asks before clearing every site's cookies."), only),
                          confirmTitle: String(localized: "Clear Cookies", comment: "Button that clears cookies, in the sheet that asks first."), destructive: true) { [weak self] confirmed in
            guard confirmed else { return }
            Task { @MainActor in
                await WebsiteData.clear(.cookies, in: store)
                self?.tabManager.selectedTab?.reload()
                if let self { Toast.show(String(localized: "Cookies cleared. You’re signed out everywhere.", comment: "Toast after every site's cookies are cleared."), symbol: "trash", duration: 2.4, in: self) }
            }
        }
    }

    /// Clears one site's cache or cookies, then loads its page again: from Site Controls' ⋯ menu, View › Developer
    /// and the command bar, which all ask the same way. Only a web site has a cache and cookies of its own.
    func confirmClear(_ kind: WebsiteData.Kind, of tab: Tab) {
        guard let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let site = ContentBlocker.site(of: url) else { return }
        let cookies = kind == .cookies
        let message = cookies ? String(localized: "You’ll be signed out of \(site). Other sites aren’t touched.", comment: "Message of the sheet that asks before clearing one site's cookies.")
                              : String(localized: "It loads a little slower the first time. You stay signed in.", comment: "Message of the sheet that asks before clearing one site's cache.")
        ConfirmSheet.show(in: root.overlay,
                          title: cookies ? String(localized: "Clear cookies for \(site)?", comment: "Title of the sheet that asks before clearing one site's cookies. The site is a domain, like example.com.")
                                         : String(localized: "Clear the cache for \(site)?", comment: "Title of the sheet that asks before clearing one site's cache. The site is a domain, like example.com."),
                          message: Words.sentences(message, tab.isDevelopment ? Self.everyPortNote(for: url, site: site) : nil),
                          confirmTitle: cookies ? String(localized: "Clear Cookies", comment: "Button that clears cookies, in the sheet that asks first.")
                                                : String(localized: "Clear Cache", comment: "Button that clears the cache, in the sheet that asks first."), destructive: cookies) { [weak self, weak tab] confirmed in
            guard confirmed, let tab else { return }
            Task { @MainActor [weak self] in
                await WebsiteData.clear(kind, site: site, in: tab.privateStore ?? tab.profile.store)
                tab.reload()
                if let self { Toast.show(kind == .cache ? String(localized: "Cache cleared for \(site)", comment: "Toast after one site's cache is cleared. The site is a domain, like example.com.")
                                                        : String(localized: "Cookies cleared for \(site)", comment: "Toast after one site's cookies are cleared. The site is a domain, like example.com."),
                                         symbol: "checkmark.circle", in: self) }
            }
        }
    }

    /// Added to that sheet on a development tab whose address has a port of its own (a development server): what
    /// a site keeps is kept for its host, so clearing localhost:3000 clears every other project on localhost too.
    /// `site`: the site as the sheet names it.
    static func everyPortNote(for url: URL, site: String) -> String? {
        guard let port = url.port, port != (url.scheme?.lowercased() == "https" ? 443 : 80) else { return nil }
        return String(localized: "That’s every port of \(site), not only \(String(port)).", comment: "Added to the message of the sheet that asks before clearing one site's cache or cookies, on a development site whose address has a port, like localhost:3000. The first placeholder is the site, the second the port's number.")
    }

    private var offeredExtensionID: String?

    /// On an extension's Chrome Web Store page, offers to add it to Zigzag (the store's own button only works in Chrome).
    private func offerWebStoreExtension() {
        guard #available(macOS 15.4, *) else { return }
        let id = ExtensionStore.webStoreID(from: tabManager.selectedTab?.url)
        guard id != offeredExtensionID else { return }
        if offeredExtensionID != nil { WebStoreOffer.hide() }
        offeredExtensionID = id
        guard let id, !installs.isInstalled(id) else { return }
        // Shown once the page has its title, so the bar can name the extension, and only where the store's own
        // button hasn't taken over (WebStoreButton): the bar stays for a store page that no longer asks it.
        DispatchQueue.main.asyncAfter(deadline: .now() + WebStoreButton.grace) { [weak self] in
            guard let self, self.offeredExtensionID == id, !WebStoreButton.isEngaged(self.selectedWebView, for: id) else { return }
            WebStoreOffer.show(id, in: self)
        }
    }

    /// The store's own button asked about the listing on screen: the bar over it steps aside.
    func webStoreButtonTookOver(_ id: String) {
        guard offeredExtensionID == id else { return }
        WebStoreOffer.hide()
    }

    /// The store's own button: Zigzag's usual download, review sheet and toasts, then whether it went in.
    func installExtensionFromStore(_ id: String) async -> Bool {
        await withCheckedContinuation { done in
            var finished = false
            installExtension(id, also: { stage in
                guard !finished else { return }
                switch stage {
                case .added: finished = true; done.resume(returning: true)
                case .failed, .cancelled: finished = true; done.resume(returning: false)
                case .downloading, .reviewing, .adding: break
                }
            })
        }
    }

    /// Adding from the store: verify the package, show what it can do, install only once confirmed.
    enum InstallStage {
        case downloading, reviewing, adding, added(String), failed(String), cancelled
        var isReviewing: Bool { if case .reviewing = self { true } else { false } }
    }

    /// Adding from the store: verify the package, show what it can do, install only once confirmed. `progress`
    /// hears each stage (the store bar shows them); without it, toasts do.
    /// `also` hears each stage beside the toasts (the store's own button waits on it).
    func installExtension(_ id: String, progress: ((InstallStage) -> Void)? = nil, also: ((InstallStage) -> Void)? = nil) {
        guard #available(macOS 15.4, *) else { also?(.failed("")); return }
        // The profile you were in when you asked: it's added there, wherever you are by the time it's ready.
        let profile = tabManager.profile
        let report: (InstallStage) -> Void = { [weak self] stage in
            also?(stage)
            if let progress { progress(stage); return }
            guard let self else { return }
            switch stage {
            case .downloading: Toast.show(String(localized: "Downloading extension…", comment: "Toast while an extension downloads from the Chrome Web Store."), symbol: "arrow.down.circle", duration: 3600, in: self)
            case .reviewing, .cancelled: Toast.hide(in: self)
            case .adding: Toast.show(String(localized: "Adding…", comment: "Toast while an extension is being added."), symbol: "arrow.down.circle", duration: 3600, in: self)
            case .added(let name): Toast.show(String(localized: "Added \(name)", comment: "Toast after an extension is added. The name is the extension's."), symbol: "checkmark.circle", duration: 2, in: self)
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
                    title: info.displayName.map { String(localized: "Add \($0)?", comment: "Title of the sheet that asks before adding an extension. The name is the extension's.") }
                        ?? String(localized: "Add this extension?", comment: "Title of the sheet that asks before adding an extension that has no name."),
                    subtitle: String(localized: "Version \(prepared.version), from the Chrome Web Store", comment: "Under the title of the sheet that asks before adding an extension."),
                    heading: String(localized: "It will be able to", comment: "Heading over the list of what an extension can do, in the sheet that asks before adding it."),
                    report: prepared.report,
                    confirm: String(localized: "Add Extension", comment: "Button that adds the extension, in the sheet that asks first."),
                    cancel: String(localized: "Cancel", comment: "Button that closes a sheet without doing anything."))
                // With more than one profile, the sheet says which it's added to, and lets you choose another.
                let profiles = Library.shared.profiles
                var asked = content
                if profiles.count > 1 {
                    asked.destination = ExtensionSheet.Destination(
                        label: String(localized: "Add to", comment: "Label in the sheet that asks before adding an extension, before the choice of the profile it's added to."),
                        options: ProfileChoice.options(profiles),
                        selected: profiles.firstIndex { $0.id == profile.id } ?? 0)
                }
                var sheet: ExtensionSheet?
                sheet = ExtensionSheet.present(asked, in: self, onConfirm: {
                    let chosen = sheet.map { $0.destinationIndex }.flatMap { profiles.indices.contains($0) ? profiles[$0] : nil }
                    // The profile chosen, held while the extension goes into it so it isn't removed meanwhile. One
                    // removed while the sheet was up gets nothing: never the first profile in its place.
                    guard let profile = Profiles.shared.listed(profiles.count > 1 ? chosen?.id ?? profile.id : profile.id),
                          Profiles.shared.hold(profile.id) else {
                        ExtensionStore.discard(prepared)
                        report(.failed(String(localized: "The profile this was going to has been deleted. Nothing was added.", comment: "Toast when the profile chosen in the sheet that adds an extension was deleted before the extension went in.")))
                        return
                    }
                    report(.adding)
                    Task {
                        defer { Profiles.shared.done(profile.id) }
                        switch await ExtensionStore.finishInstall(prepared, in: profile) {
                        case .success(let name):
                            report(.added(name))
                            // After the store bar has gone, when it's up, so the two never sit on each other.
                            DispatchQueue.main.asyncAfter(deadline: .now() + (progress == nil ? 1.5 : 3.4)) { [weak controller = self] in controller?.offerSearchEngine(of: id) }
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


    /// An extension just added that gives a search engine ("ChatGPT search"): asked, never switched to behind your
    /// back. Not now, it stays one of the engines in Settings.
    private func offerSearchEngine(of id: String) {
        guard let provider = ExtensionSearchProvider.provider(for: id), !ExtensionSearchProvider.isChosen(id) else { return }
        Toast.show(String(localized: "\(provider.name) can be your search engine", comment: "Toast after adding an extension that gives a search engine. The name is the engine's, like ChatGPT."),
                   symbol: "magnifyingglass",
                   action: (String(localized: "Use", comment: "Button in the toast offering an extension's search engine: makes it the one Zigzag searches with."), { ExtensionSearchProvider.use(provider) }),
                   duration: 10, closes: true, in: self)
    }

    /// An update that wants more access waits for this.
    func reviewExtensionUpdate(_ id: String) {
        guard #available(macOS 15.4, *) else { return }
        Task { [weak self] in
            guard let (info, report) = await ExtensionStore.pendingUpdateReport(id), let self else { return }
            let content = ExtensionSheet.Content(
                icon: info.icon(for: NSSize(width: 40, height: 40)),
                title: info.displayName.map { String(localized: "\($0) wants more access", comment: "Title of the sheet shown when an extension's update asks for more access. The name is the extension's.") }
                    ?? String(localized: "This extension wants more access", comment: "Title of the sheet shown when an update of an extension with no name asks for more access."),
                subtitle: info.version.map { String(localized: "Version \($0) is ready. Until you allow it, the current version keeps running.", comment: "Under the title of the sheet shown when an extension's update asks for more access.") }
                    ?? String(localized: "An update is ready. Until you allow it, the current version keeps running.", comment: "Under the title of the sheet shown when an extension's update asks for more access, when the update has no version."),
                heading: String(localized: "It would also be able to", comment: "Heading over the list of what an extension's update could also do."),
                report: report,
                confirm: String(localized: "Allow and Update", comment: "Button that allows an extension's update its new access."),
                cancel: String(localized: "Not Now", comment: "Button that leaves an extension's update waiting."))
            ExtensionSheet.present(content, in: self, onConfirm: {
                Task { await ExtensionStore.approvePendingUpdate(id) }
            })
        }
    }

    private weak var nowPlayingTab: Tab?

    /// The pane enlarged over the others for a moment, if any (#160).
    private(set) var paneZoom = PaneZoom()
    /// The split's pages, shape and zoomed pane as last shown, to tell when the panes move (`showPages`).
    private var shownPaneLayout = ""
    private var zoomEscMonitor: Any?

    /// Zooms `tab`'s pane over the rest of its split or group, or puts it back if it's the one zoomed. Zoomed, it's
    /// the pane you're in.
    func toggleZoom(_ tab: Tab) {
        guard let pair = tabManager.split(for: tab) else { return }
        paneZoom.toggle(tab.id, in: pair.ids, places: pair.shape.regions)
        if paneZoom.isZoomed, tabManager.selectedTab !== tab { tabManager.select(tab) } else { showPages() }
        if paneZoom.isZoomed, let webView = tab.webView { window?.makeFirstResponder(webView) }
    }

    /// Puts the zoomed pane back, if one is.
    func unzoomPane() {
        guard paneZoom.isZoomed else { return }
        paneZoom.clear()
        showPages()
    }

    /// While a pane is zoomed, Esc puts it back, as it puts Peek away; other keys go to the page as usual.
    private func refreshZoomEsc() {
        if paneZoom.isZoomed, zoomEscMonitor == nil {
            zoomEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.paneZoom.isZoomed, event.keyCode == 53, event.window === self.window,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !(self.window?.firstResponder is NSText), self.peekController?.isVisible != true else { return event }
                self.unzoomPane()
                return nil
            }
        } else if !paneZoom.isZoomed, let monitor = zoomEscMonitor {
            NSEvent.removeMonitor(monitor)
            zoomEscMonitor = nil
        }
    }

    /// The developer tools' buttons (#141), in the bar above the page of a development tab shown on its own.
    private lazy var developerBarTools: DeveloperBarTools = {
        let tools = DeveloperBarTools()
        // It says the size the page really is, which the card knows.
        root.card.onPageArea = { [weak tools] area in tools?.pageRoom = area }
        tools.pageRoom = root.card.pageArea
        return tools
    }()

    /// Gives the page you're on its developer tools in the bar above it, or takes them away: a development tab, on
    /// its own. With the address kept in the sidebar, the bar comes for them alone.
    private func showDeveloperBarTools() {
        let tab = tabManager.selectedTab
        showPageSize()
        let shows = showsDeveloperBarTools(for: tab)
        // Never made for a window that has no use for it.
        let had = root.topBar.accessory != nil
        guard shows || had else { return }
        root.topBar.accessory = shows ? developerBarTools : nil
        developerBarTools.show(shows ? tab : nil, in: self)
        if shows != had { showTopBar() }
    }

    /// The bar above the page is there while it holds the address (Settings › Appearance) or a page's own tools.
    /// The address and the sidebar's rows are where the setting puts them either way: nothing in the sidebar moves
    /// for a bar that's there for the tools alone.
    private func showTopBar() {
        root.showsTopBar = root.barHoldsAddress || root.topBar.accessory != nil
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        layoutTrafficLights()
        paintTopBar()
    }

    /// Gives the page you're on the size chosen for it with the developer tools, or its room back. A page's own
    /// size is for a page shown on its own: a split's panes share the window as they are.
    private func showPageSize() {
        let tab = tabManager.selectedTab
        let size = tab.flatMap { tabManager.split(for: $0) } == nil ? tab?.developerInEffect.size : nil
        guard root.card.pageSize != size else { return }
        root.card.pageSize = size
        paintTopBar()
    }

    /// Whether a tab has the tools in the bar above its page: Site Controls shows them where it doesn’t.
    func showsDeveloperBarTools(for tab: Tab?) -> Bool {
        DeveloperBarTools.shows(isDevelopment: tab?.isDevelopment == true, showsInBar: DeveloperTools.showsInBar,
                             inSplit: tab.flatMap { tabManager.split(for: $0) } != nil)
    }

    /// Puts the selected tab in the page card, or the pages of its split or tile group side by side, each in a card.
    private func showPages() {
        // Before the page goes on its card, so it never takes the size of the page that was there.
        showPageSize()
        defer { showDeveloperBarTools() }
        // A link address belongs to the page it was pointed at in: a different page, a different space, it goes.
        linkStatus.show(nil, in: root.cardFrame)
        let tab = tabManager.selectedTab
        let pair = tab.flatMap { tabManager.split(for: $0) }
        let pages = pair.map { $0.ids.compactMap { tabManager.tab(with: $0) } } ?? []
        let cards = root.paneCards
        // The zoom lasts while its group is on screen as it was; anything else (a swap, a move, another layout) puts
        // the pane back.
        // Going to another pane of it (a click on its part of the row) puts the zoomed one back too.
        if paneZoom.isZoomed, paneZoom.tabID != tab?.id { paneZoom.clear() }
        let zoomed = paneZoom.index(in: pages.count == pair?.count ? pair?.ids : nil, places: pair?.shape.regions)
        // Site Controls opened from a pane's strip sits under it: when the panes move (the split parts, a pane goes,
        // swaps or zooms), it would be left over nothing.
        let layout = pages.count == pair?.count ? "\(pair?.ids ?? []) \(String(describing: pair?.shape)) \(zoomed ?? -1)" : ""
        if layout != shownPaneLayout {
            shownPaneLayout = layout
            if SitePanel.isOpen(in: window), SitePanel.shown?.isFromPane == true { SitePanel.closeCurrent() }
        }
        defer {
            refreshZoomEsc()
            sidebar.list.zoomedTabID = paneZoom.tabID
        }
        if let tab, let pair, pages.count == pair.count {
            root.setTiles(pair.shape, animated: true)
            root.setZoomedPane(zoomed, animated: true)
            root.isEmpty = false
            let first = pages[0]
            for (i, card) in cards.enumerated() {
                guard pages.indices.contains(i) else { clear(card); continue }
                let page = pages[i]
                // Swap and the layout are a split of two's; a tile group's pages keep the places they were dropped in.
                card.header.arrangesSplit = !pair.isGroup
                card.header.setVertical(pair.vertical)
                card.header.orientation.onClick = { [weak self] _ in self?.tabManager.toggleSplitOrientation(for: first) }
                card.header.swap.onClick = { [weak self] _ in self?.tabManager.swapSplit(for: first) }
                card.show(page.ensureWebView())
                // Any page may have crashed while out of sight (a space switch brings it back, not only selecting it).
                page.reloadIfItStopped()
                card.isFocusedPane = page === tab
                card.isUnfocusedPane = page !== tab
                card.showsHeader = true
                // Each pane's header, line and address are its own page's, whichever of them you're in.
                card.header.show(page)
                card.showLoading(of: page)
                // A split of two ends showing the other page; a tile group's pages part, this one shown.
                let keep = pair.isGroup ? page : pages[i == 0 ? 1 : 0]
                card.header.close.onClick = { [weak self] _ in self?.unsplitWithUndo(page, keep: keep) }
                card.header.closeTab.onClick = { [weak self] _ in self?.closeWithUndo(page) }
                card.header.isZoomed = i == zoomed
                card.header.zoom.onClick = { [weak self] _ in self?.toggleZoom(page) }
                // Pressed and dragged, the strip carries its pane somewhere else (#160).
                card.header.onDrag = { [weak self] tab, press, moved in self?.dragPane(tab, press: press, moved: moved) }
                card.header.onEditAddress = { [weak self, weak card] tab in
                    guard let self, let card else { return }
                    self.editAddress(of: tab, from: card.header.address)
                }
                card.header.onSiteControls = { [weak self] tab, anchor in self?.showSiteControls(for: tab, from: anchor) }
            }
        } else {
            root.setZoomedPane(nil, animated: false)
            root.setTiles(nil, animated: true)
            root.isEmpty = tab == nil
            root.card.show(tab?.ensureWebView())
            tab?.reloadIfItStopped()
            root.card.showLoading(of: tab)
            root.card.isFocusedPane = false
            root.card.isUnfocusedPane = false
            root.card.showsHeader = false
            cards.dropFirst().forEach(clear)
        }
        func clear(_ card: PageCardView) {
            card.show(nil)
            card.showLoading(of: nil)
            card.header.show(nil)
            card.isFocusedPane = false
            card.isUnfocusedPane = false
            card.showsHeader = false
        }
    }

    // MARK: Downloads with the sidebar hidden

    /// With the sidebar hidden, its Downloads button stands in on its own, in the same bottom-left corner: a download
    /// flies into it and the panel opens above it, exactly as with the sidebar out. It goes once the panel closes.
    private(set) lazy var floatingDownloads: FloatingPanelView = {
        // A round glass button, the button filling it so its hover is the same circle.
        let chip = FloatingPanelView()
        chip.radius = Tokens.Metric.floatingButton / 2
        let button = IconButton(symbol: "arrow.down.circle", size: Tokens.Metric.floatingButton, symbolSize: Tokens.Symbol.glyph, toolTip: String(localized: "Downloads", comment: "Tooltip of the floating downloads button, shown while the sidebar is hidden."))
        button.onClick = { [weak self] _ in self?.showDownloads(nil) }
        chip.addSubview(button)
        chip.onLayout = { [weak chip, weak button] in
            guard let chip, let button else { return }
            button.frame = chip.bounds
            button.radius = chip.bounds.height / 2
        }
        return chip
    }()

    var floatingDownloadsButton: NSView { floatingDownloads.subviews.first ?? floatingDownloads }

    /// Shows the stand-in Downloads button where the sidebar's would be, if the sidebar is hidden.
    func showFloatingDownloads() {
        guard !(root.sidebarVisible || root.isSidebarFloatingVisible) else { return }
        let side = Tokens.Metric.floatingButton
        let inset = Tokens.Metric.sidebarPadding
        // In the sidebar's bottom corner, the left or the right one.
        let x = root.sidebarOnRight ? root.overlay.bounds.width - side - inset : inset
        floatingDownloads.frame = NSRect(x: x, y: root.overlay.bounds.height - side - inset, width: side, height: side)
        // With its shortcut, as the sidebar's Downloads button says it.
        (floatingDownloadsButton as? IconButton)?.toolTip = Shortcuts.tooltip(String(localized: "Downloads", comment: "Tooltip of the floating downloads button, shown while the sidebar is hidden."),
                                                                             for: #selector(showDownloads(_:)))
        guard floatingDownloads.superview == nil else { return }
        root.overlay.addSubview(floatingDownloads)
        floatingDownloads.growsFrom = CGPoint(x: 0.5, y: 0.5)
        floatingDownloads.present(arrival: .pop)
    }

    /// The panel closed, or the sidebar came back: the stand-in steps away.
    func hideFloatingDownloads() {
        guard floatingDownloads.superview != nil, !DownloadsPanel.isOpen(in: window) else { return }
        floatingDownloads.dismiss()
    }

    /// The bar above the page in the shown page's color (`Tab.pageColor`). None over what covers the page (a PDF,
    /// Settings, Reader), which has a color of its own: the bar is the plain one then.
    private func paintTopBar() {
        let covered = reader != nil && readerCard === root.card
        // The card's own word on its page's color: a page at a size of its own stands on plain ground, bar included.
        root.paintTopBar(covered ? nil : root.card.pageColor)
    }

    /// Where popovers that belong to the address bar (extension popups) open from: the address bar while the sidebar
    /// shows, or the top left of the page while it's hidden, so they never open off screen.
    var addressAnchor: (view: NSView, rect: NSRect) {
        // In split view the panes' strips stand in for the bar's address: from the address of the pane you're in.
        if root.stripsInBar {
            let address = focusedPaneAddress
            if !address.isHidden { return (address, address.bounds) }
            let pane = focusedPaneFrame
            return (root.overlay, NSRect(x: pane.minX + Tokens.Space.x3, y: pane.minY + Tokens.Space.x2, width: 1, height: 1))
        }
        // Above the page, from the address's end, where the Site Controls and the extensions are.
        if root.showsTopBar {
            let button = sidebar.address.siteControlsButton
            return (button, button.bounds)
        }
        if root.sidebarVisible || root.isSidebarFloatingVisible { return (sidebar.address, sidebar.address.bounds) }
        let card = root.cardFrame
        return (root.overlay, NSRect(x: card.minX + Tokens.Space.x3, y: card.minY + Tokens.Space.x2, width: 1, height: 1))
    }

    /// Where a popup opens from: under its pinned button when it was opened from one still showing, otherwise
    /// `addressAnchor`. `id` nil for any other popup.
    func popupAnchor(forPin id: String?) -> (view: NSView, rect: NSRect) {
        guard let id, root.sidebarVisible || root.isSidebarFloatingVisible, sidebar.address.visiblePinIDs.contains(id),
              let button = sidebar.address.pinButton(for: id) else { return addressAnchor }
        return (sidebar.address, button.frame)
    }

    private var popupHoldsSidebar: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return ExtensionCenter.holdsSidebar(in: window)
    }

    /// The address in the strip of the split pane you're in.
    var focusedPaneAddress: NSView { (root.paneCards.first { $0.isFocusedPane } ?? root.card).header.address }

    /// The page you're working in: the whole page area, or in split view the focused pane.
    var focusedPaneFrame: NSRect {
        guard let tab = tabManager.selectedTab, let pair = tabManager.split(for: tab), root.tiles != nil,
              let index = pair.ids.firstIndex(of: tab.id) else { return root.cardFrame }
        let frames = root.tileFrames
        return frames.indices.contains(index) ? frames[index] : frames[0]
    }

    /// A split pane's address clicked: that pane becomes the one you're in, and its address opens for editing right
    /// over the pill, as the sidebar's does for the page you're in.
    func editAddress(of tab: Tab, from anchor: NSView) {
        if tabManager.selectedTab !== tab { tabManager.select(tab) }
        commandBar.show(mode: .editCurrent, anchor: anchor)
    }

    /// Site Controls from a split pane's strip: that pane becomes the one you're in, and the panel is about its page,
    /// under its address (#160).
    func showSiteControls(for tab: Tab, from anchor: NSView) {
        if SitePanel.isOpen(in: window), SitePanel.shown?.describes(tab) == false { SitePanel.closeCurrent() }
        guard let page = tabManager.siteControlsTab(from: tab), page === tab else { return }
        SitePanel.toggle(in: self, from: anchor, tab: page)
    }

    /// In split view, clicking a pane makes its tab the one you're working in.
    func focusPane(at windowPoint: NSPoint) {
        guard let tab = tabManager.selectedTab, let pair = tabManager.split(for: tab) else { return }
        // A pane zoomed over the rest is the one you're in; a click beside it puts it back (the scrim's).
        guard !paneZoom.isZoomed else { return }
        // A pane's strip up in the bar above the page is that pane's too.
        let panes = root.tileTargets
        let point = root.convert(windowPoint, from: nil)
        // Clicks on what floats over the page (find, the command bar, a prompt) are for it, not the pane below.
        if let base = root.overlay.superview, root.overlay.hitTest(base.convert(windowPoint, from: nil)) != nil { return }
        guard let clickedID = Self.pane(at: point, frames: panes, ids: pair.ids, current: tab.id),
              let clicked = tabManager.tab(with: clickedID) else { return }
        tabManager.select(clicked)
    }

    /// The pane at a point of the page, when it isn't the one you're in already: the one to go to. Nil between panes,
    /// outside them, or on the pane you're in.
    nonisolated static func pane(at point: NSPoint, frames: [NSRect], ids: [UUID], current: UUID) -> UUID? {
        guard let index = frames.firstIndex(where: { $0.contains(point) }), ids.indices.contains(index) else { return nil }
        return ids[index] == current ? nil : ids[index]
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
    private let extensionActionRefresh = Coalescer()

    /// Draws the buttons again once for a burst of changes.
    private func scheduleExtensionActions(after delay: TimeInterval = 0) {
        extensionActionRefresh.schedule(after: delay) { [weak self] in self?.refreshExtensionActions() }
    }

    func refreshExtensionActions() {
        extensionActionRefresh.cancel()
        let tab = tabManager.selectedTab
        // Always there, even on a new tab: it's also where your extensions live.
        _ = tab?.url
        var attention = false
        var pins: [AddressView.Pin] = []
        var animated = false
        // Extensions don't run in a private window: no host, so nothing to show.
        if #available(macOS 15.4, *), let host = tab?.extensionHost ?? tabManager.extensionHost {
            attention = host.needsAttention(for: tab)
            pins = host.pinnedActions(for: tab).map { addressPin(for: $0, host: host) }
            animated = host.finishedLoading
        }
        sidebar.address.setSiteControls(needsAttention: attention)
        sidebar.address.setPins(pins, animated: animated)
    }

    @available(macOS 15.4, *)
    private func addressPin(for item: ExtensionHost.ActionItem, host: ExtensionHost) -> AddressView.Pin {
        AddressView.Pin(id: item.id, image: item.icon, label: item.label, badge: item.badge, needsAttention: item.attention != nil,
                               isActive: host.isPopupOnScreen(item.id, in: window),
                               action: { [weak self] button in
            guard let self else { return }
            if let press = button.currentPress, host.popupClosed(item.id, in: self.window, since: press) { return }
            host.performAction(item, tab: self.tabManager.selectedTab, in: self, fromPin: true)
        }, menu: { [weak self] in self?.extensionMenu(for: item.context) })
    }

    var isShowingReader: Bool { reader != nil }

    private func extensionsFooterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarMenus.Item(String(localized: "Manage Extensions…", comment: "Item at the bottom of the extensions menu: opens Settings › Extensions."), symbol: "puzzlepiece.extension") { [weak self] in
            if let self { SettingsPage.open(.extensions, in: self) }
        })
        menu.addItem(SidebarMenus.Item(String(localized: "Get Extensions…", comment: "Item at the bottom of the extensions menu: opens the Chrome Web Store."), symbol: "bag") { [weak self] in
            self?.tabManager.newTab(url: ExtensionStore.webStoreURL)
        })
        return menu
    }

    private func addPinItems(to menu: NSMenu, id: String) {
        let installs = installs
        let pinned = installs.pins.contains(id)
        let item = SidebarMenus.Item(pinned ? SitePanel.unpinTitle : SitePanel.pinTitle, symbol: pinned ? "pin.slash" : "pin") { installs.togglePin(id) }
        if !pinned, !installs.canPin(id) {
            item.isEnabled = false
            item.toolTip = SitePanel.pinLimitTip
        }
        menu.addItem(item)
        let visible = sidebar.address.visiblePinIDs
        guard visible.count > 1, let index = visible.firstIndex(of: id) else { return }
        menu.addItem(.separator())
        let left = SidebarMenus.Item(AddressView.moveLeftTitle, symbol: "arrow.left") { [weak self] in self?.sidebar.address.movePin(id, by: -1) }
        left.isEnabled = index > 0
        menu.addItem(left)
        let right = SidebarMenus.Item(AddressView.moveRightTitle, symbol: "arrow.right") { [weak self] in self?.sidebar.address.movePin(id, by: 1) }
        right.isEnabled = index < visible.count - 1
        menu.addItem(right)
        menu.addItem(.separator())
    }

    @available(macOS 15.4, *)
    func extensionMenu(for context: WKWebExtensionContext, footer: Bool = true) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let id = context.uniqueIdentifier
        let profile = tabManager.profile
        let installs = profile.installs
        let title = NSMenuItem(title: context.webExtension.displayName ?? String(localized: "Extension", comment: "Heading of an extension's menu when the extension has no name."), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let options = context.optionsPageURL {
            menu.addItem(SidebarMenus.Item(String(localized: "Settings", comment: "Item in an extension's menu: opens the extension's own settings page."), symbol: "gearshape") { [weak self] in
                self?.tabManager.newTab(url: options, title: context.webExtension.displayName)
            })
        }
        menu.addItem(siteAccessItem(for: id))
        addPinItems(to: menu, id: id)
        menu.addItem(SidebarMenus.Item(String(localized: "Turn Off", comment: "Item in an extension's menu: turns the extension off."), symbol: "pause.circle") { installs.setEnabled(id, false) })
        menu.addItem(SidebarMenus.Item(String(localized: "Remove from Zigzag…", comment: "Item in an extension's menu: removes the extension."), symbol: "trash") { [weak self] in
            guard let self else { return }
            ConfirmSheet.removeExtension(id: id, name: context.webExtension.displayName, from: profile, in: self.root.overlay)
        })
        guard footer else { return menu }
        menu.addItem(.separator())
        extensionsFooterMenu().items.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
        return menu
    }

    private func selectedTabChanged(_ change: Tab.Change) {
        guard let tab = shownTab else { return }
        // Each card shows its own page's load (`PageCardView.showLoading`); the sidebar follows the page you're in.
        switch change {
        case .url, .navigation, .loading:
            if change == .url {
                refreshExtensionActions()
                updateHandoff()
                // A pinned tab that moved on shows it right away.
                if tab.bookmarkID != nil { sidebar.list.refreshRows() }
            }
            sidebar.update(tab: tab)
            paintTopBar()
            updateWindowTitle()
            offerWebStoreExtension()
        case .title:
            updateWindowTitle()
        case .webView:
            showPages()
            paintTopBar()
        case .pdf, .settings:
            paintTopBar()
        case .developer:
            showDeveloperBarTools()
        case .capture:
            sidebar.address.setCapture(camera: tab.isUsingCamera, microphone: tab.isUsingMicrophone)
        case .reader:
            updateReaderButton()
        case .language:
            offerTranslation()
        case .themeColor, .darkPage:
            paintTopBar()
        default:
            break
        }
        // Reader belongs to the page it was opened on.
        if change == .url, readerTab === tab, tab.url != readerURL { closeReader() }
        // "Translating…" belongs to the page it was asked on: gone with it.
        if change == .url, translatingTab === tab { translatingTab = nil; Toast.hide(in: self) }
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
    /// The tab whose "Translating…" is showing; nil once it's answered, you've moved on, or it gave up.
    private weak var translatingTab: Tab?
    /// Which translation is the current one: an answer for an earlier one (after it gave up) changes nothing.
    private var translationAttempt = 0
    /// How long a translation may take before it says so instead of spinning on: Apple's translation can wait on
    /// a prompt that never comes up, or not answer at all.
    private static let translationTimeout: TimeInterval = 45

    private func offerTranslation() {
        guard let tab = tabManager.selectedTab, let language = tab.foreignLanguage, !tab.isTranslated,
              let site = ContentBlocker.site(of: tab.url) else { return }
        // Languages you always translate, and sites you translated a moment ago, translate on their own.
        if translatedSites.contains(site) || PageTranslator.translatesAlways(language) { translatePage(); return }
        guard PageTranslator.offers, !translationOffered.contains(site) else { return }
        translationOffered.insert(site)
        Toast.show(String(localized: "This page is in \(PageTranslator.name(of: language))", comment: "Toast offering to translate a page. The language is its name, like French."), symbol: "translate",
                   action: (title: String(localized: "Translate", comment: "Button in the toast that offers to translate a page."), run: { [weak self] in self?.translatePage() }), duration: 6, closes: true, in: self)
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
        // Read the page's language again now: what was seen as it loaded can be out of date (a site that changes
        // its page without loading a new one), and translating from the wrong language never finishes.
        // Still loading, there's too little text to tell yet: what was seen of it so far stands.
        Task { @MainActor [weak self] in
            let fresh = await PageTranslator.foreignLanguage(of: webView)
            let language = fresh ?? (webView.isLoading ? tab.foreignLanguage : nil)
            guard let self, self.tabManager.selectedTab === tab, tab.webView === webView else { return }
            guard let language else {
                Toast.show(String(localized: "This page is already in \(PageTranslator.name(of: PageTranslator.readerLanguage))", comment: "Toast when the page is already in the person's language. The language is its name, like English."), symbol: "translate", duration: 2, in: self)
                return
            }
            self.startTranslating(tab, webView: webView, from: language, site: site)
        }
    }

    /// No answer in time: it says it couldn't, and a late answer is let go. While macOS asks to download the
    /// language (its sheet on this window), it waits for you, however long that takes.
    private func watchTranslation(_ attempt: Int, of tab: Tab, name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.translationTimeout) { [weak self, weak tab] in
            guard let self, self.translationAttempt == attempt, let tab else { return }
            if self.window?.attachedSheet != nil {
                if self.translatingTab === tab {
                    Toast.show(String(localized: "Translating from \(name)…", comment: "Toast while a page is translated. The language is its name, like French."), symbol: "translate", duration: Self.translationTimeout + 5, in: self)
                }
                self.watchTranslation(attempt, of: tab, name: name)
                return
            }
            self.translationAttempt += 1
            guard self.translatingTab === tab else { return }
            self.translatingTab = nil
            Toast.show(String(localized: "Couldn’t translate this page. Try again in a moment.", comment: "Toast when translating a page fails."), symbol: "exclamationmark.triangle", duration: 3, in: self)
        }
    }

    private func startTranslating(_ tab: Tab, webView: WKWebView, from language: Locale.Language, site: String?) {
        let name = PageTranslator.name(of: language)
        translationAttempt += 1
        let attempt = translationAttempt
        translatingTab = tab
        Toast.show(String(localized: "Translating from \(name)…", comment: "Toast while a page is translated. The language is its name, like French."), symbol: "translate", duration: Self.translationTimeout + 5, in: self)
        let page = webView.url
        watchTranslation(attempt, of: tab, name: name)
        translator.translate(webView, from: language, progress: { _ in }, completion: { [weak self] result in
            guard let self, self.translationAttempt == attempt else { return }
            self.translationAttempt += 1
            // Shown only while you're still on that page; otherwise its toast already went with it.
            let showing = self.translatingTab === tab && self.tabManager.selectedTab === tab
            self.translatingTab = nil
            // Left for another page meanwhile: that page isn't translated, and there's nothing to say.
            if case .failure(let error) = result, error is TranslationHost.Cancelled { if showing { Toast.hide(in: self) }; return }
            guard tab.webView?.url == page else { if showing { Toast.hide(in: self) }; return }
            switch result {
            case .success:
                tab.isTranslated = true
                if let site { self.translatedSites.insert(site) }
                guard showing else { return }
                Toast.show(String(localized: "Translated from \(name)", comment: "Toast after a page is translated. The language is its name, like French."), symbol: "translate",
                           action: (title: String(localized: "Show Original", comment: "Button in the toast after a page is translated: shows it untranslated again."), run: { [weak self] in self?.translatePage() }), duration: 4, in: self)
            case .failure:
                guard showing else { return }
                Toast.show(String(localized: "Couldn’t translate this page. Try again in a moment.", comment: "Toast when translating a page fails."), symbol: "exclamationmark.triangle", duration: 3, in: self)
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
    var isReaderOpen: Bool { readerCard != nil }
    private var readerURL: URL?
    private var readerKeyMonitor: Any?

    /// ⌘+, ⌘− and ⌘0 while Reader is up size its text instead of the page underneath. False when it isn't up.
    func zoomReader(_ delta: Int) -> Bool {
        guard let reader, readerTab === tabManager.selectedTab else { return false }
        let percent = reader.stepTextSize(delta).percent
        Toast.show(String(localized: "Text \(percent)%", comment: "Toast when Reader's text size changes, like Text 120%."), symbol: delta < 0 ? "textformat.size.smaller" : "textformat.size.larger", in: self)
        return true
    }

    /// What Find searches: the article while Reader covers the page you're on, otherwise the page.
    var findableWebView: WKWebView? {
        if let reader, readerTab === tabManager.selectedTab { return reader.webView }
        return selectedWebView
    }

    /// What Print and Export as PDF take: the peek in front, the article Reader shows, or the page.
    var printableWebView: WKWebView? {
        if peek.isVisible, let webView = peek.tab?.webView { return webView }
        if let reader, readerTab === tabManager.selectedTab { return reader.webView }
        return selectedWebView
    }

    func toggleReader() {
        if reader != nil { closeReader(); return }
        guard let tab = tabManager.selectedTab, let webView = tab.webView, let url = tab.url else { return }
        Task { [weak self] in
            guard let article = await Reader.article(in: webView), let self else {
                if let self { Toast.show(String(localized: "This page doesn’t have an article to read", comment: "Toast when Reader can't find an article on the page."), symbol: "doc.plaintext", duration: 2, in: self) }
                return
            }
            guard self.tabManager.selectedTab === tab, self.reader == nil else { return }
            let view = ReaderView(store: webView.configuration.websiteDataStore)
            view.onClose = { [weak self] in self?.closeReader() }
            view.onOpenLink = { [weak self] link in self?.closeReader(); tab.load(link) }
            view.onPeekLink = { [weak self] link in self?.open(link, disposition: .peek, opener: tab) }
            view.onBackgroundLink = { [weak self] link in self?.open(link, disposition: .backgroundTab, opener: tab) }
            view.onForegroundLink = { [weak self] link in self?.open(link, disposition: .foregroundTab, opener: tab, allowSwitch: false) }
            view.show(article, from: url, icon: tab.favicon)
            self.reader = view
            self.readerTab = tab
            self.readerURL = url
            let index = self.tabManager.split(for: tab)?.ids.firstIndex(of: tab.id) ?? 0
            let card = self.root.paneCards[min(index, self.root.paneCards.count - 1)]
            self.readerCard = card
            card.setOverlay(view)
            // Visible from the start (WebKit doesn't paint into a hidden view); the article is local and draws
            // within a few frames, well inside the fade.
            Self.readerTransition(view, entering: true)
            self.window?.makeFirstResponder(view.webView)
            // Opened again quickly: one listener, never two.
            if let old = self.readerKeyMonitor { NSEvent.removeMonitor(old) }
            self.readerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // A peek opened from the article is in front: Esc closes that first, and Reader stays. So does the
                // command bar or a panel over it, and mid-word in an input method, Esc belongs to that.
                guard let self, event.keyCode == 53, event.window === self.window, self.reader != nil, !self.peek.isVisible,
                      !self.hasFloatingPanel, (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return event }
                self.closeReader()
                return nil
            }
            self.updateReaderButton()
            self.paintTopBar()
            // An open Find follows the article in, and back out to the page.
            self.findBar.pageChanged()
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
        paintTopBar()
        findBar.pageChanged()
    }

    /// Reader stands in for the page in place, so it only crossfades, quickly both ways: nothing rises or zooms.
    /// Moving or transforming a view that hosts web content stops WebKit drawing into it, and so does a fully
    /// transparent start (hence 0.01).
    private static func readerTransition(_ view: NSView, entering: Bool, completion: (@MainActor () -> Void)? = nil) {
        if entering { view.alphaValue = 0.01 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Tokens.Motion.crossfade * Tokens.Motion.debugSlowdown
            ctx.timingFunction = Tokens.Motion.easeOut
            view.animator().alphaValue = entering ? 1 : 0.01
        }, completionHandler: Tokens.Motion.completion(completion))
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
    /// small pulse: you see where it went without a word. With the sidebar hidden, just the pulse is skipped; with
    /// Reduce Motion, just the flight.
    #if DEBUG
    func debugFlyDownload(_ name: String) {
        sidebar.updateDownloads(active: 1, hasAny: true, progress: 0.35)
        flyDownload(DownloadItem(filename: name, sourceURL: nil, isPrivate: false), refresh: false)
    }
    #endif

    /// Downloads on their way to the button: one that finishes mid-flight waits for the landing before it's announced.
    private(set) var flyingDownloads: Set<UUID> = []

    private func flyDownload(_ item: DownloadItem, refresh: Bool = true) {
        if refresh { downloadsChanged() }
        sidebar.layoutSubtreeIfNeeded()
        let overlay = root.overlay
        guard let host = overlay.layer, let window else { return }
        let anchor = sidebar.downloadsAnchor
        let sidebarShown = root.sidebarVisible || root.isSidebarFloatingVisible
        // Sidebar hidden: its Downloads button stands in at the same corner, and the download flies there.
        if !sidebarShown { showFloatingDownloads() }
        let target = sidebarShown ? anchor : floatingDownloadsButton
        // The landing is one moment: the file goes into the button and the panel opens out of it, showing the file
        // come in, and tidies itself away a while after it's done. The ring on the button says the rest.
        let land = { [weak self] in
            guard let self else { return }
            if refresh, !self.hasFloatingPanel, self.window?.isKeyWindow == true {
                DownloadsPanel.reveal(from: target, in: self, closingAfter: item)
            } else if !sidebarShown, !DownloadsPanel.isOpen(in: self.window) {
                // Nothing opened from it: it stays a moment so you see where the file went, then goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.hideFloatingDownloads() }
            }
        }
        // With Reduce Motion nothing flies: it lands at once.
        guard !Tokens.Motion.reduceMotion else { land(); return }
        let card = root.cardFrame
        // From the pointer if it's over the page, otherwise the middle of the page.
        let mouse = overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let start = card.contains(mouse) ? mouse : NSPoint(x: card.midX, y: card.midY)
        floatingDownloads.layoutSubtreeIfNeeded()
        let end: NSPoint = !target.isHiddenOrHasHiddenAncestor
            ? overlay.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), from: target)
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
        // Carried, like a row picked up: the small carry shadow.
        flyer.shadowColor = NSColor.black.cgColor
        flyer.shadowOpacity = 0.14
        flyer.shadowRadius = Tokens.Shadow.carryRadius
        flyer.shadowOffset = CGSize(width: 0, height: Tokens.Shadow.carryDrop)
        flyer.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(flyer)
        CATransaction.commit()
        // A throw, like a ball: it slows as it rises, hangs at the top for a beat, and speeds up as it drops into
        // the button. Sampled from a real parabola in time, so the speed comes from the arc itself.
        // High enough to read as a throw, never off the top of the page.
        // Started right at the page's top, it still rises a little, so the arc stays an arc.
        let topY = min(min(start.y, end.y) - 40, max(card.minY + 40, min(start.y, end.y) - max(200, min(340, abs(end.x - start.x) * 0.4 + 140))))
        let drop = end.y - start.y, rise = start.y - topY
        // y(t) = a·t² + b·t + y0 through both ends, with its highest point at topY (y grows downward).
        let a = ((2 * drop + 4 * rise) + max(0, (2 * drop + 4 * rise) * (2 * drop + 4 * rise) - 4 * drop * drop).squareRoot()) / 2
        let b = drop - a
        let samples = 36
        var points: [NSValue] = []
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            // Sideways it eases a little, so the throw leaves quickly and settles straight down into the button.
            let side = 1 - pow(1 - t, 1.25)
            points.append(NSValue(point: NSPoint(x: start.x + (end.x - start.x) * side, y: start.y + b * t + a * t * t)))
        }
        // Slow and high, like Arc's: a lob you watch all the way down (`Motion.flight`), the one movement allowed past
        // `large` because it crosses the whole window. The parabola is sampled evenly in time, so its own shape sets
        // the speed: slowing as it rises, hanging at the top, quickening as it drops in.
        let duration = Tokens.Motion.flight * Tokens.Motion.debugSlowdown
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = points
        move.calculationMode = .linear
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        // Grows to its size as it leaves and shrinks into the button: no overshoot, no tilt.
        scale.values = [0.6, 1.0, 0.5]
        scale.keyTimes = [0, 0.3, 1]
        scale.timingFunctions = [Tokens.Motion.easeOut, CAMediaTimingFunction(name: .linear)]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 1]
        fade.keyTimes = [0, 0.1, 0.9, 1]
        let group = CAAnimationGroup()
        group.animations = [move, scale, fade]
        group.duration = duration
        flyingDownloads.insert(item.id)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.flyingDownloads.remove(item.id)
            Tokens.Motion.withoutAnimation { flyer.removeFromSuperlayer() }
            land()
        }
        flyer.add(group, forKey: "fly")
        CATransaction.commit()
    }

    // MARK: Traffic lights

    private var trafficLightsPicture: NSImage?
    /// Until this moment the sidebar is visually sliding, and the real traffic lights stay hidden.
    private var slideEndsAt = Date.distantPast
    private var isSliding: Bool { Date() < slideEndsAt }
    /// Until this moment the sidebar slides under the bar above the page with the lights staying put: its toggle
    /// stays put with them, in the bar, and the sidebar's own (riding with it) is out of sight.
    private var toggleHeldUntil = Date.distantPast
    private var holdsToggle: Bool { Date() < toggleHeldUntil }

    /// While the sidebar slides, the real buttons hide and their picture moves with the sidebar.
    /// Visibility is recomputed from the clock, so nothing can leave the buttons stuck hidden.
    private func sidebarSliding(_ duration: TimeInterval) {
        if !browserWindow.trafficLightsHidden, let image = browserWindow.trafficLightsImage() { trafficLightsPicture = image }
        // Docked and in the bar above the page, the lights are in the same spot: they stay put while the sidebar
        // slides out from under them or back, and go straight back to it as the floating sidebar leaves.
        // Beside a sidebar on the right they're in the bar the whole time, slid out or not.
        let stays = root.showsTopBar && (!root.isSidebarFloatingVisible || root.sidebarOnRight)
        // On either side the bar's toggle is where the sidebar's lands (on the right, both at the window's right end).
        if stays, duration > 0 {
            toggleHeldUntil = Date().addingTimeInterval(duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { [weak self] in self?.layoutTrafficLights() }
        }
        guard duration > 0, !stays else { slideEndsAt = .distantPast; layoutTrafficLights(); return }
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
        // Not in full screen: the lights live in the title bar that comes down with the menu bar there, so a picture of
        // them on the sliding sidebar would only flash and vanish.
        let fullScreen = window.styleMask.contains(.fullScreen)
        // With the sidebar hidden, the bar above the page keeps them at its leading end, where they'd be docked.
        // Beside a sidebar on the right, that's always where they are: the window's top left.
        let onRight = root.sidebarOnRight
        let inBar = root.showsTopBar && (onRight || (!docked && !floating))
        // Docked on the right without the bar, they're at the window's top left over the strip the page leaves them
        // (`lightsStripHeight`), not in the sidebar; slid out, the floating sidebar carries them, as on the left, as
        // the one piece of the window's chrome then in view.
        let inSidebar = !onRight || (floating && !root.showsTopBar)
        let room = fullScreen || !inSidebar ? 0 : window.trafficLightsWidth
        // Their room in the sidebar's row comes at once as it slides out, and goes only once it's out of sight, so
        // nothing in the row moves while it's on screen; until then their picture rides in it.
        if switchingSides || !(sliding && room < sidebar.trafficLightsWidth) { sidebar.trafficLightsWidth = room }
        sidebar.showTrafficLightsPicture(sliding && !fullScreen && sidebar.trafficLightsWidth > 0 ? trafficLightsPicture : nil)
        window.trafficLightsHidden = sliding || !(docked || floating || inBar)
        let container = root.sidebarContainer.frame
        let lightHeight = window.trafficLightHeight
        let x = (docked || inBar ? 0 : container.minX) + SidebarView.trafficLightsX
        // In the bar, on its middle line, wherever the bar starts: not the sidebar's line, which is still the docked
        // one while it slides away.
        let center = inBar ? root.topBarFrame.minY + Tokens.Sidebar.lightsCenter : (docked ? 0 : container.minY) + sidebar.trafficLightCenterY
        let y = center - lightHeight / 2
        window.trafficLightOrigin = NSPoint(x: x, y: y)
        if !sliding, docked || floating || inBar, let image = window.trafficLightsImage() { trafficLightsPicture = image }
        // The lights' room in the bar stays while the sidebar floats over it, so nothing in the bar moves as it does.
        root.topBar.trafficLightsWidth = root.showsTopBar && (!docked || onRight) && !fullScreen ? window.trafficLightsWidth : 0
        // With the sidebar hidden its toggle goes with it, so the bar above the page has one of its own. While the
        // sidebar slides back in, the bar's stays where the sidebar's lands, and the sidebar's shows once it's there.
        let held = root.showsTopBar && holdsToggle
        root.topBar.showsSidebarButton = root.showsTopBar && !docked
        root.topBar.sidebarOnRight = onRight
        sidebar.isOnRight = onRight
        // The sidebar's own, where the docked sidebar puts it: from the window's left edge, or on the right from where
        // the docked sidebar starts.
        let dockedMinX = onRight ? root.bounds.width - root.sidebarWidth : 0
        root.topBar.heldSidebarButtonOrigin = held && docked
            ? NSPoint(x: dockedMinX + sidebar.sidebarButton.frame.minX, y: Tokens.Sidebar.lightsCenter + root.sidebarTopRowDrop - SidebarView.toolbarButton / 2) : nil
        sidebar.sidebarButton.alphaValue = held ? 0 : 1
        sidebar.sidebarButton.toolTip = Shortcuts.tooltip(docked ? String(localized: "Hide Sidebar", comment: "Tooltip of the sidebar button while the sidebar shows.")
                                                                  : String(localized: "Show Sidebar", comment: "Tooltip of the sidebar button while the sidebar is hidden."),
                                                           for: #selector(toggleBrowserSidebar(_:)))
        root.topBar.sidebarButton.toolTip = Shortcuts.tooltip(String(localized: "Show Sidebar", comment: "Tooltip of the sidebar button while the sidebar is hidden."),
                                                              for: #selector(toggleBrowserSidebar(_:)))
        sidebar.backButton.toolTip = Shortcuts.tooltip(String(localized: "Back", comment: "Tooltip of the sidebar's back button."), for: #selector(goBack(_:)))
        sidebar.forwardButton.toolTip = Shortcuts.tooltip(String(localized: "Forward", comment: "Tooltip of the sidebar's forward button."), for: #selector(goForward(_:)))
        sidebar.reloadButton.toolTip = SidebarView.reloadTip(loading: selectedTab?.isLoading ?? false)
        sidebar.downloadsButton.toolTip = Shortcuts.tooltip(String(localized: "Downloads", comment: "Tooltip of the sidebar's downloads button."), for: #selector(showDownloads(_:)))
        sidebar.sidebarButton.isSelected = false
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights(); onStateChange?() }
    func windowDidMove(_ notification: Notification) { onStateChange?() }
    func windowDidEndLiveResize(_ notification: Notification) { layoutTrafficLights() }

    /// The window's place before it went full screen: what's saved, so leaving full screen after a relaunch gives
    /// back the window you had, not one the size of the screen.
    private(set) var windowedFrame: NSRect?

    /// In full screen the traffic lights come down with the menu bar, in AppKit's title bar. Transparent, as Zigzag's
    /// is everywhere else, it left them floating over the page; there it gets the system's bar behind them, as in Safari.
    func windowWillEnterFullScreen(_ notification: Notification) {
        windowedFrame = window?.frame
        browserWindow.titlebarAppearsTransparent = false
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        browserWindow.titlebarAppearsTransparent = false
        layoutTrafficLights()
        root.needsLayout = true
    }

    func windowWillExitFullScreen(_ notification: Notification) { browserWindow.titlebarAppearsTransparent = true }

    func windowDidExitFullScreen(_ notification: Notification) {
        browserWindow.titlebarAppearsTransparent = true
        windowedFrame = nil
        layoutTrafficLights()
        root.needsLayout = true
    }
    func windowDidResignKey(_ notification: Notification) {
        switcher.windowResignedKey()
        spaceSwitcher.windowResignedKey()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateHandoff()
        // Brand moments in other windows (Settings, Passwords) follow the space in front.
        Brand.themeChanged.send(())
        layoutTrafficLights()
        WindowManager.shared.windowBecameKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        fadeTimer?.invalidate()
        numberHints?.stop()
        Autofill.shared.forget(windowOf: window)
        // The peeked page isn't one of the window's tabs: it goes with the window, not whenever this is freed.
        peek.close()
        // The mini player floats in a panel of its own: it goes with the window too.
        miniPlayer.windowClosing()
        // So is a folder's icon picker, and the event monitor it holds.
        iconPicker?.close()
        // Nor does Reader's key monitor outlive it.
        closeReader()
        // Nor the key monitors of the command bar, find and this window's panels, which stay installed until they close.
        commandBar.dismiss(restoringFocus: false)
        if findBar.isVisible { findBar.hide() }
        if SitePanel.isOpen(in: window) { SitePanel.closeCurrent() }
        if DownloadsPanel.isOpen(in: window) { DownloadsPanel.closeCurrent() }
        if let editor = SpaceEditorPanel.current, editor.window === window { editor.close() }
        // Nor the zoomed pane's Esc.
        if let monitor = zoomEscMonitor { NSEvent.removeMonitor(monitor) }
        zoomEscMonitor = nil
        // Its page is no longer on offer to your other devices.
        handoff?.invalidate()
        onClose?(self)
    }

    // MARK: Opening pages

    /// Opens a URL the way the user asked, switching to an existing tab when the page is already open.
    func open(_ url: URL, disposition: OpenDisposition = .foregroundTab, opener: Tab? = nil, allowSwitch: Bool = true) {
        // A page that comes to the front, say a link from Mail, isn't left under the command bar the empty window opened with.
        if disposition == .foregroundTab || disposition == .currentTab, commandBar.isVisible { commandBar.dismiss(restoringFocus: false) }
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
            // A private window's links stay private.
            WindowManager.shared.newWindow(url: url, isPrivate: tabManager.isPrivate)
        case .privateWindow:
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: true)
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

    /// Closes the peek, which floats above the page, so ⌘W puts it away before the tab. Find belongs to the tab and
    /// goes with it, as in Safari; Esc closes find on its own. Returns true if something closed.
    func dismissFloatingContent() -> Bool {
        if peek.isVisible { peek.close(); return true }
        return false
    }

    // MARK: Event interception

    private func intercept(_ event: NSEvent) -> Bool {
        if (event.type == .keyDown || event.type == .flagsChanged), switcher.handle(event) { return true }
        if spaceSwitcher.handle(event) { return true }
        // A mouse's side buttons go back and forward, as in Chrome and Arc (Safari leaves them to the page, which rarely
        // uses them). On release, and the press is taken too, so the page never sees half of it.
        // In a split, the page under the pointer is the one that goes, made the one you're in first as a click
        // would, not whichever pane you were last in (#170).
        if event.type == .otherMouseDown || event.type == .otherMouseUp, event.buttonNumber == 3 || event.buttonNumber == 4 {
            if event.type == .otherMouseDown, root.tiles != nil { focusPane(at: event.locationInWindow) }
            if event.type == .otherMouseUp { event.buttonNumber == 3 ? goBack(nil) : goForward(nil) }
            return true
        }
        if event.type == .leftMouseDown, root.tiles != nil { focusPane(at: event.locationInWindow) }
        // A click anywhere else finishes a name being typed into a sidebar row, as in Finder: rows don't take focus,
        // so without this the name stays open through drags and ⌘Z keeps going to it.
        if event.type == .leftMouseDown, let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField, field.isDescendant(of: sidebar.list),
           !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(nil)
        }
        #if DEBUG
        if event.type == .scrollWheel, sidebarContains(event) { DebugBridge.recordScroll(event) }
        #endif
        if event.type == .scrollWheel, !desk.isVisible, sidebarContains(event), sidebar.handleSwipe(event) { return true }
        if event.type == .keyDown, #available(macOS 15.4, *), !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           ExtensionCenter.performCommand(for: event) {
            return true
        }
        return false
    }
}

extension BrowserWindowController: SwipeArrowHost {
    var swipeArrowLayer: NSView { root.overlay }
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
        if let pending = BrowserWebView.takePendingDisposition(for: tab.webView) {
            if pending == .peek { return showPeek(url: nil, configuration: configuration) }
            // A new window gets its own fresh page, not one tied to this tab (and a private one never shares anything).
            // From a private window, it is private too.
            if pending == .newWindow || pending == .privateWindow, let url = action.request.url {
                WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: tabManager.isPrivate || pending == .privateWindow)
                return nil
            }
            let newTab = tabManager.newTab(url: nil, select: false, configuration: configuration, opener: tab)
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
        let newTab = tabManager.newTab(url: nil, select: !background, configuration: configuration, opener: tab)
        return newTab.ensureWebView()
    }

    func tabDidRequestClose(_ tab: Tab) {
        // A peeked link that only fetched a file (or a page that closed itself): the card goes, not a tab.
        if tab.isPeek, peek.tab === tab { peek.close(); return }
        tabManager.close(tab)
    }

    func tabWantsToReturnToOpener(_ tab: Tab) {
        guard let opener = tab.opener else { return }
        tabManager.returnPane(of: tab, to: opener)
        // The page closed itself: the tabs it opened stay.
        closeWithUndo(tab, alone: true)
        if !opener.isClosed { tabManager.select(opener) }
    }

    func tabWantsToBeShown(_ tab: Tab) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if tabManager.selectedTab !== tab { tabManager.select(tab) }
    }

    func tabWantsFocus(_ tab: Tab) {
        // Only another pane of the split on screen, unless one is zoomed over the rest (that one is where you are).
        guard let selected = tabManager.selectedTab, selected !== tab, !paneZoom.isZoomed,
              tabManager.partners(of: selected).contains(where: { $0 === tab }) else { return }
        tabManager.select(tab)
    }

    func tab(_ tab: Tab, hoveringLink url: URL?) {
        guard tab === tabManager.selectedTab || tab.isPeek else { return }
        // Nothing about the page while a panel is over it.
        linkStatus.show(hasFloatingPanel ? nil : url, in: tab.isPeek ? peek.contentFrame : root.cardFrame)
    }

    /// One floating thing at a time: the command bar, site panel, downloads and space editor each close the
    /// others when they open, and previews and the link bubble stay away while any of them is up.
    var hasFloatingPanel: Bool {
        commandBar.isVisible || SitePanel.isOpen(in: window) || DownloadsPanel.isOpen(in: window) || SpaceEditorPanel.current != nil || desk.isVisible || iconPicker != nil
    }

    /// A folder's icon picker, when it's open in this window.
    private var iconPicker: IconPickerPanel? {
        IconPickerPanel.current.flatMap { $0.window === window ? $0 : nil }
    }

    func closeFloatingPanels() {
        if commandBar.isVisible { commandBar.dismiss(restoringFocus: false) }
        SitePanel.closeCurrent()
        DownloadsPanel.closeCurrent()
        SpaceEditorPanel.current?.close()
        iconPicker?.close()
        previews.hide()
        linkStatus.show(nil, in: root.cardFrame)
    }
}

// MARK: - SidebarDelegate

extension BrowserWindowController: SidebarDelegate {
    func listSelect(_ tab: Tab) { tabManager.select(tab) }
    func listOpenBookmark(_ bookmark: Bookmark) { tabManager.openBookmark(bookmark) }
    func listClose(_ tab: Tab) { closeWithUndo(tab) }
    func listClose(_ tabs: [Tab]) { closeManyWithUndo(tabs) }

    func listRenameBookmark(_ id: UUID, to name: String) {
        libraryChange(String(localized: "Rename Pinned Tab", comment: "Undo action name, shown in the Edit menu as Undo Rename Pinned Tab.")) { Library.shared.updateBookmark(id, title: name) }
    }

    // MARK: Undo (⌘Z) for sidebar actions

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { sidebarUndo }

    /// Settings › Tabs: after closing a pinned tab that went to another page, offer to pin that page instead.
    static var offersToPinWanderedPage: Bool {
        get { UserDefaults.standard.object(forKey: "OffersToPinWanderedPage") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "OffersToPinWanderedPage") }
    }

    /// Closes a tab; ⌘Z brings it back with its history, ⇧⌘Z closes it again. With the tabs under it folded away they
    /// close with it, as one step, and a toast says how many (#155); `alone` closes just this one.
    func closeWithUndo(_ tab: Tab, alone: Bool = false) {
        if !alone {
            let closing = tabManager.closing(tab)
            if closing.count > 1 { closeManyWithUndoToast(closing); return }
        }
        let wasBookmark = tab.bookmarkID != nil
        let id = tab.id
        // A pinned page you'd wandered away from: the pin keeps its own address, and the note offers to keep where
        // you were instead, so the page you were reading isn't simply gone.
        if let bookmarkID = tab.bookmarkID, let here = tab.url, let pin = Library.shared.bookmark(bookmarkID),
           TabManager.normalize(here) != TabManager.normalize(pin.url) {
            tabManager.close(tab)
            // A private window never writes where it's been into your pins, so there's nothing to offer. Nor when you
            // turned the offer off: on a site like DeepSeek every new chat is a new address.
            guard !tabManager.isPrivate, Self.offersToPinWanderedPage else { return }
            // A long page title would stretch the note across the page: the start of it says which pin.
            let name = pin.title.count > 32 ? String(pin.title.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : pin.title
            Toast.show(String(localized: "\(name) stays pinned to its own page", comment: "Toast after closing a pinned tab that had wandered to another page. The title is the pinned tab's."), symbol: "pin",
                       action: (String(localized: "Pin This Page", comment: "Button in the toast after closing a pinned tab that had wandered: pins the page it was on instead."), { [weak self] in
                self?.libraryChange(String(localized: "Update Pinned Page", comment: "Undo action name, shown in the Edit menu as Undo Update Pinned Page.")) { Library.shared.updateBookmark(bookmarkID, url: here) }
            }), duration: 5, in: self)
            return
        }
        tabManager.close(tab)
        guard !wasBookmark else { return }
        sidebarUndo.registerUndo(withTarget: self) { controller in
            guard let reopened = controller.tabManager.reopenClosedTab(id) else { return }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.closeWithUndo(reopened) }
            controller.sidebarUndo.setActionName(String(localized: "Close Tab", comment: "Undo action name, shown in the Edit menu as Undo Close Tab."))
        }
        sidebarUndo.setActionName(String(localized: "Close Tab", comment: "Undo action name, shown in the Edit menu as Undo Close Tab."))
    }

    /// Moves a tab within or between spaces, undoably. Within its space, the tabs nested under it come along; to
    /// another space it goes alone, and they move up a level where they are.
    func moveWithUndo(_ tab: Tab, to index: Int, in spaceID: UUID, nesting: TabManager.Nesting = .fit, then done: (() -> Void)? = nil) {
        // To a space on another profile, an open page reloads there: that's asked first, wherever the move began (a
        // menu, a drag, the command bar).
        confirmProfileCrossing(tabManager.panes(of: tab), to: spaceID) { [weak self] in
            self?.moveNow(tab, to: index, in: spaceID, nesting: nesting)
            done?()
        }
    }

    /// Asks before pages that are loaded move to a space on another profile, where they're rebuilt with that
    /// profile's sign-ins and extensions; `move` runs at once when nothing would change profile. Undoing such a
    /// move doesn't ask: it only puts back what was.
    func confirmProfileCrossing(_ tabs: [Tab], to spaceID: UUID, then move: @escaping () -> Void) {
        // Not moved after all: a row dragged there goes back to where it was.
        ProfileSheets.confirmCrossing(tabs, to: spaceID, in: root.overlay, cancelled: { [weak self] in self?.sidebar.list.reload(animated: true) }, then: move)
    }

    /// The same question for a pinned page, whose open page goes where it does.
    private func confirmProfileCrossing(pinned id: UUID, to spaceID: UUID, then move: @escaping () -> Void) {
        let ids = Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id]
        confirmProfileCrossing(ids.compactMap { tabManager.bookmarkTab(for: $0) }, to: spaceID, then: move)
    }

    private func moveNow(_ tab: Tab, to index: Int, in spaceID: UUID, nesting: TabManager.Nesting) {
        pageChange(spaceID == tab.spaceID ? String(localized: "Move Tab", comment: "Undo action name, shown in the Edit menu as Undo Move Tab.") : String(localized: "Move to Space", comment: "Undo action name, shown in the Edit menu as Undo Move to Space.")) { [weak self] in
            guard let self else { return }
            let oldSpace = tab.spaceID
            if spaceID == oldSpace { tabManager.move(tab, to: index, nesting: nesting) } else { tabManager.moveTabToSpace(tab, spaceID: spaceID, at: index) }
            // Dropped into the space a drag opened, with the old page still showing: you're there now, so it's this tab.
            if spaceID != oldSpace, spaceID == tabManager.currentSpaceID, shownTab !== tabManager.selectedTab { tabManager.select(tab) }
        }
    }

    /// Sends a tab to another space. It leaves the screen, so a toast says where it went, with Undo to bring it back.
    func moveToSpaceWithToast(_ tab: Tab, spaceID: UUID) {
        guard let name = Library.shared.space(spaceID)?.name, spaceID != tab.spaceID else { return }
        moveWithUndo(tab, to: 0, in: spaceID) { [weak self] in self?.toastMoved(to: name) }
    }

    private func toastMoved(to name: String) {
        // Undo brings back this tab, never whatever else was done since.
        Toast.show(String(localized: "Moved to \(name)", comment: "Toast after a tab moves to another space. The name is the space's."), symbol: "arrow.right.square", action: (String(localized: "Undo", comment: "Button in a toast: takes back what was just done."), { [weak self] in
            guard let undo = self?.sidebarUndo, undo.canUndo, undo.undoActionName == String(localized: "Move to Space", comment: "Undo action name, shown in the Edit menu as Undo Move to Space.") else { return }
            undo.undo()
        }), duration: 4, in: self)
    }

    /// Turns a tab into a bookmark, undoably. Half of a split pins the pair.
    func bookmarkWithUndo(_ tab: Tab, at index: Int?, in spaceID: UUID) {
        Tutorial.complete("pin")
        pageChange(String(localized: "Pin Tab", comment: "Undo action name, shown in the Edit menu as Undo Pin Tab.")) { [tabManager] in tabManager.bookmarkTab(tab, at: index, in: spaceID) }
    }

    /// Turns a bookmark back into a tab, undoably. Half of a pinned split unpins the pair.
    func unbookmarkWithUndo(_ bookmarkID: UUID, to index: Int?) {
        pageChange(String(localized: "Unpin Tab", comment: "Undo action name, shown in the Edit menu as Undo Unpin Tab.")) { [tabManager] in tabManager.unbookmark(bookmarkID, toIndex: index) }
    }

    /// A tab dropped on a pinned page: the two become one pinned split where the pinned page is, open side by side.
    func listPinSplit(_ tab: Tab, onto bookmarkID: UUID, tabOnRight: Bool) {
        guard !tabManager.isPrivate else { return }
        pageChange(String(localized: "Split View", comment: "Undo action name, shown in the Edit menu as Undo Split View.")) { [tabManager] in tabManager.pinSplit(tab, with: bookmarkID, tabOnRight: tabOnRight) }
    }

    /// A pinned page dropped on another: the two become one pinned split, open side by side.
    func listJoinPinned(_ bookmarkID: UUID, onto targetID: UUID, onRight: Bool) {
        guard !tabManager.isPrivate else { return }
        pageChange(String(localized: "Split View", comment: "Undo action name, shown in the Edit menu as Undo Split View.")) { [tabManager] in tabManager.joinPinned(bookmarkID, onto: targetID, onRight: onRight) }
    }

    /// A pinned page dropped on a tab: it comes down among the tabs, beside that one, and the two open side by side.
    func listUnpinSplit(_ bookmarkID: UUID, onto tab: Tab, pinnedOnRight: Bool) {
        guard !tabManager.isPrivate else { return }
        pageChange(String(localized: "Split View", comment: "Undo action name, shown in the Edit menu as Undo Split View.")) { [tabManager] in
            // From another space: into the tab's first, so the two end up side by side where the tab is.
            if Library.shared.spaceID(ofBookmark: bookmarkID) != tab.spaceID { Library.shared.moveBookmark(bookmarkID, to: Int.max, in: tab.spaceID) }
            let index = tabManager.tabs(in: tab.spaceID).firstIndex { $0 === tab }.map { $0 + 1 }
            if let unpinned = tabManager.unbookmark(bookmarkID, toIndex: index) {
                tabManager.makeSplit(tab, with: unpinned, otherOnRight: pinnedOnRight)
            }
        }
    }
    func listNewTab() { commandBar.show(mode: .newTab) }

    func listClearTabs() {
        // The tabs you've drifted away from, else every tab but yours (TabManager.tabsToClear).
        let closing = tabManager.tabsToClear(in: tabManager.currentSpaceID).tabs
        guard !closing.isEmpty else { return }
        closeManyWithUndo(closing, leavingSpaceEmpty: true)
        showClosedToast(closing.count)
    }

    /// "Closed 3 tabs", with an Undo that brings back these tabs, never whatever else was done since.
    func showClosedToast(_ count: Int) {
        Toast.show(String(localized: "Closed \(count) tabs", comment: "Toast after tabs are closed, with Undo."), symbol: "xmark.circle", action: (String(localized: "Undo", comment: "Button in a toast: takes back what was just done."), { [weak self] in
            guard let undo = self?.sidebarUndo, undo.canUndo, undo.undoActionName == String(localized: "Close Tabs", comment: "Undo action name, shown in the Edit menu as Undo Close Tabs.") else { return }
            undo.undo()
        }), duration: 4, in: self)
    }
    func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {
        previews.hover(tab, row: row, bookmark: bookmark)
    }
    func listDragHoverSpace(at windowPoint: NSPoint) -> UUID? { sidebar.spaceDot(at: windowPoint) }
    func listDragEnded() {
        sidebar.clearDropTargets()
        sidebar.favorites.isDropTarget = false
        root.splitDropHint.show(nil)
    }
    func listFavoriteTile(for bookmarkID: UUID) -> NSView? { sidebar.favorites.tile(for: bookmarkID) }
    /// A drag that opened another space kept the page on screen. Dropped in that space, you stay there, with its
    /// own page, as if you'd switched to it; dropped back home, the page you were on stays in front. Either way the
    /// selection matches what's showing, so ⌘W closes the page you see.
    func listDropFinished() {
        guard shownTab !== tabManager.selectedTab else { return }
        if let shown = shownTab, tabManager.tab(with: shown.id) != nil, shown.spaceID == tabManager.currentSpaceID {
            tabManager.select(shown)
        } else {
            tabManager.settleInShownSpace()
            showSelectedTab()
        }
    }
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID) {
        confirmProfileCrossing(pinned: id, to: spaceID) { [weak self] in
            self?.pageChange(String(localized: "Move Pinned Tab", comment: "Undo action name, shown in the Edit menu as Undo Move Pinned Tab.")) { Library.shared.moveBookmark(id, to: index, in: spaceID) }
        }
    }
    /// A pinned page dropped at a place in the list, landing in a folder or out of one.
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?) {
        confirmProfileCrossing(pinned: id, to: spaceID) { [weak self] in
            self?.pageChange(String(localized: "Move Pinned Tab", comment: "Undo action name, shown in the Edit menu as Undo Move Pinned Tab.")) { Library.shared.moveBookmark(id, to: index, in: spaceID, folder: .some(folder)) }
        }
    }
    func listMoveFolder(_ id: UUID, to index: Int, in spaceID: UUID, parent: UUID?) {
        pageChange(parent == nil ? String(localized: "Move Folder", comment: "Undo action name, shown in the Edit menu as Undo Move Folder.") : String(localized: "Move into Folder", comment: "Undo action name, shown in the Edit menu as Undo Move into Folder.")) { Library.shared.moveFolder(id, to: index, in: spaceID, parent: .some(parent)) }
    }
    func listSetFolderOpen(_ id: UUID, _ open: Bool) {
        // Opening and closing isn't an edit to undo. Shut on purpose, it hides its pages that are open now, in any
        // window, as well as the rest (#154).
        let folders = Library.shared.spaces.first { $0.folders?.contains { $0.id == id } == true }?.folders ?? []
        let pages = open ? [] : folders.pages(in: id)
        let tucking = pages.filter { page in WindowManager.shared.controllers.contains { $0.tabManager.bookmarkTab(for: page) != nil } }
        Library.shared.setFolderOpen(id, open, tucking: tucking)
    }
    func listRenameFolder(_ id: UUID, to name: String) {
        libraryChange(String(localized: "Rename Folder", comment: "Undo action name, shown in the Edit menu as Undo Rename Folder.")) { Library.shared.renameFolder(id, to: name) }
    }
    func listAsOne(_ name: String, _ body: @escaping () -> Void) { pageChange(name, body) }
    func listSetFolder(of bookmarkID: UUID, to folderID: UUID?) {
        pageChange(folderID == nil ? String(localized: "Remove from Folder", comment: "Undo action name, shown in the Edit menu as Undo Remove from Folder.") : String(localized: "Add to Folder", comment: "Undo action name, shown in the Edit menu as Undo Add to Folder.")) { Library.shared.setFolder(of: bookmarkID, to: folderID) }
    }

    /// A new folder in the current space, holding these pinned pages (or none), named right away in the sidebar.
    /// `inside`: the folder it goes in; left out, the folder its pages share, if any.
    func newFolder(with bookmarkIDs: [UUID] = [], inside: UUID? = nil) {
        var made: BookmarkFolder?
        libraryChange(String(localized: "New Folder", comment: "Undo action name, shown in the Edit menu as Undo New Folder.")) {
            made = Library.shared.addFolder(named: String(localized: "New Folder", comment: "Name a new folder of pinned tabs gets, until it's renamed."), with: bookmarkIDs, in: tabManager.currentSpaceID,
                                            parent: inside.map { .some($0) } ?? .none)
        }
        guard let made else { return }
        revealNewFolder(made.id)
    }

    /// A folder just made shows, with its name ready to type.
    func revealNewFolder(_ id: UUID) {
        if SidebarListView.isCollapsed(tabManager.currentSpaceID) { SidebarListView.setCollapsed(tabManager.currentSpaceID, false) }
        sidebar.list.reload(animated: true)
        DispatchQueue.main.async { [weak self] in self?.sidebar.list.renameFolder(id) }
    }
    func listMove(_ tab: Tab, to index: Int, in spaceID: UUID, nesting: TabManager.Nesting) { moveWithUndo(tab, to: index, in: spaceID, nesting: nesting) }
    func listSetNestedTabsCollapsed(_ tab: Tab, _ collapsed: Bool) { tabManager.setNestedTabsCollapsed(tab, collapsed) }
    func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID) {
        // Pins are shared by every window: a private one's tabs stay out of them.
        guard !tabManager.isPrivate else { return }
        confirmProfileCrossing([tab], to: spaceID) { [weak self] in self?.bookmarkWithUndo(tab, at: index, in: spaceID) }
    }
    func listUnbookmark(_ bookmarkID: UUID, to index: Int, under parent: UUID?) {
        // Pins are shared by every window: a private one doesn't take them away.
        guard !tabManager.isPrivate else { return }
        let space = tabManager.currentSpaceID
        confirmProfileCrossing(pinned: bookmarkID, to: space) { [weak self, tabManager] in
            self?.pageChange(String(localized: "Unpin Tab", comment: "Undo action name, shown in the Edit menu as Undo Unpin Tab.")) {
                // Carried here from another space: into this one first, so it comes down among the tabs you're looking at.
                if Library.shared.spaceID(ofBookmark: bookmarkID) != space { Library.shared.moveBookmark(bookmarkID, to: Int.max, in: space) }
                tabManager.unbookmark(bookmarkID, toIndex: index, under: parent)
            }
        }
    }
    /// A tab in a window of its own, a little down and to the right of this one, so both stay in view.
    func moveToNewWindow(_ tab: Tab) {
        guard !tabManager.isPrivate, let frame = window?.frame else { return }
        let target = WindowManager.shared.newWindow(spaceID: tab.spaceID, showCommandBar: false)
        target.window?.setFrame(frame.offsetBy(dx: 30, dy: -30), display: true)
        move([tab], to: target, at: 0)
    }

    /// Whether a tab's menu offers Open in Zigzag Mini (and a tab ⌥-dragged out of the windows goes there).
    func canOpenInMini(_ tab: Tab) -> Bool {
        !tab.isClosed && MiniWindowController.canTake(tab.url, isPinned: tab.bookmarkID != nil, isPrivate: tabManager.isPrivate)
    }

    /// Open in Zigzag Mini: the tab's page, live, goes into a Zigzag Mini window over this one (or where the tab was
    /// let go, `point`), and the tab leaves the list, as if the page had been opened there. ⌘O there brings it back
    /// as a new tab; ⌘Z here puts it back in its place.
    func openInMini(_ tab: Tab, at point: NSPoint? = nil) {
        guard canOpenInMini(tab), let place = tabManager.release(tab) else { return }
        let mini = MiniWindowController.open(moving: tab, from: window, at: point)
        sidebarUndo.registerUndo(withTarget: self) { [weak mini] controller in
            guard let tab = mini?.handBack() else { return }
            controller.tabManager.putBack(tab, at: place)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.openInMini(tab) }
            controller.sidebarUndo.setActionName(Self.openInMiniName)
        }
        sidebarUndo.setActionName(Self.openInMiniName)
    }

    static var openInMiniTitle: String {
        String(localized: "Open in Zigzag Mini", comment: "Item in a tab's context menu in the sidebar: moves the tab's page into a Zigzag Mini window (the small window for one page, without the sidebar). Zigzag Mini is a name, kept in Latin letters.")
    }

    private static var openInMiniName: String {
        String(localized: "Open in Zigzag Mini", comment: "Undo action name, shown in the Edit menu as Undo Open in Zigzag Mini.")
    }

    /// Tabs into another window's list at `index` (#167), pages and all, as they are: the window they land in shows
    /// the first and comes forward, and one ⌘Z there sends them back to where they were. A window the move leaves
    /// with no tabs closes, as in Chrome (`closeIfEmptied`).
    func move(_ tabs: [Tab], to target: BrowserWindowController, at index: Int) {
        let moving = tabs.filter { !$0.isClosed && $0.bookmarkID == nil && tabManager.tab(with: $0.id) === $0 }
        guard target !== self, let first = moving.first else { return }
        let places = moving.map { tab in (tab, tabManager.tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0) }
        let home = moveHome
        home.window = self
        home.frame = window?.frame
        home.space = tabManager.currentSpaceID
        // Each in at the same place, last first, so they keep their order.
        for tab in moving.reversed() { transfer(tab, to: target, at: index) }
        // The first is the one on screen there, whatever came in after it.
        if target.tabManager.selectedTab !== first { target.tabManager.select(first) }
        target.window?.makeKeyAndOrderFront(nil)
        target.sidebarUndo.registerUndo(withTarget: target) { target in
            let back = places.filter { tab, _ in target.tabManager.tab(with: tab.id) === tab }
            guard !back.isEmpty else { return }
            // Its window closed when they left: they come back in a window where it was.
            // Its window closed when they left: they come back in a window where it was, and so do tabs a later ⌘Z
            // sends back to it.
            let source: BrowserWindowController
            if let open = home.window, WindowManager.shared.controllers.contains(where: { $0 === open }) {
                source = open
            } else {
                source = WindowManager.shared.newWindow(spaceID: home.space, showCommandBar: false)
                if let frame = home.frame { source.window?.setFrame(frame, display: true) }
                source.moveHome = home
                home.window = source
            }
            // Lowest first, so each goes back in at the place it left.
            for (tab, index) in back.sorted(by: { $0.1 < $1.1 }) where target.tabManager.tab(with: tab.id) === tab {
                target.transfer(tab, to: source, at: index)
            }
            source.window?.makeKeyAndOrderFront(nil)
            target.closeIfEmptied()
        }
        target.sidebarUndo.setActionName(String(localized: "Move to Window", comment: "Undo action name, shown in the Edit menu as Undo Move to Window."))
        closeIfEmptied()
    }

    /// A tab into another window's list (`TabManager.take`); extensions hear it left this window for that one.
    private func transfer(_ tab: Tab, to target: BrowserWindowController, at index: Int) {
        let moved = target.tabManager.take(tab, from: tabManager, at: index)
        if #available(macOS 15.4, *) {
            for (page, place) in moved { ExtensionCenter.tabMoved(page, from: place, in: self) }
        }
    }

    /// Left with no tabs in any space by tabs moving out, the window closes, as in Chrome; pinned tabs and favorites
    /// are every window's, so they don't keep it. Not the only window: that one stays, as an empty window would.
    private func closeIfEmptied() {
        guard !tabManager.isPrivate, !tabManager.hasTabs, WindowManager.shared.controllers.contains(where: { $0 !== self }) else { return }
        // After the drag or menu that moved them is done with this window.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tabManager.hasTabs else { return }
            self.window?.close()
        }
    }

    func listDropOutside(_ tabs: [Tab], at screenPoint: NSPoint) -> Bool {
        guard !tabManager.isPrivate, let tab = tabs.first else { return false }
        let over = SidebarListView.window(at: screenPoint)
        // Let go with ⌥ held, one tab becomes a Zigzag Mini window there instead of a browser window.
        if NSEvent.modifierFlags.contains(.option), tabs.count == 1, canOpenInMini(tab),
           !WindowManager.shared.controllers.contains(where: { $0.window?.frame.contains(screenPoint) == true }) {
            openInMini(tab, at: screenPoint)
            return true
        }
        // Onto another window's page: the tabs go there, the first on screen.
        if let over, over !== self {
            guard !over.tabManager.isPrivate else { return false }
            over.window?.makeKeyAndOrderFront(nil)
            over.confirmProfileCrossing(tabs.flatMap(tabManager.panes(of:)), to: over.tabManager.currentSpaceID) { [weak self, weak over] in
                guard let self, let over else { return }
                self.move(tabs, to: over, at: 0)
            }
            return true
        }
        guard over == nil else { return false }
        // Somewhere that isn't a Zigzag window: a new window, roughly where the tab was let go.
        let target = WindowManager.shared.newWindow(spaceID: tab.spaceID, showCommandBar: false)
        if let window = target.window {
            var frame = window.frame
            frame.origin = NSPoint(x: screenPoint.x - 120, y: screenPoint.y - frame.height + 40)
            window.setFrame(frame, display: true)
        }
        move(tabs, to: target, at: 0)
        return true
    }

    func listDragOverFavorites(at windowPoint: NSPoint?, carrying: TabManager.SplitSide?) -> Bool {
        let favorites = sidebar.favorites
        // Favorites are shared by every window: a private one doesn't change them.
        guard let windowPoint, !tabManager.isPrivate else {
            favorites.isDropTarget = false
            return false
        }
        // An empty grid still takes drops in the band under the address, or under the top row with the address above
        // the page.
        var zone = favorites.convert(favorites.bounds, to: nil)
        if favorites.isHidden {
            let above: NSView = sidebar.holdsAddress ? sidebar.address : favorites
            let edge = above.convert(above.bounds, to: nil)
            zone = NSRect(x: edge.minX, y: edge.minY - Tokens.Space.x10, width: edge.width, height: Tokens.Space.x10)
        }
        let over = !tabManager.isPrivate && zone.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(windowPoint)
        favorites.isDropTarget = over
        if over { favorites.hoverDrop(at: windowPoint, carrying: carrying) }
        return over
    }

    func listDropOnFavorites(_ items: [SidebarItem], dragged: SidebarItem) -> Bool {
        guard sidebar.favorites.isDropTarget, !tabManager.isPrivate else { return false }
        let index = sidebar.favorites.dropIndex, split = sidebar.favorites.splitTarget
        sidebar.favorites.isDropTarget = false
        if let split {
            // A pinned page not loaded yet opens as part of the change, so ⌘Z puts it back unloaded.
            pageChange(String(localized: "Split View", comment: "Undo action name, shown in the Edit menu as Undo Split View.")) { [weak self] in
                guard let self else { return }
                let tab: Tab? = switch dragged {
                case .tab(let id): tabManager.tab(with: id)
                case .bookmark(let id): Library.shared.bookmark(id).map(tabManager.pageTab(for:))
                default: nil
                }
                if let tab { joinFavoriteWithUndo(tab, onto: split.id, onRight: split.onRight) }
            }
            return true
        }
        // Each a tile after the one before (a split's two pages make one), in list order.
        var slot = index
        for item in items {
            let tiles = Library.shared.favoriteTiles(in: tabManager.profile.id).count, at = slot
            switch item {
            case .tab(let id): if let tab = tabManager.tab(with: id) { favoriteWithUndo(tab, at: at) }
            case .bookmark(let id): pageChange(String(localized: "Add to Favorites", comment: "Undo action name, shown in the Edit menu as Undo Add to Favorites.")) { [tabManager] in tabManager.favoriteBookmark(id, at: at) }
            default: break
            }
            slot = slot.map { $0 + Library.shared.favoriteTiles(in: tabManager.profile.id).count - tiles }
        }
        return true
    }

    /// The icon grid beside the sidebar, level with the folder's row; each pick shows at once and can be undone.
    func chooseFolderIcon(_ id: UUID) {
        guard let folder = Library.shared.folder(id), let row = sidebar.list.folderRow(id) else { return }
        closeFloatingPanels()
        let panel = IconPickerPanel(noneSymbol: "folder", selected: folder.icon) { [weak self] icon in
            self?.libraryChange(String(localized: "Change Icon", comment: "Undo action name, shown in the Edit menu as Undo Change Icon.")) { Library.shared.setIcon(icon, forFolder: id) }
        }
        panel.show(beside: row, in: root.overlay, x: root.besideSidebar(width: panel.preferredWidth))
    }

    /// The icon grid beside a tab's row, as for a folder; its plain choice is the site's own icon. A private window's
    /// tabs take one too: it lasts as long as the tab.
    func chooseIcon(for tab: Tab) {
        guard let row = sidebar.list.tabRow(tab.id) else { return }
        closeFloatingPanels()
        let id = tab.id
        // The plain choice is the site's own icon, shown as it is.
        let siteIcon = tab.favicon ?? tab.url.flatMap { FaviconStore.shared.cachedIcon(for: $0) }
        let panel = IconPickerPanel(noneSymbol: "globe", noneImage: siteIcon, noneToolTip: SidebarMenus.useSiteIconTitle, selected: tab.customIcon) { [weak self] icon in
            guard let self, let tab = self.tabManager.tab(with: id) else { return }
            self.setIconWithUndo(icon, for: tab)
        }
        panel.show(beside: row, in: root.overlay, x: root.besideSidebar(width: panel.preferredWidth))
    }

    /// The icon grid beside a pinned page's row or a favorite's tile. Kept in the library, so never from a private
    /// window.
    func chooseIcon(forBookmark id: UUID) {
        guard !tabManager.isPrivate, let bookmark = Library.shared.bookmark(id) else { return }
        let anchor = Library.shared.isFavorite(id) ? sidebar.favorites.tile(for: id) : sidebar.list.bookmarkRow(id)
        guard let anchor else { return }
        closeFloatingPanels()
        let siteIcon = tabManager.bookmarkTab(for: id)?.favicon ?? FaviconStore.shared.cachedIcon(for: bookmark.url)
        let panel = IconPickerPanel(noneSymbol: "globe", noneImage: siteIcon, noneToolTip: SidebarMenus.useSiteIconTitle, selected: bookmark.icon) { [weak self] icon in
            self?.setIconWithUndo(icon, forBookmark: id)
        }
        panel.show(beside: anchor, in: root.overlay, x: root.besideSidebar(width: panel.preferredWidth))
    }

    func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool) { splitWithUndo(tab, with: other, otherOnRight: otherOnRight) }
    func listZoomPane(_ tab: Tab) { toggleZoom(tab) }

    func listDragOverPage(at windowPoint: NSPoint?, item: SidebarItem) {
        guard let windowPoint, canDropBeside(item), let current = shownTab ?? tabManager.selectedTab else { root.splitDropHint.show(nil); return }
        showDropHint(at: windowPoint, beside: current)
    }

    /// Where a tab let go at a window point would open beside `current` and the pages with it (#160): the hint over
    /// that half or quarter, with a tick as it moves to another.
    func showDropHint(at windowPoint: NSPoint, beside current: Tab) {
        root.splitDropHint.follow(windowPoint)
        let drop = root.splitDropHint.drop(at: windowPoint, shape: tabManager.split(for: current)?.shape, gap: root.paneGap)
        if let drop, drop.kind != root.splitDropHint.drop?.kind { Haptics.snap() }
        root.splitDropHint.show(drop)
    }

    func listDropOnPage(_ item: SidebarItem) -> Bool {
        let drop = root.splitDropHint.drop
        root.splitDropHint.show(nil)
        // The page showing, which after a space flip mid-drag isn't that space's selected tab.
        guard let drop, canDropBeside(item), let current = shownTab ?? tabManager.selectedTab else { return false }
        // A pinned page not loaded yet opens as part of the change, so ⌘Z puts it back unloaded.
        pageChange(String(localized: "Split View", comment: "Undo action name, shown in the Edit menu as Undo Split View.")) { [weak self] in
            guard let self else { return }
            let tab: Tab? = switch item {
            case .tab(let id): tabManager.tab(with: id)
            case .bookmark(let id): Library.shared.bookmark(id).map(tabManager.pageTab(for:))
            default: nil
            }
            guard let tab else { return }
            // Beside a page alone the two make a split, as they always did; into a split or a group, it's tiled in.
            if tabManager.split(for: current) == nil, case .place(let region, _) = drop.kind {
                splitWithUndo(current, with: tab, otherOnRight: region == .right || region == .bottom, vertical: !region.isColumn)
            } else {
                tabManager.tile(tab, beside: current, drop.kind)
            }
        }
        return true
    }

    /// Another tab, or a pinned page beside a tab, opens beside the page you're on; neither may already be half of a
    /// split. Into a split of two tabs or a tile group of three, another tab of its own (`TabManager.canTile`).
    private func canDropBeside(_ item: SidebarItem) -> Bool {
        guard let current = shownTab ?? tabManager.selectedTab else { return false }
        switch item {
        case .tab(let id):
            guard let tab = tabManager.tab(with: id) else { return false }
            return tabManager.canTile(tab, beside: current)
        case .bookmark(let id):
            // Not loaded yet, it opens at its pinned address.
            guard current.bookmarkID == nil else { return false }
            return TabManager.canSplit(tabManager.splitSide(ofBookmark: id), onto: tabManager.splitSide(of: current))
        default:
            return false
        }
    }

    func listMoveToWindow(_ tabs: [Tab], controller: BrowserWindowController, index: Int) -> Bool {
        guard !tabManager.isPrivate, !controller.tabManager.isPrivate else { return false }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.confirmProfileCrossing(tabs.flatMap(tabManager.panes(of:)), to: controller.tabManager.currentSpaceID) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.move(tabs, to: controller, at: index)
        }
        return true
    }

    func listMovePinnedToWindow(_ bookmarkID: UUID, controller: BrowserWindowController, at screenPoint: NSPoint) -> NSView? {
        guard !tabManager.isPrivate, !controller.tabManager.isPrivate else { return nil }
        return controller.takePinned(bookmarkID, from: self, at: screenPoint)
    }

    func listSwitchSpaceDuringDrag(_ spaceID: UUID) {
        // Switch without changing the selected tab, so the page doesn't jump while you drag.
        tabManager.showSpaceKeepingPage(spaceID)
    }

    func listMenu(forMarked items: [SidebarItem]) -> NSMenu? { SidebarMenus.markedMenu(for: items, controller: self) }

    /// Pinned pages for picked rows, pinning the tabs among them (in order) first.
    func pinnedIDs(for items: [SidebarItem]) -> [UUID] {
        items.compactMap { item in
            switch item {
            case .bookmark(let id): return id
            case .tab(let id):
                guard let tab = tabManager.tab(with: id), tab.url != nil else { return nil }
                if tab.bookmarkID == nil { bookmarkWithUndo(tab, at: nil, in: tab.spaceID) }
                return tab.bookmarkID
            default: return nil
            }
        }
    }

    func listMenu(for item: SidebarItem) -> NSMenu? {
        switch item {
        case .header: return sidebarSpaceMenu(for: tabManager.currentSpaceID)
        case .tab(let id): return tabManager.tab(with: id).map { SidebarMenus.tabMenu(for: $0, controller: self) }
        case .bookmark(let id): return Library.shared.bookmark(id).map { SidebarMenus.bookmarkMenu(for: $0, controller: self) }
        case .folder(let id): return Library.shared.folder(id).map { SidebarMenus.folderMenu(for: $0, controller: self) }
        default: return nil
        }
    }

    func sidebarOpenCommandBar() { commandBar.show(mode: .editCurrent) }
    func sidebarSwitchSpace(_ id: UUID) { tabManager.switchToSpace(id) }
    func sidebarAddMenu() -> [MenuPanel.Entry] { SidebarMenus.addPanel(controller: self) }
    func sidebarBlankMenu() -> [MenuPanel.Entry] { SidebarMenus.blankPanel(controller: self) }
    func sidebarShowDownloads(from view: NSView) { DownloadsPanel.show(from: view, in: self) }
    func sidebarSpaceMenu(for id: UUID) -> NSMenu? {
        let menu = SidebarMenus.spaceMenu(for: id, controller: self)
        return menu.items.isEmpty ? nil : menu
    }
}

// MARK: - Debug hooks

#if DEBUG
extension BrowserWindowController {
    func debugHover(index: Int) {
        let tabs = tabManager.currentTabs
        guard tabs.indices.contains(index), let row = sidebar.list.row(for: tabs[index]) else { previews.debugRow = nil; return }
        previews.debugRow = row
        previews.hover(tabs[index], row: row, bookmark: nil)
    }
    func debugSwitcher() {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                    context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        _ = switcher.handle(down)
    }
    func debugSpaceSwitcher(_ arg: String) {
        if arg.hasPrefix("state ") {
            try? spaceSwitcher.debugState.write(toFile: String(arg.dropFirst(6)), atomically: true, encoding: .utf8)
            return
        }
        // "again" and "back": ⌥⌘S and ⇧⌥⌘S pressed while it's up, as the window hands them over.
        let keys: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "down": (125, "", []), "up": (126, "", []), "tab": (48, "\t", []), "return": (36, "\r", []), "esc": (53, "\u{1b}", []),
            "again": (1, "s", [.command, .option]), "back": (1, "S", [.command, .option, .shift]),
        ]
        guard let (code, chars, flags) = keys[arg] ?? Int(arg).map({ (UInt16(18), String($0), []) }) else { showSpaceSwitcher(nil); return }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        _ = spaceSwitcher.handle(event)
    }
}
#endif

// MARK: - The command bar in a browser window

extension BrowserWindowController: CommandBarHost {
    var commandBarOverlay: NSView { root.overlay }
    var commandBarPageFrame: NSRect { root.cardFrame }
    /// A split pane's address when asked for; else the address above the page, or the sidebar's while the sidebar
    /// shows docked.
    func commandBarAnchor(asked: NSView?) -> NSView? {
        if let asked { return asked }
        // In split view under the bar, the bar's address steps aside: the address of the pane you're in, as ⌘L edits
        // that pane's page.
        if root.stripsInBar { return focusedPaneAddress.isHidden ? nil : focusedPaneAddress }
        if root.showsTopBar { return sidebar.address }
        return root.sidebarVisible && !root.isSidebarFloatingVisible ? sidebar.address : nil
    }
    var commandBarTabs: TabManager? { tabManager }
    var commandBarProfile: Profile { tabManager.profile }
    var commandBarTab: Tab? { tabManager.selectedTab }
    var commandBarSpace: SpaceInfo? { tabManager.currentSpace }
    var commandBarIsPrivate: Bool { tabManager.isPrivate }

    /// One floating thing at a time. Over the tab overview, the overview steps aside: whatever you open or search for
    /// shows in the window, not behind the overview.
    func commandBarWillShow() {
        if desk.isVisible { desk.hide(openingTab: nil) }
        SitePanel.closeCurrent()
        DownloadsPanel.closeCurrent()
        SpaceEditorPanel.current?.close()
        // Over a peek, Esc and ⌘L would go to the peek's page or the tab behind it: put the peek away first.
        peek.close()
        previews.hide()
        linkStatus.show(nil, in: root.cardFrame)
        // The sidebar slid out over the page steps aside too: the bar would open over its edge, and typing is no
        // time for it. Not while something holds it out (the guide pointing into it).
        root.reveal(false)
    }

    func commandBarRestoreFocus() {
        if let selectedWebView { window?.makeFirstResponder(selectedWebView) }
    }
}

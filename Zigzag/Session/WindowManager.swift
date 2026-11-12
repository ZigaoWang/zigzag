import AppKit

/// Saved state of every window and tab, written often so a crash loses nothing.
nonisolated struct SessionState: Codable, Sendable {
    nonisolated struct TabState: Codable, Sendable {
        var id: UUID
        var url: URL?
        var title: String
        var lastActivated: Date
        var createdAt: Date
        /// A name you gave the tab; older sessions don't have one.
        var customTitle: String? = nil
        /// An icon you gave the tab; older sessions don't have one.
        var customIcon: String? = nil
        /// The tab it's nested under, and whether the tabs under it are folded away; sessions from before nested tabs
        /// have neither, and their tabs come back at the top level.
        var parentID: UUID? = nil
        var collapsed: Bool? = nil
    }

    nonisolated struct SpaceTabs: Codable, Sendable {
        var spaceID: UUID
        var tabs: [TabState]
        var selectedTabID: UUID?
    }

    nonisolated struct BookmarkTabState: Codable, Sendable {
        var bookmarkID: UUID
        var tab: TabState
    }

    nonisolated struct WindowState: Codable, Sendable {
        var frame: [Double]
        var sidebarVisible: Bool
        var sidebarWidth: Double
        var currentSpaceID: UUID
        var spaces: [SpaceTabs]
        var bookmarkTabs: [BookmarkTabState]
        var isFullScreen: Bool?
        var splits: [TabManager.SplitPair]?
    }

    var windows: [WindowState]

    /// The parent each kept tab is saved with: the tabs left out (no page yet) are taken out of the tree first, so
    /// the tabs under them are saved a level up rather than under a tab that won't come back.
    nonisolated static func savedParents(_ nodes: [TabTree.Node], keeping kept: Set<UUID>) -> [UUID: UUID] {
        var tree = nodes
        for node in nodes where !kept.contains(node.id) { tree = TabTree.removing(node.id, from: tree) }
        return Dictionary(tree.compactMap { node in node.parent.map { (node.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
}

/// Writes the session file, on the queue it's given to: only what differs from what it last wrote, so a page that
/// keeps rewriting its address doesn't have the file written every few seconds with the same windows and tabs.
/// Touched only from one serial queue at a time.
nonisolated final class SessionFileWriter: @unchecked Sendable {
    private var lastWritten: Data?

    /// Whether the file was written.
    @discardableResult
    func write(_ state: SessionState, to url: URL) -> Bool {
        guard let data = JSONStore.encode(state), data != lastWritten else { return false }
        guard JSONStore.write(data, to: url) else { return false }
        lastWritten = data
        return true
    }
}

/// Creates, tracks and restores browser windows.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [BrowserWindowController] = []
    private weak var lastKey: BrowserWindowController?
    private let saveDebouncer = Debouncer(delay: 1.5, maxWait: 10)
    private var isTerminating = false

    /// The browser window's controller, for a window that's one.
    func controller(for window: NSWindow?) -> BrowserWindowController? {
        controllers.first { $0.window === window }
    }

    #if DEBUG
    /// The debug bridge's `usewindow`: the window its commands go to, whichever is in front.
    weak var debugTarget: BrowserWindowController?
    #endif

    var keyController: BrowserWindowController? {
        #if DEBUG
        if let debugTarget, controllers.contains(where: { $0 === debugTarget }) { return debugTarget }
        #endif
        if let controller = NSApp.keyWindow?.windowController as? BrowserWindowController { return controller }
        if let controller = NSApp.mainWindow?.windowController as? BrowserWindowController { return controller }
        return lastKey ?? controllers.last
    }

    func windowBecameKey(_ controller: BrowserWindowController) {
        lastKey = controller
        if #available(macOS 15.4, *) { ExtensionCenter.windowFocused(controller) }
    }

    // MARK: Creating

    /// Onboarding hasn't been finished or closed yet. Until it is, every launch starts with it, even if a hidden
    /// browser window was saved behind it.
    static var needsOnboarding: Bool {
        guard !Library.shared.importedFromArc, !UserDefaults.standard.bool(forKey: "ImportOfferDismissed"),
              !UserDefaults.standard.bool(forKey: "ArcOfferDismissed") else { return false }
        // Preferences reset (a cleaner app, a migration that moved the data but not them) while the data is
        // full: that's someone who has used Zigzag, and welcoming them would save an empty window over their tabs.
        if hasBeenUsed {
            UserDefaults.standard.set(true, forKey: "ImportOfferDismissed")
            return false
        }
        return true
    }

    /// Tabs saved, or pins and favorites made: read once, from what's on disk.
    private static let hasBeenUsed: Bool = {
        let tabs = JSONStore.load(SessionState.self, from: Paths.session)?.windows
            .contains { window in window.spaces.contains { !$0.tabs.isEmpty } || !window.bookmarkTabs.isEmpty } ?? false
        return tabs || !Library.shared.allBookmarkIDs.isEmpty
    }()

    @discardableResult
    func newWindow(url: URL? = nil, spaceID: UUID? = nil, showCommandBar: Bool = true, isPrivate: Bool = false) -> BrowserWindowController {
        // Opened for Zigzag Mini alone, the saved windows are still waiting: they come back first, so a new window never
        // saves over them, and a plain ⌘N is simply them.
        if sessionWaiting, !isPrivate, restoreSession(), url == nil, let restored = controllers.last(where: { !$0.tabManager.isPrivate }) {
            restored.window?.makeKeyAndOrderFront(nil)
            return restored
        }
        let manager = TabManager(spaceID: spaceID ?? keyController?.tabManager.currentSpaceID, isPrivate: isPrivate)
        var frame: NSRect?
        if let key = keyController, let window = key.window {
            // Cascade from the current window, like every Mac app. From full screen, from where it was before.
            let fullScreen = window.styleMask.contains(.fullScreen)
            frame = (fullScreen ? key.windowedFrame : window.frame)?.offsetBy(dx: Tokens.Space.x6, dy: -Tokens.Space.x6)
        }
        let controller = makeController(manager: manager, frame: frame, sidebarVisible: keyController?.root.sidebarVisible ?? true,
                                        sidebarWidth: keyController?.root.sidebarWidth ?? Tokens.Metric.sidebarWidth)
        let firstLaunch = url == nil && !isPrivate && Self.needsOnboarding
        if firstLaunch {
            // First launch is its own moment: the welcome window, then the browser.
            WelcomeWindowController.show { [weak controller] in
                guard let controller else { return }
                controller.showWindow(nil)
                // Straight after onboarding: the Getting started guide, in the window itself.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in
                    if let controller { GuidedTour.start(in: controller) }
                }
            }
            return controller
        }
        controller.showWindow(nil)
        // Opened straight into a page (a link, the very first launch): onboarding is skipped for good, or the next
        // launch would show it instead of restoring this window and then save over it.
        if !isPrivate, Self.needsOnboarding { UserDefaults.standard.set(true, forKey: "ImportOfferDismissed") }
        if let url {
            manager.newTab(url: url)
        } else if isPrivate {
            controller.commandBar.show(mode: .newTab)
        } else if showCommandBar {
            controller.commandBar.show(mode: .newTab)
        }
        return controller
    }

    private func makeController(manager: TabManager, frame: NSRect?, sidebarVisible: Bool, sidebarWidth: CGFloat) -> BrowserWindowController {
        let controller = BrowserWindowController(tabManager: manager, frame: frame, sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth)
        controller.onClose = { [weak self] closed in self?.windowClosed(closed) }
        controller.onStateChange = { [weak self] in self?.scheduleSave() }
        controllers.append(controller)
        if #available(macOS 15.4, *) { ExtensionCenter.windowOpened(controller) }
        return controller
    }

    private func windowClosed(_ controller: BrowserWindowController) {
        guard !isTerminating else { return }
        // Keep the last window's tabs for next launch even if it is closed before quitting.
        // (A private window open alongside doesn't count: it isn't saved.)
        if !controller.tabManager.isPrivate, controllers.filter({ !$0.tabManager.isPrivate }).count == 1 { saveNow(synchronously: true) }
        // Kept to reopen (⇧⌘T's sibling in the File menu), with each tab's back/forward list. Never private windows.
        if !controller.tabManager.isPrivate, controller.tabManager.allTabs.contains(where: { $0.url != nil }) {
            var history: [UUID: Data] = [:]
            for tab in controller.tabManager.allTabs { if let data = tab.interactionStateForSaving { history[tab.id] = data } }
            closedWindows.append((windowState(controller), history))
            if closedWindows.count > 10 { closedWindows.removeFirst() }
        }
        controllers.removeAll { $0 === controller }
        if lastKey === controller { lastKey = nil }
        if #available(macOS 15.4, *) { ExtensionCenter.windowClosed(controller) }
        controller.tabManager.invalidate()
        if controller.tabManager.isPrivate, !controllers.contains(where: { $0.tabManager.isPrivate }) { DownloadManager.shared.forgetPrivate() }
        if !controllers.isEmpty { scheduleSave() }
    }

    /// No browser window is open (the last one was closed): bring back the saved one, tabs and all, rather than
    /// open an empty window whose first save would wipe them. Nothing saved: a new window.
    func reopen() {
        guard !controllers.contains(where: { !$0.tabManager.isPrivate }) else { newWindow(); return }
        if !restoreSession() { newWindow() }
    }

    /// No browser window is open: brings back the saved session and returns its window, so what opens next joins it
    /// instead of a new window whose first save would wipe it. Nil when one is open or nothing was saved.
    @discardableResult
    func restoreIfNoWindows() -> BrowserWindowController? {
        guard !controllers.contains(where: { !$0.tabManager.isPrivate }), restoreSession() else { return nil }
        return controllers.last { !$0.tabManager.isPrivate }
    }

    /// Opens a URL from outside (another app, Finder, the Dock) in the frontmost window. Never a private one: a link
    /// from elsewhere doesn't get to choose that.
    func openExternal(_ url: URL) { open(url, fromAnotherApp: true) }

    /// A page Zigzag itself opens (About's links, Send Feedback, release notes): a tab in the front window, as any
    /// link inside Zigzag, never Zigzag Mini, which is for links from other apps.
    func openFromZigzag(_ url: URL) {
        open(url, fromAnotherApp: false)
        NSApp.activate()
    }

    private func open(_ url: URL, fromAnotherApp: Bool) {
        // Settings › Zigzag Mini can send links to a Zigzag Mini of their own instead; files and links before onboarding
        // still open here. Zigzag Mini is never saved, so nothing about the session changes.
        if fromAnotherApp, opensInMini(url) {
            MiniWindowController.open(url: url, fromAnotherApp: true)
            return
        }
        // A link opened before onboarding was finished: you're browsing now, so the next launch restores this window
        // instead of starting over with the welcome (and then saving over what you opened).
        if Self.needsOnboarding { UserDefaults.standard.set(true, forKey: "ImportOfferDismissed") }
        let key = keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        if let controller = key ?? controllers.last(where: { !$0.tabManager.isPrivate }) ?? restoreIfNoWindows() {
            controller.open(url, disposition: .foregroundTab)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(url: url)
        }
    }

    /// A page from another app goes to Zigzag Mini rather than a tab here.
    func opensInMini(_ url: URL) -> Bool {
        MiniWindowController.takes(url, settingOn: MiniWindowController.opensExternalLinks, needsOnboarding: Self.needsOnboarding)
    }

    // MARK: Saving

    func scheduleSave() {
        saveDebouncer.call { [weak self] in self?.saveNow() }
    }

    func saveNow(synchronously: Bool = false) {
        saveDebouncer.cancel()
        guard !controllers.isEmpty, !sessionWaiting else { return }
        // Private windows are never written down.
        let saved = controllers.filter { !$0.tabManager.isPrivate }
        guard !saved.isEmpty else { return }
        // Gathered here, where the windows and tabs are; encoded and written on the writer's queue, and only when
        // it says something the file doesn't already (a page rewriting its address back and forth).
        let state = SessionState(windows: saved.map(windowState))
        // Back/forward lists live in their own files: opaque and occasionally large. Only changed ones are
        // written, and never on the main thread.
        var keep = Set<UUID>()
        var writes: [(URL, Data)] = []
        for controller in saved {
            for tab in controller.tabManager.allTabs {
                keep.insert(tab.id)
                // Only the tabs that went somewhere or were scrolled are encoded again: with many tabs, the rest cost
                // nothing, and the page you're reading isn't encoded again every few seconds for nothing.
                guard tabStates.needsEncoding(tab.id, changed: tab.navigatedSinceSave || tab.scrolledSinceSave) else { continue }
                tab.navigatedSinceSave = false
                tab.scrolledSinceSave = false
                guard let data = tab.interactionStateForSaving, tabStates.update(tab.id, with: data) else { continue }
                writes.append((Paths.tabState.appendingPathComponent(tab.id.uuidString), data))
            }
        }
        tabStates.finish(keeping: keep)
        let directory = Paths.tabState, session = Paths.session, writer = sessionWriter
        // Frozen copies for the writer's queue, so nothing it reads can change under it. With no back/forward list
        // changed and no tab come or gone, the folder isn't looked through again.
        let toWrite = writes, kept = keep, tabsChanged = !writes.isEmpty || keep != lastKept
        lastKept = keep
        let work: @Sendable () -> Void = {
            writer.write(state, to: session)
            if tabsChanged { Self.writeTabStates(toWrite, keeping: kept, in: directory) }
        }
        if synchronously { stateWriter.sync(execute: work) } else { stateWriter.async(execute: work) }
    }

    /// Waits for the saves on their way to disk, before reading the session back.
    func finishSaving() { stateWriter.sync {} }

    private var tabStates = TabStateCache()
    /// The tabs the last save kept back/forward files for.
    private var lastKept: Set<UUID>?
    /// One writer at a time, in order, so an older write can't delete a file a newer one just wrote.
    private let stateWriter = DispatchQueue(label: "Zigzag.tab-states")
    private let sessionWriter = SessionFileWriter()

    /// Runs off the main thread: writes changed back/forward lists and removes ones for closed tabs.
    nonisolated private static func writeTabStates(_ writes: [(URL, Data)], keeping keep: Set<UUID>, in directory: URL) {
        for (url, data) in writes { try? data.write(to: url, options: .atomic) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where UUID(uuidString: file.lastPathComponent).map({ !keep.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func windowState(_ controller: BrowserWindowController) -> SessionState.WindowState {
        let manager = controller.tabManager
        let fullScreen = controller.window?.styleMask.contains(.fullScreen) == true
        let frame = (fullScreen ? controller.windowedFrame : nil) ?? controller.window?.frame ?? .zero
        func state(_ tab: Tab, parent: UUID? = nil) -> SessionState.TabState { SessionState.TabState(tab, parent: parent) }
        let spaces = Library.shared.spaces.map { space in
            let tabs = manager.tabs(in: space.id)
            // New tabs with no page aren't kept: the tabs under one come back a level up, as if it had closed.
            let parents = SessionState.savedParents(manager.treeNodes(in: space.id), keeping: Set(tabs.filter { $0.url != nil }.map(\.id)))
            return SessionState.SpaceTabs(spaceID: space.id, tabs: tabs.filter { $0.url != nil }.map { state($0, parent: parents[$0.id]) },
                                          selectedTabID: manager.selectedTab(in: space.id)?.id)
        }
        let bookmarkTabs = manager.bookmarkTabs.map { SessionState.BookmarkTabState(bookmarkID: $0.key, tab: state($0.value)) }
        return SessionState.WindowState(frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                                        sidebarVisible: controller.root.sidebarVisible,
                                        sidebarWidth: Double(controller.root.sidebarWidth),
                                        currentSpaceID: manager.currentSpaceID,
                                        spaces: spaces, bookmarkTabs: bookmarkTabs,
                                        isFullScreen: controller.window?.styleMask.contains(.fullScreen),
                                        splits: manager.splits)
    }

    // MARK: Restoring

    /// Zigzag opened for a link going to Zigzag Mini, as Arc's Little Arc does: the browser windows weren't brought back.
    /// Whatever asks for a browser window next brings them back first.
    var sessionWaiting = false

    /// Brings back every window and tab from the last run, crash or not. Returns false if there was nothing.
    @discardableResult
    func restoreSession() -> Bool {
        sessionWaiting = false
        finishSaving()
        guard let state = JSONStore.load(SessionState.self, from: Paths.session), !state.windows.isEmpty else { return false }
        var allIDs = Set<UUID>()
        for windowState in state.windows {
            allIDs.formUnion(restoreWindow(windowState))
        }
        SnapshotStore.prune(keeping: allIDs)
        return !controllers.isEmpty
    }

    /// Windows closed this session, newest last, to bring back with ⇧⌘N's neighbor, Reopen Closed Window.
    private var closedWindows: [(state: SessionState.WindowState, history: [UUID: Data])] = []
    var canReopenClosedWindow: Bool {
        let open = openTabIDs
        return closedWindows.contains { !isBack($0.state, open: open) }
    }

    /// Brings back the last closed window, its spaces, tabs, history and place on screen.
    func reopenClosedWindow() {
        // Already back (the Dock icon restored it after the last window closed): never a second copy of the same tabs,
        // so it's passed over for the one closed before it.
        let open = openTabIDs
        while let closed = closedWindows.popLast() {
            guard !isBack(closed.state, open: open) else { continue }
            restoreWindow(closed.state, history: closed.history)
            return
        }
    }

    private var openTabIDs: Set<UUID> { Set(controllers.flatMap { $0.tabManager.allTabs.map(\.id) }) }

    private func isBack(_ state: SessionState.WindowState, open: Set<UUID>) -> Bool {
        let ids = state.spaces.flatMap { $0.tabs.map(\.id) } + state.bookmarkTabs.map(\.tab.id)
        return ids.contains(where: open.contains)
    }

    /// One window from saved state; returns its tabs' ids. `history` stands in for back/forward lists not on disk.
    @discardableResult
    private func restoreWindow(_ windowState: SessionState.WindowState, history: [UUID: Data] = [:]) -> Set<UUID> {
            var allIDs = Set<UUID>()
            let manager = TabManager(spaceID: windowState.currentSpaceID)
            var selection: [UUID: UUID] = [:]
            // A space that's gone (the library couldn't be read and started over) keeps its tabs: they join the space
            // the window was on, or the first one, rather than vanish and be overwritten by the next save.
            let fallback = Library.shared.space(windowState.currentSpaceID) != nil ? windowState.currentSpaceID : Library.shared.spaces[0].id
            for spaceTabs in windowState.spaces {
                let space = Library.shared.space(spaceTabs.spaceID) != nil ? spaceTabs.spaceID : fallback
                let tabs = spaceTabs.tabs.map { restoreTab($0, spaceID: space, history: history[$0.id]) }
                manager.adopt(tabs, in: space)
                if space == spaceTabs.spaceID, let selected = spaceTabs.selectedTabID { selection[space] = selected }
                allIDs.formUnion(tabs.map(\.id))
            }
            for bookmarkState in windowState.bookmarkTabs {
                let isFavorite = Library.shared.isFavorite(bookmarkState.bookmarkID)
                // A favorite's page comes back in a space of the favorite's own profile: the one the window was in if
                // that's on it, else that profile's first.
                let favoriteSpace: UUID? = isFavorite ? {
                    let home = Library.shared.profileID(ofFavorite: bookmarkState.bookmarkID)
                    if Library.shared.profileID(ofSpace: windowState.currentSpaceID) == home { return windowState.currentSpaceID }
                    return Library.shared.spaces(in: home).first?.id ?? windowState.currentSpaceID
                }() : nil
                guard let spaceID = Library.shared.spaceID(ofBookmark: bookmarkState.bookmarkID) ?? favoriteSpace else { continue }
                let tab = restoreTab(bookmarkState.tab, spaceID: spaceID, history: history[bookmarkState.tab.id])
                tab.isFavorite = isFavorite
                manager.adoptBookmarkTab(tab, bookmarkID: bookmarkState.bookmarkID)
                allIDs.insert(tab.id)
            }
            let f = windowState.frame
            var frame: NSRect? = f.count == 4 ? NSRect(x: f[0], y: f[1], width: f[2], height: f[3]) : nil
            if let rect = frame, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { frame = nil }
            let controller = makeController(manager: manager, frame: frame, sidebarVisible: windowState.sidebarVisible,
                                            sidebarWidth: CGFloat(windowState.sidebarWidth))
            manager.restoreSplits(windowState.splits ?? [])
            manager.restoreSelection(selection, currentSpaceID: windowState.currentSpaceID)
            controller.showWindow(nil)
            if windowState.isFullScreen == true { controller.window?.toggleFullScreen(nil) }
            return allIDs
    }

    private func restoreTab(_ state: SessionState.TabState, spaceID: UUID, history: Data? = nil) -> Tab {
        let interaction = history ?? (try? Data(contentsOf: Paths.tabState.appendingPathComponent(state.id.uuidString)))
        let tab = Tab(id: state.id, url: state.url, title: state.title, spaceID: spaceID, interactionState: interaction,
                      lastActivated: state.lastActivated, createdAt: state.createdAt)
        state.apply(to: tab)
        return tab
    }

    func prepareForTermination() {
        saveNow(synchronously: true)
        isTerminating = true
        Library.shared.saveNow()
    }
}

@MainActor extension SessionState.TabState {
    /// A tab as the session keeps it, under `parent` in the list.
    init(_ tab: Tab, parent: UUID? = nil) {
        self.init(id: tab.id, url: tab.url, title: tab.title.isEmpty ? tab.displayTitle : tab.title, lastActivated: tab.lastActivated,
                  createdAt: tab.createdAt, customTitle: tab.customTitle, customIcon: tab.customIcon, parentID: parent,
                  collapsed: tab.isCollapsed ? true : nil)
    }

    /// What the session kept beyond the page itself, back on the tab made from it.
    func apply(to tab: Tab) {
        tab.customTitle = customTitle
        tab.customIcon = customIcon
        tab.parentID = parentID
        tab.isCollapsed = collapsed ?? false
    }
}

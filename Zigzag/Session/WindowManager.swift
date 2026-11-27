import AppKit

/// Saved state of every window and tab, written often so a crash loses nothing. With shared tabs (#162), the first
/// sharing window carries the full list (tabs, open pinned and favorite pages, splits, groups) and the others only
/// their frame, space and selected tab per space, the 0.8.7 beta 1 format, which older builds or sharing off read as
/// separate windows (`givingWindowsTheirOwnTabs`).
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
        /// Its tab group (#209); nil in older sessions.
        var groupID: UUID? = nil
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
        /// Tab groups (#209) with names and open state; nil when none or in older sessions.
        var tabGroups: [TabGroup]? = nil
    }

    var windows: [WindowState]

    /// The parent each kept tab is saved with: the tabs left out (no page yet) are taken out of the tree first, so
    /// the tabs under them are saved a level up rather than under a tab that won't come back.
    nonisolated static func savedParents(_ nodes: [TabTree.Node], keeping kept: Set<UUID>) -> [UUID: UUID] {
        var tree = nodes
        for node in nodes where !kept.contains(node.id) { tree = TabTree.removing(node.id, from: tree) }
        return Dictionary(tree.compactMap { node in node.parent.map { (node.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Zigzag 0.8.7 beta 1 showed every window the same tabs (#162) and saved them that way: the first window with the
    /// whole list, each other window with only its place, space and the tab it had chosen in each space. Windows have
    /// tabs of their own again (#167), so read back, the list stays with the first window and each other window takes
    /// the tab it was on in the space it was showing (with the pages beside it in a split), so every tab and every
    /// window comes back, each tab once. A tab the first window was on stays there. Any other session is as it was.
    @MainActor func givingWindowsTheirOwnTabs() -> SessionState {
        var windows = self.windows
        for w in windows.indices where windows[w].hasNoTabs {
            let space = windows[w].currentSpaceID
            let wanted = windows[w].spaces.first { $0.spaceID == space }?.selectedTabID
            // What it chose in other spaces are tabs it no longer has.
            for i in windows[w].spaces.indices { windows[w].spaces[i].selectedTabID = nil }
            guard let wanted, let from = windows.indices.first(where: { $0 != w && windows[$0].holds(wanted) }) else { continue }
            let chosenThere = windows[from].spaces.first { $0.spaceID == space }?.selectedTabID
            if let list = windows[from].spaces.firstIndex(where: { $0.spaceID == space && $0.tabs.contains { $0.id == wanted } }) {
                let ids = Set(windows[from].spaces[list].tabs.map(\.id))
                // A split or tile group of tabs goes along whole; one with a pinned page stays, and the tab leaves it.
                let pair = windows[from].splits?.first { $0.ids.contains(wanted) }
                let whole = pair.map { $0.ids.allSatisfy(ids.contains) } ?? false
                let moving = Set(whole ? pair?.ids ?? [wanted] : [wanted])
                guard chosenThere.map({ !moving.contains($0) }) ?? true else { continue }
                var kept: [TabState] = [], taken: [TabState] = []
                let lifted = Dictionary(windows[from].spaces[list].tabs.filter { moving.contains($0.id) }.map { ($0.id, $0.parentID) },
                                        uniquingKeysWith: { a, _ in a })
                for var tab in windows[from].spaces[list].tabs {
                    if moving.contains(tab.id) {
                        // Under a tab that stays behind: at the top level here.
                        if let parent = tab.parentID, !moving.contains(parent) { tab.parentID = nil }
                        taken.append(tab)
                    } else {
                        // Under a tab that left: a level up, under that one's own parent.
                        while let parent = tab.parentID, moving.contains(parent) { tab.parentID = lifted[parent] ?? nil }
                        kept.append(tab)
                    }
                }
                windows[from].spaces[list].tabs = kept
                windows[from].splits?.removeAll { !$0.ids.allSatisfy { !moving.contains($0) } }
                if whole, let pair { windows[w].splits = (windows[w].splits ?? []) + [pair] }
                if let mine = windows[w].spaces.firstIndex(where: { $0.spaceID == space }) {
                    windows[w].spaces[mine].tabs = taken
                    windows[w].spaces[mine].selectedTabID = wanted
                }
            } else if chosenThere != wanted, let page = windows[from].bookmarkTabs.firstIndex(where: { $0.tab.id == wanted }),
                      !(windows[from].splits ?? []).contains(where: { $0.ids.contains(wanted) }),
                      let mine = windows[w].spaces.firstIndex(where: { $0.spaceID == space }) {
                // A pinned page or favorite it was on: its open page comes with it.
                windows[w].bookmarkTabs.append(windows[from].bookmarkTabs.remove(at: page))
                windows[w].spaces[mine].selectedTabID = wanted
            }
        }
        return SessionState(windows: windows)
    }
}

private extension SessionState.WindowState {
    nonisolated var hasNoTabs: Bool { spaces.allSatisfy(\.tabs.isEmpty) && bookmarkTabs.isEmpty }
    nonisolated func holds(_ id: UUID) -> Bool {
        spaces.contains { $0.tabs.contains { $0.id == id } } || bookmarkTabs.contains { $0.tab.id == id }
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

    /// A tab's window: its creator, or with shared tabs (#162) the one showing it or that last did, else the first
    /// listing it. Extensions, scripts and prompts use this.
    func window(of tab: Tab) -> BrowserWindowController? {
        if let host = tab.host as? BrowserWindowController, !host.tabManager.isInvalidated, host.tabManager.tab(with: tab.id) === tab { return host }
        return controllers.first { $0.tabManager.tab(with: tab.id) === tab }
    }

    /// Each open tab of your windows once; `everyOpenTab` adds AI apps'.
    var openTabs: [Tab] {
        var seen = Set<ObjectIdentifier>()
        return controllers.flatMap { controller -> [Tab] in
            guard seen.insert(ObjectIdentifier(controller.tabManager.store)).inserted else { return [] }
            return controller.tabManager.allTabs
        }
    }

    /// With Settings › Tabs sharing on (#162), the first open everyday window's tabs.
    private var sharedStore: TabStore? {
        guard TabStore.windowsShareTabs else { return nil }
        return controllers.first { !$0.tabManager.isPrivate && !$0.tabManager.isInvalidated }?.tabManager.store
    }

    /// Sharing toggled: windows' tabs merge into one list, or each keeps its own (`TabStore.share`, `unshare`). No tab
    /// is lost.
    func tabSharingChanged() {
        let everyday = controllers.filter { !$0.tabManager.isPrivate }.map(\.tabManager)
        if TabStore.windowsShareTabs { TabStore.share(everyday) } else { TabStore.unshare(everyday) }
        scheduleSave()
    }

    #if DEBUG
    /// The debug bridge's `usewindow`: the window its commands go to, whichever is in front.
    weak var debugTarget: BrowserWindowController?
    #endif

    var keyController: BrowserWindowController? {
        #if DEBUG
        if let debugTarget, controllers.contains(where: { $0 === debugTarget }) { return debugTarget }
        #endif
        // Only your windows: AI apps' window in the background (Headless) isn't one.
        if let controller = NSApp.keyWindow?.windowController as? BrowserWindowController, controllers.contains(where: { $0 === controller }) { return controller }
        if let controller = NSApp.mainWindow?.windowController as? BrowserWindowController, controllers.contains(where: { $0 === controller }) { return controller }
        return lastKey ?? controllers.last
    }

    func windowBecameKey(_ controller: BrowserWindowController) {
        // AI apps' window in the background, shown to watch them: never taken for one of yours.
        guard controllers.contains(where: { $0 === controller }) else { return }
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

    /// How a new window comes on screen: in front and key, behind the front window, or straight into the Dock.
    enum Placement { case front, behind, minimized }

    @discardableResult
    func newWindow(url: URL? = nil, spaceID: UUID? = nil, showCommandBar: Bool = true, isPrivate: Bool = false,
                   by sender: Tab.LoadSender = .zigzag, placement: Placement = .front) -> BrowserWindowController {
        // Opened for Zigzag Mini alone, the saved windows are still waiting: they come back first, so a new window never
        // saves over them, and a plain ⌘N is simply them.
        if sessionWaiting, !isPrivate, restoreSession(), url == nil, let restored = controllers.last(where: { !$0.tabManager.isPrivate }) {
            restored.window?.makeKeyAndOrderFront(nil)
            return restored
        }
        // With shared tabs (#162), everyday windows share; private ones have their own.
        let shared = isPrivate ? nil : sharedStore
        let manager = TabManager(spaceID: spaceID ?? keyController?.tabManager.currentSpaceID, isPrivate: isPrivate, store: shared)
        if let shared, let front = (keyController.flatMap { $0.tabManager.store === shared ? $0 : nil }) ?? controllers.first(where: { $0.tabManager.store === shared }) {
            manager.startSelection(from: front.tabManager)
        }
        var frame: NSRect?
        let inFront = keyController?.window
        if let key = keyController, let window = key.window {
            // Cascade from the current window, like every Mac app. From full screen, from where it was before.
            let fullScreen = window.styleMask.contains(.fullScreen)
            frame = (fullScreen ? key.windowedFrame : window.frame)?.offsetBy(dx: Tokens.Space.x6, dy: -Tokens.Space.x6)
        }
        let controller = makeController(manager: manager, frame: frame, sidebarVisible: keyController?.root.sidebarVisible ?? true,
                                        sidebarWidth: keyController?.root.sidebarWidth)
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
        if placement == .front { controller.showWindow(nil) } else if let window = controller.window { Self.show(window, placement, front: inFront) }
        // Opened straight into a page (a link, the very first launch): onboarding is skipped for good, or the next
        // launch would show it instead of restoring this window and then save over it.
        if !isPrivate, Self.needsOnboarding { UserDefaults.standard.set(true, forKey: "ImportOfferDismissed") }
        if let url {
            manager.newTab(url: url, by: sender)
        } else if isPrivate {
            controller.commandBar.show(mode: .newTab)
        } else if showCommandBar {
            controller.commandBar.show(mode: .newTab)
        }
        return controller
    }

    /// Puts a new window on screen without taking focus from the window in front, or into the Dock.
    static func show(_ window: NSWindow, _ placement: Placement, front: NSWindow?) {
        switch placement {
        case .front: window.makeKeyAndOrderFront(nil)
        case .behind:
            if let front, front.isVisible { window.order(.below, relativeTo: front.windowNumber) } else { window.orderBack(nil) }
        case .minimized: window.miniaturize(nil)
        }
    }

    /// Your windows plus AI apps' unseen one: for tabs wherever they are, never for your windows.
    var everyController: [BrowserWindowController] { controllers + [Headless.window].compactMap { $0 } }

    /// Each open tab once, AI apps' included: for what reaches every running page.
    var everyOpenTab: [Tab] { openTabs + (Headless.window?.tabManager.allTabs ?? []) }

    /// AI apps' unseen window, kept out of `controllers`: never saved, scripted or taken for the front one.
    func makeHeadless(spaceID: UUID) -> BrowserWindowController {
        BrowserWindowController(tabManager: TabManager(spaceID: spaceID, isPrivate: false, keepsToProfile: Library.shared.profileID(ofSpace: spaceID)),
                                frame: NSRect(origin: Headless.parkedOrigin, size: Headless.parkedSize))
    }

    private func makeController(manager: TabManager, frame: NSRect?, sidebarVisible: Bool, sidebarWidth: CGFloat?) -> BrowserWindowController {
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
        // With shared tabs (#162), closing a window closes no tabs, so nothing to reopen.
        let isLastView = controller.tabManager.isLastView
        // Tabs closed in it before it closed: ⇧⌘T brings them back into another window after it. Never private ones.
        if isLastView, !controller.tabManager.isPrivate {
            orphanedClosedTabs = (orphanedClosedTabs + controller.tabManager.closedTabRecords).sorted { $0.closedAt < $1.closedAt }
            if orphanedClosedTabs.count > 50 { orphanedClosedTabs.removeFirst(orphanedClosedTabs.count - 50) }
        }
        // Kept to reopen (⇧⌘T's sibling in the File menu), with each tab's back/forward list. Never private windows.
        if isLastView, !controller.tabManager.isPrivate, controller.tabManager.allTabs.contains(where: { $0.url != nil }) {
            var history: [UUID: Data] = [:]
            for tab in controller.tabManager.allTabs { if let data = tab.interactionStateForSaving { history[tab.id] = data } }
            closedWindows.append((UUID(), windowState(controller), history, Date()))
            if closedWindows.count > 10 { closedWindows.removeFirst() }
        }
        controllers.removeAll { $0 === controller }
        if lastKey === controller { lastKey = nil }
        // Hand its tabs to windows still showing them first, so extensions see a move, not a close.
        if !isLastView { controller.tabManager.invalidate() }
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

    /// A page handed off from another device: routed like a link from another app, but always a tab, never Zigzag Mini.
    func openHandedOff(_ url: URL) { open(url, fromAnotherApp: true, allowsMini: false) }

    /// A page Zigzag itself opens (About's links, Send Feedback, release notes): a tab in the front window, as any
    /// link inside Zigzag, never Zigzag Mini, which is for links from other apps.
    func openFromZigzag(_ url: URL) {
        open(url, fromAnotherApp: false)
        NSApp.activate()
    }

    private func open(_ url: URL, fromAnotherApp: Bool, allowsMini: Bool = true) {
        // Settings › Zigzag Mini can send links to a Zigzag Mini of their own instead; files and links before onboarding
        // still open here. Zigzag Mini is never saved, so nothing about the session changes.
        if fromAnotherApp, allowsMini, opensInMini(url) {
            MiniWindowController.open(url: url, fromAnotherApp: true)
            return
        }
        // A link opened before onboarding was finished: you're browsing now, so the next launch restores this window
        // instead of starting over with the welcome (and then saving over what you opened).
        if Self.needsOnboarding { UserDefaults.standard.set(true, forKey: "ImportOfferDismissed") }
        let key = keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        if let controller = key ?? controllers.last(where: { !$0.tabManager.isPrivate }) ?? restoreIfNoWindows() {
            // Routed sites open in their space (#286).
            if fromAnotherApp, controller.openRouted(url, arrival: .otherApp, by: .zigzag) {
                controller.window?.makeKeyAndOrderFront(nil)
                return
            }
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
        Freezes.mark("session save")
        saveDebouncer.cancel()
        guard !controllers.isEmpty, !sessionWaiting else { return }
        // Started fresh and nothing done yet: the session from before is still the one to bring back.
        if freshStartUnused { return }
        // Private windows are never written down.
        let saved = controllers.filter { !$0.tabManager.isPrivate }
        guard !saved.isEmpty else { return }
        // Collected here; encoded and written on the writer's queue, only when changed (a page can flip its address
        // back and forth). With shared tabs (#162), the first window carries the list, the others only their selection.
        var listed = Set<ObjectIdentifier>()
        let state = SessionState(windows: saved.map { windowState($0, withTabs: listed.insert(ObjectIdentifier($0.tabManager.store)).inserted) })
        // Back/forward lists live in their own files: opaque and occasionally large. Only changed ones are
        // written, and never on the main thread.
        var keep = Set<UUID>()
        var writes: [(URL, Data)] = []
        var seen = Set<ObjectIdentifier>()
        for controller in saved where seen.insert(ObjectIdentifier(controller.tabManager.store)).inserted {
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
        for (url, data) in writes {
            // Owner-only folder and file: back and forward lists are history.
            guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
            Paths.makePrivate(url)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where UUID(uuidString: file.lastPathComponent).map({ !keep.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// `withTabs` false: a window sharing tabs with one saved before it (#162); keeps only its frame, space and
    /// selected tabs.
    private func windowState(_ controller: BrowserWindowController, withTabs: Bool = true) -> SessionState.WindowState {
        let manager = controller.tabManager
        let fullScreen = controller.window?.styleMask.contains(.fullScreen) == true
        let frame = (fullScreen ? controller.windowedFrame : nil) ?? controller.window?.frame ?? .zero
        func state(_ tab: Tab, parent: UUID? = nil) -> SessionState.TabState { SessionState.TabState(tab, parent: parent) }
        let spaces = Library.shared.spaces.map { space in
            let tabs = manager.tabs(in: space.id)
            // New tabs with no page aren't kept: the tabs under one come back a level up, as if it had closed.
            let parents = SessionState.savedParents(manager.treeNodes(in: space.id), keeping: Set(tabs.filter { $0.url != nil }.map(\.id)))
            return SessionState.SpaceTabs(spaceID: space.id, tabs: withTabs ? tabs.filter { $0.url != nil }.map { state($0, parent: parents[$0.id]) } : [],
                                          selectedTabID: manager.selectedTab(in: space.id)?.id)
        }
        let bookmarkTabs = withTabs ? manager.bookmarkTabs.map { SessionState.BookmarkTabState(bookmarkID: $0.key, tab: state($0.value)) } : []
        return SessionState.WindowState(frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                                        sidebarVisible: controller.root.sidebarVisible,
                                        sidebarWidth: Double(controller.root.sidebarWidth),
                                        currentSpaceID: manager.currentSpaceID,
                                        spaces: spaces, bookmarkTabs: bookmarkTabs,
                                        isFullScreen: controller.savesFullScreen,
                                        splits: withTabs ? manager.splits : nil,
                                        tabGroups: Self.savedGroups(spaces, in: manager))
    }

    /// Saved tabs' groups, top to bottom; nil when none.
    private static func savedGroups(_ spaces: [SessionState.SpaceTabs], in manager: TabManager) -> [TabGroup]? {
        var seen: Set<UUID> = []
        let groups = spaces.flatMap(\.tabs).compactMap { tab in tab.groupID.flatMap { seen.insert($0).inserted ? manager.group($0) : nil } }
        return groups.isEmpty ? nil : groups
    }

    // MARK: Restoring

    /// Zigzag opened for a link going to Zigzag Mini, as Arc's Little Arc does: the browser windows weren't brought back.
    /// Whatever asks for a browser window next brings them back first.
    var sessionWaiting = false

    /// Launched with Settings › General › On launch set to start fresh: until the new window is used, saving would put
    /// one blank page in place of the session that's still there to reopen (#433).
    var startingFresh = false

    /// Whether a page has actually loaded since a fresh start, so the old session should give way. It stays used for
    /// the rest of the run, even after that page closes. A new window or a second blank tab isn't browsing by itself,
    /// and mustn't let a save overwrite the session that's still there to reopen (#433).
    var sessionWasUsed: Bool {
        get { sessionUsed }
        set { if newValue { sessionUsed = true } }
    }
    private var sessionUsed = false

    /// Called as pages load: a page that finished loading somewhere marks the fresh session used, and it stays used
    /// for the rest of the run even after its tabs close.
    func pageLoaded() { sessionWasUsed = true }

    /// Started fresh and nothing done yet: the session on disk is still the one passed over.
    var freshStartUnused: Bool { startingFresh && !sessionWasUsed }

    /// Brings back every window and tab from the last run, crash or not. Returns false if there was nothing.
    @discardableResult
    func restoreSession() -> Bool {
        sessionWaiting = false
        // Its tabs are made by now: what they kept of their sessionStorage is saved again from here.
        defer { SavedSessionStorage.sessionCameBack() }
        // The session on disk is the one a fresh start passed over: it comes back only from History.
        if freshStartUnused { return false }
        finishSaving()
        guard let saved = JSONStore.load(SessionState.self, from: Paths.session), !saved.windows.isEmpty else { return false }
        // With shared tabs (#162), every window's tabs restore into one list, each once, however saved; otherwise per
        // window.
        let shares = TabStore.windowsShareTabs
        let state = shares ? saved : saved.givingWindowsTheirOwnTabs()
        var allIDs = Set<UUID>()
        let store: TabStore? = shares ? sharedStore ?? TabStore() : nil
        for windowState in state.windows {
            allIDs.formUnion(restoreWindow(windowState, store: store))
        }
        SnapshotStore.prune(keeping: allIDs)
        return !controllers.isEmpty
    }

    /// A fresh start passed the last session over: keep it, so History › Reopen Last Session can bring back what it
    /// was, however long the fresh window is used first (#433). An empty session never replaces a kept one: a fresh
    /// start that only opened Settings or a Mini must not erase the session it passed over.
    func keepSessionForReopening(session: URL = Paths.session, kept: URL = Paths.previousSession,
                                 tabStates: URL = Paths.tabState, keptTabStates: URL = Paths.previousTabState) {
        // One copy per run: the session from before this launch, never this run's own saving over it.
        guard !keptPreviousSession else { return }
        guard let saved = JSONStore.load(SessionState.self, from: session),
              saved.windows.contains(where: { !$0.hasNoTabs }) else { return }
        guard JSONStore.save(saved, to: kept) else { return }
        Self.keepTabStates(of: saved, from: tabStates, to: keptTabStates)
        keptPreviousSession = true
    }

    /// Whether there's a session from before a fresh start to bring back.
    var canReopenLastSession: Bool { hasSessionToReopen(at: Paths.previousSession) }

    /// Whether the kept session at `kept` still has a window that isn't already open.
    func hasSessionToReopen(at kept: URL) -> Bool {
        guard let saved = JSONStore.load(SessionState.self, from: kept) else { return false }
        return !Self.windowsToReopen(saved, open: openTabIDs, shares: TabStore.windowsShareTabs).isEmpty
    }

    /// The kept session's windows not open again, so reopening never brings back a tab that's open. A window saved
    /// without tabs (#162) is back once any of the session's tabs is.
    static func windowsToReopen(_ saved: SessionState, open: Set<UUID>, shares: Bool) -> [SessionState.WindowState] {
        guard saved.windows.contains(where: { !$0.hasNoTabs }) else { return [] }
        let windows = (shares ? saved : saved.givingWindowsTheirOwnTabs()).windows
        let anyBack = windows.contains { isBack($0, open: open) }
        return windows.filter { $0.hasNoTabs ? !anyBack : !isBack($0, open: open) }
    }

    /// History › Reopen Last Session: the windows and tabs a fresh start passed over come back, with the back/forward
    /// lists kept beside them, and the fresh session stays until the next launch writes over it.
    func reopenLastSession(kept: URL = Paths.previousSession, keptTabStates: URL = Paths.previousTabState,
                           tabStates: URL = Paths.tabState) {
        guard let saved = JSONStore.load(SessionState.self, from: kept) else { return }
        let shares = TabStore.windowsShareTabs
        let windows = Self.windowsToReopen(saved, open: openTabIDs, shares: shares)
        guard !windows.isEmpty else { return }
        Self.restoreKeptTabStates(of: SessionState(windows: windows), from: keptTabStates, to: tabStates)
        let store: TabStore? = shares ? sharedStore ?? TabStore() : nil
        for windowState in windows { restoreWindow(windowState, store: store) }
    }

    /// The back/forward lists of a session being kept: copied now, before the fresh session's saves can clean up the
    /// old tabs' files (#433).
    nonisolated static func keepTabStates(of saved: SessionState, from source: URL, to destination: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(destination.path, 0o700)
        for id in tabIDs(of: saved) {
            let from = source.appendingPathComponent(id.uuidString)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = destination.appendingPathComponent(id.uuidString)
            guard (try? fm.copyItem(at: from, to: to)) != nil else { continue }
            Paths.makePrivate(to)
        }
    }

    /// Puts a kept session's back/forward lists back where restoring reads them, so reopening brings the history
    /// with the tabs.
    nonisolated static func restoreKeptTabStates(of saved: SessionState, from source: URL, to destination: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for id in tabIDs(of: saved) {
            let from = source.appendingPathComponent(id.uuidString)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = destination.appendingPathComponent(id.uuidString)
            // A tab already open has a current list of its own: the kept older one mustn't replace it.
            guard !fm.fileExists(atPath: to.path) else { continue }
            guard (try? fm.copyItem(at: from, to: to)) != nil else { continue }
            Paths.makePrivate(to)
        }
    }

    private nonisolated static func tabIDs(of saved: SessionState) -> Set<UUID> {
        var ids = Set<UUID>()
        for window in saved.windows {
            for space in window.spaces { ids.formUnion(space.tabs.map(\.id)) }
            ids.formUnion(window.bookmarkTabs.map(\.tab.id))
        }
        return ids
    }

    private var keptPreviousSession = false

    #if DEBUG
    /// Tests that keep more than one session in a run: the one copy per run is a launch rule (#433).
    func forgetKeptSessionForTesting() { keptPreviousSession = false }
    /// Tests that close a whole window: what it left for ⇧⌘T goes, so the next test starts with nothing to reopen.
    func forgetClosedForTesting() { closedWindows.removeAll(); orphanedClosedTabs.removeAll() }
    #endif

    /// Windows closed this session, newest last, to bring back with ⇧⌘N's neighbor, Reopen Closed Window.
    private var closedWindows: [(id: UUID, state: SessionState.WindowState, history: [UUID: Data], closedAt: Date)] = [] {
        didSet { Self.recentlyClosedChanged.send() }
    }
    /// Tabs closed in everyday windows that have closed since, oldest first.
    private var orphanedClosedTabs: [TabManager.ClosedTab] = [] {
        didSet { Self.recentlyClosedChanged.send() }
    }

    /// Fires when everyday windows' closed tabs or the closed windows change; never for a private window.
    static let recentlyClosedChanged = Signal<Void>()

    /// What can be brought back, for `chrome.sessions`, never a private window's: tabs closed in open windows (one
    /// list per shared store), tabs of windows since closed, and closed windows not already back.
    var recentlyClosed: (tabs: [TabManager.ClosedTab], windows: [(id: UUID, state: SessionState.WindowState, closedAt: Date)]) {
        var stores = Set<ObjectIdentifier>()
        var tabs = orphanedClosedTabs
        for manager in controllers.map(\.tabManager) where !manager.isPrivate && !manager.isInvalidated
            && stores.insert(ObjectIdentifier(manager.store)).inserted {
            tabs += manager.closedTabRecords
        }
        let open = openTabIDs
        return (tabs, closedWindows.filter { !Self.isBack($0.state, open: open) }.map { ($0.id, $0.state, $0.closedAt) })
    }

    /// Reopens one closed tab as History › Recently Closed does, in its window brought to the front. One of a window
    /// since closed goes into the front everyday window, as ⇧⌘T puts it. False when it's no longer there.
    @discardableResult
    func reopenClosedTab(_ id: UUID) -> Bool {
        let key = keyController
        let everyday = controllers.filter { !$0.tabManager.isPrivate && !$0.tabManager.isInvalidated }
        let ordered = everyday.filter { $0 === key } + everyday.filter { $0 !== key }
        if let controller = ordered.first(where: { $0.tabManager.closedTabRecords.contains { $0.id == id } }) {
            controller.window?.makeKeyAndOrderFront(nil)
            return controller.tabManager.reopenClosedTab(id) != nil
        }
        guard orphanedClosedTabs.contains(where: { $0.id == id }) else { return false }
        if !controllers.contains(where: { !$0.tabManager.isPrivate }) { reopen() }
        let front = keyController?.tabManager
        let into = front.flatMap { $0.isPrivate ? nil : $0 } ?? controllers.first { !$0.tabManager.isPrivate }?.tabManager
        guard let into, let index = orphanedClosedTabs.lastIndex(where: { $0.id == id }) else { return false }
        let record = orphanedClosedTabs.remove(at: index)
        controllers.first { $0.tabManager === into }?.window?.makeKeyAndOrderFront(nil)
        return into.reopenFromClosedWindow(record) != nil
    }

    /// What ⇧⌘T brings back: a tab, into the window it closed in, a tab of a window since closed, or a window.
    enum LastClosed: Equatable { case tab, tabOfClosedWindow, window }

    /// The latest of the three, by when each closed; a tie goes to the tab.
    static func lastClosed(tab: Date?, tabOfClosedWindow: Date?, window: Date?) -> LastClosed? {
        var best: (kind: LastClosed, at: Date)?
        for (kind, date) in [(LastClosed.tab, tab), (.tabOfClosedWindow, tabOfClosedWindow), (.window, window)] {
            guard let date else { continue }
            if best.map({ date > $0.at }) ?? true { best = (kind, date) }
        }
        return best?.kind
    }

    /// The everyday window views with closed tabs, `front`'s first, one per shared store, and each one's latest.
    private func latestClosedTab(from front: TabManager?) -> (manager: TabManager, tab: TabManager.ClosedTab)? {
        var managers = controllers.map(\.tabManager).filter { !$0.isPrivate && !$0.isInvalidated }
        if let front { managers.insert(front, at: 0) }
        var stores = Set<ObjectIdentifier>()
        var best: (manager: TabManager, tab: TabManager.ClosedTab)?
        for manager in managers where stores.insert(ObjectIdentifier(manager.store)).inserted {
            guard let last = manager.lastClosedTab else { continue }
            if best.map({ last.closedAt > $0.tab.closedAt }) ?? true { best = (manager, last) }
        }
        return best
    }

    private func lastClosed(from front: TabManager?) -> (kind: LastClosed, manager: TabManager?, id: UUID?)? {
        // A private window brings back only its own tabs; an everyday one never a private tab.
        if let front, front.isPrivate { return front.lastClosedTab.map { (.tab, front, $0.id) } }
        let tab = latestClosedTab(from: front)
        let open = openTabIDs
        let window = closedWindows.last { !Self.isBack($0.state, open: open) }
        switch Self.lastClosed(tab: tab?.tab.closedAt, tabOfClosedWindow: orphanedClosedTabs.last?.closedAt, window: window?.closedAt) {
        case .tab: return tab.map { (.tab, $0.manager, $0.tab.id) }
        case .tabOfClosedWindow: return (.tabOfClosedWindow, nil, nil)
        case .window: return (.window, nil, nil)
        case nil: return nil
        }
    }

    /// ⇧⌘T: anything closed to bring back, from the window `front` shows.
    func canReopenLastClosed(from front: TabManager?) -> Bool { lastClosed(from: front) != nil }

    /// ⇧⌘T, as in Chrome: the latest closed tab or window anywhere. A tab goes back into its window if that's still
    /// open, else into `front`'s.
    func reopenLastClosed(from front: TabManager?) {
        guard let last = lastClosed(from: front) else { return }
        switch last.kind {
        case .tab:
            guard let manager = last.manager, let id = last.id else { return }
            if manager !== front, let controller = controllers.first(where: { $0.tabManager === manager }) {
                controller.window?.makeKeyAndOrderFront(nil)
            }
            manager.reopenClosedTab(id)
        case .tabOfClosedWindow:
            if !controllers.contains(where: { !$0.tabManager.isPrivate }) { reopen() }
            let into = front.flatMap { $0.isPrivate ? nil : $0 } ?? controllers.first { !$0.tabManager.isPrivate }?.tabManager
            guard let into, let record = orphanedClosedTabs.popLast() else { return }
            controllers.first { $0.tabManager === into }?.window?.makeKeyAndOrderFront(nil)
            into.reopenFromClosedWindow(record)
        case .window:
            reopenClosedWindow()
        }
    }

    var canReopenClosedWindow: Bool {
        let open = openTabIDs
        return closedWindows.contains { !Self.isBack($0.state, open: open) }
    }

    /// Brings back the last closed window, its spaces, tabs, history and place on screen.
    func reopenClosedWindow() {
        // Already back (the Dock icon restored it after the last window closed): never a second copy of the same tabs,
        // so it's passed over for the one closed before it.
        let open = openTabIDs
        while let closed = closedWindows.popLast() {
            guard !Self.isBack(closed.state, open: open) else { continue }
            restoreWindow(closed.state, history: closed.history, store: sharedStore)
            return
        }
    }

    /// Reopenable closed windows, newest first, for History › Recently Closed, with tab count and shown tab.
    var recentlyClosedWindows: [(id: UUID, tabCount: Int, shown: SessionState.TabState?)] {
        let open = openTabIDs
        return closedWindows.reversed().filter { !Self.isBack($0.state, open: open) }.map { closed in
            let state = closed.state
            let tabs = state.spaces.flatMap(\.tabs) + state.bookmarkTabs.map(\.tab)
            let space = state.spaces.first { $0.spaceID == state.currentSpaceID }
            let shown = space.flatMap { space in space.tabs.first { $0.id == space.selectedTabID } } ?? tabs.first
            return (closed.id, tabs.count, shown)
        }
    }

    /// Reopens a closed window from History › Recently Closed.
    func reopenClosedWindow(_ id: UUID) {
        guard let index = closedWindows.firstIndex(where: { $0.id == id }) else { return }
        let closed = closedWindows.remove(at: index)
        guard !Self.isBack(closed.state, open: openTabIDs) else { return }
        restoreWindow(closed.state, history: closed.history, store: sharedStore)
    }

    private var openTabIDs: Set<UUID> { Set(openTabs.map(\.id)) }

    private static func isBack(_ state: SessionState.WindowState, open: Set<UUID>) -> Bool {
        let ids = state.spaces.flatMap { $0.tabs.map(\.id) } + state.bookmarkTabs.map(\.tab.id)
        return ids.contains(where: open.contains)
    }

    /// Restores one window and returns its tab ids. `history` replaces back/forward lists missing on disk. `store`:
    /// tabs shared with other windows (#162); existing tabs aren't duplicated and the window selects the shared one.
    @discardableResult
    private func restoreWindow(_ windowState: SessionState.WindowState, history: [UUID: Data] = [:], store: TabStore? = nil) -> Set<UUID> {
            let (manager, allIDs) = restoredTabs(windowState, history: history, store: store)
            let f = windowState.frame
            var frame: NSRect? = f.count == 4 ? NSRect(x: f[0], y: f[1], width: f[2], height: f[3]) : nil
            if let rect = frame, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { frame = nil }
            let controller = makeController(manager: manager, frame: frame, sidebarVisible: windowState.sidebarVisible,
                                            sidebarWidth: CGFloat(windowState.sidebarWidth))
            controller.showWindow(nil)
            if windowState.isFullScreen == true { controller.window?.toggleFullScreen(nil) }
            return allIDs
    }

    /// A saved window's tabs, splits and selections, restored before the window is created, plus the tab ids.
    func restoredTabs(_ windowState: SessionState.WindowState, history: [UUID: Data] = [:], store: TabStore? = nil) -> (TabManager, Set<UUID>) {
            var allIDs = Set<UUID>()
            let manager = TabManager(spaceID: windowState.currentSpaceID, store: store)
            let present = Set(manager.allTabs.map(\.id))
            // A pinned page another window already restored: reuse that tab.
            var sameAs: [UUID: UUID] = [:]
            // Groups before tabs so tabs find theirs.
            manager.restoreGroups(windowState.tabGroups ?? [])
            var selection: [UUID: UUID] = [:]
            // A space that's gone (the library couldn't be read and started over) keeps its tabs: they join the space
            // the window was on, or the first one, rather than vanish and be overwritten by the next save.
            let fallback = Library.shared.space(windowState.currentSpaceID) != nil ? windowState.currentSpaceID : Library.shared.spaces[0].id
            for spaceTabs in windowState.spaces {
                let space = Library.shared.space(spaceTabs.spaceID) != nil ? spaceTabs.spaceID : fallback
                let tabs = spaceTabs.tabs.filter { !present.contains($0.id) }.map { restoreTab($0, spaceID: space, history: history[$0.id]) }
                manager.adopt(tabs, in: space)
                if space == spaceTabs.spaceID, let selected = spaceTabs.selectedTabID { selection[space] = selected }
                allIDs.formUnion(tabs.map(\.id))
                allIDs.formUnion(spaceTabs.tabs.map(\.id).filter(present.contains))
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
                if let there = manager.bookmarkTab(for: bookmarkState.bookmarkID) {
                    sameAs[bookmarkState.tab.id] = there.id
                    allIDs.insert(there.id)
                    continue
                }
                guard !present.contains(bookmarkState.tab.id) else { continue }
                let tab = restoreTab(bookmarkState.tab, spaceID: spaceID, history: history[bookmarkState.tab.id])
                tab.isFavorite = isFavorite
                manager.adoptBookmarkTab(tab, bookmarkID: bookmarkState.bookmarkID)
                allIDs.insert(tab.id)
            }
            // Splits and selection before the window is created, so its first frame shows them; otherwise it briefly
            // drew a blank address and no page.
            manager.restoreSplits(windowState.splits ?? [])
            manager.restoreSelection(selection.mapValues { sameAs[$0] ?? $0 }, currentSpaceID: windowState.currentSpaceID)
            return (manager, allIDs)
    }

    private func restoreTab(_ state: SessionState.TabState, spaceID: UUID, history: Data? = nil) -> Tab {
        let interaction = history ?? (try? Data(contentsOf: Paths.tabState.appendingPathComponent(state.id.uuidString)))
        let tab = Tab(id: state.id, url: state.url, title: state.title, spaceID: spaceID, interactionState: interaction,
                      lastActivated: state.lastActivated, createdAt: state.createdAt)
        state.apply(to: tab)
        tab.isRestored = true
        SavedSessionStorage.restore(into: tab)
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
                  collapsed: tab.isCollapsed ? true : nil, groupID: tab.bookmarkID == nil ? tab.groupID : nil)
    }

    /// What the session kept beyond the page itself, back on the tab made from it.
    func apply(to tab: Tab) {
        tab.customTitle = customTitle
        tab.customIcon = customIcon
        tab.parentID = parentID
        tab.isCollapsed = collapsed ?? false
        tab.groupID = groupID
    }
}

extension BrowserWindowController {
    /// Whether this window holds a listed tab (for extensions, scripts, the mini player): always, unless tabs are
    /// shared (#162), then only if it's the tab's window (`WindowManager.window(of:)`).
    func holds(_ tab: Tab) -> Bool {
        !tabManager.store.isShared || WindowManager.shared.window(of: tab) === self
    }
}

import AppKit

/// Saved state of every window and tab, written often so a crash loses nothing.
struct SessionState: Codable {
    struct TabState: Codable {
        var id: UUID
        var url: URL?
        var title: String
        var lastActivated: Date
        var createdAt: Date
    }

    struct SpaceTabs: Codable {
        var spaceID: UUID
        var tabs: [TabState]
        var selectedTabID: UUID?
    }

    struct BookmarkTabState: Codable {
        var bookmarkID: UUID
        var tab: TabState
    }

    struct WindowState: Codable {
        var frame: [Double]
        var sidebarVisible: Bool
        var sidebarWidth: Double
        var currentSpaceID: UUID
        var spaces: [SpaceTabs]
        var bookmarkTabs: [BookmarkTabState]
        var isFullScreen: Bool?
    }

    var windows: [WindowState]
}

/// Creates, tracks and restores browser windows.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [BrowserWindowController] = []
    private weak var lastKey: BrowserWindowController?
    private let saveDebouncer = Debouncer(delay: 1.5)
    private var isTerminating = false

    var keyController: BrowserWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? BrowserWindowController { return controller }
        if let controller = NSApp.mainWindow?.windowController as? BrowserWindowController { return controller }
        return lastKey ?? controllers.last
    }

    func windowBecameKey(_ controller: BrowserWindowController) {
        lastKey = controller
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowFocused(controller) }
    }

    // MARK: Creating

    @discardableResult
    func newWindow(url: URL? = nil, spaceID: UUID? = nil, showCommandBar: Bool = true) -> BrowserWindowController {
        let manager = TabManager(spaceID: spaceID ?? keyController?.tabManager.currentSpaceID)
        var frame: NSRect?
        if let key = keyController?.window {
            // Cascade from the current window, like every Mac app.
            frame = key.frame.offsetBy(dx: Tokens.Space.x6, dy: -Tokens.Space.x6)
        }
        let controller = makeController(manager: manager, frame: frame, sidebarVisible: keyController?.root.sidebarVisible ?? true,
                                        sidebarWidth: keyController?.root.sidebarWidth ?? Tokens.Metric.sidebarWidth)
        controller.showWindow(nil)
        if let url {
            manager.newTab(url: url)
        } else if !Library.shared.importedFromArc, !UserDefaults.standard.bool(forKey: "ArcOfferDismissed"), ArcImporter.isAvailable {
            controller.showWelcome()
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
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowOpened(controller) }
        return controller
    }

    private func windowClosed(_ controller: BrowserWindowController) {
        guard !isTerminating else { return }
        // Keep the last window's tabs for next launch even if it is closed before quitting.
        if controllers.count == 1 { saveNow() }
        controllers.removeAll { $0 === controller }
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowClosed(controller) }
        controller.tabManager.invalidate()
        if !controllers.isEmpty { scheduleSave() }
    }

    /// Opens a URL from outside (another app, Finder, the Dock) in the frontmost window.
    func openExternal(_ url: URL) {
        if let controller = keyController {
            controller.open(url, disposition: .foregroundTab)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(url: url)
        }
    }

    // MARK: Saving

    func scheduleSave() {
        saveDebouncer.call { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        saveDebouncer.cancel()
        guard !controllers.isEmpty else { return }
        let state = SessionState(windows: controllers.map(windowState))
        JSONStore.save(state, to: Paths.session)
        // Back/forward lists live in their own files: opaque and occasionally large.
        var keep = Set<UUID>()
        for controller in controllers {
            for tab in controller.tabManager.allTabs {
                keep.insert(tab.id)
                if let data = tab.interactionStateForSaving {
                    try? data.write(to: Paths.tabState.appendingPathComponent(tab.id.uuidString), options: .atomic)
                }
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.tabState, includingPropertiesForKeys: nil)) ?? []
        for file in files where UUID(uuidString: file.lastPathComponent).map({ !keep.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func windowState(_ controller: BrowserWindowController) -> SessionState.WindowState {
        let manager = controller.tabManager
        let frame = controller.window?.frame ?? .zero
        func state(_ tab: Tab) -> SessionState.TabState {
            SessionState.TabState(id: tab.id, url: tab.url, title: tab.displayTitle, lastActivated: tab.lastActivated, createdAt: tab.createdAt)
        }
        let spaces = Library.shared.spaces.map { space in
            SessionState.SpaceTabs(spaceID: space.id, tabs: manager.tabs(in: space.id).filter { $0.url != nil }.map(state),
                                   selectedTabID: manager.selectedTab(in: space.id)?.id)
        }
        let bookmarkTabs = manager.bookmarkTabs.map { SessionState.BookmarkTabState(bookmarkID: $0.key, tab: state($0.value)) }
        return SessionState.WindowState(frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                                        sidebarVisible: controller.root.sidebarVisible,
                                        sidebarWidth: Double(controller.root.sidebarWidth),
                                        currentSpaceID: manager.currentSpaceID,
                                        spaces: spaces, bookmarkTabs: bookmarkTabs,
                                        isFullScreen: controller.window?.styleMask.contains(.fullScreen))
    }

    // MARK: Restoring

    /// Brings back every window and tab from the last run, crash or not. Returns false if there was nothing.
    @discardableResult
    func restoreSession() -> Bool {
        guard let state = JSONStore.load(SessionState.self, from: Paths.session), !state.windows.isEmpty else { return false }
        var allIDs = Set<UUID>()
        for windowState in state.windows {
            let manager = TabManager(spaceID: windowState.currentSpaceID)
            var selection: [UUID: UUID] = [:]
            for spaceTabs in windowState.spaces where Library.shared.space(spaceTabs.spaceID) != nil {
                let tabs = spaceTabs.tabs.map { restoreTab($0, spaceID: spaceTabs.spaceID) }
                manager.adopt(tabs, in: spaceTabs.spaceID)
                if let selected = spaceTabs.selectedTabID { selection[spaceTabs.spaceID] = selected }
                allIDs.formUnion(tabs.map(\.id))
            }
            for bookmarkState in windowState.bookmarkTabs {
                guard let spaceID = Library.shared.spaceID(ofBookmark: bookmarkState.bookmarkID) else { continue }
                let tab = restoreTab(bookmarkState.tab, spaceID: spaceID)
                manager.adoptBookmarkTab(tab, bookmarkID: bookmarkState.bookmarkID)
                allIDs.insert(tab.id)
            }
            let f = windowState.frame
            var frame: NSRect? = f.count == 4 ? NSRect(x: f[0], y: f[1], width: f[2], height: f[3]) : nil
            if let rect = frame, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { frame = nil }
            let controller = makeController(manager: manager, frame: frame, sidebarVisible: windowState.sidebarVisible,
                                            sidebarWidth: CGFloat(windowState.sidebarWidth))
            manager.restoreSelection(selection, currentSpaceID: windowState.currentSpaceID)
            controller.showWindow(nil)
            if windowState.isFullScreen == true { controller.window?.toggleFullScreen(nil) }
        }
        SnapshotStore.prune(keeping: allIDs)
        return !controllers.isEmpty
    }

    private func restoreTab(_ state: SessionState.TabState, spaceID: UUID) -> Tab {
        let interaction = try? Data(contentsOf: Paths.tabState.appendingPathComponent(state.id.uuidString))
        return Tab(id: state.id, url: state.url, title: state.title, spaceID: spaceID, interactionState: interaction,
                   lastActivated: state.lastActivated, createdAt: state.createdAt)
    }

    func prepareForTermination() {
        saveNow()
        isTerminating = true
        Library.shared.saveNow()
    }
}

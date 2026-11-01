import AppKit

/// ⌘Z for everything you do in the sidebar. Each action registers its own inverse, and the inverse registers the redo.
extension BrowserWindowController {
    /// Routes ⌘Z: text fields keep their own undo; the page keeps it when its edit is newer than the sidebar's.
    func handleUndoKey(redo: Bool) -> Bool {
        let responder = window?.firstResponder
        if responder is NSText { return false }
        guard redo ? sidebarUndo.canRedo : sidebarUndo.canUndo else { return false }
        if let page = (responder as? NSView)?.undoManager, page !== sidebarUndo, redo ? page.canRedo : page.canUndo,
           UndoClock.lastPageEdit > UndoClock.lastSidebarEdit {
            return false
        }
        redo ? sidebarUndo.redo() : sidebarUndo.undo()
        return true
    }

    /// The window whose ⌘Z takes changes made from elsewhere (settings, menus without a window).
    static var undoTarget: BrowserWindowController? { WindowManager.shared.keyController ?? WindowManager.shared.controllers.first }

    /// A change made from outside any browser window (Settings): undoable from the front one, made all the same
    /// when there's none.
    static func changeLibrary(_ name: String, _ change: () -> Void) {
        if let undoTarget { undoTarget.libraryChange(name, change) } else { change() }
    }

    /// Runs a change to spaces, bookmarks or favorites; ⌘Z puts the library back exactly as it was.
    func libraryChange(_ name: String, _ change: () -> Void) {
        let before = Library.shared.snapshot
        change()
        registerLibraryUndo(name, restoring: before, redo: Library.shared.snapshot)
    }

    /// For changes made step by step (the space editor): one ⌘Z back to `before`.
    func recordLibraryUndo(_ name: String, before: Library.Snapshot) {
        registerLibraryUndo(name, restoring: before, redo: Library.shared.snapshot)
    }

    private func registerLibraryUndo(_ name: String, restoring before: Library.Snapshot, redo after: Library.Snapshot) {
        sidebarUndo.registerUndo(withTarget: self) { controller in
            // Changed since (an import, another window): putting back the old copy would undo those too.
            guard controller.libraryUnchanged(since: after) else { return }
            Library.shared.restore(before)
            controller.registerLibraryUndo(name, restoring: after, redo: before)
        }
        sidebarUndo.setActionName(name)
    }

    /// Whether the library is still as a change left it; if not, says why ⌘Z did nothing.
    func libraryUnchanged(since snapshot: Library.Snapshot) -> Bool {
        guard Library.shared.snapshot != snapshot else { return true }
        Toast.show("Can’t undo: spaces or pinned tabs have changed since then", symbol: "arrow.uturn.backward", duration: 2.5, in: self)
        return false
    }

    /// Runs a change to tabs, pinned pages or favorites. ⌘Z puts the library and this window's tabs back exactly as
    /// they were (the same pages, names and places, open or not); ⇧⌘Z does the change again.
    func pageChange(_ name: String, _ change: @escaping () -> Void) {
        let before = (library: Library.shared.snapshot, tabs: tabManager.arrangement)
        change()
        let after = (library: Library.shared.snapshot, tabs: tabManager.arrangement)
        guard before.library != after.library || !before.tabs.isSame(as: after.tabs) else { return }
        sidebarUndo.registerUndo(withTarget: self) { controller in
            guard controller.libraryUnchanged(since: after.library), controller.tabsUnchanged(since: after.tabs) else { return }
            Library.shared.restore(before.library)
            controller.tabManager.restore(before.tabs, undoing: after.tabs)
            controller.sidebarUndo.registerUndo(withTarget: controller) { controller in
                guard controller.libraryUnchanged(since: before.library), controller.tabsUnchanged(since: before.tabs) else { return }
                controller.pageChange(name, change)
            }
            controller.sidebarUndo.setActionName(name)
        }
        sidebarUndo.setActionName(name)
    }

    /// Whether this window's tabs are still as a change left them; if not, says why ⌘Z did nothing.
    private func tabsUnchanged(since arrangement: TabManager.Arrangement) -> Bool {
        guard !tabManager.isUnchanged(since: arrangement) else { return true }
        Toast.show("Can’t undo: tabs have changed since then", symbol: "arrow.uturn.backward", duration: 2.5, in: self)
        return false
    }

    // MARK: Split view

    func splitWithUndo(_ tab: Tab, with other: Tab, otherOnRight: Bool = true) {
        guard tabManager.canSplit(tab, with: other) else { return }
        pageChange("Split View") { [tabManager] in tabManager.makeSplit(tab, with: other, otherOnRight: otherOnRight) }
    }

    /// Ends a split, showing `keep` (or the tab itself) on its own. A pinned split ends too: both pages stay pinned,
    /// no longer a pair.
    func unsplitWithUndo(_ tab: Tab, keep: Tab? = nil) {
        guard tabManager.split(for: tab) != nil else { return }
        pageChange("Separate Tabs") { [tabManager] in
            if let keep { tabManager.unsplit(tab, keep: keep) } else { tabManager.unsplit(tab) }
            if let id = tab.bookmarkID { Library.shared.removePinnedSplit(containing: id) }
        }
    }

    /// A split favorite parted into two favorites, side by side in the grid; open, its pages part on screen too.
    func separateFavoriteSplitWithUndo(_ favoriteID: UUID) {
        guard let pair = Library.shared.pinnedSplit(containing: favoriteID) else { return }
        pageChange("Separate Tabs") { [tabManager] in
            for id in [pair.left, pair.right] { if let live = tabManager.bookmarkTab(for: id) { tabManager.unsplit(live) } }
            Library.shared.removePinnedSplit(containing: favoriteID)
        }
    }

    // MARK: Favorites

    /// A tab (and a split's other half) into the favorites at a tile's place (nil: the end).
    func favoriteWithUndo(_ tab: Tab, at index: Int? = nil) {
        pageChange("Add to Favorites") { [tabManager] in tabManager.favoriteTab(tab, at: index) }
    }

    /// A tab or pinned page dropped on a favorite's middle: the two become one favorite, side by side.
    func joinFavoriteWithUndo(_ tab: Tab, onto favoriteID: UUID, onRight: Bool) {
        pageChange("Split View") { [tabManager] in tabManager.joinFavorite(tab, onto: favoriteID, onRight: onRight) }
    }

    /// A favorite back to a regular tab in a space's list (nil: the space you're in).
    func unfavoriteWithUndo(_ id: UUID, to index: Int, in spaceID: UUID? = nil) {
        pageChange("Move to Tabs") { [tabManager] in tabManager.unbookmark(id, toIndex: index, in: spaceID) }
    }

    func removeFavoriteWithUndo(_ id: UUID) {
        // A split favorite goes as one: both its pages.
        let ids = Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id]
        libraryChange("Remove from Favorites") {
            for id in ids { if let live = tabManager.bookmarkTab(for: id) { tabManager.close(live) } }
            Library.shared.removeBookmarks(ids)
        }
    }

    // MARK: Tabs

    /// Closes several tabs; ⌘Z reopens them all, each where it was, with the tab you were on selected again.
    /// `leavingSpaceEmpty`: if no tabs are left, the space shows empty instead of a pinned page from earlier.
    func closeManyWithUndo(_ tabs: [Tab], leavingSpaceEmpty: Bool = false) {
        let selectedID = tabManager.selectedTab?.id
        let ids = leavingSpaceEmpty ? tabManager.closeLeavingSpaceEmpty(tabs) : tabManager.close(tabs)
        guard !ids.isEmpty else { return }
        sidebarUndo.registerUndo(withTarget: self) { controller in
            // By id, so a tab reopened meanwhile with ⇧⌘T doesn't make this bring back an unrelated one.
            var reopened: [Tab] = []
            var selected = selectedID.flatMap { controller.tabManager.tab(with: $0) }
            for id in ids.reversed() {
                guard let tab = controller.tabManager.reopenClosedTab(id) else { continue }
                reopened.append(tab)
                if id == selectedID { selected = tab }
            }
            if let selected { controller.tabManager.select(selected) }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.closeManyWithUndo(reopened) }
            controller.sidebarUndo.setActionName("Close Tabs")
        }
        sidebarUndo.setActionName("Close Tabs")
    }

    // MARK: Spaces

    /// Deletes a space; ⌘Z brings back the space, its bookmarks and its tabs, history and all.
    func removeSpaceWithUndo(_ id: UUID) {
        guard Library.shared.spaces.count > 1, let index = Library.shared.index(of: id), let space = Library.shared.space(id) else { return }
        struct Closed {
            weak var window: BrowserWindowController?
            let isPrivate: Bool
            let selected: UUID?
            let tabs: [(id: UUID, url: URL?, title: String)]
        }
        // The space's tabs in every window close first, as closed tabs, so ⌘Z can reopen each where it was.
        let closed = WindowManager.shared.controllers.map { window in
            let list = window.tabManager.tabs(in: id)
            let info = Dictionary(uniqueKeysWithValues: list.map { ($0.id, (url: $0.url, title: $0.displayTitle)) })
            let selected = window.tabManager.selectedTab(in: id)?.id
            let order = window.tabManager.close(list)
            return Closed(window: window, isPrivate: window.tabManager.isPrivate, selected: selected,
                          tabs: order.compactMap { tabID in info[tabID].map { (id: tabID, url: $0.url, title: $0.title) } })
        }
        Library.shared.removeSpace(id)
        sidebarUndo.registerUndo(withTarget: self) { controller in
            // Only this space comes back, so whatever changed since in the others stays.
            Library.shared.insertSpace(space, at: index)
            var shown: Tab?
            for entry in closed {
                // A window closed since: its tabs come back here, unless they were private.
                let target: BrowserWindowController
                if let window = entry.window, WindowManager.shared.controllers.contains(where: { $0 === window }) {
                    target = window
                } else if !entry.isPrivate {
                    target = controller
                } else {
                    continue
                }
                for tab in entry.tabs.reversed() {
                    // Too long ago to still be among the closed tabs: back as a fresh one.
                    let reopened = target.tabManager.reopenClosedTab(tab.id, select: false)
                        ?? target.tabManager.newTab(url: tab.url, spaceID: id, select: false, title: tab.title)
                    if target === controller, tab.id == entry.selected { shown = reopened }
                }
            }
            if let shown { controller.tabManager.select(shown) } else { controller.tabManager.switchToSpace(id) }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.removeSpaceWithUndo(id) }
            controller.sidebarUndo.setActionName("Delete Space")
        }
        sidebarUndo.setActionName("Delete Space")
    }
}

/// When the sidebar and the page last recorded something undoable, so ⌘Z undoes the newer one.
@MainActor
enum UndoClock {
    static var lastSidebarEdit = Date.distantPast
    /// Set by typing into a page (see BrowserWindow.sendEvent).
    static var lastPageEdit = Date.distantPast
    private static var token: NSObjectProtocol?

    static func start() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: nil, queue: .main) { note in
            let source = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if WindowManager.shared.controllers.contains(where: { ObjectIdentifier($0.sidebarUndo) == source }) { lastSidebarEdit = Date() }
            }
        }
    }
}

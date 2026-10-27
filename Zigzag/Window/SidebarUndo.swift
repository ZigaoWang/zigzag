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
        Toast.show("Can’t undo: spaces or pinned tabs changed since", symbol: "arrow.uturn.backward", duration: 2.5, in: self)
        return false
    }

    // MARK: Split view

    func splitWithUndo(_ tab: Tab, with other: Tab, otherOnRight: Bool = true) {
        guard tabManager.canSplit(tab, with: other) else { return }
        let previous = [tabManager.split(for: tab), tabManager.split(for: other)].compactMap { $0 }
        let selected = tabManager.selectedTab
        tabManager.makeSplit(tab, with: other, otherOnRight: otherOnRight)
        sidebarUndo.registerUndo(withTarget: self) { controller in
            controller.tabManager.unsplit(other, notify: true)
            previous.forEach { controller.tabManager.restoreSplit($0) }
            if let selected { controller.tabManager.select(selected) }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.splitWithUndo(tab, with: other, otherOnRight: otherOnRight) }
            controller.sidebarUndo.setActionName("Split View")
        }
        sidebarUndo.setActionName("Split View")
    }

    /// Ends a split, showing `keep` (or the tab itself) on its own.
    func unsplitWithUndo(_ tab: Tab, keep: Tab? = nil) {
        guard let pair = tabManager.split(for: tab) else { return }
        let selected = tabManager.selectedTab
        if let keep { tabManager.unsplit(tab, keep: keep) } else { tabManager.unsplit(tab) }
        sidebarUndo.registerUndo(withTarget: self) { controller in
            controller.tabManager.restoreSplit(pair)
            if let selected { controller.tabManager.select(selected) }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.unsplitWithUndo(tab, keep: keep) }
            controller.sidebarUndo.setActionName("Separate Tabs")
        }
        sidebarUndo.setActionName("Separate Tabs")
    }

    // MARK: Favorites

    func favoriteWithUndo(_ tab: Tab, at index: Int? = nil) {
        let oldIndex = tabManager.tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0
        let wasBookmark = tab.bookmarkID
        let before = Library.shared.snapshot
        tabManager.favoriteTab(tab, at: index)
        guard let id = tab.bookmarkID else { return }
        let after = Library.shared.snapshot
        sidebarUndo.registerUndo(withTarget: self) { controller in
            if wasBookmark != nil {
                // It was a bookmark: it simply goes back to its space.
                guard controller.libraryUnchanged(since: after) else { return }
                Library.shared.restore(before)
                tab.isFavorite = false
            } else {
                controller.tabManager.unbookmark(id, toIndex: oldIndex)
            }
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.favoriteWithUndo(tab, at: index) }
            controller.sidebarUndo.setActionName("Add to Favorites")
        }
        sidebarUndo.setActionName("Add to Favorites")
    }

    /// A favorite back to a regular tab in the list.
    func unfavoriteWithUndo(_ id: UUID, to index: Int) {
        let before = Library.shared.snapshot
        let live = tabManager.bookmarkTab(for: id)
        tabManager.unbookmark(id, toIndex: index)
        let after = Library.shared.snapshot
        sidebarUndo.registerUndo(withTarget: self) { controller in
            if let live {
                let oldPosition = before.favoriteIndex(of: id) ?? Library.shared.favorites.count
                controller.tabManager.favoriteTab(live, at: oldPosition)
            } else {
                guard controller.libraryUnchanged(since: after) else { return }
                Library.shared.restore(before)
            }
            let redoID = live?.bookmarkID ?? id
            controller.sidebarUndo.registerUndo(withTarget: controller) { $0.unfavoriteWithUndo(redoID, to: index) }
            controller.sidebarUndo.setActionName("Move to Tabs")
        }
        sidebarUndo.setActionName("Move to Tabs")
    }

    func removeFavoriteWithUndo(_ id: UUID) {
        libraryChange("Remove from Favorites") {
            if let live = tabManager.bookmarkTab(for: id) { tabManager.close(live) }
            Library.shared.removeBookmark(id)
        }
    }

    // MARK: Tabs

    /// Closes several tabs; ⌘Z reopens them all, each where it was, with the tab you were on selected again.
    func closeManyWithUndo(_ tabs: [Tab]) {
        let selectedID = tabManager.selectedTab?.id
        let ids = tabManager.close(tabs)
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
        // The space's tabs in every window close first, as closed tabs, so ⌘Z can reopen each where it was.
        let closed = WindowManager.shared.controllers.map { window in
            let list = window.tabManager.tabs(in: id)
            let info = Dictionary(uniqueKeysWithValues: list.map { ($0.id, (url: $0.url, title: $0.displayTitle)) })
            let selected = window.tabManager.selectedTab(in: id)?.id
            let order = window.tabManager.close(list)
            return (window: ObjectIdentifier(window), selected: selected,
                    tabs: order.compactMap { tabID in info[tabID].map { (id: tabID, url: $0.url, title: $0.title) } })
        }
        Library.shared.removeSpace(id)
        sidebarUndo.registerUndo(withTarget: self) { controller in
            // Only this space comes back, so whatever changed since in the others stays.
            Library.shared.insertSpace(space, at: index)
            var shown: Tab?
            for entry in closed {
                // A window closed since: its tabs come back here.
                let target = WindowManager.shared.controllers.first { ObjectIdentifier($0) == entry.window } ?? controller
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

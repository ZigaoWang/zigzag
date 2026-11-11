import AppKit

/// Right-click menus for sidebar rows and spaces. Native menus: they are the Mac way.
enum SidebarMenus {
    /// Menu items that run a closure. The handler object rides along as the item's represented object.
    final class Handler: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func runAction(_ sender: Any?) { run() }
    }

    /// The spaces to move something to, as a submenu's items: under their profiles' names once there's more than
    /// one profile, since moving to another profile's space is a bigger step.
    static func addSpaces(to menu: NSMenu, excluding current: UUID?, _ move: @escaping (SpaceInfo) -> Void) {
        let groups = Library.shared.spaceGroups(excluding: current)
        for group in groups {
            if Library.shared.hasManyProfiles { menu.addItem(.sectionHeader(title: group.profile.displayName)) }
            for space in group.spaces { menu.addItem(Item(space.name) { move(space) }) }
        }
    }

    static func Item(_ title: String, symbol: String? = nil, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = Handler(handler)
        let item = NSMenuItem(title: title, action: #selector(Handler.runAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        if let symbol { item.image = Tokens.Symbol.image(symbol) }
        return item
    }

    /// For several picked rows: what makes sense for all of them at once, each item saying how many it acts on.
    /// With pinned pages and tabs picked together, each acts on the rows it makes sense for. The rows stay picked
    /// after it, wherever they now are, so the next one applies to the same set.
    static func markedMenu(for items: [SidebarItem], controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        let rows = controller.markedTabRows(items)
        let pins = controller.markedPinRows(items)
        let count = items.count
        // A private window's tabs never join the pins and favorites every window shares.
        let isPrivate = manager.isPrivate
        if !isPrivate || rows.isEmpty {
            menu.addItem(Item(String(localized: "Add \(count) to New Folder", comment: "Menu item for several picked sidebar rows")) {
                controller.fileMarked(items, in: nil)
            })
            let folders = Library.shared.folders(in: manager.currentSpaceID)
            if !folders.isEmpty {
                let add = NSMenuItem(title: String(localized: "Add \(count) to Folder", comment: "Menu item for several picked sidebar rows"), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for folder in folders { sub.addItem(Item(folder.name) { controller.fileMarked(items, in: folder.id) }) }
                add.submenu = sub
                menu.addItem(add)
            }
        }
        if !isPrivate {
            menu.addItem(Item(String(localized: "Add \(count) to Favorites", comment: "Menu item for several picked sidebar rows")) {
                controller.favoriteMarked(items)
            })
        }
        if Library.shared.spaces.count > 1, !(isPrivate && !pins.isEmpty) {
            let move = NSMenuItem(title: String(localized: "Move \(count) to Space", comment: "Menu item for several picked sidebar rows"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            addSpaces(to: sub, excluding: manager.currentSpaceID) { controller.moveMarked(items, to: $0.id) }
            move.submenu = sub
            menu.addItem(move)
        }
        if !pins.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let pages = controller.markedPinPages(pins).compactMap(manager.bookmarkTab(for:))
            if !pages.isEmpty {
                menu.addItem(Item(pages.count == 1 ? String(localized: "Unload Page", comment: "Menu item")
                                  : String(localized: "Unload \(pages.count) Pages", comment: "Menu item for several picked pinned pages")) {
                    manager.close(pages)
                })
            }
            // Pins are shared by every window: a private one doesn't take them away.
            if !isPrivate {
                menu.addItem(Item(pins.count == 1 ? String(localized: "Unpin Tab", comment: "Menu item")
                                  : String(localized: "Unpin \(pins.count) Tabs", comment: "Menu item for several picked pinned pages")) {
                    controller.unpinMarked(pins)
                })
            }
        }
        if !rows.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if !isPrivate {
                menu.addItem(Item(rows.count == 1 ? String(localized: "Pin Tab", comment: "Menu item")
                                  : String(localized: "Pin \(rows.count) Tabs", comment: "Menu item for several picked tabs")) {
                    controller.pinMarked(rows)
                })
            }
        }
        // What goes, last, as in a single row's menu.
        if !rows.isEmpty || (!pins.isEmpty && !isPrivate) { menu.addItem(.separator()) }
        if !rows.isEmpty {
            menu.addItem(Item(rows.count == 1 ? String(localized: "Close Tab", comment: "Menu item")
                              : String(localized: "Close \(rows.count) Tabs", comment: "Menu item for several picked tabs")) {
                controller.closeManyWithUndoToast(controller.markedTabs(items))
            })
        }
        if !pins.isEmpty, !isPrivate {
            menu.addItem(Item(Self.removePinsTitle(pins.count)) { controller.removePinnedWithUndo(pins) })
        }
        return menu
    }

    /// "Remove Pinned Page", or for several, how many.
    static func removePinsTitle(_ count: Int) -> String {
        count == 1 ? String(localized: "Remove Pinned Page", comment: "Menu item: takes a pinned page out of the sidebar")
            : String(localized: "Remove \(count) Pinned Pages", comment: "Menu item: takes several picked pinned pages out of the sidebar")
    }

    static func tabMenu(for tab: Tab, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        menu.addItem(Item(String(localized: "Rename", comment: "Item in a tab's context menu in the sidebar.")) { controller.sidebar.list.beginRenaming(tab: tab.id) })
        menu.addItem(Item(String(localized: "Copy Link", comment: "Item in a tab's context menu in the sidebar."), enabled: tab.url != nil) {
            if let url = tab.url { controller.copyLink(url) }
        })
        // Half of a split pins with its other half, as a split.
        let pinsPair = manager.partner(of: tab).map { $0.bookmarkID == nil && $0.url != nil } ?? false
        // Pins and favorites are shared by every window: a private one's tabs stay out of them.
        if !manager.isPrivate {
            menu.addItem(Item(pinsPair ? String(localized: "Pin Split View", comment: "Item in a tab's context menu in the sidebar. The tab is half of a split view; both pin together.") : String(localized: "Pin Tab", comment: "Item in a tab's context menu in the sidebar."), enabled: tab.url != nil) { controller.bookmarkWithUndo(tab, at: nil, in: tab.spaceID) })
            menu.addItem(Item(String(localized: "Add to Favorites", comment: "Item in a tab's context menu in the sidebar."), enabled: tab.url != nil) { controller.favoriteWithUndo(tab) })
        }
        if manager.split(for: tab) != nil {
            menu.addItem(Item(String(localized: "Separate Tabs", comment: "Item in a tab's context menu in the sidebar. Ends the split view the tab is in.")) { controller.unsplitWithUndo(tab) })
        } else if let current = manager.selectedTab, manager.canSplit(current, with: tab) {
            menu.addItem(Item(String(localized: "Open in Split View", comment: "Item in a tab's context menu in the sidebar. Shows this tab beside the current one.")) { controller.splitWithUndo(current, with: tab) })
        }
        menu.addItem(Item(String(localized: "Duplicate Tab", comment: "Item in a tab's context menu in the sidebar.")) { controller.duplicate(tab) })
        if !controller.tabManager.isPrivate, tab.bookmarkID == nil {
            menu.addItem(Item(String(localized: "Move Tab to New Window", comment: "Item in a tab's context menu in the sidebar.")) { controller.moveToNewWindow(tab) })
        }
        menu.addItem(.separator())
        menu.addItem(Item(String(localized: "Reload Page", comment: "Item in a tab's context menu in the sidebar.")) { tab.reload() })
        if tab.isPlayingAudio || tab.isMuted {
            menu.addItem(Item(tab.isMuted ? String(localized: "Unmute Tab", comment: "Item in a tab's context menu in the sidebar.") : String(localized: "Mute Tab", comment: "Item in a tab's context menu in the sidebar.")) { tab.setMuted(!tab.isMuted) })
        }
        if Library.shared.spaces.count > 1 {
            let move = NSMenuItem(title: String(localized: "Move to Space", comment: "Item in a tab's context menu in the sidebar. Opens a list of spaces."), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            addSpaces(to: sub, excluding: tab.spaceID) { controller.moveToSpaceWithToast(tab, spaceID: $0.id) }
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        menu.addItem(Item(String(localized: "Close Tab", comment: "Item in a tab's context menu in the sidebar.")) { controller.closeWithUndo(tab) })
        // As in the menu bar: the tab's split partner is part of it, so neither closes it.
        let tabs = manager.tabs(in: tab.spaceID)
        let partner = manager.partner(of: tab)
        if let last = tabs.lastIndex(where: { $0 === tab || $0 === partner }) {
            let below = Array(tabs.dropFirst(last + 1))
            menu.addItem(Item(String(localized: "Close Tabs Below", comment: "Item in a tab's context menu in the sidebar."), enabled: !below.isEmpty) { controller.closeManyWithUndoToast(below) })
            let others = tabs.filter { $0 !== tab && $0 !== partner }
            menu.addItem(Item(String(localized: "Close Other Tabs", comment: "Item in a tab's context menu in the sidebar."), enabled: !others.isEmpty) { controller.closeManyWithUndoToast(others) })
        }
        return menu
    }

    static func bookmarkMenu(for bookmark: Bookmark, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        let live = manager.bookmarkTab(for: bookmark.id)
        let pinned = Library.shared.pinnedSplit(containing: bookmark.id)
        // A pinned split's row is named after both its pages, so renaming one of them from it would be a puzzle.
        if pinned == nil { menu.addItem(Item(String(localized: "Rename", comment: "Item in a pinned tab's context menu in the sidebar.")) { BookmarkEditor.edit(bookmark.id, in: controller) }) }
        // Copy Link right after Rename, as in a tab's and a favorite's menus.
        menu.addItem(Item(String(localized: "Copy Link", comment: "Item in a pinned tab's context menu in the sidebar.")) { controller.copyLink(bookmark.url) })
        if let live, let url = live.url, TabManager.normalize(url) != TabManager.normalize(bookmark.url) {
            menu.addItem(Item(String(localized: "Back to Pinned Page", comment: "Item in a pinned tab's context menu in the sidebar. Goes back to the page the tab was pinned with.")) { manager.resetBookmarkTab(bookmark.id) })
            menu.addItem(Item(String(localized: "Separate from Pinned Tab", comment: "Item in a pinned tab's context menu in the sidebar. The page wandered off; this opens it as a tab of its own.")) { manager.separateBookmarkTab(bookmark.id) })
            // A private window never writes where it's been into your pins.
            if !manager.isPrivate {
                menu.addItem(Item(String(localized: "Pin This Page Instead", comment: "Item in a pinned tab's context menu in the sidebar. Makes the page it shows now the pinned one.")) {
                    controller.libraryChange(String(localized: "Update Pinned Page", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.updateBookmark(bookmark.id, url: url) }
                })
            }
        }
        menu.addItem(Item(String(localized: "Add to Favorites", comment: "Item in a pinned tab's context menu in the sidebar.")) {
            controller.libraryChange(String(localized: "Add to Favorites", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.makeFavorite(bookmark.id, in: manager.profile.id) }
            live?.isFavorite = true
        })
        // Beside the tab you're on, as a tab opens; not loaded yet, it opens at its pinned address.
        if pinned == nil, let current = manager.selectedTab, current.bookmarkID == nil, live.map({ manager.split(for: $0) == nil }) ?? true {
            menu.addItem(Item(String(localized: "Open in Split View", comment: "Item in a pinned tab's context menu in the sidebar. Shows this pinned tab beside the current one.")) { controller.splitWithUndo(current, with: manager.pageTab(for: bookmark)) })
        }
        // Folders of this space's pinned pages.
        let current = Library.shared.folderID(containing: bookmark.id)
        let spaceFolders = Library.shared.spaceID(ofBookmark: bookmark.id).map { Library.shared.folders(in: $0) } ?? []
        menu.addItem(.separator())
        menu.addItem(Item(String(localized: "Add to New Folder", comment: "Item in a pinned tab's context menu in the sidebar.")) { controller.newFolder(with: [bookmark.id]) })
        let others = spaceFolders.filter { $0.id != current }
        if !others.isEmpty {
            let add = NSMenuItem(title: String(localized: "Add to Folder", comment: "Item in a pinned tab's context menu in the sidebar. Opens a list of folders."), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for folder in others {
                sub.addItem(Item(folder.name) { controller.listSetFolder(of: bookmark.id, to: folder.id) })
            }
            add.submenu = sub
            menu.addItem(add)
        }
        if current != nil {
            menu.addItem(Item(String(localized: "Remove from Folder", comment: "Item in a pinned tab's context menu in the sidebar.")) { controller.listSetFolder(of: bookmark.id, to: nil) })
        }
        if Library.shared.spaces.count > 1 {
            let move = NSMenuItem(title: String(localized: "Move to Space", comment: "Item in a pinned tab's context menu in the sidebar. Opens a list of spaces."), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = Library.shared.spaceID(ofBookmark: bookmark.id)
            addSpaces(to: sub, excluding: current) { space in
                // Its open page goes with it: to another profile's space, that's asked first.
                controller.confirmProfileCrossing([live].compactMap { $0 }, to: space.id) {
                    controller.libraryChange(String(localized: "Move to Space", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.moveBookmark(bookmark.id, to: Int.max, in: space.id) }
                }
            }
            move.submenu = sub
            menu.addItem(move)
        }
        if pinned != nil || live != nil || !manager.isPrivate { menu.addItem(.separator()) }
        if let pinned {
            // Both stay pinned, each in a row of its own.
            menu.addItem(Item(String(localized: "Separate Tabs", comment: "Item in a pinned tab's context menu in the sidebar. Parts a pinned split view into two pinned tabs.")) {
                let open = [pinned.left, pinned.right].compactMap(manager.bookmarkTab(for:)).first { manager.split(for: $0) != nil }
                if let open {
                    controller.unsplitWithUndo(open)
                } else {
                    controller.libraryChange(String(localized: "Separate Tabs", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.removePinnedSplit(containing: bookmark.id) }
                }
            })
            let pages = [pinned.left, pinned.right].compactMap(manager.bookmarkTab(for:))
            if !pages.isEmpty {
                menu.addItem(Item(String(localized: "Unload Pages", comment: "Item in a pinned tab's context menu in the sidebar. Unloads both pages of a pinned split view.")) { manager.close(pages) })
            }
            if !manager.isPrivate {
                menu.addItem(Item(String(localized: "Unpin Split View", comment: "Item in a pinned tab's context menu in the sidebar.")) { controller.unbookmarkWithUndo(bookmark.id, to: 0) })
                menu.addItem(Item(removePinsTitle(1)) { controller.removePinnedWithUndo([bookmark.id]) })
            }
            return menu
        }
        if let live {
            menu.addItem(Item(String(localized: "Unload Page", comment: "Item in a pinned tab's context menu in the sidebar. Unloads the page; the pinned tab stays.")) { manager.close(live) })
        }
        // Pins are shared by every window: a private one doesn't take them away.
        if !manager.isPrivate {
            menu.addItem(Item(String(localized: "Unpin Tab", comment: "Item in a pinned tab's context menu in the sidebar.")) { controller.unbookmarkWithUndo(bookmark.id, to: 0) })
            menu.addItem(Item(removePinsTitle(1)) { controller.removePinnedWithUndo([bookmark.id]) })
        }
        return menu
    }

    static func folderMenu(for folder: BookmarkFolder, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Item(String(localized: "Rename", comment: "Item in a folder's context menu in the sidebar.")) { controller.sidebar.list.renameFolder(folder.id) })
        menu.addItem(Item(String(localized: "Change Icon…", comment: "Item in a folder's context menu in the sidebar.")) { controller.chooseFolderIcon(folder.id) })
        menu.addItem(Item(folder.isOpen ? String(localized: "Close Folder", comment: "Item in a folder's context menu in the sidebar.") : String(localized: "Open Folder", comment: "Item in a folder's context menu in the sidebar.")) { controller.listSetFolderOpen(folder.id, !folder.isOpen) })
        menu.addItem(Item(String(localized: "New Folder Inside", comment: "Item in a folder's context menu in the sidebar.")) { controller.newFolder(inside: folder.id) })
        // Out of the folder it's in, to the level above.
        if let parent = folder.parentID {
            menu.addItem(Item(String(localized: "Move Out of Folder", comment: "Item in a folder's context menu in the sidebar. Moves the folder up a level, out of the folder it's in.")) {
                let up = Library.shared.folder(parent)?.parentID
                // Just after the folder it leaves, counted without its own pages (as moving a folder counts).
                let own = Set(Library.shared.allBookmarkIDs(inFolder: folder.id))
                let after = Library.shared.allBookmarkIDs(inFolder: parent).last { !own.contains($0) }
                let order = Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).map(\.id).filter { !own.contains($0) }
                // Just after the folder it leaves; with nothing else in that folder, where the folder itself sits.
                let first = Library.shared.allBookmarkIDs(inFolder: parent).first { !own.contains($0) }
                let at = after.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 }
                    ?? first.flatMap { order.firstIndex(of: $0) }
                    ?? Library.shared.allBookmarkIDs(inFolder: folder.id).first.flatMap { id in Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).map(\.id).firstIndex(of: id) }
                    ?? 0
                controller.listMoveFolder(folder.id, to: at, in: controller.tabManager.currentSpaceID, parent: up)
            })
        }
        menu.addItem(.separator())
        // The folder goes; what was in it stays pinned, where it was.
        menu.addItem(Item(String(localized: "Remove Folder", comment: "Item in a folder's context menu in the sidebar. The folder goes; its pinned tabs stay.")) {
            controller.libraryChange(String(localized: "Remove Folder", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.removeFolder(folder.id) }
        })
        return menu
    }

    static func favoriteMenu(for favorite: Bookmark, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        let live = manager.bookmarkTab(for: favorite.id)
        // Not a split favorite: a new name would only reach its left page.
        if Library.shared.pinnedSplit(containing: favorite.id) == nil {
            menu.addItem(Item(String(localized: "Rename…", comment: "Item in a favorite's context menu.")) { BookmarkEditor.edit(favorite.id, in: controller) })
        }
        menu.addItem(Item(String(localized: "Copy Link", comment: "Item in a favorite's context menu.")) { controller.copyLink(favorite.url) })
        if let live, let url = live.url, TabManager.normalize(url) != TabManager.normalize(favorite.url) {
            menu.addItem(Item(String(localized: "Back to Favorite’s Page", comment: "Item in a favorite's context menu. Goes back to the page the favorite was saved with.")) { manager.resetBookmarkTab(favorite.id) })
            menu.addItem(Item(String(localized: "Separate from Favorite", comment: "Item in a favorite's context menu. The page wandered off; this opens it as a tab of its own.")) { manager.separateBookmarkTab(favorite.id) })
            // A private window never writes where it's been into your favorites.
            if !manager.isPrivate {
                menu.addItem(Item(String(localized: "Make This Page the Favorite", comment: "Item in a favorite's context menu.")) {
                    controller.libraryChange(String(localized: "Update Favorite", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.updateBookmark(favorite.id, url: url) }
                })
            }
        }
        // A split favorite: its two pages go and come as one, and can be parted into two favorites.
        if let pair = Library.shared.pinnedSplit(containing: favorite.id) {
            menu.addItem(Item(String(localized: "Separate Tabs", comment: "Item in a favorite's context menu. Parts a split favorite into two favorites.")) { controller.separateFavoriteSplitWithUndo(favorite.id) })
            if !manager.isPrivate { menu.addItem(Item(String(localized: "Move to Tabs", comment: "Item in a favorite's context menu. Turns the favorite back into a pinned tab.")) { controller.unfavoriteWithUndo(favorite.id, to: 0) }) }
            menu.addItem(.separator())
            let pages = [pair.left, pair.right].compactMap { manager.bookmarkTab(for: $0) }
            if !pages.isEmpty { menu.addItem(Item(String(localized: "Unload Pages", comment: "Item in a favorite's context menu. Unloads both pages of a split favorite.")) { manager.close(pages) }) }
            if !manager.isPrivate { menu.addItem(Item(String(localized: "Remove from Favorites", comment: "Item in a favorite's context menu.")) { controller.removeFavoriteWithUndo(favorite.id) }) }
            return menu
        }
        // Favorites are shared by every window: a private one doesn't take them away.
        if !manager.isPrivate { menu.addItem(Item(String(localized: "Move to Tabs", comment: "Item in a favorite's context menu. Turns the favorite back into a pinned tab.")) { controller.unfavoriteWithUndo(favorite.id, to: 0) }) }
        if live != nil || !manager.isPrivate { menu.addItem(.separator()) }
        if let live {
            if live.isPlayingAudio || live.isMuted {
                menu.addItem(Item(live.isMuted ? String(localized: "Unmute Tab", comment: "Item in a favorite's context menu.") : String(localized: "Mute Tab", comment: "Item in a favorite's context menu.")) { live.setMuted(!live.isMuted) })
            }
            menu.addItem(Item(String(localized: "Unload Page", comment: "Item in a favorite's context menu. Unloads the page; the favorite stays.")) { manager.close(live) })
        }
        if !manager.isPrivate { menu.addItem(Item(String(localized: "Remove from Favorites", comment: "Item in a favorite's context menu.")) { controller.removeFavoriteWithUndo(favorite.id) }) }
        return menu
    }

    static func spaceMenu(for id: UUID, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A private window borrows a space's look but keeps nothing: it can't change the spaces you keep.
        guard let space = Library.shared.space(id), !controller.tabManager.isPrivate else { return menu }
        menu.addItem(Item(String(localized: "Edit Space…", comment: "Item in a space's context menu.")) {
            let anchor = controller.sidebar.dot(for: id) ?? controller.sidebar.list.headerView
            controller.openSpaceEditor(id, anchor: anchor)
        })
        _ = space
        if id == controller.tabManager.currentSpaceID {
            menu.addItem(Item(String(localized: "New Folder", comment: "Item in a space's context menu.")) { controller.newFolder() })
        }
        // How every space's name shows, large or a plain heading, right where you see it. A setting, so it stands
        // apart from the actions, as a menu's checkmark items do.
        menu.addItem(.separator())
        let large = Item(String(localized: "Large Space Names", comment: "Item in a space's context menu. A checkmark item: shows every space's name large at the top of the sidebar.")) { SpaceHeaderView.isLarge.toggle() }
        large.state = SpaceHeaderView.isLarge ? .on : .off
        menu.addItem(large)
        menu.addItem(.separator())
        menu.addItem(Item(String(localized: "New Space", comment: "Item in a space's context menu.")) { controller.newSpace(nil) })
        menu.addItem(Item(String(localized: "Delete Space", comment: "Item in a space's context menu."), enabled: Library.shared.spaces.count > 1) {
            SpaceEditor.confirmDelete(spaceID: id, in: controller)
        })
        return menu
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: Tokens.Space.x3, height: Tokens.Space.x3)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Renaming spaces and bookmarks happens where they are: the space editor, or the row itself.
enum SpaceEditor {
    static func rename(spaceID: UUID, in controller: BrowserWindowController) {
        controller.openSpaceEditor(spaceID, anchor: controller.sidebar.list.headerView)
    }

    /// Deletes right away: ⌘Z brings the space back with its tabs, so there's nothing to confirm. The toast says what
    /// went and offers the same Undo, for whoever doesn't know ⌘Z reaches this far.
    static func confirmDelete(spaceID: UUID, in controller: BrowserWindowController) {
        guard let name = Library.shared.space(spaceID)?.name else { return }
        controller.removeSpaceWithUndo(spaceID)
        guard Library.shared.space(spaceID) == nil else { return }
        // Undo brings back this space, never whatever else was done since.
        Toast.show(String(localized: "Deleted “\(name)”", comment: "Toast after a space is deleted. The name is the space's."), symbol: "trash", action: (String(localized: "Undo", comment: "Button in a toast: undoes what the toast says happened."), { [weak controller] in
            guard let undo = controller?.sidebarUndo, undo.canUndo, undo.undoActionName == String(localized: "Delete Space", comment: "Undo action name, shown in Edit › Undo.") else { return }
            undo.undo()
        }), duration: 4, in: controller)
    }
}

enum BookmarkEditor {
    static func edit(_ id: UUID, in controller: BrowserWindowController) {
        // A favorite has no row to type in; it's renamed in a small field on the page instead.
        if controller.sidebar.list.beginRenaming(bookmark: id) { return }
        guard let bookmark = Library.shared.bookmark(id) else { return }
        RenamePanel.show(title: bookmark.title, in: controller) { title in
            controller.libraryChange(Library.shared.isFavorite(id) ? String(localized: "Rename Favorite", comment: "Undo action name, shown in Edit › Undo.")
                                                                 : String(localized: "Rename Pinned Tab", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.updateBookmark(id, title: title) }
        }
    }
}

/// One field in a small Zigzag panel, for renaming something that has no row of its own (a favorite).
final class RenamePanel: FloatingPanelView, NSTextFieldDelegate {
    private let field = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the field that renames a favorite."))
    private let save = PillButton(title: String(localized: "Rename", comment: "Button that saves a favorite's new name."), style: .prominent)
    private var done: ((String) -> Void)?
    private var monitor: Any?

    static func show(title: String, in controller: BrowserWindowController, done: @escaping (String) -> Void) {
        controller.closeFloatingPanels()
        let card = controller.root.cardFrame
        // Never wider than the page it's over, in a small window or one side of a split.
        let width = min(Tokens.Dialog.width, card.width - Tokens.Space.x6)
        let panel = RenamePanel(frame: NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.controlHeight + Tokens.Space.x3 * 2))
        panel.done = done
        panel.field.stringValue = title
        panel.field.field.delegate = panel
        panel.refreshSave()
        // Where the command bar opens, the other place you type a name.
        panel.frame.origin = NSPoint(x: round(card.midX - width / 2), y: card.minY + max(Tokens.Space.x12, floor(card.height * 0.18)))
        controller.root.overlay.addSubview(panel)
        panel.present()
        controller.window?.makeFirstResponder(panel.field.field)
        panel.field.field.currentEditor()?.selectAll(nil)
        panel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak panel] event in
            guard let panel, event.window === panel.window else { return event }
            if event.type == .keyDown {
                // Mid-word in a Chinese or Japanese input method, Return and Esc belong to it.
                if (panel.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                if event.keyCode == 53 { panel.close(commit: false); return nil }
                if event.keyCode == 36 || event.keyCode == 76 { panel.close(commit: true); return nil }
                return event
            }
            if !panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) { panel.close(commit: false) }
            return event
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [field, save].forEach { addSubview($0) }
        save.onClick = { [weak self] _ in self?.close(commit: true) }
        onLayout = { [weak self] in
            guard let self else { return }
            let pad = Tokens.Space.x3, h = Tokens.Metric.controlHeight
            let bw = max(self.save.fittingWidth, Tokens.Dialog.minButtonWidth)
            self.save.frame = NSRect(x: self.bounds.width - pad - bw, y: (self.bounds.height - h) / 2, width: bw, height: h)
            self.field.frame = NSRect(x: pad, y: (self.bounds.height - h) / 2, width: self.save.frame.minX - pad * 2, height: h)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var name: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A name is needed: with the field empty, Rename waits, and Return does nothing.
    fileprivate func refreshSave() { save.isEnabled = !name.isEmpty }

    func controlTextDidChange(_ obj: Notification) { refreshSave() }

    private func close(commit: Bool) {
        if commit, name.isEmpty { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if commit { done?(name) }
        done = nil
        dismiss()
    }
}

/// What picked rows do together. Each is one change, saved and shown once however many rows there are: one ⌘Z
/// takes it all back, and the rows stay picked after it, so the next action applies to the same ones.
extension BrowserWindowController {
    /// The tab of each picked tab row, the left half for a split.
    func markedTabRows(_ items: [SidebarItem]) -> [Tab] {
        items.compactMap { item in if case .tab(let id) = item { tabManager.tab(with: id) } else { nil } }
    }

    /// The tabs of the picked tab rows, both halves of a split, as closing its row closes both.
    func markedTabs(_ items: [SidebarItem]) -> [Tab] {
        markedTabRows(items).flatMap { tab in [tab] + (tabManager.partner(of: tab).map { [$0] } ?? []) }
    }

    /// The pinned page of each picked pinned row, the left one for a pinned split.
    func markedPinRows(_ items: [SidebarItem]) -> [UUID] {
        items.compactMap { item in if case .bookmark(let id) = item { id } else { nil } }
    }

    /// Every pinned page in these rows, both of a pinned split.
    func markedPinPages(_ pins: [UUID]) -> [UUID] {
        pins.flatMap { id in Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id] }
    }

    func unpinMarked(_ pins: [UUID]) {
        var pages: [Tab] = []
        pageChange(String(localized: "Unpin Tabs", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            pages = []
            // Each comes down to the top of the tabs, the last first, so they keep their order.
            Library.shared.together { for id in pins.reversed() { if let tab = tabManager.unbookmark(id, toIndex: 0) { pages.append(tab) } } }
        }
        sidebar.list.mark(pages: pages)
    }

    func pinMarked(_ tabs: [Tab]) {
        Tutorial.complete("pin")
        pageChange(String(localized: "Pin Tabs", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            Library.shared.together { for tab in tabs where tab.bookmarkID == nil { tabManager.bookmarkTab(tab, in: tab.spaceID) } }
        }
        sidebar.list.mark(pages: tabs)
    }

    /// Into a folder of this space (nil: a new one, named right away), the tabs among them pinned first.
    func fileMarked(_ items: [SidebarItem], in folder: UUID?) {
        var ids: [UUID] = []
        var made: BookmarkFolder?
        pageChange(folder == nil ? String(localized: "New Folder", comment: "Undo action name, shown in Edit › Undo.") : String(localized: "Add to Folder", comment: "Undo action name, shown in Edit › Undo.")) { [self] in
            Library.shared.together {
                ids = pinnedIDs(for: items)
                if let folder {
                    for id in ids { Library.shared.setFolder(of: id, to: folder) }
                } else {
                    made = Library.shared.addFolder(named: String(localized: "New Folder", comment: "Name a new folder of pinned tabs gets, until it's renamed."), with: ids, in: tabManager.currentSpaceID)
                }
            }
        }
        if let made { revealNewFolder(made.id) }
        sidebar.list.mark(pins: ids)
    }

    /// Into the favorites, in order. They leave the list for the grid, so nothing stays picked.
    func favoriteMarked(_ items: [SidebarItem]) {
        pageChange(String(localized: "Add to Favorites", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            Library.shared.together {
                for item in items {
                    switch item {
                    case .tab(let id): if let tab = tabManager.tab(with: id) { tabManager.favoriteTab(tab) }
                    case .bookmark(let id):
                        Library.shared.makeFavorite(id, in: tabManager.profile.id)
                        tabManager.bookmarkTab(for: id)?.isFavorite = true
                    default: break
                    }
                }
            }
        }
    }

    /// Into another space, tabs and pinned pages each at the top of their own section there, in order. They leave
    /// the list on show, so a toast says where they went, with Undo, as moving one tab does.
    func moveMarked(_ items: [SidebarItem], to spaceID: UUID) {
        guard let name = Library.shared.space(spaceID)?.name else { return }
        let tabs = markedTabRows(items)
        let pins = markedPinRows(items)
        let open = tabs + pins.compactMap { tabManager.bookmarkTab(for: $0) }
        confirmProfileCrossing(open, to: spaceID) { [weak self] in self?.moveMarkedNow(items, tabs: tabs, pins: pins, to: spaceID, name: name) }
    }

    private func moveMarkedNow(_ items: [SidebarItem], tabs: [Tab], pins: [UUID], to spaceID: UUID, name: String) {
        pageChange(String(localized: "Move to Space", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            Library.shared.together {
                for tab in tabs.reversed() { tabManager.moveTabToSpace(tab, spaceID: spaceID, at: 0) }
                var at = 0
                for id in pins {
                    Library.shared.moveBookmark(id, to: at, in: spaceID)
                    at += Library.shared.pinnedSplit(containing: id) == nil ? 1 : 2
                }
            }
        }
        Toast.show(String(localized: "Moved \(items.count) to \(name)", comment: "Toast after moving several picked sidebar rows to another space"),
                   symbol: "arrow.right.square", action: (String(localized: "Undo", comment: "Toast button"), { [weak self] in
            guard let undo = self?.sidebarUndo, undo.canUndo, undo.undoActionName == String(localized: "Move to Space", comment: "Undo action name, shown in Edit › Undo.") else { return }
            undo.undo()
        }), duration: 4, in: self)
    }

    /// Takes pinned pages out of the sidebar, open ones closing first. ⌘Z (or Undo on the toast) puts them back.
    func removePinnedWithUndo(_ pins: [UUID]) {
        guard !tabManager.isPrivate, !pins.isEmpty else { return }
        let ids = markedPinPages(pins)
        pageChange(String(localized: "Remove Pinned Pages", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            Library.shared.together {
                tabManager.close(ids.compactMap(tabManager.bookmarkTab(for:)))
                Library.shared.removeBookmarks(ids)
            }
        }
        let what = pins.count == 1 ? String(localized: "Removed 1 pinned page", comment: "Toast")
            : String(localized: "Removed \(pins.count) pinned pages", comment: "Toast after removing several pinned pages")
        Toast.show(what, symbol: "pin.slash", action: (String(localized: "Undo", comment: "Toast button"), { [weak self] in
            guard let undo = self?.sidebarUndo, undo.canUndo, undo.undoActionName == String(localized: "Remove Pinned Pages", comment: "Undo action name, shown in Edit › Undo.") else { return }
            undo.undo()
        }), duration: 4, in: self)
    }

    /// ⌘W on picked rows: what it does to one row, to all of them. Tabs close, with the count and Undo; pinned
    /// pages unload and stay pinned.
    func closeMarked(_ items: [SidebarItem]) {
        let tabs = markedTabs(items)
        let pages = markedPinPages(markedPinRows(items)).compactMap(tabManager.bookmarkTab(for:))
        if tabs.isEmpty { tabManager.close(pages); return }
        closeManyWithUndo(pages + tabs)
        showClosedToast(tabs.count)
    }

    /// What ⌘W closes with these rows picked, for the File menu to say: their tabs and open pinned pages.
    func closingCount(_ items: [SidebarItem]) -> Int {
        markedTabRows(items).count + markedPinRows(items).filter { id in markedPinPages([id]).contains { tabManager.bookmarkTab(for: $0) != nil } }.count
    }

    /// ⌫ on picked rows: their tabs close and their pinned pages come out of the sidebar, as one ⌘Z.
    func listRemove(_ items: [SidebarItem]) {
        let pins = markedPinRows(items)
        let tabs = markedTabs(items)
        if !pins.isEmpty, !tabManager.isPrivate { removePinnedWithUndo(pins) }
        // The tabs last, so the toast's Undo (Close Tabs) takes back both: they're one step.
        if !tabs.isEmpty { closeManyWithUndoToast(tabs) }
    }
}

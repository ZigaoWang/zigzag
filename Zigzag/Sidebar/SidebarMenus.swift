import AppKit

/// Right-click menus for sidebar rows and spaces, built as AppKit menus and shown as Zigzag's own (`MenuPanel`).
enum SidebarMenus {
    /// Menu items that run a closure. The handler object rides along as the item's represented object, with the
    /// item's symbol for its drawn row.
    final class Handler: NSObject, MenuItemStyle {
        let run: () -> Void
        let symbol: String?
        let isDestructive: Bool
        init(symbol: String? = nil, destructive: Bool = false, _ run: @escaping () -> Void) {
            self.symbol = symbol; self.isDestructive = destructive; self.run = run
        }
        @objc func runAction(_ sender: Any?) { run() }
    }

    /// One symbol per action, the same in every sidebar menu and matching the command bar and the + menu.
    enum Symbol {
        static let newTab = "plus", newFolder = "folder.badge.plus", newSpace = "plus.square", edit = "pencil"
        static let defaultColors = "arrow.counterclockwise", largeNames = "textformat.size"
        static let collapse = "rectangle.compress.vertical", expand = "rectangle.expand.vertical"
        static let showPins = "eye", hidePins = "eye.slash"
        static let reload = "arrow.clockwise", suspend = "moon.zzz", duplicate = "plus.square.on.square", copyLink = "link"
        static let mute = "speaker.slash", unmute = "speaker.wave.2", play = "play", pause = "pause"
        static let pin = "star", unpin = "star.slash", favorite = "heart", toTabs = "arrow.down.square"
        static let group = "rectangle.stack.badge.plus", ungroup = "rectangle.stack.badge.minus"
        static let split = "rectangle.split.2x1", separateSplit = "rectangle.split.2x1.slash", leaveSplit = "rectangle.badge.minus"
        static let moveTo = "arrow.right.square", newWindow = "macwindow.badge.plus", mini = "macwindow"
        static let outOfFolder = "arrow.turn.up.left", removeFromFolder = "folder.badge.minus", openAll = "plus.rectangle.on.rectangle"
        static let back = "arrow.uturn.backward", setCurrent = "checkmark.circle", separate = "rectangle.portrait.and.arrow.right"
        // The outline face: macOS draws face.smiling filled in dark mode.
        static let changeIcon = "face.dashed", folder = "folder", showTab = "arrow.forward.square"
        static let close = "xmark", closeSplit = "xmark.rectangle", closeBelow = "arrow.down.to.line", closeOthers = "xmark.circle"
        static let remove = "trash"
    }

    /// The spaces to move something to, as a submenu's items: under their profiles' names once there's more than
    /// one profile, since moving to another profile's space is a bigger step.
    static func addSpaces(to menu: NSMenu, excluding current: UUID?, _ move: @escaping (SpaceInfo) -> Void) {
        let groups = Library.shared.spaceGroups(excluding: current)
        for group in groups {
            if Library.shared.hasManyProfiles { menu.addItem(.sectionHeader(title: group.profile.displayName)) }
            for space in group.spaces {
                let item = Item(space.name, symbol: space.icon.flatMap { IconChoice.isSymbol($0) ? $0 : nil }) { move(space) }
                if item.image == nil { item.image = space.icon.map { IconChoice.image($0, size: DropdownButton.iconSide) } ?? swatch(space.swatch) }
                menu.addItem(item)
            }
        }
    }

    static func Item(_ title: String, symbol: String? = nil, destructive: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = Handler(symbol: symbol, destructive: destructive, handler)
        let item = NSMenuItem(title: title, action: #selector(Handler.runAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        if let symbol { item.image = Tokens.Symbol.image(symbol) }
        return item
    }

    /// Sections in order, a separator between those that have items.
    static func menu(_ sections: [[NSMenuItem]]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        return menu
    }

    static func Submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol {
            item.image = Tokens.Symbol.image(symbol)
            item.representedObject = Handler(symbol: symbol) {}
        }
        let sub = NSMenu(title: title)
        items.forEach(sub.addItem)
        item.submenu = sub
        return item
    }

    /// The menu bar's shortcut for `action`, as it is now, shown on the item.
    static func withShortcut(_ item: NSMenuItem, of action: Selector) -> NSMenuItem {
        guard let bar = Shortcuts.allItems.first(where: { $0.action == action }), !bar.keyEquivalent.isEmpty else { return item }
        item.keyEquivalent = bar.keyEquivalent
        item.keyEquivalentModifierMask = bar.keyEquivalentModifierMask
        return item
    }

    /// The spaces to move to, as submenu items.
    static func spaceItems(excluding current: UUID?, _ move: @escaping (SpaceInfo) -> Void) -> [NSMenuItem] {
        let menu = NSMenu()
        addSpaces(to: menu, excluding: current, move)
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// "Add to New Folder" while the space has no other folder; else "Add to Folder" with New Folder first.
    private static func folderItems(new newTitle: String, add addTitle: String, folders: [BookmarkFolder],
                                    new: @escaping () -> Void, into: @escaping (BookmarkFolder) -> Void) -> [NSMenuItem] {
        guard !folders.isEmpty else { return [Item(newTitle, symbol: Symbol.newFolder, new)] }
        let newFolder = Item(String(localized: "New Folder", comment: "Item in a space's context menu."), symbol: Symbol.newFolder, new)
        return [Submenu(addTitle, symbol: Symbol.newFolder, [newFolder, .separator()] + folders.map { folder in folderItem(folder) { into(folder) } })]
    }

    /// A folder in a list of folders, with the icon its row shows.
    private static func folderItem(_ folder: BookmarkFolder, _ handler: @escaping () -> Void) -> NSMenuItem {
        guard let icon = folder.icon else { return Item(folder.name, symbol: Symbol.folder, handler) }
        let item = Item(folder.name, handler)
        item.image = IconChoice.folder(icon, open: false, size: DropdownButton.iconSide)
        return item
    }

    static var separateSplitTitle: String {
        String(localized: "Separate Split View", comment: "Item at the top of the context menu of a tab, pinned tab or favorite in a split view, in the sidebar: ends the split view, each page a tab of its own again.")
    }

    static var removeFromSplitTitle: String {
        String(localized: "Remove from Split View", comment: "Item at the top of a tab's context menu in the sidebar, for one page of a split view of three or four: takes just this page out; the others stay side by side.")
    }

    static var moveToTitle: String {
        String(localized: "Move To", comment: "Item in a tab's context menu in the sidebar. Opens a list: New Window, Zigzag Mini, then the spaces.")
    }

    /// For several picked rows: what makes sense for all of them at once, each item saying how many it acts on.
    /// With pinned pages and tabs picked together, each acts on the rows it makes sense for. The rows stay picked
    /// after it, wherever they now are, so the next one applies to the same set.
    static func markedMenu(for items: [SidebarItem], controller: BrowserWindowController) -> NSMenu {
        let manager = controller.tabManager
        let rows = controller.markedTabRows(items)
        let pins = controller.markedPinRows(items)
        let count = items.count
        // A private window's tabs never join the pins and favorites every window shares.
        let isPrivate = manager.isPrivate
        var page: [NSMenuItem] = []
        let sleepers = controller.markedTabs(items).filter(manager.maySuspend)
        if !sleepers.isEmpty {
            page.append(Item(suspendTitle(sleepers.count), symbol: Symbol.suspend) { controller.suspendWithToast(sleepers) })
        }
        var organize: [NSMenuItem] = []
        if !rows.isEmpty, !isPrivate {
            organize.append(Item(rows.count == 1 ? String(localized: "Pin Tab", comment: "Menu item for one picked tab: pins the page into Pinned, at the end of it.")
                                 : String(localized: "Pin \(rows.count) Tabs", comment: "Menu item for several picked tabs: pins them into Pinned, at the end of it."), symbol: Symbol.pin) {
                controller.pinMarked(rows)
            })
        }
        // Pinned pages are shared by every window: a private one doesn't take them away.
        if !pins.isEmpty, !isPrivate {
            organize.append(Item(pins.count == 1 ? String(localized: "Unpin Tab", comment: "Menu item")
                                 : String(localized: "Unpin \(pins.count) Tabs", comment: "Menu item for several picked pinned pages"), symbol: Symbol.unpin) {
                controller.unpinMarked(pins)
            })
        }
        if !isPrivate {
            organize.append(Item(String(localized: "Add \(count) to Favorites", comment: "Menu item for several picked sidebar rows"), symbol: Symbol.favorite) {
                controller.favoriteMarked(items)
            })
        }
        if !isPrivate {
            organize += folderItems(new: String(localized: "Add \(count) to New Folder", comment: "Menu item for several picked sidebar rows"),
                                    add: String(localized: "Add \(count) to Folder", comment: "Menu item for several picked sidebar rows"),
                                    folders: Library.shared.folders(in: manager.currentSpaceID),
                                    new: { controller.fileMarked(items, in: nil) }, into: { controller.fileMarked(items, in: $0.id) })
        }
        if !rows.isEmpty {
            // New tab group from the selection (#209), placed at the first tab.
            organize.append(Item(rows.count == 1 ? String(localized: "New Group with Tab", comment: "Item in a tab's context menu in the sidebar: puts the tab in a new group of tabs, a folder among the tabs.")
                                 : String(localized: "Group \(rows.count) Tabs", comment: "Menu item for several picked tabs: puts them in a new group of tabs, a folder among the tabs."), symbol: Symbol.group) {
                controller.groupWithUndo(rows)
            })
        }
        if Library.shared.spaces.count > 1, !(isPrivate && !pins.isEmpty) {
            organize.append(Submenu(String(localized: "Move \(count) to Space", comment: "Menu item for several picked sidebar rows"), symbol: Symbol.moveTo,
                                    spaceItems(excluding: manager.currentSpaceID) { controller.moveMarked(items, to: $0.id) }))
        }
        // What goes, last, as in a single row's menu.
        var close: [NSMenuItem] = []
        let pages = controller.markedPinPages(pins).compactMap(manager.bookmarkTab(for:))
        if !pages.isEmpty {
            close.append(Item(pages.count == 1 ? String(localized: "Unload Page", comment: "Menu item")
                              : String(localized: "Unload \(pages.count) Pages", comment: "Menu item for several picked pinned pages"), symbol: Symbol.close) {
                manager.close(pages)
            })
        }
        if !rows.isEmpty {
            close.append(Item(rows.count == 1 ? String(localized: "Close Tab", comment: "Menu item")
                              : String(localized: "Close \(rows.count) Tabs", comment: "Menu item for several picked tabs"), symbol: Symbol.close) {
                controller.closeManyWithUndoToast(controller.markedTabs(items))
            })
        }
        if !pins.isEmpty, !isPrivate {
            close.append(Item(Self.removePinsTitle(pins.count), symbol: Symbol.remove) { controller.removePinnedWithUndo(pins) })
        }
        return menu([page, organize, close])
    }

    /// "Suspend Page", or for several, how many (#342).
    static func suspendTitle(_ count: Int) -> String {
        count == 1 ? String(localized: "Suspend Page", comment: "Item in a tab's context menu in the sidebar: puts its page to sleep; it loads again when you click the tab.")
            : String(localized: "Suspend \(count) Pages", comment: "Menu item for several picked tabs: puts their pages to sleep; each loads again when you click it.")
    }

    static var changeIconTitle: String {
        String(localized: "Change Icon…", comment: "Item in the context menu of a folder, a tab, a pinned tab or a favorite in the sidebar. Opens the icon choices.")
    }

    static var useSiteIconTitle: String {
        String(localized: "Use Site Icon", comment: "Button at the foot of the icon choices of a tab, a pinned tab or a favorite that has an icon you chose: puts the site's own icon back. Also the tooltip of that choice among the icons.")
    }

    static var chooseImageTitle: String {
        String(localized: "Choose Image…", comment: "Button at the foot of the icon choices of a tab, a pinned tab or a favorite in the sidebar: opens the open panel to pick an image file (SVG, PNG and others) as its icon.")
    }

    static var unpinGroupTitle: String {
        String(localized: "Unpin Group", comment: "Item in a pinned tab's context menu in the sidebar. The tab is in a pinned group; the whole group goes back to the tabs.")
    }

    /// "Remove Pinned Page", or for several, how many.
    static func removePinsTitle(_ count: Int) -> String {
        count == 1 ? String(localized: "Remove Pinned Page", comment: "Menu item: takes a pinned page out of the sidebar")
            : String(localized: "Remove \(count) Pinned Pages", comment: "Menu item: takes several picked pinned pages out of the sidebar")
    }

    /// A tab's menu, or one page's of a split row. What only this tab has comes first (its split, its sound), then the
    /// page, where it's kept, where it's shown, its name and icon, and closing last. Translate is the page's own, in
    /// View › Translate Page, Site Controls and the page's menu.
    static func tabMenu(for tab: Tab, controller: BrowserWindowController) -> NSMenu {
        typealias C = BrowserWindowController
        let manager = controller.tabManager
        let isPrivate = manager.isPrivate
        // Every tab's menu shows the menu bar's keys, as Chrome's does.
        func keyed(_ item: NSMenuItem, _ action: Selector) -> NSMenuItem { withShortcut(item, of: action) }

        var context: [NSMenuItem] = []
        if let split = manager.split(for: tab) {
            // One page of three or four can leave; the rest stay side by side.
            if split.isGroup, tab.bookmarkID == nil { context.append(Item(removeFromSplitTitle, symbol: Symbol.leaveSplit) { controller.leaveGroupWithUndo(tab) }) }
            context.append(keyed(Item(separateSplitTitle, symbol: Symbol.separateSplit) { controller.unsplitWithUndo(tab) }, #selector(C.closeSplitView(_:))))
        }
        let mute = keyed(Item(tab.isMuted ? String(localized: "Unmute Tab", comment: "Item in a tab's context menu in the sidebar.") : String(localized: "Mute Tab", comment: "Item in a tab's context menu in the sidebar."), symbol: tab.isMuted ? Symbol.unmute : Symbol.mute) { tab.setMuted(!tab.isMuted) }, #selector(C.toggleMute(_:)))
        // At the top while it plays or is muted; with the page's actions otherwise, to mute it before it plays (#490).
        let soundsNow = tab.isPlayingAudio || tab.isMuted
        if soundsNow { context.append(mute) }

        var page: [NSMenuItem] = []
        if tab.url != nil {
            page.append(keyed(Item(String(localized: "Reload Page", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.reload) { tab.reload() }, #selector(C.reloadPage(_:))))
        }
        if manager.maySuspend(tab) {
            page.append(keyed(Item(suspendTitle(1), symbol: Symbol.suspend) { controller.suspendWithToast([tab]) }, #selector(C.suspendPage(_:))))
        }
        page.append(keyed(Item(String(localized: "Duplicate Tab", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.duplicate) { controller.duplicate(tab) }, #selector(C.duplicateTab(_:))))
        if !soundsNow { page.append(mute) }
        if let url = tab.url {
            page.append(keyed(Item(String(localized: "Copy Link", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.copyLink) { controller.copyLink(url, title: tab.displayTitle) }, #selector(C.copyPageURL(_:))))
        }

        var organize: [NSMenuItem] = []
        // Save at the end of Pinned, or with ⇧ held where the picker says (#326). A whole group or a split view saves
        // as one, so the item says which. Pinned pages are shared by every window: a private one's tabs stay out.
        if !isPrivate, tab.bookmarkID == nil, tab.url != nil, manager.canPin(tab) {
            let pinsPair = manager.pinsSplit(tab)
            let saveTitle = manager.pinsGroup(tab) ? String(localized: "Pin Group", comment: "Item in a tab's context menu in the sidebar. The tab is in a group of tabs; the whole group is pinned as a folder.")
                : pinsPair ? String(localized: "Pin Split View", comment: "Item in a tab's context menu in the sidebar. The tab is half of a split view; both pages are pinned together.")
                : String(localized: "Pin Tab", comment: "Item in a tab's context menu in the sidebar: pins the page into Pinned, and with ⇧ held, asks which folder.")
            organize.append(keyed(Item(saveTitle, symbol: Symbol.pin) {
                // ⇧ held asks where, as ⇧⌘D does.
                if C.shiftHeld { controller.save(tab, request: .picker) } else { controller.bookmarkWithUndo(tab, at: nil, in: tab.spaceID) }
            }, #selector(C.toggleBookmark(_:))))
            organize.append(keyed(Item(String(localized: "Add to Favorites", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.favorite) { controller.favoriteWithUndo(tab) }, #selector(C.addToFavorites(_:))))
        }
        if tab.bookmarkID == nil { organize += groupItems(for: tab, controller: controller) }

        var view: [NSMenuItem] = []
        if manager.split(for: tab) == nil, let current = manager.selectedTab, manager.canSplit(current, with: tab) {
            view.append(Item(String(localized: "Open in Split View", comment: "Item in a tab's context menu in the sidebar. Shows this tab beside the current one."), symbol: Symbol.split) { controller.splitWithUndo(current, with: tab) })
        }
        // Another window, Zigzag Mini or another space: one list of where the tab can go.
        var places: [NSMenuItem] = []
        if !isPrivate, tab.bookmarkID == nil {
            places.append(keyed(Item(String(localized: "New Window", comment: "File menu item."), symbol: Symbol.newWindow) { controller.moveToNewWindow(tab) }, #selector(C.moveTabToNewWindow(_:))))
        }
        if controller.canOpenInMini(tab) {
            places.append(Item(String(localized: "Zigzag Mini", comment: "The name of Zigzag's small window for one page, without the sidebar (Arc called it Little Arc). Kept in Latin letters, like the app's name."), symbol: Symbol.mini) { controller.openInMini(tab) })
        }
        let spaces = Library.shared.spaces.count > 1 ? spaceItems(excluding: tab.spaceID) { controller.moveToSpaceWithToast(tab, spaceID: $0.id) } : []
        if !places.isEmpty, !spaces.isEmpty { places.append(.separator()) }
        places += spaces
        if !places.isEmpty { view.append(Submenu(moveToTitle, symbol: Symbol.moveTo, places)) }

        let edit = [
            Item(String(localized: "Rename", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.edit) { controller.sidebar.list.beginRenaming(tab: tab.id) },
            Item(changeIconTitle, symbol: Symbol.changeIcon) { controller.chooseIcon(for: tab) },
        ]

        var close = [keyed(Item(String(localized: "Close Tab", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.close) { controller.closeWithUndo(tab) }, #selector(C.closeTab(_:)))]
        // As in the menu bar: the tab's split partner is part of it, so neither closes it.
        let tabs = manager.tabs(in: tab.spaceID)
        let panes = manager.panes(of: tab)
        // Close Tab closes this page alone; this closes every page of the split.
        if panes.count > 1 {
            close.append(Item(String(localized: "Close Split View", comment: "Item in a tab's context menu in the sidebar, for a page of a split view: closes all its pages."), symbol: Symbol.closeSplit) { controller.closeManyWithUndo(panes) })
        }
        if let last = tabs.lastIndex(where: { page in panes.contains { $0 === page } }) {
            let below = Array(tabs.dropFirst(last + 1))
            if !below.isEmpty {
                close.append(keyed(Item(String(localized: "Close Tabs Below", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.closeBelow) { controller.closeManyWithUndoToast(below) }, #selector(C.closeTabsBelow(_:))))
            }
            let others = tabs.filter { page in !panes.contains { $0 === page } }
            if !others.isEmpty {
                close.append(keyed(Item(String(localized: "Close Other Tabs", comment: "Item in a tab's context menu in the sidebar."), symbol: Symbol.closeOthers) {
 controller.closeManyWithUndoToast(others) }, #selector(C.closeOtherTabs(_:))))
            }
        }
        return menu([context, page, organize, view, edit, close])
    }

    /// A pinned page's menu. Wandered off its pinned address, going back or keeping where it is now come first; split
    /// beside a tab, ending the split does.
    static func bookmarkMenu(for bookmark: Bookmark, controller: BrowserWindowController) -> NSMenu {
        let manager = controller.tabManager
        let isPrivate = manager.isPrivate
        let live = manager.bookmarkTab(for: bookmark.id)
        let pinned = Library.shared.pinnedSplit(containing: bookmark.id)
        // Every page's menu shows the menu bar's keys, as a tab's does.
        func keyed(_ item: NSMenuItem, _ action: Selector) -> NSMenuItem { withShortcut(item, of: action) }

        var context: [NSMenuItem] = []
        if let live, let url = live.url, manager.isAway(bookmark.id) {
            context.append(Item(String(localized: "Back to Pinned Page", comment: "Item in a pinned tab's context menu in the sidebar. Goes back to the page the tab was pinned with."), symbol: Symbol.back) { manager.resetBookmarkTab(bookmark.id) })
            // A private window never writes where it's been into your pins.
            if !isPrivate {
                context.append(Item(String(localized: "Set Current Page as Pinned", comment: "Item in a pinned tab's context menu in the sidebar. Makes the page it shows now the pinned one."), symbol: Symbol.setCurrent) {
                    controller.libraryChange(String(localized: "Update Pinned Page", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.updateBookmark(bookmark.id, url: url) }
                })
            }
            context.append(Item(String(localized: "Separate from Pinned Tab", comment: "Item in a pinned tab's context menu in the sidebar. The page wandered off; this opens it as a tab of its own."), symbol: Symbol.separate) { manager.separateBookmarkTab(bookmark.id) })
        }
        if let pinned {
            // One page of three or four can leave, as from a group of tabs; the rest stay one pinned group.
            if pinned.isGroup, !isPrivate { context.append(Item(removeFromSplitTitle, symbol: Symbol.leaveSplit) { controller.leavePinnedGroupWithUndo(bookmark.id) }) }
            // Both stay pinned, each in a row of its own.
            context.append(Item(separateSplitTitle, symbol: Symbol.separateSplit) {
                let open = pinned.ids.compactMap(manager.bookmarkTab(for:)).first { manager.split(for: $0) != nil }
                if let open {
                    controller.unsplitWithUndo(open)
                } else {
                    controller.libraryChange(String(localized: "Separate Tabs", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.removePinnedSplit(containing: bookmark.id) }
                }
            })
        } else if let live, manager.split(for: live) != nil {
            // Split beside a tab, its row carries the pair, so it ends the split here as a tab's row does.
            context.append(keyed(Item(separateSplitTitle, symbol: Symbol.separateSplit) { controller.unsplitWithUndo(live) }, #selector(BrowserWindowController.closeSplitView(_:))))
        }
        // At the top while it plays or is muted; with the page's actions otherwise.
        let mute = pinned == nil ? live.map { live in keyed(Item(live.isMuted ? String(localized: "Unmute Tab", comment: "Item in a tab's context menu in the sidebar.") : String(localized: "Mute Tab", comment: "Item in a tab's context menu in the sidebar."), symbol: live.isMuted ? Symbol.unmute : Symbol.mute) { live.setMuted(!live.isMuted) }, #selector(BrowserWindowController.toggleMute(_:))) } : nil
        let soundsNow = live.map { $0.isPlayingAudio || $0.isMuted } ?? false
        if soundsNow, let mute { context.append(mute) }

        var page = [Item(String(localized: "Copy Link", comment: "Item in a pinned tab's context menu in the sidebar."), symbol: Symbol.copyLink) { controller.copyLink(bookmark.url, title: bookmark.title) }]
        if !soundsNow, let mute { page.insert(mute, at: 0) }

        var organize: [NSMenuItem] = []
        // Pins are shared by every window: a private one leaves them as they are.
        if !isPrivate {
            let unpin = Library.shared.pinnedGroup(containing: bookmark.id) != nil ? unpinGroupTitle
                : pinned != nil ? String(localized: "Unpin Split View", comment: "Item in a pinned tab's context menu in the sidebar: takes both pages of a pinned split view out of Pinned.")
                : String(localized: "Unpin Tab", comment: "Item in a pinned tab's context menu in the sidebar: takes it out of Pinned, back among the tabs.")
            organize.append(Item(unpin, symbol: Symbol.unpin) { controller.unbookmarkWithUndo(bookmark.id, to: 0) })
            organize.append(Item(String(localized: "Add to Favorites", comment: "Item in a pinned tab's context menu in the sidebar."), symbol: Symbol.favorite) {
                controller.libraryChange(String(localized: "Add to Favorites", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.makeFavorite(bookmark.id, in: manager.profile.id) }
                live?.isFavorite = true
            })
        }
        // Folders of this space's pinned pages.
        let folder = Library.shared.folderID(containing: bookmark.id)
        let spaceFolders = Library.shared.spaceID(ofBookmark: bookmark.id).map { Library.shared.folders(in: $0) } ?? []
        if !isPrivate {
            organize += folderItems(new: String(localized: "Add to New Folder", comment: "Item in a pinned tab's context menu in the sidebar."),
                                    add: String(localized: "Add to Folder", comment: "Item in a pinned tab's context menu in the sidebar. Opens a list of folders."),
                                    folders: spaceFolders.filter { $0.id != folder },
                                    new: { controller.newFolder(with: [bookmark.id]) }, into: { controller.listSetFolder(of: bookmark.id, to: $0.id) })
            if folder != nil {
                organize.append(Item(String(localized: "Remove from Folder", comment: "Item in a pinned tab's context menu in the sidebar."), symbol: Symbol.removeFromFolder) { controller.listSetFolder(of: bookmark.id, to: nil) })
            }
            if Library.shared.spaces.count > 1 {
                organize.append(Submenu(String(localized: "Move to Space", comment: "Item in a pinned tab's context menu in the sidebar. Opens a list of spaces."), symbol: Symbol.moveTo,
                                        spaceItems(excluding: Library.shared.spaceID(ofBookmark: bookmark.id)) { space in
                    // Its open page goes with it: to another profile's space, that's asked first.
                    controller.confirmProfileCrossing([live].compactMap { $0 }, to: space.id) {
                        controller.libraryChange(String(localized: "Move to Space", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.moveBookmark(bookmark.id, to: Int.max, in: space.id) }
                    }
                }))
            }
        }

        var view: [NSMenuItem] = []
        // Beside the tab you're on, as a tab opens; not loaded yet, it opens at its pinned address.
        if pinned == nil, let current = manager.selectedTab, current.bookmarkID == nil, live.map({ manager.split(for: $0) == nil }) ?? true {
            view.append(Item(String(localized: "Open in Split View", comment: "Item in a pinned tab's context menu in the sidebar. Shows this pinned tab beside the current one."), symbol: Symbol.split) { controller.splitWithUndo(current, with: manager.pageTab(for: bookmark)) })
        }

        // A pinned split's row is named after both its pages, so renaming one of them from it would be a puzzle.
        var edit: [NSMenuItem] = []
        // A private window never writes a name or an icon into your pins.
        if pinned == nil, !isPrivate {
            edit.append(Item(String(localized: "Rename", comment: "Item in a pinned tab's context menu in the sidebar."), symbol: Symbol.edit) { BookmarkEditor.edit(bookmark.id, in: controller) })
            edit.append(Item(changeIconTitle, symbol: Symbol.changeIcon) { controller.chooseIcon(forBookmark: bookmark.id) })
        }

        var close: [NSMenuItem] = []
        if let pinned {
            let pages = pinned.ids.compactMap(manager.bookmarkTab(for:))
            if !pages.isEmpty {
                close.append(Item(String(localized: "Unload Pages", comment: "Item in a pinned tab's context menu in the sidebar. Unloads both pages of a pinned split view."), symbol: Symbol.close) { manager.close(pages) })
            }
        } else if let live {
            close.append(Item(String(localized: "Unload Page", comment: "Item in a pinned tab's context menu in the sidebar. Unloads the page; the pinned tab stays."), symbol: Symbol.close) { manager.close(live) })
        }
        if !isPrivate { close.append(Item(removePinsTitle(1), symbol: Symbol.remove) { controller.removePinnedWithUndo([bookmark.id]) }) }
        return menu([context, page, organize, view, edit, close])
    }

    static func folderMenu(for folder: BookmarkFolder, controller: BrowserWindowController) -> NSMenu {
        // First item, as in Safari's bookmark folders.
        var open: [NSMenuItem] = []
        if !Library.shared.allBookmarkIDs(inFolder: folder.id).isEmpty {
            open.append(Item(String(localized: "Open All in Tabs", comment: "Item in a folder's context menu in the sidebar: opens every page in the folder and the folders inside it as new tabs."), symbol: Symbol.openAll) { controller.openAllInTabs(folder.id) })
        }
        var view = [Item(folder.isOpen ? String(localized: "Close Folder", comment: "Item in a folder's context menu in the sidebar.") : String(localized: "Open Folder", comment: "Item in a folder's context menu in the sidebar."), symbol: folder.isOpen ? Symbol.collapse : Symbol.expand) { controller.listSetFolderOpen(folder.id, !folder.isOpen) }]
        // Only with subfolders, and only when it would change something.
        let folders = Library.shared.spaces.first { $0.folders?.contains { $0.id == folder.id } == true }?.folders ?? []
        if !folders.descendants(of: folder.id).isEmpty {
            if folders.anyInTree(of: folder.id, isOpen: false) {
                view.append(Item(String(localized: "Expand All", comment: "Item in a folder's context menu in the sidebar: opens the folder and every folder inside it."), symbol: Symbol.expand) { controller.setFolderTreeOpen(folder.id, true) })
            }
            if folders.anyInTree(of: folder.id, isOpen: true) {
                view.append(Item(String(localized: "Collapse All", comment: "Item in a folder's context menu in the sidebar: shuts the folder and every folder inside it."), symbol: Symbol.collapse) { controller.setFolderTreeOpen(folder.id, false) })
            }
        }
        var organize = [Item(String(localized: "New Folder Inside", comment: "Item in a folder's context menu in the sidebar."), symbol: Symbol.newFolder) { controller.newFolder(inside: folder.id) }]
        // Out of the folder it's in, to the level above.
        if let parent = folder.parentID {
            organize.append(Item(String(localized: "Move Out of Folder", comment: "Item in a folder's context menu in the sidebar. Moves the folder up a level, out of the folder it's in."), symbol: Symbol.outOfFolder) {
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
        let edit = [
            Item(String(localized: "Rename", comment: "Item in a folder's context menu in the sidebar."), symbol: Symbol.edit) { controller.sidebar.list.renameFolder(folder.id) },
            Item(changeIconTitle, symbol: Symbol.changeIcon) { controller.chooseFolderIcon(folder.id) },
        ]
        // The folder goes; what was in it stays pinned, where it was.
        let close = [Item(String(localized: "Remove Folder", comment: "Item in a folder's context menu in the sidebar. The folder goes; its pinned tabs stay."), symbol: Symbol.remove) {
            controller.libraryChange(String(localized: "Remove Folder", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.removeFolder(folder.id) }
        }]
        // A private window opens and folds folders but leaves them as they are.
        if controller.tabManager.isPrivate { return menu([open, view]) }
        return menu([open, view, organize, edit, close])
    }

    /// Into a new or existing tab group (#209), or out of one. With no other group, New Group with Tab on its own;
    /// else Add to Group lists them, New Group first.
    private static func groupItems(for tab: Tab, controller: BrowserWindowController) -> [NSMenuItem] {
        let others = controller.tabManager.groups(in: tab.spaceID).filter { $0.id != tab.groupID }
        var items: [NSMenuItem] = []
        let newGroup = { controller.groupWithUndo([tab]) }
        if tab.groupID == nil {
            if others.isEmpty {
                items.append(Item(String(localized: "New Group with Tab", comment: "Item in a tab's context menu in the sidebar: puts the tab in a new group of tabs, a folder among the tabs."), symbol: Symbol.group, newGroup))
            }
        } else {
            items.append(Item(String(localized: "Remove from Group", comment: "Item in a tab's context menu in the sidebar: takes the tab out of its group of tabs."), symbol: Symbol.ungroup) { controller.setGroupWithUndo(of: [tab], to: nil) })
        }
        if !others.isEmpty {
            var list = others.map { group in Item(group.name, symbol: Symbol.folder) { controller.setGroupWithUndo(of: [tab], to: group.id) } }
            if tab.groupID == nil { list = [Item(String(localized: "New Group", comment: "Name a new group of tabs gets, until it's renamed."), symbol: Symbol.group, newGroup), .separator()] + list }
            items.append(Submenu(String(localized: "Add to Group", comment: "Item in a tab's context menu in the sidebar. Opens a list of the space's groups of tabs."), symbol: Symbol.group, list))
        }
        return items
    }

    /// Tab group menu (#209): like a folder's, plus tab actions.
    static func groupMenu(for group: TabGroup, controller: BrowserWindowController) -> NSMenu {
        let view = [Item(group.isOpen ? String(localized: "Collapse Group", comment: "Item in a group of tabs' context menu in the sidebar: folds its tabs away.")
                         : String(localized: "Expand Group", comment: "Item in a group of tabs' context menu in the sidebar: shows its tabs again."), symbol: group.isOpen ? Symbol.collapse : Symbol.expand) {
            controller.listSetGroupOpen(group.id, !group.isOpen)
        }]
        var organize = [Item(String(localized: "Ungroup", comment: "Item in a group of tabs' context menu in the sidebar. The group goes; its tabs stay where they are."), symbol: Symbol.ungroup) { controller.ungroupWithUndo(group.id) }]
        if Library.shared.spaces.count > 1, let space = controller.tabManager.tabs(inGroup: group.id).first?.spaceID {
            organize.append(Submenu(String(localized: "Move to Space", comment: "Item in a group of tabs' context menu in the sidebar. Opens a list of spaces."), symbol: Symbol.moveTo,
                                    spaceItems(excluding: space) { controller.listMoveGroup(group.id, to: Int.max, in: $0.id) }))
        }
        let edit = [Item(String(localized: "Rename", comment: "Item in a group of tabs' context menu in the sidebar."), symbol: Symbol.edit) { controller.sidebar.list.renameGroup(group.id) }]
        let close = [Item(String(localized: "Close Group", comment: "Item in a group of tabs' context menu in the sidebar: closes all its tabs, with Undo."), symbol: Symbol.close) { controller.closeGroupWithUndo(group.id) }]
        return menu([view, organize, edit, close])
    }

    /// A favorite's menu, laid out as a pinned page's.
    static func favoriteMenu(for favorite: Bookmark, controller: BrowserWindowController) -> NSMenu {
        let manager = controller.tabManager
        let isPrivate = manager.isPrivate
        let live = manager.bookmarkTab(for: favorite.id)
        let pair = Library.shared.pinnedSplit(containing: favorite.id)
        // Every page's menu shows the menu bar's keys, as a tab's does.
        func keyed(_ item: NSMenuItem, _ action: Selector) -> NSMenuItem { withShortcut(item, of: action) }

        var context: [NSMenuItem] = []
        if let pair {
            // An away page goes back, like a single-page favorite.
            let away = pair.ids.filter(manager.isAway)
            if !away.isEmpty {
                context.append(Item(String(localized: "Back to Favorite’s Page", comment: "Item in a favorite's context menu. Goes back to the page the favorite was saved with."), symbol: Symbol.back) { away.forEach(manager.resetBookmarkTab) })
            }
            // Its pages go and come as one, and part into two favorites.
            context.append(Item(separateSplitTitle, symbol: Symbol.separateSplit) { controller.separateFavoriteSplitWithUndo(favorite.id) })
        } else if let live, let url = live.url, manager.isAway(favorite.id) {
            context.append(Item(String(localized: "Back to Favorite’s Page", comment: "Item in a favorite's context menu. Goes back to the page the favorite was saved with."), symbol: Symbol.back) { manager.resetBookmarkTab(favorite.id) })
            // A private window never writes where it's been into your favorites.
            if !isPrivate {
                context.append(Item(String(localized: "Set Current Page as Favorite", comment: "Item in a favorite's context menu. The page wandered off the favorite's address; this makes the page it shows now the favorite."), symbol: Symbol.setCurrent) {
                    controller.libraryChange(String(localized: "Update Favorite", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.updateBookmark(favorite.id, url: url) }
                })
            }
            context.append(Item(String(localized: "Separate from Favorite", comment: "Item in a favorite's context menu. The page wandered off; this opens it as a tab of its own."), symbol: Symbol.separate) { manager.separateBookmarkTab(favorite.id) })
        }
        // At the top while it plays or is muted; with the page's actions otherwise.
        let mute = pair == nil ? live.map { live in keyed(Item(live.isMuted ? String(localized: "Unmute Tab", comment: "Item in a favorite's context menu.") : String(localized: "Mute Tab", comment: "Item in a favorite's context menu."), symbol: live.isMuted ? Symbol.unmute : Symbol.mute) { live.setMuted(!live.isMuted) }, #selector(BrowserWindowController.toggleMute(_:))) } : nil
        let soundsNow = live.map { $0.isPlayingAudio || $0.isMuted } ?? false
        if soundsNow, let mute { context.append(mute) }

        var page = [Item(String(localized: "Copy Link", comment: "Item in a favorite's context menu."), symbol: Symbol.copyLink) { controller.copyLink(favorite.url, title: favorite.title) }]
        if !soundsNow, let mute { page.insert(mute, at: 0) }
        // Favorites are shared by every window: a private one doesn't take them away.
        let organize = isPrivate ? [] : [Item(String(localized: "Move to Tabs", comment: "Item in a favorite's context menu. Turns the favorite into a plain tab of the space you're in."), symbol: Symbol.toTabs) { controller.unfavoriteWithUndo(favorite.id, to: 0) }]

        // Not a split favorite: a new name or icon would only reach its left page.
        var edit: [NSMenuItem] = []
        // A private window never writes a name or an icon into your favorites.
        if pair == nil, !isPrivate {
            edit.append(Item(String(localized: "Rename…", comment: "Item in a favorite's context menu."), symbol: Symbol.edit) { BookmarkEditor.edit(favorite.id, in: controller) })
            edit.append(Item(changeIconTitle, symbol: Symbol.changeIcon) { controller.chooseIcon(forBookmark: favorite.id) })
        }

        var close: [NSMenuItem] = []
        if let pair {
            let pages = pair.ids.compactMap { manager.bookmarkTab(for: $0) }
            if !pages.isEmpty { close.append(Item(String(localized: "Unload Pages", comment: "Item in a favorite's context menu. Unloads both pages of a split favorite."), symbol: Symbol.close) { manager.close(pages) }) }
        } else if let live {
            close.append(Item(String(localized: "Unload Page", comment: "Item in a favorite's context menu. Unloads the page; the favorite stays."), symbol: Symbol.close) { manager.close(live) })
        }
        if !isPrivate { close.append(Item(String(localized: "Remove from Favorites", comment: "Item in a favorite's context menu."), symbol: Symbol.remove) { controller.removeFavoriteWithUndo(favorite.id) }) }

        return menu([context, page, organize, edit, close])
    }

    /// `anchor`: the row or dot the menu opened on, which Edit Space… opens beside.
    static func spaceMenu(for id: UUID, controller: BrowserWindowController, anchor: NSView? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A private window borrows a space's look but keeps nothing: it can't change the spaces you keep.
        guard let space = Library.shared.space(id), !controller.tabManager.isPrivate else { return menu }
        // Its profile on top once there's more than one, as the Move to Space menus head each profile's spaces.
        if let profile = Library.shared.directory.shownName(ofSpace: id, spaceName: space.name) { menu.addItem(.sectionHeader(title: profile)) }
        typealias C = BrowserWindowController
        let isCurrent = id == controller.tabManager.currentSpaceID
        // Every space's menu shows the menu bar's keys, as a tab's does.
        func keyed(_ item: NSMenuItem, _ action: Selector) -> NSMenuItem { withShortcut(item, of: action) }
        menu.addItem(keyed(Item(String(localized: "Edit Space…", comment: "Item in a space's context menu."), symbol: Symbol.edit) {
            controller.openSpaceEditor(id, anchor: anchor ?? controller.sidebar.list.headerView)
        }, #selector(C.renameSpace(_:))))
        _ = space
        menu.addItem(useDefaultColorsItem(for: id, symbol: Symbol.defaultColors) { controller.libraryChange($0, $1) })
        if isCurrent {
            menu.addItem(Item(String(localized: "New Folder", comment: "Item in a space's context menu."), symbol: Symbol.newFolder) { controller.newFolder() })
        }
        // Every pinned folder at once, each only when it would change something (#343).
        if BrowserWindowController.hasFolders(in: id, isOpen: true) {
            menu.addItem(keyed(Item(collapseAllFoldersTitle, symbol: Symbol.collapse) { controller.setAllFoldersOpen(in: id, false) }, #selector(C.collapseAllFolders(_:))))
        }
        if BrowserWindowController.hasFolders(in: id, isOpen: false) {
            menu.addItem(keyed(Item(expandAllFoldersTitle, symbol: Symbol.expand) { controller.setAllFoldersOpen(in: id, true) }, #selector(C.expandAllFolders(_:))))
        }
        // How every space's name shows, large or a plain heading, right where you see it. A setting, so it stands
        // apart from the actions, as a menu's checkmark items do.
        menu.addItem(.separator())
        let large = Item(String(localized: "Large Space Names", comment: "Item in a space's context menu. A checkmark item: shows every space's name large at the top of the sidebar."), symbol: Symbol.largeNames) { SpaceHeaderView.isLarge.toggle() }
        large.state = SpaceHeaderView.isLarge ? .on : .off
        menu.addItem(large)
        menu.addItem(.separator())
        menu.addItem(withShortcut(Item(String(localized: "New Space", comment: "Item in a space's context menu."), symbol: Symbol.newSpace) { controller.newSpace(anchor) }, of: #selector(C.newSpace(_:))))
        menu.addItem(Item(String(localized: "Delete Space", comment: "Item in a space's context menu."), symbol: Symbol.remove, destructive: true, enabled: Library.shared.spaces.count > 1) {

            SpaceEditor.confirmDelete(spaceID: id, in: controller)
        })
        return menu
    }

    static var collapseAllFoldersTitle: String {
        String(localized: "Collapse All Folders", comment: "Item in the View menu and in a space's context menu in the sidebar: shuts every pinned folder in the space.")
    }
    static var expandAllFoldersTitle: String {
        String(localized: "Expand All Folders", comment: "Item in the View menu and in a space's context menu in the sidebar: opens every pinned folder in the space.")
    }

    /// Use Default Colors, beside Edit Space…: the colors the space was made with, back in one step that ⌘Z undoes.
    /// Dimmed while it still has them.
    static func useDefaultColorsItem(for id: UUID, symbol: String? = nil, change: @escaping (String, () -> Void) -> Void) -> NSMenuItem {
        let title = String(localized: "Use Default Colors", comment: "Item in a space's context menu, and tooltip of the first swatch in the space editor: puts back the colors the space had when it was made.")
        return Item(title, symbol: symbol, enabled: !Library.shared.hasDefaultColors(id)) {

            change(title) { Library.shared.useDefaultColors(forSpace: id) }
        }
    }

    /// What the sidebar's own menus hold, in order, before they're made into items: the + at its bottom and the
    /// right-click on its empty space. Both are Zigzag's own drawn menu (`MenuPanel`), so they look and work alike.
    enum Entry: Equatable { case newTab, newFolder, editSpace, newSpace, separator }

    /// The + at the bottom of the sidebar: what you can add, smallest first. A private window keeps no pinned tabs
    /// or spaces, so only a tab.
    static func addEntries(isPrivate: Bool) -> [Entry] {
        isPrivate ? [.newTab] : [.newTab, .newFolder, .newSpace]
    }

    /// Right-click on the sidebar where there's no row or button: the same as the +, with the space itself beside
    /// a new one.
    static func blankEntries(isPrivate: Bool) -> [Entry] {
        isPrivate ? [.newTab] : [.newTab, .newFolder, .separator, .editSpace, .newSpace]
    }

    /// What an entry is called, its symbol and the shortcut the menu bar gives it now (none for a folder).
    static func title(of entry: Entry) -> String {
        switch entry {
        case .newTab: String(localized: "New Tab", comment: "Item in the menu of the sidebar's + and its empty space.")
        case .newFolder: String(localized: "New Folder", comment: "Item in a space's context menu.")
        case .editSpace: String(localized: "Edit Space…", comment: "Item in a space's context menu.")
        case .newSpace: String(localized: "New Space", comment: "Item in the menu of the sidebar's + and its empty space: adds a space and opens it to be named.")
        case .separator: ""
        }
    }

    static func symbol(of entry: Entry) -> String? {
        switch entry {
        case .newTab: "plus"
        case .newFolder: "folder.badge.plus"
        case .editSpace: "pencil"
        case .newSpace: "plus.square"
        case .separator: nil
        }
    }

    static func action(of entry: Entry) -> Selector? {
        switch entry {
        case .newTab: #selector(BrowserWindowController.newTab(_:))
        case .newSpace: #selector(BrowserWindowController.newSpace(_:))
        case .editSpace: #selector(BrowserWindowController.renameSpace(_:))
        case .newFolder, .separator: nil
        }
    }

    static func addPanel(controller: BrowserWindowController) -> [MenuPanel.Entry] {
        panel(addEntries(isPrivate: controller.tabManager.isPrivate), controller: controller, from: controller.sidebar.newSpaceButton)
    }

    static func blankPanel(controller: BrowserWindowController) -> [MenuPanel.Entry] {
        panel(blankEntries(isPrivate: controller.tabManager.isPrivate), controller: controller)
    }

    /// `from`: the button the menu opened from, where a new space's editor opens.
    private static func panel(_ entries: [Entry], controller: BrowserWindowController, from button: NSView? = nil) -> [MenuPanel.Entry] {
        entries.map { entry in
            guard entry != .separator else { return .separator }
            let shortcut = action(of: entry).map(Shortcuts.keys(for:)) ?? ""
            return .item(MenuPanel.Item(title: title(of: entry), symbol: symbol(of: entry), shortcut: shortcut) { [weak controller, weak button] in
                guard let controller else { return }
                switch entry {
                case .newTab: controller.listNewTab()
                case .newFolder: controller.newFolder()
                // Beside the space's name, as the View menu's Edit Space… opens it.
                case .editSpace: controller.openSpaceEditor(controller.tabManager.currentSpaceID, anchor: controller.sidebar.list.headerView)
                case .newSpace: controller.newSpace(button)
                case .separator: break
                }
            })
        }
    }

    /// A space with no icon, by its color: a dot in the middle of an icon's square.
    private static func swatch(_ color: NSColor) -> NSImage {
        let side = DropdownButton.iconSide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: (side - Tokens.Space.x3) / 2, dy: (side - Tokens.Space.x3) / 2)).fill()
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
        }), duration: Toast.undoDuration, in: controller)
    }
}

enum BookmarkEditor {
    static func edit(_ id: UUID, in controller: BrowserWindowController) {
        // Pins and favorites are shared by every window: a private one leaves their names alone.
        guard !controller.tabManager.isPrivate else { return }
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
        panel.monitor = TouchPress.addMonitor(matching: [.keyDown, .leftMouseDown]) { [weak panel] event in
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
        if let monitor { TouchPress.removeMonitor(monitor) }
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
        markedTabRows(items).flatMap { tab in tabManager.panes(of: tab) }
    }

    /// The pinned page of each picked pinned row, the left one for a pinned split.
    func markedPinRows(_ items: [SidebarItem]) -> [UUID] {
        items.compactMap { item in if case .bookmark(let id) = item { id } else { nil } }
    }

    /// Every pinned page in these rows, all of a pinned split or group.
    func markedPinPages(_ pins: [UUID]) -> [UUID] {
        pins.flatMap { id in Library.shared.pinnedSplit(containing: id).map(\.ids) ?? [id] }
    }

    func unpinMarked(_ pins: [UUID]) {
        guard !tabManager.isPrivate else { return }
        var pages: [Tab] = []
        pageChange(String(localized: "Unpin Tabs", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            pages = []
            // Each comes down to the top of the tabs, the last first, so they keep their order.
            Library.shared.together { for id in pins.reversed() { if let tab = tabManager.unbookmark(id, toIndex: 0) { pages.append(tab) } } }
        }
        sidebar.list.mark(pages: pages)
    }

    /// Several tabs pinned at once, each through `SavePath.save`, so a picked row lands where the star and ⌘D do.
    func pinMarked(_ tabs: [Tab]) {
        Tutorial.complete("pin")
        pageChange(String(localized: "Pin Tabs", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            Library.shared.together {
                for tab in tabs where tab.bookmarkID == nil {
                    guard let page = SavePath.Page(tab: tab) else { continue }
                    _ = SavePath.save(page, to: SavePath.quickPlace(in: tab.spaceID), in: tabManager)
                }
            }
        }
        sidebar.list.mark(pages: tabs)
    }

    /// Into a folder of this space (nil: a new one, named right away), the tabs among them pinned first.
    func fileMarked(_ items: [SidebarItem], in folder: UUID?) {
        guard !tabManager.isPrivate else { return }
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
        guard !tabManager.isPrivate else { return }
        pageChange(String(localized: "Add to Favorites", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            Library.shared.together {
                for item in items {
                    switch item {
                    case .tab(let id): if let tab = tabManager.tab(with: id), tabManager.canPin(tab, keepingGroup: false) { tabManager.favoriteTab(tab) }
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
                    at += Library.shared.pinnedSplit(containing: id)?.ids.count ?? 1
                }
            }
        }
        Toast.show(String(localized: "Moved \(items.count) to \(name)", comment: "Toast after moving several picked sidebar rows to another space"),
                   symbol: "arrow.right.square", action: (String(localized: "Undo", comment: "Toast button"), { [weak self] in
            guard let undo = self?.sidebarUndo, undo.canUndo, undo.undoActionName == String(localized: "Move to Space", comment: "Undo action name, shown in Edit › Undo.") else { return }
            undo.undo()
        }), duration: Toast.undoDuration, in: self)
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
        }), duration: Toast.undoDuration, in: self)
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

    // MARK: Groups of tabs (#209)

    /// New group from these tabs (a split's row brings its other pages), renamed in place.
    func groupWithUndo(_ tabs: [Tab]) {
        var made: UUID?
        pageChange(String(localized: "New Group", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            made = tabManager.makeGroup(with: tabs, name: String(localized: "New Group", comment: "Name a new group of tabs gets, until it's renamed."))
        }
        sidebar.list.clearMarks()
        guard let made else { return }
        sidebar.list.reload(animated: true)
        DispatchQueue.main.async { [weak self] in self?.sidebar.list.renameGroup(made) }
    }

    /// Into a group (nil: out of theirs), after its last tab.
    func setGroupWithUndo(of tabs: [Tab], to group: UUID?) {
        pageChange(group == nil ? String(localized: "Remove from Group", comment: "Undo action name, shown in Edit › Undo.")
                   : String(localized: "Add to Group", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in
            for tab in tabs { tabManager.setGroup(of: tab, to: group) }
        }
    }

    /// Ungroup: the group goes, tabs stay.
    func ungroupWithUndo(_ id: UUID) {
        pageChange(String(localized: "Ungroup", comment: "Undo action name, shown in Edit › Undo.")) { [tabManager] in tabManager.ungroup(id) }
    }

    /// Closes every tab in the group, whole splits; ⌘Z (or the toast's Undo) restores them with the group.
    func closeGroupWithUndo(_ id: UUID) {
        closeManyWithUndoToast(tabManager.tabs(inGroup: id).flatMap(tabManager.panes(of:)).reduce(into: [Tab]()) { all, tab in
            if !all.contains(where: { $0 === tab }) { all.append(tab) }
        })
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

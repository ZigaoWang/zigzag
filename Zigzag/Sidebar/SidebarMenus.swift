import AppKit

/// Right-click menus for sidebar rows and spaces. Native menus: they are the Mac way.
enum SidebarMenus {
    /// Menu items that run a closure. The handler object rides along as the item's represented object.
    final class Handler: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func runAction(_ sender: Any?) { run() }
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

    /// For several picked rows: what makes sense for all of them at once.
    static func markedMenu(for items: [SidebarItem], controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tabs = items.compactMap { item -> Tab? in if case .tab(let id) = item { controller.tabManager.tab(with: id) } else { nil } }
        let count = items.count
        // A private window's tabs never join the pins every window shares, in a folder or on their own.
        let isPrivate = controller.tabManager.isPrivate
        if !isPrivate || tabs.isEmpty {
            menu.addItem(Item("Add \(count) to New Folder") { controller.sidebar.list.clearMarks(); controller.newFolder(with: controller.pinnedIDs(for: items)) })
            let folders = Library.shared.folders(in: controller.tabManager.currentSpaceID)
            if !folders.isEmpty {
                let add = NSMenuItem(title: "Add \(count) to Folder", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for folder in folders {
                    sub.addItem(Item(folder.name) {
                        controller.sidebar.list.clearMarks()
                        for id in controller.pinnedIDs(for: items) { controller.listSetFolder(of: id, to: folder.id) }
                    })
                }
                add.submenu = sub
                menu.addItem(add)
            }
        }
        // Picked pinned rows, a pinned split's as one.
        let pins = items.compactMap { item -> UUID? in if case .bookmark(let id) = item { id } else { nil } }
        let pages = pins.flatMap { id in Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id] }
            .compactMap(controller.tabManager.bookmarkTab(for:))
        if !pins.isEmpty, Library.shared.spaces.count > 1 || !pages.isEmpty || !isPrivate {
            let manager = controller.tabManager
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if Library.shared.spaces.count > 1 {
                let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let current = Library.shared.spaceID(ofBookmark: pins[0])
                for space in Library.shared.spaces where space.id != current {
                    sub.addItem(Item(space.name) {
                        controller.sidebar.list.clearMarks()
                        controller.libraryChange("Move to Space") { for id in pins { Library.shared.moveBookmark(id, to: Int.max, in: space.id) } }
                    })
                }
                move.submenu = sub
                menu.addItem(move)
            }
            if !pages.isEmpty {
                menu.addItem(Item(pages.count == 1 ? "Unload Page" : "Unload \(pages.count) Pages") {
                    controller.sidebar.list.clearMarks()
                    manager.close(pages)
                })
            }
            // Pins are shared by every window: a private one doesn't take them away.
            if !isPrivate {
                menu.addItem(Item(pins.count == 1 ? "Unpin Tab" : "Unpin \(pins.count) Tabs") {
                    controller.sidebar.list.clearMarks()
                    // Each comes down to the top of the tabs, the last first, so they keep their order.
                    for id in pins.reversed() { controller.unbookmarkWithUndo(id, to: 0) }
                })
            }
        }
        if !tabs.isEmpty {
            if !pins.isEmpty, !menu.items.isEmpty { menu.addItem(.separator()) }
            if !isPrivate {
                menu.addItem(Item(tabs.count == 1 ? "Pin Tab" : "Pin \(tabs.count) Tabs") {
                    controller.sidebar.list.clearMarks()
                    for tab in tabs where tab.bookmarkID == nil { controller.bookmarkWithUndo(tab, at: nil, in: tab.spaceID) }
                })
                menu.addItem(.separator())
            }
            menu.addItem(Item(tabs.count == 1 ? "Close Tab" : "Close \(tabs.count) Tabs") {
                controller.sidebar.list.clearMarks()
                controller.closeManyWithUndo(tabs)
            })
        }
        return menu
    }

    static func tabMenu(for tab: Tab, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        menu.addItem(Item("Rename") { controller.sidebar.list.beginRenaming(tab: tab.id) })
        menu.addItem(Item("Copy Link", enabled: tab.url != nil) {
            if let url = tab.url { controller.copyLink(url) }
        })
        // Half of a split pins with its other half, as a split.
        let pinsPair = manager.partner(of: tab).map { $0.bookmarkID == nil && $0.url != nil } ?? false
        // Pins and favorites are shared by every window: a private one's tabs stay out of them.
        if !manager.isPrivate {
            menu.addItem(Item(pinsPair ? "Pin Split View" : "Pin Tab", enabled: tab.url != nil) { controller.bookmarkWithUndo(tab, at: nil, in: tab.spaceID) })
            menu.addItem(Item("Add to Favorites", enabled: tab.url != nil) { controller.favoriteWithUndo(tab) })
        }
        if manager.split(for: tab) != nil {
            menu.addItem(Item("Separate Tabs") { controller.unsplitWithUndo(tab) })
        } else if let current = manager.selectedTab, manager.canSplit(current, with: tab) {
            menu.addItem(Item("Open in Split View") { controller.splitWithUndo(current, with: tab) })
        }
        menu.addItem(Item("Duplicate Tab") { controller.duplicate(tab) })
        if !controller.tabManager.isPrivate, tab.bookmarkID == nil {
            menu.addItem(Item("Move Tab to New Window") { controller.moveToNewWindow(tab) })
        }
        menu.addItem(.separator())
        menu.addItem(Item("Reload Page") { tab.reload() })
        if tab.isPlayingAudio || tab.isMuted {
            menu.addItem(Item(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) })
        }
        if Library.shared.spaces.count > 1 {
            let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for space in Library.shared.spaces where space.id != tab.spaceID {
                sub.addItem(Item(space.name) { controller.moveToSpaceWithToast(tab, spaceID: space.id) })
            }
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        menu.addItem(Item("Close Tab") { controller.closeWithUndo(tab) })
        let tabs = manager.tabs(in: tab.spaceID)
        if let index = tabs.firstIndex(where: { $0 === tab }) {
            let below = Array(tabs.dropFirst(index + 1))
            menu.addItem(Item("Close Tabs Below", enabled: !below.isEmpty) { controller.closeManyWithUndoToast(below) })
            let others = tabs.filter { $0 !== tab }
            menu.addItem(Item("Close Other Tabs", enabled: !others.isEmpty) { controller.closeManyWithUndoToast(others) })
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
        if pinned == nil { menu.addItem(Item("Rename") { BookmarkEditor.edit(bookmark.id, in: controller) }) }
        if let live, let url = live.url, TabManager.normalize(url) != TabManager.normalize(bookmark.url) {
            menu.addItem(Item("Back to Pinned Page") { manager.resetBookmarkTab(bookmark.id) })
            menu.addItem(Item("Separate from Pinned Tab") { manager.separateBookmarkTab(bookmark.id) })
            menu.addItem(Item("Pin This Page Instead") {
                controller.libraryChange("Update Pinned Page") { Library.shared.updateBookmark(bookmark.id, url: url) }
            })
        }
        menu.addItem(Item("Copy Link") { controller.copyLink(bookmark.url) })
        menu.addItem(Item("Add to Favorites") {
            controller.libraryChange("Add to Favorites") { Library.shared.makeFavorite(bookmark.id) }
            live?.isFavorite = true
        })
        // Beside the tab you're on, as a tab opens; not loaded yet, it opens at its pinned address.
        if pinned == nil, let current = manager.selectedTab, current.bookmarkID == nil, live.map({ manager.split(for: $0) == nil }) ?? true {
            menu.addItem(Item("Open in Split View") { controller.splitWithUndo(current, with: manager.pageTab(for: bookmark)) })
        }
        // Folders of this space's pinned pages.
        let current = Library.shared.folderID(containing: bookmark.id)
        let spaceFolders = Library.shared.spaceID(ofBookmark: bookmark.id).map { Library.shared.folders(in: $0) } ?? []
        menu.addItem(.separator())
        menu.addItem(Item("Add to New Folder") { controller.newFolder(with: [bookmark.id]) })
        let others = spaceFolders.filter { $0.id != current }
        if !others.isEmpty {
            let add = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for folder in others {
                sub.addItem(Item(folder.name) { controller.listSetFolder(of: bookmark.id, to: folder.id) })
            }
            add.submenu = sub
            menu.addItem(add)
        }
        if current != nil {
            menu.addItem(Item("Remove from Folder") { controller.listSetFolder(of: bookmark.id, to: nil) })
        }
        if Library.shared.spaces.count > 1 {
            let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = Library.shared.spaceID(ofBookmark: bookmark.id)
            for space in Library.shared.spaces where space.id != current {
                sub.addItem(Item(space.name) {
                    controller.libraryChange("Move to Space") { Library.shared.moveBookmark(bookmark.id, to: Int.max, in: space.id) }
                })
            }
            move.submenu = sub
            menu.addItem(move)
        }
        if pinned != nil || live != nil || !manager.isPrivate { menu.addItem(.separator()) }
        if let pinned {
            // Both stay pinned, each in a row of its own.
            menu.addItem(Item("Separate Tabs") {
                let open = [pinned.left, pinned.right].compactMap(manager.bookmarkTab(for:)).first { manager.split(for: $0) != nil }
                if let open {
                    controller.unsplitWithUndo(open)
                } else {
                    controller.libraryChange("Separate Tabs") { Library.shared.removePinnedSplit(containing: bookmark.id) }
                }
            })
            let pages = [pinned.left, pinned.right].compactMap(manager.bookmarkTab(for:))
            if !pages.isEmpty {
                menu.addItem(Item("Unload Pages") { manager.close(pages) })
            }
            if !manager.isPrivate { menu.addItem(Item("Unpin Split View") { controller.unbookmarkWithUndo(bookmark.id, to: 0) }) }
            return menu
        }
        if let live {
            menu.addItem(Item("Unload Page") { manager.close(live) })
        }
        // Pins are shared by every window: a private one doesn't take them away.
        if !manager.isPrivate { menu.addItem(Item("Unpin Tab") { controller.unbookmarkWithUndo(bookmark.id, to: 0) }) }
        return menu
    }

    static func folderMenu(for folder: BookmarkFolder, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Item("Rename") { controller.sidebar.list.renameFolder(folder.id) })
        menu.addItem(Item("Change Icon…") { controller.chooseFolderIcon(folder.id) })
        menu.addItem(Item(folder.isOpen ? "Close Folder" : "Open Folder") { controller.listSetFolderOpen(folder.id, !folder.isOpen) })
        menu.addItem(.separator())
        // The folder goes; what was in it stays pinned, where it was.
        menu.addItem(Item("Remove Folder") {
            controller.libraryChange("Remove Folder") { Library.shared.removeFolder(folder.id) }
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
            menu.addItem(Item("Rename…") { BookmarkEditor.edit(favorite.id, in: controller) })
        }
        menu.addItem(Item("Copy Link") { controller.copyLink(favorite.url) })
        if let live, let url = live.url, TabManager.normalize(url) != TabManager.normalize(favorite.url) {
            menu.addItem(Item("Back to Pinned Page") { manager.resetBookmarkTab(favorite.id) })
            menu.addItem(Item("Separate from Pinned Tab") { manager.separateBookmarkTab(favorite.id) })
            menu.addItem(Item("Pin This Page Instead") {
                controller.libraryChange("Update Pinned Page") { Library.shared.updateBookmark(favorite.id, url: url) }
            })
        }
        // A split favorite: its two pages go and come as one, and can be parted into two favorites.
        if let pair = Library.shared.pinnedSplit(containing: favorite.id) {
            menu.addItem(Item("Separate Tabs") { controller.separateFavoriteSplitWithUndo(favorite.id) })
            if !manager.isPrivate { menu.addItem(Item("Move to Tabs") { controller.unfavoriteWithUndo(favorite.id, to: 0) }) }
            menu.addItem(.separator())
            let pages = [pair.left, pair.right].compactMap { manager.bookmarkTab(for: $0) }
            if !pages.isEmpty { menu.addItem(Item("Unload Pages") { manager.close(pages) }) }
            if !manager.isPrivate { menu.addItem(Item("Remove from Favorites") { controller.removeFavoriteWithUndo(favorite.id) }) }
            return menu
        }
        // Favorites are shared by every window: a private one doesn't take them away.
        if !manager.isPrivate { menu.addItem(Item("Move to Tabs") { controller.unfavoriteWithUndo(favorite.id, to: 0) }) }
        if live != nil || !manager.isPrivate { menu.addItem(.separator()) }
        if let live {
            menu.addItem(Item("Unload Page") { manager.close(live) })
        }
        if !manager.isPrivate { menu.addItem(Item("Remove from Favorites") { controller.removeFavoriteWithUndo(favorite.id) }) }
        return menu
    }

    static func spaceMenu(for id: UUID, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A private window borrows a space's look but keeps nothing: it can't change the spaces you keep.
        guard let space = Library.shared.space(id), !controller.tabManager.isPrivate else { return menu }
        menu.addItem(Item("Edit Space…") {
            let anchor = controller.sidebar.dot(for: id) ?? controller.sidebar.list.headerView
            controller.openSpaceEditor(id, anchor: anchor)
        })
        _ = space
        if id == controller.tabManager.currentSpaceID {
            menu.addItem(Item("New Folder") { controller.newFolder() })
        }
        menu.addItem(.separator())
        menu.addItem(Item("New Space") { controller.newSpace(nil) })
        menu.addItem(Item("Delete Space", enabled: Library.shared.spaces.count > 1) {
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
        Toast.show("Deleted “\(name)”", symbol: "trash", action: ("Undo", { [weak controller] in
            guard let undo = controller?.sidebarUndo, undo.canUndo, undo.undoActionName == "Delete Space" else { return }
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
            controller.libraryChange("Rename Pinned Tab") { Library.shared.updateBookmark(id, title: title) }
        }
    }
}

/// One field in a small Zigzag panel, for renaming something that has no row of its own (a favorite).
final class RenamePanel: FloatingPanelView, NSTextFieldDelegate {
    private let field = FilledField(placeholder: "Name")
    private let save = PillButton(title: "Rename", style: .prominent)
    private var done: ((String) -> Void)?
    private var monitor: Any?

    static func show(title: String, in controller: BrowserWindowController, done: @escaping (String) -> Void) {
        controller.closeFloatingPanels()
        let panel = RenamePanel(frame: NSRect(x: 0, y: 0, width: Tokens.Dialog.width, height: Tokens.Metric.controlHeight + Tokens.Space.x3 * 2))
        panel.done = done
        panel.field.stringValue = title
        let card = controller.root.cardFrame
        // Where the command bar opens, the other place you type a name.
        panel.frame.origin = NSPoint(x: round(card.midX - Tokens.Dialog.width / 2), y: card.minY + max(Tokens.Space.x12, floor(card.height * 0.18)))
        controller.root.overlay.addSubview(panel)
        panel.present(arrival: .fade)
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

    private func close(commit: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if commit, !text.isEmpty { done?(text) }
        done = nil
        dismiss()
    }
}

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

    static func tabMenu(for tab: Tab, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        menu.addItem(Item("Copy Link", enabled: tab.url != nil) {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
        menu.addItem(Item("Bookmark", enabled: tab.url != nil) { controller.bookmarkWithUndo(tab, at: nil, in: tab.spaceID) })
        menu.addItem(Item("Duplicate") {
            if let url = tab.url { manager.newTab(url: url) }
        })
        menu.addItem(.separator())
        menu.addItem(Item("Reload") { tab.reload() })
        if tab.isPlayingAudio || tab.isMuted {
            menu.addItem(Item(tab.isMuted ? "Unmute" : "Mute") { tab.setMuted(!tab.isMuted) })
        }
        if Library.shared.spaces.count > 1 {
            let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for space in Library.shared.spaces where space.id != tab.spaceID {
                sub.addItem(Item(space.name) { controller.moveWithUndo(tab, to: 0, in: space.id) })
            }
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        menu.addItem(Item("Close Tab") { controller.closeWithUndo(tab) })
        let tabs = manager.tabs(in: tab.spaceID)
        if let index = tabs.firstIndex(where: { $0 === tab }) {
            let below = Array(tabs.dropFirst(index + 1))
            menu.addItem(Item("Close Tabs Below", enabled: !below.isEmpty) { manager.close(below) })
            let others = tabs.filter { $0 !== tab }
            menu.addItem(Item("Close Other Tabs", enabled: !others.isEmpty) { manager.close(others) })
        }
        return menu
    }

    static func bookmarkMenu(for bookmark: Bookmark, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let manager = controller.tabManager
        let live = manager.bookmarkTab(for: bookmark.id)
        menu.addItem(Item("Rename…") { BookmarkEditor.edit(bookmark.id, in: controller) })
        if let live, let url = live.url, TabManager.normalize(url) != TabManager.normalize(bookmark.url) {
            menu.addItem(Item("Go Back to Bookmarked Page") { manager.resetBookmarkTab(bookmark.id) })
            menu.addItem(Item("Use Current Page as Bookmark") {
                Library.shared.updateBookmark(bookmark.id, url: url)
            })
        }
        menu.addItem(Item("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
        })
        if Library.shared.spaces.count > 1 {
            let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = Library.shared.spaceID(ofBookmark: bookmark.id)
            for space in Library.shared.spaces where space.id != current {
                sub.addItem(Item(space.name) { Library.shared.moveBookmark(bookmark.id, to: Int.max, in: space.id) })
            }
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        if let live {
            menu.addItem(Item("Unload Page") { manager.close(live) })
        }
        menu.addItem(Item("Remove Bookmark") { controller.unbookmarkWithUndo(bookmark.id, to: 0) })
        return menu
    }

    static func spaceMenu(for id: UUID, controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let space = Library.shared.space(id) else { return menu }
        menu.addItem(Item("Edit Space…") {
            let anchor = controller.sidebar.dot(for: id) ?? controller.sidebar.list.headerView
            controller.openSpaceEditor(id, anchor: anchor)
        })
        _ = space
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

/// Renaming spaces and bookmarks: small native sheets with one field.
enum SpaceEditor {
    static func rename(spaceID: UUID, in controller: BrowserWindowController) {
        guard let space = Library.shared.space(spaceID) else { return }
        TextPrompt.ask(title: "Rename Space", value: space.name, in: controller) { name in
            Library.shared.renameSpace(spaceID, to: name)
        }
    }

    static func confirmDelete(spaceID: UUID, in controller: BrowserWindowController) {
        guard let space = Library.shared.space(spaceID), let window = controller.window else { return }
        let count = controller.tabManager.tabs(in: spaceID).count + space.bookmarks.count
        if count == 0 { Library.shared.removeSpace(spaceID); return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.name)”?"
        alert.informativeText = "Its \(count) tab\(count == 1 ? "" : "s") and bookmark\(count == 1 ? "" : "s") will be closed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { Library.shared.removeSpace(spaceID) }
        }
    }
}

enum BookmarkEditor {
    static func edit(_ id: UUID, in controller: BrowserWindowController) {
        guard let bookmark = Library.shared.bookmark(id) else { return }
        TextPrompt.ask(title: "Rename Bookmark", value: bookmark.title, in: controller) { title in
            Library.shared.updateBookmark(id, title: title)
        }
    }
}

enum TextPrompt {
    static func ask(title: String, value: String, in controller: BrowserWindowController, done: @escaping (String) -> Void) {
        guard let window = controller.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { done(text) }
        }
    }
}

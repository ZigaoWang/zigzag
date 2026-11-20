import AppKit
import Testing
@testable import Zigzag

/// The sidebar's own menus, the + and a right-click on its empty space: Zigzag's drawn menu, the same items in the
/// same order, with the shortcuts the menu bar gives them, and the keys a menu takes.
@MainActor
struct SidebarMenuTests {
    @Test func plusOffersTabFolderThenSpace() {
        #expect(SidebarMenus.addEntries(isPrivate: false) == [.newTab, .newFolder, .newSpace])
    }

    @Test func emptySpaceMatchesThePlusWithEditSpace() {
        #expect(SidebarMenus.blankEntries(isPrivate: false) == [.newTab, .newFolder, .separator, .editSpace, .newSpace])
        // The same items as the +, in the same order.
        #expect(SidebarMenus.blankEntries(isPrivate: false).filter { $0 != .separator && $0 != .editSpace } == SidebarMenus.addEntries(isPrivate: false))
    }

    @Test func privateWindowOnlyMakesTabs() {
        #expect(SidebarMenus.blankEntries(isPrivate: true) == [.newTab])
        #expect(SidebarMenus.addEntries(isPrivate: true) == [.newTab])
    }

    @Test func everyItemHasASymbolAndTheMenuBarsShortcut() {
        for entry in SidebarMenus.blankEntries(isPrivate: false) where entry != .separator {
            #expect(SidebarMenus.symbol(of: entry) != nil)
            #expect(!SidebarMenus.title(of: entry).isEmpty)
        }
        #expect(SidebarMenus.action(of: .newTab) == #selector(BrowserWindowController.newTab(_:)))
        #expect(SidebarMenus.action(of: .newSpace) == #selector(BrowserWindowController.newSpace(_:)))
        #expect(SidebarMenus.action(of: .editSpace) == #selector(BrowserWindowController.renameSpace(_:)))
        // No menu bar item makes a folder, so it shows no shortcut rather than an invented one.
        #expect(SidebarMenus.action(of: .newFolder) == nil)
        // New Space makes the space at once, as New Folder does: no ellipsis, the same as in the menu bar.
        #expect(SidebarMenus.title(of: .newSpace) == String(localized: "New Space", comment: "View menu item."))
        #expect(SidebarMenus.title(of: .editSpace).hasSuffix("…"))
    }

    // MARK: The drawn menu

    private func host() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = content
        let anchor = NSView(frame: NSRect(x: 200, y: 20, width: 26, height: 26))
        content.addSubview(anchor)
        return (window, anchor)
    }

    private func key(_ code: UInt16, _ characters: String = "", in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func entries(_ chosen: @escaping (String) -> Void) -> [MenuPanel.Entry] {
        ["New Tab", "New Folder", "New Space"].map { title in
            .item(MenuPanel.Item(title: title, symbol: "plus", shortcut: title == "New Tab" ? "⌘T" : "") { chosen(title) })
        }
    }

    @Test func opensJustAboveThePlusAlignedToIt() throws {
        let (window, anchor) = host()
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .aboveTrailing))
        defer { menu.close(animated: false) }
        let frame = menu.convert(menu.bounds, to: nil)
        let button = anchor.convert(anchor.bounds, to: nil)
        #expect(abs(frame.maxX - button.maxX) < 0.5)
        #expect(frame.minY >= button.maxY)
        #expect(frame.minY - button.maxY <= Tokens.Space.x1 + 0.5)
        #expect(menu.itemTitles == ["New Tab", "New Folder", "New Space"])
        _ = window
    }

    @Test func rightClickOpensUnderThePointer() throws {
        let (_, anchor) = host()
        let point = NSPoint(x: 120, y: 400)
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .at(point)))
        defer { menu.close(animated: false) }
        let frame = menu.convert(menu.bounds, to: nil)
        #expect(abs(frame.minX - point.x) < 0.5)
        #expect(abs(frame.maxY - point.y) < 0.5)
    }

    @Test func aShortcutWidensTheMenuToFitIt() throws {
        let (_, anchor) = host()
        let plain = try #require(MenuPanel.show([.item(MenuPanel.Item(title: "New Tab") {})], from: anchor))
        let plainWidth = plain.frame.width
        plain.close(animated: false)
        let keyed = try #require(MenuPanel.show([.item(MenuPanel.Item(title: "New Tab", shortcut: "⌥⌘N") {})], from: anchor))
        defer { keyed.close(animated: false) }
        #expect(keyed.frame.width > plainWidth)
    }

    @Test func arrowsMoveReturnPicksEscapeCloses() throws {
        let (window, anchor) = host()
        var picked: String?
        let menu = try #require(MenuPanel.show(entries { picked = $0 }, from: anchor, placement: .aboveTrailing))
        #expect(menu.highlightedIndex == nil)
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.highlightedIndex == 0)
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.highlightedIndex == 1)
        #expect(menu.handleKey(key(126, in: window)))
        #expect(menu.highlightedIndex == 0)
        // Up from the first stays there; End goes to the last.
        #expect(menu.handleKey(key(126, in: window)))
        #expect(menu.highlightedIndex == 0)
        #expect(menu.handleKey(key(119, in: window)))
        #expect(menu.highlightedIndex == 2)
        #expect(menu.handleKey(key(36, "\r", in: window)))
        #expect(picked == "New Space")
        #expect(MenuPanel.current == nil)

        let again = try #require(MenuPanel.show(entries { picked = $0 }, from: anchor, placement: .aboveTrailing))
        picked = nil
        #expect(again.handleKey(key(53, in: window)))
        #expect(picked == nil)
        #expect(MenuPanel.current == nil)
    }

    @Test func isAMenuOfMenuItemsForVoiceOver() throws {
        let (_, anchor) = host()
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .aboveTrailing))
        defer { menu.close(animated: false) }
        #expect(menu.accessibilityRole() == .menu)
        let items = (menu.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.accessibilityRole() == .menuItem })
        #expect(items.first?.accessibilityLabel() == "New Tab")
    }
}

/// The right-click menus of the sidebar's rows (#327): what's about this row first, then sections in a set order
/// with close last, only items that would do something, and the menu bar's keys on the tab you're on.
@MainActor
struct SidebarRowMenuTests {
    /// A window over a fresh manager with tabs `titles` in the first space and a second space to move to; the
    /// library is restored after.
    /// `local`: blank pages, so tabs can be woken without reaching the network.
    private func inWindow(_ titles: [String], isPrivate: Bool = false, local: Bool = false, _ body: (BrowserWindowController, [Tab], UUID) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        if Library.shared.spaces.count < 2 { _ = Library.shared.addSpace(name: "Other") }
        let manager = TabManager(spaceID: space, isPrivate: isPrivate)
        defer { manager.invalidate() }
        let tabs = titles.enumerated().map { i, title in Tab(url: URL(string: local ? "about:blank#\(i)" : "https://example.com/menu/\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        try body(controller, tabs, space)
    }

    /// Titles, "-" for a separator.
    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    private func run(_ item: NSMenuItem?) throws {
        let item = try #require(item)
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }

    @Test func aTabsMenuIsGroupedWithCloseLast() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let menu = SidebarMenus.tabMenu(for: tabs[1], controller: controller)
            #expect(titles(menu) == ["Reload Page", "Duplicate Tab", "Copy Link", "-",
                                     "Save Page", "New Group with Tab", "-",
                                     "Open in Split View", "Move To", "-",
                                     "Rename", "Change Icon…", "-",
                                     "Close Tab", "Close Tabs Below", "Close Other Tabs"])
            // Translate is the page's own now, and nothing shows dimmed.
            #expect(!titles(menu).contains(PageTranslator.menuTitle(translated: false)))
            #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled })
            // One list of where the tab can go.
            let places = try #require(menu.items.first { $0.title == "Move To" }?.submenu)
            #expect(Array(titles(places).prefix(3)) == ["New Window", "Zigzag Mini", "-"])
            #expect(places.items.count > 3)
            // Not the tab you're on: the menu bar's keys would act on another, so none show.
            #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        }
    }

    @Test func aRunningTabCanBePutToSleepFromItsMenu() throws {
        try inWindow(["A", "B", "C"], local: true) { controller, tabs, _ in
            // Not running: nothing to put to sleep.
            #expect(!titles(SidebarMenus.tabMenu(for: tabs[1], controller: controller)).contains("Suspend Page"))
            tabs[1].ensureWebView()
            let menu = SidebarMenus.tabMenu(for: tabs[1], controller: controller)
            #expect(Array(titles(menu).prefix(3)) == ["Reload Page", "Suspend Page", "Duplicate Tab"])
            try run(menu.items.first { $0.title == "Suspend Page" })
            #expect(tabs[1].isAsleep && !tabs[1].isLoaded)
            #expect(tabs[1].notLoadedNote == "You put it to sleep. Loads when you click it.")
            #expect(controller.tabManager.selectedTab === tabs[0])
        }
    }

    @Test func theTabYoureOnGoesOutOfSightAsItSleeps() throws {
        try inWindow(["A", "B"], local: true) { controller, tabs, _ in
            tabs[0].ensureWebView()
            #expect(controller.tabManager.maySuspend(tabs[0]))
            controller.suspendPage(nil)
            #expect(controller.tabManager.selectedTab === tabs[1])
            #expect(tabs[0].isAsleep)
        }
    }

    @Test func theOnlyTabHasNowhereToGoAndStaysAwake() throws {
        try inWindow(["A"], local: true) { controller, tabs, _ in
            tabs[0].ensureWebView()
            #expect(!controller.tabManager.maySuspend(tabs[0]))
            #expect(!titles(SidebarMenus.tabMenu(for: tabs[0], controller: controller)).contains("Suspend Page"))
        }
    }

    @Test func pickedTabsSleepTogether() throws {
        try inWindow(["A", "B", "C"], local: true) { controller, tabs, _ in
            tabs[1].ensureWebView()
            tabs[2].ensureWebView()
            let menu = SidebarMenus.markedMenu(for: [.tab(tabs[1].id), .tab(tabs[2].id)], controller: controller)
            #expect(Array(titles(menu).prefix(2)) == ["Suspend 2 Pages", "-"])
            try run(menu.items.first)
            #expect(tabs[1].isAsleep && tabs[2].isAsleep)
        }
    }

    @Test func theTabYoureOnShowsTheMenuBarsKeys() throws {
        try inWindow(["A", "B"]) { controller, tabs, _ in
            let menu = SidebarMenus.tabMenu(for: tabs[0], controller: controller)
            // Nothing to split it with but itself.
            #expect(!titles(menu).contains("Open in Split View"))
            // Nothing below the last tab to close.
            #expect(!titles(SidebarMenus.tabMenu(for: tabs[1], controller: controller)).contains("Close Tabs Below"))
            let keyed: [(String, Selector)] = [("Reload Page", #selector(BrowserWindowController.reloadPage(_:))), ("Copy Link", #selector(BrowserWindowController.copyPageURL(_:))),
                                               ("Save Page", #selector(BrowserWindowController.savePage(_:))), ("Close Tab", #selector(BrowserWindowController.closeTab(_:)))]
            for (title, action) in keyed {
                let bar = Shortcuts.allItems.first { $0.action == action }
                let item = try #require(menu.items.first { $0.title == title })
                #expect(item.keyEquivalent == (bar?.keyEquivalent ?? ""), "\(title)")
                if let bar { #expect(item.keyEquivalentModifierMask == bar.keyEquivalentModifierMask, "\(title)") }
            }
        }
    }

    @Test func aPinnedPageOnItsAddressOffersNoWayBack() throws {
        try inWindow(["A", "B"]) { controller, tabs, space in
            controller.tabManager.bookmarkTab(tabs[0], in: space)
            let id = try #require(tabs[0].bookmarkID)
            controller.tabManager.select(tabs[1])
            let menu = SidebarMenus.bookmarkMenu(for: try #require(Library.shared.bookmark(id)), controller: controller)
            #expect(titles(menu) == ["Copy Link", "-",
                                     "Unsave Page", "In Every Space", "Add to New Folder", "Move to Space", "-",
                                     "Open in Split View", "-",
                                     "Rename", "Change Icon…", "-",
                                     "Unload Page", "Remove Pinned Page"])
        }
    }

    @Test func aPinnedPageThatWanderedOffLeadsWithGoingBackOrKeepingIt() throws {
        try inWindow(["A", "B"]) { controller, tabs, space in
            controller.tabManager.bookmarkTab(tabs[0], in: space)
            let id = try #require(tabs[0].bookmarkID)
            Library.shared.updateBookmark(id, url: URL(string: "https://example.com/home")!)
            let menu = SidebarMenus.bookmarkMenu(for: try #require(Library.shared.bookmark(id)), controller: controller)
            #expect(Array(titles(menu).prefix(4)) == ["Back to Pinned Page", "Save This Page Instead", "Separate from Pinned Tab", "-"])
            // Kept: the pinned address becomes the page it shows now, and there's nothing to go back to.
            try run(menu.items.first { $0.title == "Save This Page Instead" })
            #expect(Library.shared.bookmark(id)?.url == tabs[0].url)
            #expect(!titles(SidebarMenus.bookmarkMenu(for: try #require(Library.shared.bookmark(id)), controller: controller)).contains("Back to Pinned Page"))
        }
    }

    @Test func aSplitLeadsWithSeparatingItAndEachPageGetsItsOwnMenu() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            // The right half of the row: its own menu, not the left page's.
            let menu = try #require(controller.listMenu(for: .tab(tabs[0].id), page: tabs[1]))
            #expect(Array(titles(menu).prefix(2)) == ["Separate Split View", "-"])
            #expect(titles(menu).contains("Save Split View"))
            #expect(!titles(menu).contains("Remove from Split View"))
            #expect(!titles(menu).contains("Open in Split View"))
            try run(menu.items.first)
            #expect(manager.split(for: tabs[0]) == nil)
        }
    }

    @Test func onePageOfThreeCanLeaveTheRestSideBySide() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            let placed = try #require(TileShape.placing(.bottomRight, beside: manager.split(for: tabs[0])?.shape.regions ?? []))
            manager.tile(tabs[2], beside: tabs[0], .place(region: .bottomRight, regions: placed))
            #expect(manager.split(for: tabs[2])?.isGroup == true)
            let menu = SidebarMenus.tabMenu(for: tabs[2], controller: controller)
            #expect(Array(titles(menu).prefix(3)) == ["Remove from Split View", "Separate Split View", "-"])
            try run(menu.items.first)
            #expect(manager.split(for: tabs[2]) == nil)
            #expect(manager.split(for: tabs[0])?.ids.count == 2)
        }
    }

    @Test func groupsAreOneItemOrOneSubmenu() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let manager = controller.tabManager
            let group = try #require(manager.makeGroup(with: [tabs[0]], name: "Reading"))
            // With another group, joining one or starting one is one submenu, New Group first.
            let outside = SidebarMenus.tabMenu(for: tabs[1], controller: controller)
            #expect(!titles(outside).contains("New Group with Tab"))
            let add = try #require(outside.items.first { $0.title == "Add to Group" }?.submenu)
            #expect(titles(add) == ["New Group", "-", "Reading"])
            #expect(titles(SidebarMenus.tabMenu(for: tabs[0], controller: controller)).contains("Remove from Group"))
            let header = SidebarMenus.groupMenu(for: try #require(manager.group(group)), controller: controller)
            #expect(titles(header) == ["Collapse Group", "-", "Ungroup", "Move to Space", "-", "Rename", "-", "Close Group"])
        }
    }

    @Test func pickedRowsOrganizeThenClose() {
        inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let menu = SidebarMenus.markedMenu(for: [.tab(tabs[0].id), .tab(tabs[1].id)], controller: controller)
            // Only the tab you're on is running, so only it can be suspended; saving replaces main's Pin and Favorites items.
            #expect(titles(menu) == ["Suspend Page", "-", "Save 2 Pages", "Add 2 to New Folder", "Group 2 Tabs", "Move 2 to Space", "-", "Close 2 Tabs"])
        }
    }

    @Test func aPrivateWindowsTabKeepsOutOfSavesAndWindows() throws {
        try inWindow(["A", "B"], isPrivate: true) { controller, tabs, _ in
            let menu = SidebarMenus.tabMenu(for: tabs[1], controller: controller)
            #expect(!titles(menu).contains("Save Page") && !titles(menu).contains("In Every Space"))
            let places = try #require(menu.items.first { $0.title == "Move To" }?.submenu)
            #expect(!titles(places).contains("New Window") && !titles(places).contains("Zigzag Mini"))
        }
    }
}

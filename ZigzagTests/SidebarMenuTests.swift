import AppKit
import Testing
import WebKit
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

    /// Short of room below, the menu slides up only as far as it must, as macOS's does, never flipped whole above.
    @Test func rightClickNearTheBottomSlidesUpJustEnough() throws {
        let (window, anchor) = host()
        let area = try #require(window.contentView).bounds
        let point = NSPoint(x: 120, y: area.minY + 40)
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .at(point)))
        defer { menu.close(animated: false) }
        let frame = menu.convert(menu.bounds, to: nil)
        // Its bottom rests on the window's margin, so its top is no higher than it needs to be.
        #expect(frame.minY >= area.minY)
        #expect(frame.minY - area.minY <= 12)
        #expect(frame.maxY > point.y)
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

    @Test func aButtonsMenuOpensInwardFromTheRightHalf() throws {
        let (_, left) = host()
        let leftMenu = try #require(MenuPanel.show(entries { _ in }, from: left))
        let leftFrame = leftMenu.convert(leftMenu.bounds, to: nil), leftButton = left.convert(left.bounds, to: nil)
        leftMenu.close(animated: false)
        #expect(abs(leftFrame.minX - leftButton.minX) < 0.5)

        let (window, _) = host()
        let right = NSView(frame: NSRect(x: 680, y: 500, width: 110, height: 28))
        window.contentView?.addSubview(right)
        let rightMenu = try #require(MenuPanel.show(entries { _ in }, from: right))
        defer { rightMenu.close(animated: false) }
        let frame = rightMenu.convert(rightMenu.bounds, to: nil), button = right.convert(right.bounds, to: nil)
        #expect(abs(frame.maxX - button.maxX) < 0.5)
        #expect(abs(frame.maxY - (button.minY - Tokens.Space.x1)) < 0.5)
        #expect(frame.maxX <= 800)
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

    // MARK: Submenus

    /// "Copy Link", then "Move To" with "Work" and "Home" inside.
    private func nested(_ chosen: @escaping (String) -> Void) -> [MenuPanel.Entry] {
        let spaces: [MenuPanel.Entry] = ["Work", "Home"].map { title in .item(MenuPanel.Item(title: title, symbol: "square") { chosen(title) }) }
        return [.item(MenuPanel.Item(title: "Copy Link", symbol: "link") { chosen("Copy Link") }),
                .item(MenuPanel.Item(title: "Move To", symbol: "arrow.right.square", submenu: spaces) { chosen("Move To") })]
    }

    @Test func rightOpensASubmenuLeftClosesOnlyIt() throws {
        let (window, anchor) = host()
        var picked: String?
        let menu = try #require(MenuPanel.show(nested { picked = $0 }, from: anchor, placement: .at(NSPoint(x: 100, y: 400))))
        defer { menu.close(animated: false) }
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.highlightedIndex == 1)
        // Right on Move To: its submenu, first item lit, beside it on the right.
        #expect(menu.handleKey(key(124, in: window)))
        let sub = try #require(menu.openSubmenu)
        #expect(sub.itemTitles == ["Work", "Home"])
        #expect(sub.highlightedIndex == 0)
        #expect(sub.convert(sub.bounds, to: nil).minX >= menu.convert(menu.bounds, to: nil).maxX)
        // The keys go to it now.
        #expect(menu.handleKey(key(125, in: window)))
        #expect(sub.highlightedIndex == 1)
        // Left closes the submenu alone; Move To stays lit.
        #expect(menu.handleKey(key(123, in: window)))
        #expect(menu.openSubmenu == nil)
        #expect(MenuPanel.current === menu)
        #expect(menu.highlightedIndex == 1)
        #expect(picked == nil)
    }

    @Test func returnOpensASubmenuAndChoosingInsideClosesEveryMenu() throws {
        let (window, anchor) = host()
        var picked: String?
        let menu = try #require(MenuPanel.show(nested { picked = $0 }, from: anchor, placement: .at(NSPoint(x: 100, y: 400))))
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.handleKey(key(119, in: window)))
        // Return on an item with a submenu opens it rather than running anything.
        #expect(menu.handleKey(key(36, "\r", in: window)))
        let sub = try #require(menu.openSubmenu)
        #expect(picked == nil)
        // Esc in the submenu closes only it.
        #expect(menu.handleKey(key(53, in: window)))
        #expect(menu.openSubmenu == nil)
        #expect(MenuPanel.current === menu)
        #expect(menu.handleKey(key(124, in: window)))
        #expect(menu.openSubmenu !== sub)
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.handleKey(key(36, "\r", in: window)))
        #expect(picked == "Home")
        #expect(MenuPanel.current == nil)
        #expect(menu.superview == nil || menu.openSubmenu == nil)
    }

    @Test func aSubmenuOpensInwardAtTheWindowsRightEdge() throws {
        let (window, anchor) = host()
        let menu = try #require(MenuPanel.show(nested { _ in }, from: anchor, placement: .at(NSPoint(x: 700, y: 400))))
        defer { menu.close(animated: false) }
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.handleKey(key(119, in: window)))
        #expect(menu.handleKey(key(124, in: window)))
        let sub = try #require(menu.openSubmenu)
        let frame = sub.convert(sub.bounds, to: nil)
        #expect(frame.maxX <= menu.convert(menu.bounds, to: nil).minX)
        #expect(frame.maxX <= 800)
    }

    @Test func aSubmenuItemShowsAChevronNotACheck() throws {
        let (_, anchor) = host()
        let menu = try #require(MenuPanel.show(nested { _ in }, from: anchor))
        defer { menu.close(animated: false) }
        let items = (menu.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        #expect(items.map { $0.accessibilityRole() } == [.menuItem, .menuButton])
    }

    // MARK: AppKit menus drawn

    @Test func anAppKitMenuKeepsItsItemsWhenDrawn() throws {
        var ran: [String] = []
        let menu = SidebarMenus.menu([
            [SidebarMenus.Item("Reload Page", symbol: "arrow.clockwise") { ran.append("reload") }],
            [SidebarMenus.Item("Delete Space", symbol: "trash", destructive: true, enabled: false) { ran.append("delete") }],
            [SidebarMenus.Submenu("Move To", symbol: "arrow.right.square", [SidebarMenus.Item("Work") { ran.append("work") }])],
        ])
        let large = SidebarMenus.Item("Large Space Names", symbol: "textformat.size") {}
        large.state = .on
        menu.addItem(large)
        let keyed = SidebarMenus.withShortcut(SidebarMenus.Item("Close Tab", symbol: "xmark") {}, of: #selector(BrowserWindowController.closeTab(_:)))
        menu.addItem(keyed)
        menu.insertItem(.sectionHeader(title: "Profile"), at: 0)

        let entries = MenuPanel.entries(from: menu)
        var titles: [String] = []
        var items: [MenuPanel.Item] = []
        for entry in entries {
            switch entry {
            case .item(let item): titles.append(item.title); items.append(item)
            case .header(let text): titles.append("# " + text)
            case .separator: titles.append("-")
            case .note: titles.append("note")
            }
        }
        #expect(titles == ["# Profile", "Reload Page", "-", "Delete Space", "-", "Move To", "Large Space Names", "Close Tab"])
        #expect(items.allSatisfy { $0.symbol != nil })
        let delete = try #require(items.first { $0.title == "Delete Space" })
        #expect(delete.isDestructive && !delete.isEnabled)
        #expect(items.first { $0.title == "Large Space Names" }?.isChecked == true)
        #expect(items.first { $0.title == "Close Tab" }?.shortcut == Shortcuts.keys(for: #selector(BrowserWindowController.closeTab(_:))))
        let move = try #require(items.first { $0.title == "Move To" })
        guard case .item(let work)? = move.submenu?.first else { Issue.record("no submenu"); return }
        items.first { $0.title == "Reload Page" }?.action()
        work.action()
        #expect(ran == ["reload", "work"])
    }

    /// A help button's lines open in the drawn menu's panel, not a system popover: wrapped to its width, read as a
    /// popover, closed by Esc or the button again.
    @Test func aNoteOpensInTheDrawnPanel() throws {
        let (window, anchor) = host()
        let text = NSAttributedString(string: String(repeating: "Matches pages on the exact hostname you enter. ", count: 4))
        let menu = try #require(MenuPanel.show([.note(text)], from: anchor, minWidth: 300))
        #expect(MenuPanel.current === menu)
        #expect(menu.accessibilityRole() == .popover)
        #expect(menu.itemTitles.isEmpty)
        #expect(menu.frame.width >= 300)
        // Several lines, all inside it.
        #expect(menu.frame.height > Tokens.Page.controlHeight * 2)
        #expect(menu.handleKey(key(53, "\u{1b}", in: window)))
        #expect(MenuPanel.current == nil)
    }

    @Test func theMatchTypeHelpTogglesItsPanel() throws {
        let (window, anchor) = host()
        let help = SiteRouteSheet.matchHelpButton()
        help.frame = anchor.frame
        anchor.superview?.addSubview(help)
        #expect(help.accessibilityPerformPress())
        let menu = try #require(MenuPanel.current)
        #expect(menu.anchor === help)
        #expect(menu.accessibilityRole() == .popover)
        #expect(help.accessibilityPerformPress())
        #expect(MenuPanel.current == nil)
        _ = window
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
        // A library this Mac already has may keep folders in its first space, which turns these menus' "Add … to New
        // Folder" into "Add … to Folder". The snapshot puts them back afterwards.
        for folder in Library.shared.folders(in: space) { Library.shared.removeFolder(folder.id) }
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
            #expect(titles(menu) == ["Reload Page", "Duplicate Tab", "Mute Tab", "Copy Link", "-",
                                     "Pin Tab", "Add to Favorites", "New Group with Tab", "-",
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
            // Every tab's menu shows the menu bar's keys, the one you're on or not.
            #expect(menu.items.first { $0.title == "Reload Page" }?.keyEquivalent == "r")
            #expect(menu.items.first { $0.title == "Close Tab" }?.keyEquivalent == "w")
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

    @Test func aTabCanBeMutedBeforeItPlays() throws {
        try inWindow(["A", "B", "C"], local: true) { controller, tabs, space in
            // Not running and silent: Mute Tab is with the page's actions.
            let menu = SidebarMenus.tabMenu(for: tabs[1], controller: controller)
            #expect(Array(titles(menu).prefix(3)) == ["Reload Page", "Duplicate Tab", "Mute Tab"])
            try run(menu.items.first { $0.title == "Mute Tab" })
            #expect(tabs[1].isMuted)
            // Muted, Unmute Tab leads the menu as it always has.
            #expect(Array(titles(SidebarMenus.tabMenu(for: tabs[1], controller: controller)).prefix(2)) == ["Unmute Tab", "-"])
            // Its page starts muted, and stays muted after a reload and after sleeping.
            let webView = tabs[1].ensureWebView()
            #expect(webView.pageMutedState.map(WKWebView.isAudioMuted) == true)
            tabs[1].reload()
            #expect(webView.pageMutedState.map(WKWebView.isAudioMuted) == true)
            controller.suspendWithToast([tabs[1]])
            #expect(tabs[1].isAsleep && tabs[1].isMuted)
            #expect(tabs[1].ensureWebView().pageMutedState.map(WKWebView.isAudioMuted) == true)
            // A pinned page that's open has it too.
            controller.tabManager.bookmarkTab(tabs[2], in: space)
            let pin = try #require(tabs[2].bookmarkID.flatMap(Library.shared.bookmark))
            try run(SidebarMenus.bookmarkMenu(for: pin, controller: controller).items.first { $0.title == "Mute Tab" })
            #expect(tabs[2].isMuted)
            #expect(SidebarMenus.bookmarkMenu(for: pin, controller: controller).items.first?.title == "Unmute Tab")
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

    /// One page of a split you're on sleeps and leaves the split; you stay on the other.
    @Test func onePageOfASplitSleepsAndTheOtherStaysShown() throws {
        try inWindow(["A", "B", "C"], local: true) { controller, tabs, _ in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            tabs[0].ensureWebView()
            #expect(manager.maySuspend(tabs[0]))
            controller.suspendPage(nil)
            #expect(tabs[0].isAsleep)
            #expect(manager.split(for: tabs[1]) == nil)
            #expect(manager.selectedTab === tabs[1])
            #expect(!tabs[1].isAsleep)
        }
    }

    @Test func theSplitPageYoureNotInSleepsAndYouStay() throws {
        try inWindow(["A", "B", "C"], local: true) { controller, tabs, _ in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            controller.suspendWithToast([tabs[1]])
            #expect(tabs[1].isAsleep)
            #expect(manager.split(for: tabs[0]) == nil)
            #expect(manager.selectedTab === tabs[0])
        }
    }

    /// Text you typed keeps the page awake, and you're not moved off it first.
    @Test func aPageWithTypedTextKeepsYouOnIt() async throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        // A library this Mac already has may keep folders in its first space, which turns these menus' "Add … to New
        // Folder" into "Add … to Folder". The snapshot puts them back afterwards.
        for folder in Library.shared.folders(in: space) { Library.shared.removeFolder(folder.id) }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = ["A", "B"].enumerated().map { i, title in Tab(url: URL(string: "about:blank#\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let page = tabs[0].ensureWebView()
        page.loadHTMLString("<html><body><input id='note'></body></html>", baseURL: URL(string: "https://example.com/"))
        var ready = false
        for _ in 0..<200 where !ready {
            try await Task.sleep(for: .milliseconds(50))
            guard tabs[0].hasLoadedOnce, !page.isLoading else { continue }
            ready = (try? await page.evaluateJavaScript("!!document.getElementById('note')")) as? Bool == true
        }
        try #require(ready)
        _ = try await page.evaluateJavaScript("const el = document.getElementById('note'); el.value = 'half written'; window.__zigzagTyped.add(el); true",
                                              in: nil, contentWorld: .defaultClient)
        let why = await withCheckedContinuation { (done: CheckedContinuation<Tab.StaysAwake, Never>) in
            manager.suspend(chosen: [tabs[0]]) { _, why in done.resume(returning: why) }
        }
        #expect(why == .typedText)
        #expect(manager.selectedTab === tabs[0])
        #expect(tabs[0].isLoaded && !tabs[0].isAsleep)
    }

    @Test func theTabYoureOnShowsTheMenuBarsKeys() throws {
        try inWindow(["A", "B"]) { controller, tabs, _ in
            let menu = SidebarMenus.tabMenu(for: tabs[0], controller: controller)
            // Nothing to split it with but itself.
            #expect(!titles(menu).contains("Open in Split View"))
            // Nothing below the last tab to close.
            #expect(!titles(SidebarMenus.tabMenu(for: tabs[1], controller: controller)).contains("Close Tabs Below"))
            let keyed: [(String, Selector)] = [("Reload Page", #selector(BrowserWindowController.reloadPage(_:))), ("Copy Link", #selector(BrowserWindowController.copyPageURL(_:))),
                                               ("Pin Tab", #selector(BrowserWindowController.toggleBookmark(_:))), ("Close Tab", #selector(BrowserWindowController.closeTab(_:)))]
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
            #expect(titles(menu) == ["Mute Tab", "Copy Link", "-",
                                     "Unpin Tab", "Add to Favorites", "Add to New Folder", "Move to Space", "-",
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
            #expect(Array(titles(menu).prefix(4)) == ["Back to Pinned Page", "Set Current Page as Pinned", "Separate from Pinned Tab", "-"])
            // Kept: the pinned address becomes the page it shows now, and there's nothing to go back to.
            try run(menu.items.first { $0.title == "Set Current Page as Pinned" })
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
            #expect(titles(menu).contains("Pin Split View"))
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

    /// A tab whose group can't be pinned whole (Settings is in it) still adds to Favorites from its menu, as the menu
    /// bar and the command bar offer.
    @Test func aTabOfAnUnpinnableGroupStillAddsToFavorites() throws {
        try inWindow(["A"]) { controller, tabs, space in
            let manager = controller.tabManager
            let settings = Tab(url: try #require(URL(string: "zigzag://settings")), title: "Settings", spaceID: space)
            manager.adopt([settings], in: space)
            _ = try #require(manager.makeGroup(with: [tabs[0], settings], name: "Mixed"))
            manager.select(tabs[0])
            let menu = titles(SidebarMenus.tabMenu(for: tabs[0], controller: controller))
            #expect(!menu.contains("Pin Group") && !menu.contains("Pin Tab"))
            #expect(menu.contains("Add to Favorites"))
            #expect(CommandRanker.context(for: manager).canFavorite)
            let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.addToFavorites(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(item))
        }
    }

    @Test func pickedRowsOrganizeThenClose() {
        inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let menu = SidebarMenus.markedMenu(for: [.tab(tabs[0].id), .tab(tabs[1].id)], controller: controller)
            // Only the tab you're on is running, so only it can be suspended.
            #expect(titles(menu) == ["Suspend Page", "-", "Pin 2 Tabs", "Add 2 to Favorites", "Add 2 to New Folder", "Group 2 Tabs", "Move 2 to Space", "-", "Close 2 Tabs"])
        }
    }

    @Test func aPrivateWindowsTabKeepsOutOfSavesAndWindows() throws {
        try inWindow(["A", "B"], isPrivate: true) { controller, tabs, _ in
            let menu = SidebarMenus.tabMenu(for: tabs[1], controller: controller)
            #expect(!titles(menu).contains("Pin Tab") && !titles(menu).contains("Add to Favorites"))
            let places = try #require(menu.items.first { $0.title == "Move To" }?.submenu)
            #expect(!titles(places).contains("New Window") && !titles(places).contains("Zigzag Mini"))
        }
    }

    /// A private window leaves your pins and favorites as they are: no Add to Favorites, Rename or Change Icon on
    /// them, File › Add to Favorites is off, and a rename that gets through anyway writes nothing.
    @Test func aPrivateWindowNeitherFavoritesNorRenamesYourPins() throws {
        try inWindow(["A", "B"], isPrivate: true) { controller, _, space in
            let pin = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/menu/pin")!, title: "Pin", to: space))
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/menu/favorite")!, title: "Favorite", in: controller.tabManager.profile.id)
            let writes = ["Add to Favorites", "Rename", "Rename…", SidebarMenus.changeIconTitle]
            let pinned = titles(SidebarMenus.bookmarkMenu(for: pin, controller: controller))
            #expect(!pinned.contains { writes.contains($0) }, "\(pinned)")
            let favorites = titles(SidebarMenus.favoriteMenu(for: favorite, controller: controller))
            #expect(!favorites.contains { writes.contains($0) }, "\(favorites)")

            // On the pinned page itself, File › Add to Favorites is off and does nothing.
            let manager = controller.tabManager
            let tab = manager.pageTab(for: pin)
            manager.select(tab)
            let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.addToFavorites(_:)), keyEquivalent: "")
            #expect(!controller.validateMenuItem(item))
            controller.addToFavorites(item)
            #expect(!Library.shared.isFavorite(pin.id))

            BookmarkEditor.edit(pin.id, in: controller)
            controller.listRenameBookmark(pin.id, to: "Renamed")
            #expect(Library.shared.bookmark(pin.id)?.title == "Pin")
        }
    }

    /// A private window leaves your pins where they are: no filing, moving or folder edits in its menus, and a drop
    /// or a menu action that gets through anyway changes nothing.
    @Test func aPrivateWindowLeavesYourPinsWhereTheyAre() throws {
        try inWindow(["A", "B"], isPrivate: true) { controller, _, space in
            let first = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/menu/first")!, title: "First", to: space))
            let second = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/menu/second")!, title: "Second", to: space))
            let folder = try #require(Library.shared.addFolder(named: "Kept", with: [first.id], in: space))
            let other = try #require(Library.shared.spaces.first { $0.id != space }?.id)
            let before = Library.shared.snapshot

            let pinned = titles(SidebarMenus.bookmarkMenu(for: first, controller: controller))
            for title in ["Add to New Folder", "Add to Folder", "Remove from Folder", "Move to Space"] { #expect(!pinned.contains(title), "\(title)") }
            let picked = titles(SidebarMenus.markedMenu(for: [.bookmark(first.id), .bookmark(second.id)], controller: controller))
            #expect(!picked.contains { $0.hasPrefix("Add 2 to") || $0.hasPrefix("Unpin") }, "\(picked)")
            let shelf = titles(SidebarMenus.folderMenu(for: folder, controller: controller))
            for title in ["New Folder Inside", "Rename", SidebarMenus.changeIconTitle, "Remove Folder"] { #expect(!shelf.contains(title), "\(title)") }
            #expect(shelf.contains("Open All in Tabs"))

            controller.listMoveBookmark(second.id, to: 0, in: space, folder: nil)
            controller.listMoveBookmark(second.id, to: Int.max, in: other)
            controller.listSetFolder(of: second.id, to: folder.id)
            controller.listMoveFolder(folder.id, to: Int.max, in: other, parent: nil)
            controller.listRenameFolder(folder.id, to: "Renamed")
            controller.newFolder(with: [second.id])
            controller.fileMarked([.bookmark(second.id)], in: nil)
            controller.unpinMarked([second.id])
            controller.favoriteMarked([.bookmark(second.id)])
            #expect(Library.shared.snapshot == before)
        }
    }

    /// Every item of a drawn menu, submenus' too, with whether it has a picture.
    private func drawn(_ menu: NSMenu) -> [(title: String, pictured: Bool)] {
        func walk(_ entries: [MenuPanel.Entry]) -> [(title: String, pictured: Bool)] {
            entries.flatMap { entry -> [(title: String, pictured: Bool)] in
                guard case .item(let item) = entry else { return [] }
                return [(item.title, item.symbol != nil || item.image != nil)] + walk(item.submenu ?? [])
            }
        }
        return walk(MenuPanel.entries(from: menu))
    }

    private func item(_ title: String, in menu: NSMenu) -> MenuPanel.Item? {
        MenuPanel.entries(from: menu).compactMap { entry -> MenuPanel.Item? in
            if case .item(let item) = entry, item.title == title { item } else { nil }
        }.first
    }

    /// The sidebar's right-click menus are Zigzag's own: the AppKit menu's items in order, each with its symbol.
    @Test func everySidebarMenuItemHasAPicture() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, space in
            let manager = controller.tabManager
            manager.bookmarkTab(tabs[2], in: space)
            let pin = try #require(tabs[2].bookmarkID.flatMap { Library.shared.bookmark($0) })
            let folder = try #require(Library.shared.addFolder(named: "Shelf", with: [pin.id], in: space))
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/menu/favorite")!, title: "Favorite", in: manager.profile.id)
            let menus: [NSMenu] = [
                SidebarMenus.tabMenu(for: tabs[1], controller: controller),
                SidebarMenus.tabMenu(for: tabs[0], controller: controller),
                SidebarMenus.bookmarkMenu(for: pin, controller: controller),
                SidebarMenus.folderMenu(for: folder, controller: controller),
                SidebarMenus.favoriteMenu(for: favorite, controller: controller),
                SidebarMenus.spaceMenu(for: space, controller: controller),
                SidebarMenus.markedMenu(for: [.tab(tabs[0].id), .tab(tabs[1].id)], controller: controller),
            ]
            for menu in menus {
                let items = drawn(menu)
                #expect(!items.isEmpty)
                for item in items { #expect(item.pictured, "\(item.title)") }
                let top = MenuPanel.entries(from: menu).compactMap { entry -> String? in if case .item(let item) = entry { item.title } else { nil } }
                #expect(top == menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }.map(\.title))
            }
            #expect(item("Delete Space", in: SidebarMenus.spaceMenu(for: space, controller: controller))?.isDestructive == true)
        }
    }

    /// Every tab's drawn menu shows the menu bar's keys, as they are now.
    @Test func theDrawnMenuShowsTheMenuBarsKeys() throws {
        try inWindow(["A", "B"]) { controller, tabs, _ in
            let close = item("Close Tab", in: SidebarMenus.tabMenu(for: tabs[0], controller: controller))
            #expect(close?.shortcut == Shortcuts.keys(for: #selector(BrowserWindowController.closeTab(_:))))
            #expect(close?.shortcut.isEmpty == false)
            #expect(item("Close Tab", in: SidebarMenus.tabMenu(for: tabs[1], controller: controller))?.shortcut == close?.shortcut)
        }
    }

    /// Every drawn sidebar menu shows the menu bar's keys on an item for the same action: a tab's, a pinned page's
    /// (loaded or not), a favorite's, a space's, picked rows' and the +'s.
    @Test func everySidebarMenuShowsTheMenuBarsKeysForTheSameAction() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, space in
            typealias C = BrowserWindowController
            let manager = controller.tabManager
            manager.bookmarkTab(tabs[2], in: space)
            let pin = try #require(tabs[2].bookmarkID.flatMap { Library.shared.bookmark($0) })
            let resting = Library.shared.addBookmark(url: URL(string: "https://example.com/menu/resting")!, title: "Resting", to: space)
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/menu/favorite")!, title: "Favorite", in: manager.profile.id)
            let actions: [String: Selector] = [
                "Reload Page": #selector(C.reloadPage(_:)), "Duplicate Tab": #selector(C.duplicateTab(_:)), "Suspend Page": #selector(C.suspendPage(_:)),
                "Mute Tab": #selector(C.toggleMute(_:)), "Unmute Tab": #selector(C.toggleMute(_:)), "Copy Link": #selector(C.copyPageURL(_:)),
                "Pin Tab": #selector(C.toggleBookmark(_:)), "Unpin Tab": #selector(C.toggleBookmark(_:)), "Move to Tabs": #selector(C.toggleBookmark(_:)),
                "Add to Favorites": #selector(C.addToFavorites(_:)), "Close Tab": #selector(C.closeTab(_:)), "Close Tabs Below": #selector(C.closeTabsBelow(_:)),
                "Close Other Tabs": #selector(C.closeOtherTabs(_:)), "Edit Space…": #selector(C.renameSpace(_:)), "New Space": #selector(C.newSpace(_:)),
                "New Tab": #selector(C.newTab(_:)),
            ]
            var menus: [[MenuPanel.Entry]] = [
                SidebarMenus.tabMenu(for: tabs[0], controller: controller), SidebarMenus.tabMenu(for: tabs[1], controller: controller),
                SidebarMenus.bookmarkMenu(for: pin, controller: controller), SidebarMenus.favoriteMenu(for: favorite, controller: controller),
                SidebarMenus.spaceMenu(for: space, controller: controller),
                SidebarMenus.markedMenu(for: [.tab(tabs[0].id), .tab(tabs[1].id)], controller: controller),
            ].map(MenuPanel.entries(from:))
            if let resting { menus.append(MenuPanel.entries(from: SidebarMenus.bookmarkMenu(for: resting, controller: controller))) }
            menus += [SidebarMenus.addPanel(controller: controller), SidebarMenus.blankPanel(controller: controller)]
            @MainActor func items(_ entries: [MenuPanel.Entry]) -> [MenuPanel.Item] {
                entries.flatMap { entry -> [MenuPanel.Item] in
                    guard case .item(let item) = entry else { return [] }
                    return [item] + items(item.submenu ?? [])
                }
            }
            var checked = Set<String>()
            for item in menus.flatMap(items) {
                guard let action = actions[item.title] else { continue }
                #expect(item.shortcut == Shortcuts.keys(for: action), "\(item.title)")
                checked.insert(item.title)
            }
            #expect(checked.isSuperset(of: ["Copy Link", "Unpin Tab", "Move to Tabs", "Close Tab", "New Tab", "Edit Space…"]))
        }
    }

    /// A right-click on a tab's row opens the drawn menu and gives AppKit none.
    @Test func aRightClickOnARowOpensTheDrawnMenu() throws {
        try inWindow(["A", "B"]) { controller, tabs, _ in
            controller.sidebar.list.reload(animated: false)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let row = try #require(controller.sidebar.list.tabRow(tabs[1].id) as? InteractiveView)
            #expect(row.drawsMenu)
            let point = row.convert(NSPoint(x: 20, y: row.bounds.midY), to: nil)
            let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(row.menu(for: click) == nil)
            row.rightMouseDown(with: click)
            let menu = try #require(MenuPanel.current)
            defer { menu.close(animated: false) }
            #expect(menu.anchor === row)
            #expect(menu.itemTitles.first == "Reload Page")
            #expect(menu.itemTitles.last == "Close Other Tabs")
        }
    }
}

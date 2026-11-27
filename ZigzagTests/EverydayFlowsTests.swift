import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Everyday flows checked against what the window shows: the sidebar's rows and tiles as drawn, the row that's lit,
/// the page on the card and the panels that are up, not only what TabManager or Library hold. Each test follows one
/// flow end to end through the window's own actions; its spec line names it.
@MainActor @Suite(.serialized) struct EverydayFlowsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    // MARK: The window and what it shows

    /// A window over a manager of its own with tabs `titles` in the first space, the first selected. Tabs at
    /// `addressed` have a web address, the rest none, so no page renames them. The library, tab placing and the
    /// window are put back afterwards.
    private func inWindow(_ titles: [String], addressed: Set<Int> = [], _ body: (BrowserWindowController, [Tab]) async throws -> Void) async rethrows {
        let before = Library.shared.snapshot
        let place = TabManager.newTabPlace, nests = TabManager.nestsOpenedLinks
        TabManager.newTabPlace = .next
        TabManager.nestsOpenedLinks = false
        defer { TabManager.newTabPlace = place; TabManager.nestsOpenedLinks = nests; Library.shared.restore(before) }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = titles.enumerated().map { i, title in
            Tab(url: addressed.contains(i) ? URL(string: "http://127.0.0.1:9/everyday/\(i)") : nil, title: title, spaceID: space)
        }
        manager.adopt(tabs, in: space)
        if let first = tabs.first { manager.select(first) }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 900, height: 600))
        defer { controller.window?.close() }
        await settle()
        try await body(controller, tabs)
    }

    /// Lets what the window queued on the main queue run, a few turns deep, so the views have caught up: each turn
    /// waits behind everything queued before it.
    private func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        }
    }

    /// Waits for `condition`, looking every 20 ms, at most `seconds`.
    private func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func untilAsync(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// The window as drawn: the sidebar's rows top to bottom, the favorites' tiles, and the page on the card.
    /// Rows read "Title"; a lit row starts with "*", a pinned page's row that isn't loaded with "~", a split row
    /// joins its pages with "|", a folder reads "▾Name" open or "▸Name" shut. Tiles read the same, "+" for an open one.
    private struct Screen: CustomStringConvertible {
        var rows: [String]
        var favorites: [String]
        var page: Tab?
        var isEmpty: Bool
        /// The lit rows and tiles by title, a tile's "+" left off.
        var lit: [String] {
            (rows + favorites).filter { $0.hasPrefix("*") }.map { let title = $0.dropFirst(); return String(title.hasPrefix("+") ? title.dropFirst() : title) }
        }
        var description: String { "rows \(rows) favorites \(favorites) page \(page?.displayTitle ?? "none")\(isEmpty ? " empty" : "")" }
    }

    private func screen(_ controller: BrowserWindowController) async -> Screen {
        await settle()
        // A space switch slides the new list in over the old one; it's the list once the slide is done.
        _ = await until { !controller.sidebar.debugIsHandingOff }
        let sidebar = controller.sidebar, list = sidebar.list, manager = controller.tabManager
        sidebar.layoutSubtreeIfNeeded()
        var rows: [String] = []
        for item in list.debugItems {
            var name: String
            var view: NSView?
            switch item {
            case .tab(let id):
                guard let tab = manager.tab(with: id) else { rows.append("?gone"); continue }
                name = manager.panes(of: tab).map(\.displayTitle).joined(separator: "|")
                view = list.row(for: tab)
            case .bookmark(let id):
                let ids = Library.shared.pinnedSplit(containing: id).map(\.ids) ?? [id]
                name = ids.compactMap { Library.shared.bookmark($0)?.title }.joined(separator: "|")
                view = list.row(forBookmark: id)
                if let row = view as? TabRowView, row.isUnloaded { name = "~" + name }
            case .folder(let id):
                guard let folder = Library.shared.folder(id) else { rows.append("?gone"); continue }
                name = (folder.isOpen ? "▾" : "▸") + folder.name
                view = list.row(forFolder: id)
            case .tabGroup(let id):
                name = "group:" + (manager.group(id)?.name ?? "?")
                view = list.groupRow(id)
            default:
                continue
            }
            if (view as? InteractiveView)?.isSelected == true { name = "*" + name }
            rows.append(name)
        }
        var tiles: [FavoriteTile] = []
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if let tile = sub as? FavoriteTile, tile.bookmark != nil { tiles.append(tile) } else { walk(sub) }
            }
        }
        walk(sidebar.favorites)
        tiles.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let favorites = tiles.map { tile in
            (tile.isSelected ? "*" : "") + (tile.isOpen ? "+" : "") + (tile.bookmark?.title ?? "")
        }
        let page = (controller.root.card.webView as? BrowserWebView)?.owner
        return Screen(rows: rows, favorites: favorites, page: controller.root.isEmpty ? nil : page, isEmpty: controller.root.isEmpty)
    }

    /// The pages on the pane cards that show, left to right, top to bottom.
    private func panes(_ controller: BrowserWindowController) async -> [String] {
        await settle()
        controller.root.layoutSubtreeIfNeeded()
        return controller.root.paneCards.filter { !$0.isHidden && $0.webView != nil }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .compactMap { ($0.webView as? BrowserWebView)?.owner?.displayTitle }
    }

    /// The sidebar's rows read as `expected`.
    private func expectRows(_ controller: BrowserWindowController, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
        let shown = await screen(controller)
        #expect(shown.rows == expected, "\(shown)", sourceLocation: sourceLocation)
    }

    /// The pane cards show `expected`.
    private func expectPanes(_ controller: BrowserWindowController, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
        // A split's second page can come a moment after the first on a busy Mac.
        _ = await untilAsync { await self.panes(controller) == expected }
        let shown = await panes(controller)
        #expect(shown == expected, sourceLocation: sourceLocation)
    }

    /// The tab on screen: lit in the sidebar, on the card, and the one selected.
    private func expectShown(_ tab: Tab, in controller: BrowserWindowController, _ comment: String = "",
                             sourceLocation: SourceLocation = #_sourceLocation) async {
        let shown = await screen(controller)
        #expect(controller.tabManager.selectedTab === tab, "\(comment) selected \(controller.tabManager.selectedTab?.displayTitle ?? "none")", sourceLocation: sourceLocation)
        #expect(shown.page === tab, "\(comment) \(shown)", sourceLocation: sourceLocation)
        #expect(shown.lit == [controller.tabManager.panes(of: tab).map(\.displayTitle).joined(separator: "|")], "\(comment) \(shown)", sourceLocation: sourceLocation)
    }

    private func pin(_ title: String) throws -> Bookmark {
        try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/everyday/pin/\(title)")!, title: title, to: space))
    }

    private func favorite(_ title: String) -> Bookmark {
        Library.shared.addFavorite(url: URL(string: "http://127.0.0.1:9/everyday/fav/\(title)")!, title: title,
                                   in: Library.shared.profileID(ofSpace: space))
    }

    private func favoriteTile(_ controller: BrowserWindowController, _ id: UUID) -> FavoriteTile? {
        var found: FavoriteTile?
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let tile = sub as? FavoriteTile, tile.bookmark?.id == id { found = tile } else { walk(sub) }
            }
        }
        walk(controller.sidebar.favorites)
        return found
    }

    // MARK: Closing tabs (specs/tabs.md, Closing)

    /// tabs.md: "⌘W on a tab you opened yourself (⌘T, New Tab), before you switched tabs → the tab you were on."
    @Test func commandTThenCommandWGoesBackToTheTabYouWereOn() async throws {
        try await inWindow(["A", "B", "C", "D"]) { controller, tabs in
            controller.listSelect(tabs[2])
            controller.listSelect(tabs[1])
            await expectShown(tabs[1], in: controller)
            controller.newTab(nil)
            #expect(controller.commandBar.isVisible && controller.commandBar.mode == .newTab)
            controller.commandBar.debugType("http://127.0.0.1:9/everyday/new")
            controller.commandBar.debugEnter()
            #expect(!controller.commandBar.isVisible)
            let opened = try #require(controller.tabManager.selectedTab)
            #expect(!tabs.contains { $0 === opened })
            await expectShown(opened, in: controller, "the new tab")
            controller.closeTab(nil)
            await expectShown(tabs[1], in: controller, "after ⌘W")
            await expectRows(controller, ["A", "*B", "C", "D"])
        }
    }

    enum ReturnPlace: String, CaseIterable { case pin, favorite, pinInFolder, pinnedSplit }

    /// tabs.md: "⌘W on a tab you opened yourself … → the tab you were on", when that was a pinned page, a favorite,
    /// a pin in a folder or a page of a pinned split.
    @Test(arguments: ReturnPlace.allCases)
    func commandTThenCommandWGoesBackToThePinOrFavoriteYouWereOn(place: ReturnPlace) async throws {
        try await inWindow(["A", "B", "C"]) { controller, tabs in
            let mark: Bookmark
            switch place {
            case .pin: mark = try pin("Pinned")
            case .favorite: mark = favorite("Favorite")
            case .pinInFolder:
                mark = try pin("Filed")
                let folder = try #require(Library.shared.addFolder(named: "Folder", with: [mark.id], in: space))
                Library.shared.setFolderOpen(folder.id, true)
            case .pinnedSplit:
                let left = try pin("Left")
                mark = try pin("Right")
                controller.listJoinPinned(mark.id, onto: left.id, onRight: true)
            }
            controller.sidebar.list.reload(animated: false)
            controller.listSelect(tabs[2])
            controller.listOpenBookmark(mark)
            let page = try #require(controller.tabManager.bookmarkTab(for: mark.id))
            // A split shows its pages side by side, the half you were on lit with them.
            let shownAs = { (comment: String) async in
                if place == .pinnedSplit {
                    #expect(controller.tabManager.selectedTab === page, "\(comment)")
                    await self.expectPanes(controller, controller.tabManager.panes(of: page).map(\.displayTitle))
                    #expect(await self.screen(controller).lit == [controller.tabManager.panes(of: page).map(\.displayTitle).joined(separator: "|")], "\(comment)")
                } else {
                    await self.expectShown(page, in: controller, comment)
                }
            }
            await shownAs("\(place) opened")
            controller.newTab(nil)
            controller.commandBar.debugType("http://127.0.0.1:9/everyday/new")
            controller.commandBar.debugEnter()
            let opened = try #require(controller.tabManager.selectedTab)
            #expect(opened !== page)
            await expectShown(opened, in: controller, "\(place) the new tab")
            controller.closeTab(nil)
            #expect(opened.isClosed)
            await shownAs("\(place) after ⌘W")
        }
    }

    /// tabs.md: "⌘W on a tab opened from another tab, before you switched tabs yourself → the next tab that opener
    /// opened, else the opener."
    @Test func aLinkOpenedInFrontClosesBackToItsPage() async throws {
        try await inWindow(["A", "B", "C"]) { controller, tabs in
            controller.listSelect(tabs[1])
            controller.tab(tabs[1], openURL: URL(string: "http://127.0.0.1:9/everyday/front")!, disposition: .foregroundTab)
            let link = try #require(controller.tabManager.selectedTab)
            #expect(link !== tabs[1])
            await expectShown(link, in: controller, "the link")
            #expect(await screen(controller).rows.count == 4)
            controller.closeTab(nil)
            await expectShown(tabs[1], in: controller, "after ⌘W")
            await expectRows(controller, ["A", "*B", "C"])
        }
    }

    /// tabs.md: links opened behind land below their page in reading order; "⌘W on any other tab you switched to →
    /// the tab below, else the one above".
    @Test func aLinkOpenedBehindThenClosedGoesToTheNext() async throws {
        try await inWindow(["A", "B", "C"]) { controller, tabs in
            controller.listSelect(tabs[1])
            for name in ["one", "two"] {
                controller.tab(tabs[1], openURL: URL(string: "http://127.0.0.1:9/everyday/\(name)")!, disposition: .backgroundTab)
            }
            await expectShown(tabs[1], in: controller, "links behind leave the page in front")
            let list = controller.tabManager.tabs(in: space)
            #expect(list.count == 5)
            let one = list[2], two = list[3]
            #expect(list[4] === tabs[2], "the links land under their page, in order")
            controller.listSelect(one)
            await expectShown(one, in: controller)
            controller.closeTab(nil)
            await expectShown(two, in: controller, "the next link")
            controller.closeTab(nil)
            await expectShown(tabs[2], in: controller, "the tab below")
            await expectRows(controller, ["A", "B", "*C"])
        }
    }

    /// tabs.md: "⌘W on the last tab of a space → the space's most recent page, else the space shows empty."
    @Test func closingTheLastTabOfASpace() async throws {
        try await inWindow(["Last"]) { controller, tabs in
            let mark = try pin("Recent")
            controller.listOpenBookmark(mark)
            let page = try #require(controller.tabManager.bookmarkTab(for: mark.id))
            controller.listSelect(tabs[0])
            controller.closeTab(nil)
            await expectShown(page, in: controller, "the space's recent page")
            await expectRows(controller, ["*Recent"])
            // The pinned page closed too: nothing left, and the space shows empty.
            controller.closeTab(nil)
            let shown = await screen(controller)
            #expect(shown.isEmpty, "\(shown)")
            #expect(shown.lit.isEmpty, "\(shown)")
            #expect(shown.rows == ["~Recent"])
            #expect(controller.tabManager.currentSpaceID == space)
        }
    }

    // MARK: Pinned tabs and favorites (specs/tabs.md, specs/pinning.md)

    enum PinPlace: String, CaseIterable { case top, openFolder, foldedSection, foldedInFolder, shutFolder }

    /// tabs.md: "⌘W on a pinned tab or favorite → it unloads and stays"; pinning.md: the same in a folded section and
    /// under a shut folder. Closed with ⌘W or the row's ×, its row stays where it was, unloaded, and the tab you
    /// were on is the one shown.
    @Test(arguments: PinPlace.allCases, [true, false])
    func aClosedPinnedTabStaysWhereItShows(place: PinPlace, byButton: Bool) async throws {
        let collapsed = SidebarListView.debugCollapsed
        defer { SidebarListView.debugCollapsed = collapsed }
        try await inWindow(["Tab"]) { controller, tabs in
            let mark = try pin("Pinned")
            var folder: BookmarkFolder?
            if place == .openFolder || place == .foldedInFolder || place == .shutFolder {
                folder = try #require(Library.shared.addFolder(named: "Folder", with: [mark.id], in: space))
                Library.shared.setFolderOpen(folder!.id, place != .shutFolder)
            }
            SidebarListView.debugCollapsed = place == .foldedSection || place == .foldedInFolder ? [space.uuidString] : []
            controller.sidebar.list.reload(animated: false)
            controller.listOpenBookmark(mark)
            let page = try #require(controller.tabManager.bookmarkTab(for: mark.id))
            await expectShown(page, in: controller, "opened")
            let open = await screen(controller).rows
            let label = "\(place) byButton=\(byButton)"
            if byButton {
                let row = try #require(controller.sidebar.list.row(forBookmark: mark.id) as? TabRowView, "\(label)")
                row.onClose?()
            } else {
                controller.closeTab(nil)
            }
            #expect(page.isClosed, "\(label)")
            #expect(Library.shared.bookmark(mark.id) != nil, "\(label)")
            let shown = await screen(controller)
            let expected = open.map { $0 == "*Pinned" ? "~Pinned" : $0 == "Tab" ? "*Tab" : $0 }
            #expect(shown.rows == expected, "\(label): before \(open), after \(shown)")
            #expect(shown.page === tabs[0], "\(label): \(shown)")
            // Opened again and closed with its × while the tab is the one shown: the same.
            controller.listOpenBookmark(mark)
            controller.listSelect(tabs[0])
            let row = try #require(controller.sidebar.list.row(forBookmark: mark.id) as? TabRowView, "\(label)")
            row.onClose?()
            #expect(controller.tabManager.bookmarkTab(for: mark.id) == nil, "\(label)")
            await expectShown(tabs[0], in: controller, "\(label) closed from behind")
            let behind = await screen(controller)
            #expect(behind.rows == expected, "\(label) closed from behind: \(behind)")
        }
    }

    /// tabs.md: "⌘W on a pinned tab or favorite → it unloads and stays". Closed with ⌘W or its tile's ×, the tile
    /// stays in Favorites, no longer open, and the tab you were on is shown.
    @Test(arguments: [true, false])
    func aClosedFavoriteStaysInFavorites(byButton: Bool) async throws {
        try await inWindow(["Tab"]) { controller, tabs in
            let mark = favorite("Favorite")
            await settle()
            #expect(await screen(controller).favorites == ["Favorite"])
            controller.sidebar.favorites.onOpen?(mark)
            let page = try #require(controller.tabManager.bookmarkTab(for: mark.id))
            #expect(await screen(controller).page === page)
            #expect(await screen(controller).favorites == ["*+Favorite"])
            if byButton { try #require(favoriteTile(controller, mark.id)).onClose?() } else { controller.closeTab(nil) }
            #expect(page.isClosed)
            let shown = await screen(controller)
            #expect(shown.favorites == ["Favorite"], "\(shown)")
            #expect(shown.page === tabs[0], "\(shown)")
            #expect(shown.rows == ["*Tab"], "\(shown)")
        }
    }

    // MARK: Reopening (specs/tabs.md, Reopening)

    /// tabs.md: "⇧⌘T for a tab → back in its own window, at its old place".
    @Test func shiftCommandTBringsBackAClosedTabInItsPlace() async throws {
        try await inWindow(["A", "B", "C"]) { controller, tabs in
            controller.listSelect(tabs[1])
            controller.closeTab(nil)
            await expectRows(controller, ["A", "*C"])
            controller.reopenClosedTab(nil)
            let back = try #require(controller.tabManager.selectedTab)
            #expect(back.displayTitle == "B")
            await expectShown(back, in: controller, "reopened")
            await expectRows(controller, ["A", "*B", "C"])
        }
    }

    /// tabs.md: "⇧⌘T after ⌘W on a pinned page or favorite → it loads again in its own row".
    @Test func shiftCommandTBringsBackAClosedPinnedTabInItsRow() async throws {
        try await inWindow(["Tab"]) { controller, tabs in
            let mark = try pin("Pinned")
            controller.listOpenBookmark(mark)
            controller.closeTab(nil)
            await expectRows(controller, ["~Pinned", "*Tab"])
            controller.reopenClosedTab(nil)
            let back = try #require(controller.tabManager.bookmarkTab(for: mark.id))
            await expectShown(back, in: controller, "reopened")
            await expectRows(controller, ["*Pinned", "Tab"])
        }
    }

    /// tabs.md: "⇧⌘T → whatever closed last comes back, app-wide: a tab, a tab of a closed window, or a whole window."
    @Test func shiftCommandTBringsBackAClosedWindow() async throws {
        let windows = WindowManager.shared
        defer { windows.forgetClosedForTesting() }
        windows.forgetClosedForTesting()
        try await inWindow(["Front"]) { front, _ in
            let url = URL(string: "http://127.0.0.1:9/everyday/window")!
            let closing = windows.newWindow(url: url, showCommandBar: false, placement: .behind)
            let id = try #require(closing.tabManager.selectedTab?.id)
            closing.window?.close()
            await settle()
            #expect(!windows.controllers.contains { $0 === closing })
            #expect(windows.canReopenLastClosed(from: front.tabManager))
            front.reopenClosedTab(nil)
            let back = try #require(windows.controllers.first { $0.tabManager.allTabs.contains { $0.id == id } })
            defer { back.window?.close() }
            #expect(back.window?.isVisible == true)
            let tab = try #require(back.tabManager.selectedTab)
            #expect(tab.id == id)
            await expectShown(tab, in: back, "in the window that came back")
            #expect(front.tabManager.allTabs.count == 1)
        }
    }

    // MARK: Spaces (specs/spaces.md, Making and switching)

    /// A window with "A1" and "A2" in the first space and "B1" and "B2" in another, the second of each last used.
    private func inTwoSpaces(_ body: (BrowserWindowController, [Tab], [Tab], UUID) async throws -> Void) async throws {
        try await inWindow(["A1", "A2"]) { controller, first in
            let manager = controller.tabManager
            let other = Library.shared.addSpace(name: "Other").id
            let second = ["B1", "B2"].map { title in Tab(url: nil, title: title, spaceID: other) }
            manager.adopt(second, in: other)
            manager.switchToSpace(other)
            controller.listSelect(second[1])
            manager.switchToSpace(space)
            controller.listSelect(first[1])
            await settle()
            try await body(controller, first, second, other)
        }
    }

    private func spaceItem(_ number: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.selectSpaceByNumber(_:)), keyEquivalent: "")
        item.tag = number
        return item
    }

    /// spaces.md: "⌃1–⌃9 → that space" and "⌥⌘→ / ⌥⌘← → next or previous space". Each switch shows that space's rows
    /// and the tab you were on there.
    @Test func switchingSpacesByKeysShowsThatSpacesTabsAndSelection() async throws {
        try await inTwoSpaces { controller, first, second, other in
            let spaces = controller.tabManager.listedSpaces.map(\.id)
            let number = try #require(spaces.firstIndex(of: other)) + 1
            let home = try #require(spaces.firstIndex(of: space)) + 1
            controller.selectSpaceByNumber(spaceItem(number))
            #expect(controller.tabManager.currentSpaceID == other)
            await expectRows(controller, ["B1", "*B2"])
            await expectShown(second[1], in: controller, "⌃\(number)")
            controller.selectSpaceByNumber(spaceItem(home))
            await expectRows(controller, ["A1", "*A2"])
            await expectShown(first[1], in: controller, "⌃\(home)")
            if number == home + 1 {
                controller.nextSpace(nil)
                await expectRows(controller, ["B1", "*B2"])
                await expectShown(second[1], in: controller, "⌥⌘→")
                controller.previousSpace(nil)
                await expectShown(first[1], in: controller, "⌥⌘←")
            }
        }
    }

    /// spaces.md: "Swipe sideways on the sidebar → the next space slides in with your fingers … calling it off goes
    /// back"; let go past half and the sidebar shows that space's rows and selection.
    @Test func swipingTheSidebarShowsTheNextSpace() async throws {
        try await inTwoSpaces { controller, first, second, other in
            let spaces = controller.tabManager.listedSpaces.map(\.id)
            let here = try #require(spaces.firstIndex(of: space))
            try #require(spaces.indices.contains(here + 1) && spaces[here + 1] == other)
            let sidebar = controller.sidebar
            let width = sidebar.bounds.width
            let start = ProcessInfo.processInfo.systemUptime
            // A finger to the left past half: the next space.
            sidebar.touchSwipeBegan()
            for step in 1...6 { sidebar.touchSwipeMoved(by: -width * 0.12, at: start + Double(step) * 0.05) }
            sidebar.touchSwipeEnded(velocity: 0, cancelled: false)
            #expect(controller.tabManager.currentSpaceID == other)
            await expectRows(controller, ["B1", "*B2"])
            await expectShown(second[1], in: controller, "after the swipe")
            // And back to the right.
            sidebar.touchSwipeBegan()
            for step in 1...6 { sidebar.touchSwipeMoved(by: width * 0.12, at: start + 1 + Double(step) * 0.05) }
            sidebar.touchSwipeEnded(velocity: 0, cancelled: false)
            #expect(controller.tabManager.currentSpaceID == space)
            await expectRows(controller, ["A1", "*A2"])
            await expectShown(first[1], in: controller, "swiped back")
            // Called off: it stays.
            sidebar.touchSwipeBegan()
            sidebar.touchSwipeMoved(by: -width * 0.3, at: start + 2)
            sidebar.touchSwipeEnded(velocity: 0, cancelled: true)
            #expect(controller.tabManager.currentSpaceID == space)
            await expectRows(controller, ["A1", "*A2"])
        }
    }

    // MARK: Split view (specs/splits.md)

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = menuItem(title, in: sub) { return found }
        }
        return nil
    }

    /// splits.md: Open in Split View opens on the right; × on one part closes that page and the one left takes the
    /// row's place; ⌘W in a split closes the page you're in; Separate Tabs gives each page its row, the selection
    /// staying.
    @Test func splitViewOpensClosesOnePageAndSeparates() async throws {
        try await inWindow(["A", "B", "C"]) { controller, tabs in
            let manager = controller.tabManager
            controller.listSelect(tabs[0])
            let open = try #require(menuItem("Open in Split View", in: SidebarMenus.tabMenu(for: tabs[2], controller: controller)))
            NSApp.sendAction(try #require(open.action), to: open.target, from: open)
            await expectRows(controller, ["*A|C", "B"])
            await expectPanes(controller, ["A", "C"])
            // The × on C's part: C goes, A is a plain tab in the row's place.
            controller.listClose(tabs[2])
            await expectRows(controller, ["*A", "B"])
            await expectPanes(controller, ["A"])
            await expectShown(tabs[0], in: controller, "one page closed")
            // ⌘W on the page you're in of a split: only it closes; the other stays shown where the row was.
            manager.makeSplit(tabs[0], with: tabs[1])
            controller.listSelect(tabs[1])
            await expectRows(controller, ["*A|B"])
            controller.closeTab(nil)
            await expectRows(controller, ["*A"])
            await expectShown(tabs[0], in: controller, "⌘W in a split")
            // Separate Tabs: each page its own row, the one you're in still shown.
            let other = manager.newTab(url: nil, spaceID: space, select: false, title: "D")
            manager.makeSplit(tabs[0], with: other)
            controller.listSelect(tabs[0])
            await expectRows(controller, ["*A|D"])
            controller.closeSplitView(nil)
            #expect(manager.split(for: tabs[0]) == nil)
            await expectRows(controller, ["*A", "D"])
            await expectShown(tabs[0], in: controller, "separated")
            await expectPanes(controller, ["A"])
        }
    }

    // MARK: Folders and dragging (specs/pinning.md, Folders; specs/tabs.md, Touch)

    /// The row of `tab`, laid out.
    private func shownRow(_ tab: Tab, in controller: BrowserWindowController) throws -> TabRowView {
        let list = controller.sidebar.list
        list.layoutSubtreeIfNeeded()
        return try #require(list.row(for: tab) as? TabRowView)
    }

    /// Picks up `tab`'s row and lets go at `target` (window points) as a finger does, through the list's own drag.
    private func drag(_ tab: Tab, to target: NSPoint, in controller: BrowserWindowController) async throws {
        let row = try shownRow(tab, in: controller)
        let window = try #require(controller.window)
        let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let finger = TouchCarry()
        TouchCarry.starting = finger
        #expect(row.onDragStart?(down) == true)
        for step in 1...4 {
            finger.move(to: NSPoint(x: start.x, y: start.y + (target.y - start.y) * CGFloat(step) / 4))
        }
        finger.move(to: target)
        finger.release(at: target)
        await settle()
    }

    /// A window point a little inside the top edge of `view`.
    private func topOf(_ view: NSView) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.maxY - 3)
    }

    /// tabs.md: "A finger and the mouse drag a row the same way: reorder". The rows show the new order after the drop.
    @Test func draggingARowReordersWhatTheSidebarShows() async throws {
        try await inWindow(["A", "B", "C", "D"]) { controller, tabs in
            // Behind the other windows: a drag finds the list under the pointer among the windows on screen.
            controller.window?.orderBack(nil)
            controller.window?.layoutIfNeeded()
            await expectRows(controller, ["*A", "B", "C", "D"])
            try await drag(tabs[3], to: topOf(try shownRow(tabs[1], in: controller)), in: controller)
            await expectRows(controller, ["*A", "D", "B", "C"])
            #expect(controller.tabManager.tabs(in: space).map(\.displayTitle) == ["A", "D", "B", "C"])
            await expectShown(tabs[0], in: controller, "after the drop")
        }
    }

    /// pinning.md: "New Folder … → a folder named New Folder, ready to rename"; shut, its pages go from the list and
    /// opened they're back; tabs.md: a row dragged "into a folder" is pinned there.
    @Test func aFolderIsMadeOpenedShutAndTakesADraggedTab() async throws {
        try await inWindow(["Tab", "Filed"], addressed: [1]) { controller, tabs in
            controller.window?.orderBack(nil)
            controller.window?.layoutIfNeeded()
            let mark = try pin("Pinned")
            controller.newFolder(with: [mark.id])
            let folder = try #require(Library.shared.folderID(containing: mark.id).flatMap(Library.shared.folder))
            await expectRows(controller, ["▾New Folder", "~Pinned", "*Tab", "Filed"])
            #expect(controller.window?.firstResponder is NSTextView, "its name ready to type")
            controller.window?.makeFirstResponder(nil)
            controller.listSetFolderOpen(folder.id, false)
            await expectRows(controller, ["▸New Folder", "*Tab", "Filed"])
            controller.listSetFolderOpen(folder.id, true)
            await expectRows(controller, ["▾New Folder", "~Pinned", "*Tab", "Filed"])
            // A tab let go in the gap just under the open folder's row: pinned in it, at its top.
            let row = try #require(controller.sidebar.list.row(forFolder: folder.id))
            let frame = row.convert(row.bounds, to: nil)
            try await drag(tabs[1], to: NSPoint(x: frame.midX, y: frame.minY + 2), in: controller)
            let filed = Library.shared.folder(folder.id)?.bookmarkIDs.compactMap { Library.shared.bookmark($0)?.title } ?? []
            #expect(filed.sorted() == ["Filed", "Pinned"], "\(filed)")
            let rows = await screen(controller).rows
            #expect(rows.first == "▾New Folder" && rows.count == 4 && rows.last == "*Tab" && rows.contains { $0.hasSuffix("Filed") }, "\(rows)")
            #expect(controller.tabManager.tabs(in: space).map(\.displayTitle) == ["Tab"])
        }
    }

    // MARK: The floating sidebar (specs/spaces.md, Sidebar)

    /// spaces.md: "Pointer at the sidebar's edge of the window while it's hidden → it slides out once", a menu from it
    /// keeps it out with the pointer away, and once the menu is gone it slides back.
    @Test func theFloatingSidebarComesOutStaysForItsMenuAndGoesAfter() async throws {
        try await inWindow(["A", "B"]) { controller, tabs in
            let root = controller.root
            root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            root.setSidebarVisible(false, animated: false)
            root.layoutSubtreeIfNeeded()
            defer { root.debugEdgePointer(nil); MenuPanel.current?.close(animated: false) }
            #expect(!root.isSidebarFloatingVisible)
            root.debugEdgePointer(NSPoint(x: 2, y: 300))
            #expect(await until { root.isSidebarFloatingVisible }, "the edge brings it out")
            await expectRows(controller, ["*A", "B"])
            let row = try shownRow(tabs[0], in: controller)
            let menu = try #require(MenuPanel.show(menu: SidebarMenus.tabMenu(for: tabs[0], controller: controller), from: row,
                                                   placement: .at(row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil))))
            root.debugEdgePointer(NSPoint(x: 700, y: 300))
            let later = ProcessInfo.processInfo.systemUptime + 5
            root.followPointer(at: later)
            root.followPointer(at: later + 1)
            #expect(root.isSidebarFloatingVisible, "its menu keeps it out")
            menu.close(animated: false)
            // The menu lets go of the sidebar once its close has gone through.
            await settle()
            root.followPointer(at: later + 2)
            root.followPointer(at: later + 3)
            #expect(!root.isSidebarFloatingVisible, "gone once the menu is")
        }
    }

    // MARK: Pages (specs/tabs.md, Back and Forward and New tabs; specs/shortcuts.md, Page)

    /// Local pages in a folder of their own, removed afterwards.
    private func pages(_ bodies: [String: String], _ body: ([String: URL]) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("everyday-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var urls: [String: URL] = [:]
        for (name, html) in bodies {
            let url = folder.appendingPathComponent("\(name).html")
            try html.write(to: url, atomically: true, encoding: .utf8)
            urls[name] = url
        }
        try await body(urls)
    }

    /// A window with one tab at `url`, selected.
    private func pageWindow(_ url: URL, _ body: (BrowserWindowController, Tab) async throws -> Void) async throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: url, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 900, height: 600))
        defer { controller.window?.close() }
        await settle()
        try await body(controller, tab)
    }

    private func settled(_ tab: Tab, at url: URL) async -> Bool {
        await untilAsync { tab.webView?.url == url && tab.webView?.isLoading == false }
    }

    /// A two-finger trackpad scroll at `phase` (1 began, 2 changed, 4 ended), `dx` points sideways, at `time`.
    private func scroll(phase: Int64, dx: Int32 = 0, at time: TimeInterval) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.timestamp = CGEventTimestamp(time * 1_000_000_000)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// tabs.md: two fingers sideways on a page → the arrow shows with the first steps and fills; "the trackpad taps
    /// once as the arrow fills"; letting go goes back.
    @Test func swipingBackShowsTheArrowTapsOnceAndGoesBack() async throws {
        try #require(NSEvent.isSwipeTrackingFromScrollEventsEnabled && SwipeNavigator.isOn, "swiping between pages is off on this Mac")
        try await pages(["first": "<title>First</title><p>first", "second": "<title>Second</title><p>second"]) { urls in
            let first = try #require(urls["first"]), second = try #require(urls["second"])
            try await pageWindow(first) { controller, tab in
                #expect(await settled(tab, at: first))
                tab.load(second, by: .you)
                #expect(await settled(tab, at: second))
                #expect(tab.webView?.canGoBack == true)
                let page = try #require(tab.webView as? BrowserWebView)
                let swipe = page.swipeNavigator
                var taps = 0
                swipe.tap = { taps += 1 }
                // Nothing scrolls sideways where the fingers are, so the swipe needn't wait for the page to say so.
                let room: (left: Bool, right: Bool) = (false, false)
                let start = ProcessInfo.processInfo.systemUptime
                _ = swipe.handle(try scroll(phase: 1, dx: 2, at: start), room: room)
                var step = 0
                var arrowShown = false
                while !swipe.isArmed, step < 60 {
                    step += 1
                    _ = swipe.handle(try scroll(phase: 2, dx: 6, at: start + Double(step) * 0.05), room: room)
                    if controller.swipeArrowLayer.subviews.contains(where: { $0 is SwipeArrowView }) { arrowShown = true }
                }
                #expect(arrowShown, "the arrow shows")
                #expect(swipe.isArmed, "the arrow fills")
                // On a little further and resting: still one tap.
                for more in 1...3 { _ = swipe.handle(try scroll(phase: 2, dx: 2, at: start + Double(step + more) * 0.05), room: room) }
                #expect(taps == 1)
                _ = swipe.handle(try scroll(phase: 4, at: start + Double(step + 4) * 0.05), room: room)
                #expect(await settled(tab, at: first), "back on the first page")
                #expect(taps == 1)
                #expect(await screen(controller).page === tab)
                #expect(await until { !controller.swipeArrowLayer.subviews.contains { $0 is SwipeArrowView } }, "the arrow goes")
            }
        }
    }

    /// tabs.md: "⇧-click or Open Link in Zigzag Mini → a Zigzag Mini centered over the window's page" and "⌘O in a
    /// Mini opened from a page → the same live page becomes a tab right after the one it came from".
    @Test func aLinkInMiniComesBackToTheWindowAsATab() async throws {
        let inPage = InPageMiniSettings.isEnabled
        InPageMiniSettings.isEnabled = false
        defer { InPageMiniSettings.isEnabled = inPage }
        try await pages(["link": "<title>Link</title><p>link"]) { urls in
            let link = try #require(urls["link"])
            try await pageWindow(URL(string: "http://127.0.0.1:9/everyday/source")!) { controller, source in
                let others = MiniWindowController.all
                controller.tab(source, openURL: link, disposition: .mini)
                let mini = try #require(MiniWindowController.all.first { candidate in !others.contains { $0 === candidate } })
                defer { if mini.window?.isVisible == true { mini.window?.close() } }
                #expect(mini.window?.isVisible == true)
                #expect(mini.fromPage && mini.source === controller)
                #expect(await screen(controller).page === source, "the window's page stays behind it")
                #expect(controller.tabManager.tabs(in: space).count == 1)
                let page = mini.tab
                #expect(await until { page.url == link })
                mini.openInZigzag()
                #expect(await until { controller.tabManager.tabs(in: space).contains { $0 === page } })
                #expect(controller.tabManager.tabs(in: space).map(\.id) == [source.id, page.id])
                await expectShown(page, in: controller, "back in the window")
                #expect(await until { mini.window?.isVisible != true }, "the Mini is gone")
            }
        }
    }

    /// shortcuts.md: "⌘F → the find bar; ⌘F again with its field focused hides it", the count beside the field
    /// following what's typed.
    @Test func findInPageCountsWhatIsTyped() async throws {
        try await pages(["find": "<title>Find</title><p>apple pear apple</p><p>plum apple</p>"]) { urls in
            let url = try #require(urls["find"])
            try await pageWindow(url) { controller, tab in
                #expect(await settled(tab, at: url))
                controller.showFindBar(nil)
                #expect(controller.findBar.isVisible)
                let editor = try #require(controller.window?.firstResponder as? NSTextView)
                editor.insertText("apple", replacementRange: NSRange(location: NSNotFound, length: 0))
                #expect(await until { controller.findBar.debugCount.contains("3") }, "\(controller.findBar.debugCount)")
                editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                #expect(await until { !controller.findBar.debugCount.isEmpty && !controller.findBar.debugCount.contains("3") },
                        "\(controller.findBar.debugCount)")
                controller.showFindBar(nil)
                #expect(!controller.findBar.isVisible)
                #expect(await screen(controller).page === tab)
            }
        }
    }

    /// shortcuts.md: "⌥⌘R → Reader on or off".
    @Test func readerComesOnOverThePageAndGoesOff() async throws {
        let paragraph = "<p>" + String(repeating: "Reading a long article about rivers and the towns along them, one sentence after another. ", count: 12) + "</p>"
        let html = "<title>Rivers</title><article><h1>Rivers</h1>" + String(repeating: paragraph, count: 8) + "</article>"
        try await pages(["article": html]) { urls in
            let url = try #require(urls["article"])
            try await pageWindow(url) { controller, tab in
                #expect(await settled(tab, at: url))
                controller.toggleReader(nil)
                #expect(await until(10) { controller.isReaderOnHere }, "Reader is on")
                let reader = try #require(controller.readerHere)
                #expect(reader.window === controller.window && !reader.isHidden)
                #expect(controller.sidebar.address.readerButton.isSelected)
                controller.toggleReader(nil)
                #expect(await until { !controller.isReaderOnHere }, "Reader is off")
                #expect(!controller.sidebar.address.readerButton.isSelected)
                #expect(await screen(controller).page === tab)
            }
        }
    }

    /// shortcuts.md: "⌘L → the command bar opens over the address"; an address typed there and Return loads in the
    /// tab you're on, with no new tab.
    @Test func typingAnAddressAndReturnLoadsItInTheTab() async throws {
        try await pages(["here": "<title>Here</title><p>here", "there": "<title>There</title><p>there"]) { urls in
            let here = try #require(urls["here"]), there = try #require(urls["there"])
            try await pageWindow(here) { controller, tab in
                #expect(await settled(tab, at: here))
                controller.openLocation(nil)
                #expect(controller.commandBar.isVisible && controller.commandBar.mode == .editCurrent)
                controller.commandBar.debugType(there.absoluteString)
                #expect(controller.commandBar.debugState["typed"] as? String == there.absoluteString)
                controller.commandBar.debugEnter()
                #expect(!controller.commandBar.isVisible)
                #expect(await settled(tab, at: there))
                #expect(controller.tabManager.tabs(in: space).map(\.id) == [tab.id])
                await expectShown(tab, in: controller, "the typed page")
            }
        }
    }

    /// shortcuts.md: "⌘, → Settings … opens as a tab in the front window"; settings.md: "Settings opened on one pane →
    /// only that pane's rows are made". Each pane opens shown, building only itself, well inside a stall.
    @Test func settingsOpensOnEachPane() async throws {
        try await inWindow(["Tab"]) { controller, tabs in
            for pane in SettingsPane.allCases where pane != .websiteData {
                let took = ContinuousClock().measure {
                    SettingsPage.open(pane, in: controller)
                    controller.root.layoutSubtreeIfNeeded()
                }
                let tab = try #require(controller.tabManager.selectedTab, "\(pane)")
                let view = try #require(tab.settingsView, "\(pane)")
                view.layoutSubtreeIfNeeded()
                #expect(view.pane == pane)
                #expect(view.debugBuiltPanes == [pane], "\(pane): \(view.debugBuiltPanes)")
                #expect(view.window === controller.window, "\(pane) on screen")
                #expect(await screen(controller).lit == [tab.displayTitle], "\(pane)")
                #expect(took < .seconds(2), "\(pane) took \(took)")
                controller.closeTab(nil)
                await expectShown(tabs[0], in: controller, "\(pane) closed")
            }
        }
    }
}

import AppKit
import Testing
@testable import Zigzag

/// Settings › Appearance's switches from #537, #538 and #539: each keeps today's look until turned, and is kept.
@MainActor
struct AppearanceSwitchesTests {
    /// Runs `body` with `key` cleared, as on a new install, and puts back what was there.
    private func fresh(_ key: String, _ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        try body()
    }

    // MARK: Show link address on hover (#537)

    @Test func theLinkAddressShowsUntilTurnedOff() {
        fresh(LinkStatusController.defaultsKey) {
            #expect(LinkStatusController.showsOnHover)
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            status.show(URL(string: "https://example.com/a"), in: overlay.bounds)
            #expect(status.isShowing)
            #expect(!overlay.subviews.isEmpty)
        }
    }

    @Test func offNoLinkAddressShowsAndTheChoiceIsKept() {
        fresh(LinkStatusController.defaultsKey) {
            LinkStatusController.showsOnHover = false
            #expect(UserDefaults.standard.object(forKey: LinkStatusController.defaultsKey) as? Bool == false)
            #expect(!LinkStatusController.showsOnHover)
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            status.show(URL(string: "https://example.com/a"), in: overlay.bounds)
            #expect(!status.isShowing)
            #expect(overlay.subviews.isEmpty)
            LinkStatusController.showsOnHover = true
            status.show(URL(string: "https://example.com/a"), in: overlay.bounds)
            #expect(status.isShowing)
        }
    }

    // MARK: Shorter floating sidebar (#538)

    @Test func theFloatingSidebarIsFullHeightUntilTurnedOn() {
        fresh(BrowserRootView.shortFloatingKey) {
            #expect(!BrowserRootView.shortFloatingSidebar)
            let bounds = NSRect(x: 0, y: 0, width: 1200, height: 900)
            let inset = Tokens.Metric.cardInset
            let out = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: true, onRight: false)
            #expect(out == NSRect(x: inset, y: inset, width: 260, height: 900 - inset * 2))
        }
    }

    @Test func onTheFloatingSidebarIsTwoThirdsHighInTheMiddle() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let inset = Tokens.Metric.cardInset
        for onRight in [false, true] {
            let out = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: true, onRight: onRight, short: true)
            #expect(out.height == 600)
            #expect(out.minY == 150 && bounds.maxY - out.maxY == 150)
            #expect(onRight ? out.maxX == 1200 - inset : out.minX == inset)
            // Away past the edge it keeps the same height, so it slides straight in and out.
            let away = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: false, onRight: onRight, short: true)
            #expect(away.minY == out.minY && away.height == out.height)
        }
        // Docked, it runs the window's height as always.
        let docked = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: true, revealed: false, onRight: false, short: true)
        #expect(docked == NSRect(x: 0, y: 0, width: 260, height: 900))
    }

    @Test func theShorterFloatingSidebarIsKept() {
        fresh(BrowserRootView.shortFloatingKey) {
            BrowserRootView.shortFloatingSidebar = true
            #expect(UserDefaults.standard.bool(forKey: BrowserRootView.shortFloatingKey))
            #expect(BrowserRootView.shortFloatingSidebar)
            let bounds = NSRect(x: 0, y: 0, width: 1200, height: 600)
            #expect(BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: true, onRight: false).height == 400)
        }
    }

    /// The shorter card comes out below the bar, and the lights stay in the bar (#542).
    @Test func theLightsStayInTheBarBesideTheShorterCard() throws {
        try fresh(BrowserRootView.shortFloatingKey) {
            BrowserRootView.shortFloatingSidebar = true
            let before = Library.shared.snapshot
            defer { Library.shared.restore(before) }
            let space = Library.shared.spaces[0].id
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
            defer { controller.window?.close() }
            let root = controller.root
            root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            root.showsTopBar = true
            root.barHoldsAddress = true
            root.setSidebarVisible(false, animated: false)
            root.layoutSubtreeIfNeeded()
            controller.layoutTrafficLights()
            let close = try #require(controller.browserWindow.standardWindowButton(.closeButton))
            #expect(!close.isHidden)
            root.holdReveal = true
            defer { root.holdReveal = false }
            root.reveal(true)
            #expect(root.isSidebarFloatingVisible)
            controller.layoutTrafficLights()
            #expect(!close.isHidden, "the lights stay in the bar")
            #expect(root.topBar.trafficLightsWidth == controller.browserWindow.trafficLightsWidth)
            #expect(controller.sidebar.trafficLightsWidth == 0, "the card's own row keeps no room for them")
        }
    }

    // MARK: Pinned tabs as tiles (#539)

    /// A window over the first space with pinned pages A and B in no folder and C in a folder.
    private func pinned(_ body: (BrowserWindowController, [Bookmark], UUID) throws -> Void) throws {
        try fresh(SidebarView.pinnedTilesKey) {
            let before = Library.shared.snapshot
            defer { Library.shared.restore(before) }
            let space = Library.shared.spaces[0].id
            let marks = try ["A", "B", "C"].map { title in
                try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/tiles/\(title)")!, title: title, to: space))
            }
            _ = try #require(Library.shared.addFolder(named: "Folder", with: [marks[2].id], in: space))
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            try body(controller, marks, space)
        }
    }

    private func rows(_ controller: BrowserWindowController) -> [SidebarItem] {
        controller.sidebar.list.reload(animated: false)
        return controller.sidebar.list.pageRows
    }

    @Test func pinnedTabsAreRowsUntilTurnedOn() throws {
        try pinned { controller, marks, _ in
            #expect(!SidebarView.pinnedTabsAsTiles)
            #expect(rows(controller) == marks.map { .bookmark($0.id) })
            #expect(controller.sidebar.pinnedTiles.tileIDs.isEmpty)
            #expect(controller.sidebar.pinnedTiles.isHidden)
        }
    }

    @Test func onPagesOutsideFoldersAreTilesUnderTheFavorites() throws {
        try pinned { controller, marks, _ in
            SidebarView.pinnedTabsAsTiles = true
            #expect(UserDefaults.standard.bool(forKey: SidebarView.pinnedTilesKey))
            // The folder's page stays a row; the others are tiles, in their order.
            #expect(rows(controller) == [.bookmark(marks[2].id)])
            #expect(controller.sidebar.pinnedTiles.tileIDs == [marks[0].id, marks[1].id])
            controller.sidebar.layoutSubtreeIfNeeded()
            #expect(!controller.sidebar.pinnedTiles.isHidden)
            // ⌘1 and the row keys count them after the favorites, before the rows.
            #expect(Array(controller.tabRowStops.prefix(3)) == [.bookmark(marks[0].id), .bookmark(marks[1].id), .bookmark(marks[2].id)])
            SidebarView.pinnedTabsAsTiles = false
            #expect(rows(controller) == marks.map { .bookmark($0.id) })
            #expect(controller.sidebar.pinnedTiles.tileIDs.isEmpty)
        }
    }

    @Test func aTileOpensUnloadsAndHasThePinnedTabsMenu() throws {
        try pinned { controller, marks, _ in
            SidebarView.pinnedTabsAsTiles = true
            let grid = controller.sidebar.pinnedTiles
            grid.onOpen?(marks[0])
            let page = try #require(controller.tabManager.bookmarkTab(for: marks[0].id))
            #expect(controller.tabManager.selectedTab === page)
            let menu = try #require(grid.onMenu?(marks[0]))
            let pinnedMenu = SidebarMenus.bookmarkMenu(for: marks[0], controller: controller)
            #expect(menu.items.map(\.title) == pinnedMenu.items.map(\.title))
            grid.onClose?(marks[0])
            #expect(controller.tabManager.bookmarkTab(for: marks[0].id) == nil)
            #expect(Library.shared.bookmark(marks[0].id) != nil)
        }
    }

    @Test func draggingATileReordersThePinnedPages() throws {
        try pinned { controller, marks, space in
            SidebarView.pinnedTabsAsTiles = true
            controller.sidebar.pinnedTiles.onReorder?(marks[1], 0)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == [marks[1].id, marks[0].id, marks[2].id])
            #expect(Library.shared.folderID(containing: marks[1].id) == nil)
            #expect(controller.sidebar.pinnedTiles.tileIDs == [marks[1].id, marks[0].id])
            controller.sidebarUndo.undo()
            #expect(Library.shared.bookmarks(in: space).map(\.id) == marks.map(\.id))
        }
    }

    /// Aims the pinned tiles' drop bar just inside the first tile's leading edge.
    private func aimAtFirstTile(_ controller: BrowserWindowController) throws {
        let grid = controller.sidebar.pinnedTiles
        controller.sidebar.layoutSubtreeIfNeeded()
        let first = try #require(grid.tile(for: grid.tileIDs[0]))
        grid.isDropTarget = true
        grid.hoverDrop(at: first.convert(NSPoint(x: 1, y: first.bounds.midY), to: nil), carrying: nil)
        #expect(grid.dropIndex == 0)
    }

    @Test func aFoldersPageDroppedOnTheTilesIsPinnedThereOutOfItsFolder() throws {
        try pinned { controller, marks, space in
            SidebarView.pinnedTabsAsTiles = true
            try aimAtFirstTile(controller)
            #expect(controller.listDropOnFavorites([.bookmark(marks[2].id)], dragged: .bookmark(marks[2].id)))
            #expect(Library.shared.bookmarks(in: space).map(\.id) == [marks[2].id, marks[0].id, marks[1].id])
            #expect(Library.shared.folderID(containing: marks[2].id) == nil)
            #expect(controller.sidebar.pinnedTiles.tileIDs == [marks[2].id, marks[0].id, marks[1].id])
            #expect(!controller.sidebar.pinnedTiles.isDropTarget)
        }
    }

    @Test func aFavoriteDroppedOnTheTilesIsPinnedThereAndLeavesFavorites() throws {
        try pinned { controller, marks, space in
            SidebarView.pinnedTabsAsTiles = true
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/tiles/F")!, title: "F",
                                                      in: Library.shared.profileID(ofSpace: space))
            try aimAtFirstTile(controller)
            let dropped = controller.sidebar.favorites.onDrop?(favorite, NSPoint(x: -20000, y: -20000))
            #expect(dropped?.handled == true)
            #expect(!Library.shared.isFavorite(favorite.id))
            #expect(Library.shared.bookmarks(in: space).map(\.id).first == favorite.id)
            #expect(controller.sidebar.pinnedTiles.tileIDs.first == favorite.id)
        }
    }

    @Test func aPinnedSplitIsOneTileAndAFoldedSectionKeepsOnlyOpenOnes() throws {
        try pinned { controller, marks, space in
            SidebarView.pinnedTabsAsTiles = true
            Library.shared.joinPinned(marks[1].id, beside: marks[0].id, onRight: true)
            controller.reloadPinnedTiles()
            #expect(controller.sidebar.pinnedTiles.tileIDs == [marks[0].id])
            #expect(controller.sidebar.tile(for: marks[1].id) === controller.sidebar.tile(for: marks[0].id))
            let saved = SidebarListView.debugCollapsed
            defer { SidebarListView.debugCollapsed = saved }
            SidebarListView.debugCollapsed = [space.uuidString]
            controller.reloadPinnedTiles()
            #expect(controller.sidebar.pinnedTiles.tileIDs.isEmpty)
        }
    }

    @Test func aTilesSlotIsAPlaceAmongThePinnedPages() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        // C is in a folder, between the tiles; D and E are a split.
        let order = [a, c, b, d, e]
        let tiles = [[a], [b], [d, e]]
        #expect(Library.pinnedIndex(forTile: 0, tiles: tiles, order: order) == 0)
        #expect(Library.pinnedIndex(forTile: 1, tiles: tiles, order: order) == 2)
        #expect(Library.pinnedIndex(forTile: 2, tiles: tiles, order: order) == 3)
        #expect(Library.pinnedIndex(forTile: 3, tiles: tiles, order: order) == 5)
        #expect(Library.pinnedIndex(forTile: 0, tiles: [], order: order) == 0)
    }

    @Test func theGridsShareTheirColumnsOnlyWhileBothHaveTiles() {
        #expect(SidebarView.sharedColumns(width: 220, favorites: 0, pinned: 5) == nil)
        #expect(SidebarView.sharedColumns(width: 220, favorites: 5, pinned: 0) == nil)
        let shared = SidebarView.sharedColumns(width: 220, favorites: 2, pinned: 6)
        #expect(shared.map { $0 >= 2 && $0 <= 6 } == true)
    }
}

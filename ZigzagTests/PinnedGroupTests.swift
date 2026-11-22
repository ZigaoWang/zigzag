import AppKit
import Foundation
import Testing
@testable import Zigzag

/// A tile group of three or four pages pins, becomes a favorite and comes back exactly as a split of two does (#203):
/// one pinned split holding every page and its layout, kept together in the list and in folders, opening and unpinning
/// as it was laid out. Checked away from the saved library.
@MainActor struct PinnedGroupTests {
    nonisolated private static let shapes: [TileShape] = [
        TileShape(regions: [.left, .right], column: 0.4),
        TileShape(regions: [.top, .bottom], row: 0.6),
        TileShape(regions: [.left, .topRight, .bottomRight], column: 0.35, row: 0.55),
        TileShape(regions: [.top, .bottomLeft, .bottomRight], column: 0.6, row: 0.45),
        TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], column: 0.3, row: 0.7),
    ]

    private func pins(_ n: Int) -> [Bookmark] {
        (0..<n).map { Bookmark(url: URL(string: "https://example.com/\($0)")!, title: "\($0)") }
    }

    /// The group on screen, its tabs in its order.
    private func group(_ shape: TileShape) -> TabManager.SplitPair {
        TabManager.SplitPair(ids: shape.regions.map { _ in UUID() }, shape: shape)!
    }

    // MARK: Pin and unpin

    /// Pinning keeps every page and its place; unpinning lays the pages out again exactly so, for 2, 3 and 4 pages.
    @Test(arguments: shapes) func pinningAndUnpinningKeepTheLayout(shape: TileShape) throws {
        let pair = group(shape)
        let marks = pair.ids.map { _ in UUID() }
        let pinned = try #require(PinnedSplit(marks, as: pair))
        #expect(pinned.ids == marks)
        #expect(pinned.isGroup == (pair.count > 2))
        // Unpinned (or opened) as new tabs: the same places and lines.
        let tabs = marks.map { _ in UUID() }
        let back = try #require(pinned.pair(of: tabs))
        #expect(back.ids == tabs)
        #expect(back.shape == pair.shape)
        // And pinned again: the same pinned split, layout and all.
        let again = try #require(PinnedSplit(marks, as: back))
        #expect(again == pinned)
        #expect(again.regions == pinned.regions && again.ratio == pinned.ratio && again.otherRatio == pinned.otherRatio && again.vertical == pinned.vertical)
    }

    @Test(arguments: shapes) func aPinnedGroupIsSavedAndReadBack(shape: TileShape) throws {
        let pinned = try #require(PinnedSplit(pins(shape.regions.count).map(\.id), as: group(shape)))
        let read = try JSONDecoder().decode(PinnedSplit.self, from: JSONEncoder().encode(pinned))
        #expect(read == pinned)
        #expect(read.regions == pinned.regions)
        #expect(read.pair(of: pinned.ids)?.shape == shape)
    }

    /// Two pages are written as they always were, so an older Zigzag still opens them.
    @Test func aPairIsWrittenAsBefore() throws {
        let pinned = try #require(PinnedSplit(pins(2).map(\.id), as: group(Self.shapes[0])))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pinned)) as! [String: Any]
        #expect(Set(json.keys) == ["left", "right", "ratio", "vertical"])
    }

    /// A group whose places don't add up opens as the split of its first two, never a broken group.
    @Test func aBrokenGroupReadsAsAPair() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PinnedSplit(pins(3).map(\.id), as: group(Self.shapes[2]))!)) as! [String: Any]
        json["regions"] = ["left", "right", "topRight"]
        let read = try JSONDecoder().decode(PinnedSplit.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.ids.count == 2 && read.regions == nil)
    }

    /// The same pages in the same order are the same pinned split, whatever the layout: moving a line isn't a
    /// change ⌘Z has to step over. Another order is.
    @Test func sameGroupInAnotherLayoutIsTheSameForUndo() throws {
        let marks = pins(4).map(\.id)
        let a = try #require(PinnedSplit(marks, as: group(Self.shapes[4])))
        var moved = Self.shapes[4]
        moved.column = 0.5
        #expect(PinnedSplit(marks, as: group(moved)) == a)
        #expect(PinnedSplit(marks.reversed(), as: group(Self.shapes[4])) != a)
    }

    // MARK: In the list

    /// Every page of a pinned group sits right after the one before it, the first leading, in its folder.
    @Test func aGroupsPagesStayTogetherInTheListAndItsFolder() throws {
        let b = pins(6)
        let folder = BookmarkFolder(name: "F", bookmarkIDs: [b[1].id])
        let pinned = try #require(PinnedSplit([b[1].id, b[4].id, b[2].id, b[5].id], as: group(Self.shapes[4])))
        let (bookmarks, folders, splits) = Library.tidied(b, [folder], [pinned])
        #expect(bookmarks.map(\.id) == [b[0], b[1], b[4], b[2], b[5], b[3]].map(\.id))
        #expect(folders[0].bookmarkIDs == [b[1], b[4], b[2], b[5]].map(\.id))
        #expect(splits == [pinned])
    }

    @Test func aGroupEndsWhenAPageGoesOrIsInAnother() throws {
        let b = pins(5)
        let gone = try #require(PinnedSplit([b[0].id, b[1].id, UUID()], as: group(Self.shapes[2])))
        #expect(Library.tidied(b, [], [gone]).splits.isEmpty)
        let first = try #require(PinnedSplit([b[0].id, b[1].id, b[2].id], as: group(Self.shapes[2])))
        let overlapping = PinnedSplit(left: b[2].id, right: b[3].id)
        #expect(Library.tidied(b, [], [first, overlapping]).splits == [first])
    }

    /// A folder dropped between a group's pages goes to the nearer end of the group.
    @Test func aFolderNeverLandsInsideAGroup() throws {
        let b = pins(6).map(\.id)
        let pinned = try #require(PinnedSplit(Array(b[1...4]), as: group(Self.shapes[4])))
        #expect(Library.folderDropIndex(2, in: b, folders: [], splits: [pinned]) == 1)
        #expect(Library.folderDropIndex(4, in: b, folders: [], splits: [pinned]) == 5)
    }

    // MARK: Favorites

    /// A favorite group is one tile: dropping before the tile after it lands after all its pages.
    @Test func aFavoriteGroupCountsAsOneTile() throws {
        let ids = (0..<6).map { _ in UUID() }
        let pinned = try #require(PinnedSplit(Array(ids[1...4]), as: group(Self.shapes[4])))
        // Tiles: [0], [1|2|3|4], [5]. Slot 2 is the tile of 5.
        let order = Library.placing([UUID()], atSlot: 2, in: ids, splits: [pinned])
        #expect(Array(order.prefix(5)) == Array(ids[0...4]))
        #expect(order.last == ids[5])
        // Moving the group keeps it together.
        #expect(Library.placing(Array(ids[1...4]), atSlot: 0, in: ids, splits: [pinned]) == [ids[1], ids[2], ids[3], ids[4], ids[0], ids[5]])
    }

    @Test func aFavoriteGroupKeepsItsPagesTogetherAndInOneProfile() throws {
        let marks = pins(5)
        let pinned = try #require(PinnedSplit([marks[3].id, marks[0].id, marks[4].id], as: group(Self.shapes[2])))
        let (favorites, splits) = Library.tidied(marks, splits: [pinned], directory: ProfileDirectory())
        #expect(splits == [pinned])
        #expect(favorites.map(\.id) == [marks[1], marks[2], marks[3], marks[0], marks[4]].map(\.id))
        // A page on another profile undoes it.
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        directory.assign(favorite: marks[4].id, to: work.id)
        #expect(Library.tidied(marks, splits: [pinned], directory: directory).1.isEmpty)
    }

    // MARK: Groups of tabs pinned (#325)

    /// A window with tabs `titles` in the first space; the library is restored after.
    private func withTabs(_ titles: [String], _ body: (TabManager, [Tab], UUID) throws -> Void) rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tabs = titles.enumerated().map { i, title in Tab(url: URL(string: "https://example.com/group/\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs, space)
    }

    /// Pinning a tab in a group pins the whole group as one folder; unpinning restores the group.
    @Test func pinningAGroupOfTabsKeepsItWholeAsOneFolder() throws {
        try withTabs(["0", "1", "2", "3"]) { manager, tabs, space in
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Reading"))
            manager.bookmarkTab(tabs[0], in: space)
            let page = try #require(tabs[0].bookmarkID)
            let folder = try #require(Library.shared.pinnedGroup(containing: page))
            #expect(folder.name == "Reading")
            #expect(folder.groupID == groupID)
            #expect(folder.bookmarkIDs == tabs.compactMap(\.bookmarkID))
            // One entry: every page in the folder, none as its own pinned split.
            #expect(Library.shared.pinnedSplit(containing: page) == nil)
            #expect(Library.shared.bookmarks(in: space).filter { folder.bookmarkIDs.contains($0.id) }.map(\.id) == folder.bookmarkIDs)
            #expect(manager.tabs(in: space).isEmpty)
            // Unpinning a page restores the whole group.
            manager.unbookmark(folder.bookmarkIDs[2], toIndex: 0)
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(manager.groups(in: space).map(\.id) == [groupID])
            #expect(manager.tabs(inGroup: groupID).map(\.id) == tabs.map(\.id))
            #expect(manager.tabs(in: space).map(\.id) == tabs.map(\.id))
        }
    }

    /// A one-tab group pins as a one-page folder and comes back as a group.
    @Test func aGroupOfOneTabPinsAsAGroupToo() throws {
        try withTabs(["0"]) { manager, tabs, space in
            let groupID = try #require(manager.makeGroup(with: [tabs[0]], name: "Solo"))
            manager.bookmarkTab(tabs[0], in: space)
            let page = try #require(tabs[0].bookmarkID)
            let folder = try #require(Library.shared.pinnedGroup(containing: page))
            #expect(folder.bookmarkIDs == [page])
            manager.unbookmark(page, toIndex: 0)
            #expect(manager.group(groupID)?.name == "Solo")
            #expect(manager.tabs(inGroup: groupID).map(\.id) == [tabs[0].id])
        }
    }

    /// A split in a group pins as a pinned split in the folder and comes back side by side.
    @Test func aSplitInAGroupStaysASplit() throws {
        try withTabs(["0", "1", "2"]) { manager, tabs, space in
            manager.makeSplit(tabs[1], with: tabs[2])
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Mixed"))
            #expect(manager.tabs(inGroup: groupID).count == 3)
            manager.bookmarkTab(tabs[0], in: space)
            let folder = try #require(tabs[0].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
            #expect(folder.bookmarkIDs.count == 3)
            let pinned = try #require(tabs[1].bookmarkID.flatMap(Library.shared.pinnedSplit(containing:)))
            #expect(Set(pinned.ids) == Set([tabs[1], tabs[2]].compactMap(\.bookmarkID)))
            // Unpinning one split page restores the group with the split.
            manager.unbookmark(pinned.ids[0], toIndex: 0)
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(Set(manager.tabs(inGroup: groupID).map(\.id)) == Set(tabs.map(\.id)))
            #expect(manager.split(for: tabs[1])?.contains(tabs[2].id) == true)
        }
    }

    /// A collapsed group pins as a closed folder and comes back collapsed.
    @Test func aFoldedGroupPinsShut() throws {
        try withTabs(["0", "1"]) { manager, tabs, space in
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Folded"))
            manager.setGroupOpen(groupID, false)
            manager.bookmarkTab(tabs[0], in: space)
            let folder = try #require(tabs[0].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
            #expect(!folder.isOpen)
            #expect(Set(folder.tucked ?? []) == Set(folder.bookmarkIDs))
            manager.unbookmark(folder.bookmarkIDs[0], toIndex: 0)
            #expect(manager.group(groupID)?.isOpen == false)
        }
    }

    /// Dragging one tab of a group to pinned pins only that tab.
    @Test func aTabPinnedOutOfItsGroupLeavesTheRest() throws {
        try withTabs(["0", "1"]) { manager, tabs, space in
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Two"))
            manager.bookmarkTab(tabs[0], in: space, keepingGroup: false)
            let page = try #require(tabs[0].bookmarkID)
            #expect(Library.shared.pinnedGroup(containing: page) == nil)
            #expect(manager.tabs(inGroup: groupID).map(\.id) == [tabs[1].id])
        }
    }

    /// An ungrouped tab pins on its own, outside any folder.
    @Test func aTabOutsideAGroupStillPinsOnItsOwn() throws {
        try withTabs(["0"]) { manager, tabs, space in
            manager.bookmarkTab(tabs[0], in: space)
            let page = try #require(tabs[0].bookmarkID)
            #expect(Library.shared.pinnedGroup(containing: page) == nil)
            #expect(Library.shared.bookmarks(in: space).map(\.id).contains(page))
        }
    }

    // MARK: Through the window (#325)

    /// A window over a fresh manager, with tabs `titles` in the first space, closed and the library restored after.
    private func inWindow(_ titles: [String], _ body: (BrowserWindowController, [Tab], UUID) throws -> Void) rethrows {
        try withTabs(titles) { manager, tabs, space in
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            try body(controller, tabs, space)
        }
    }

    /// ⌘D (File › Save Group) on a tab of a group saves the group as one folder, and ⌘Z brings the group back.
    @Test func commandDSavesTheWholeGroupAndUndoes() throws {
        try inWindow(["0", "1", "2"]) { controller, tabs, space in
            let manager = controller.tabManager
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Reading"))
            manager.select(tabs[1])
            let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.toggleBookmark(_:)), keyEquivalent: "d")
            #expect(controller.validateMenuItem(item))
            #expect(item.title == String(localized: "Pin Group", comment: "Menu bar item: pins the whole group of tabs the tab is in, as a folder."))
            controller.toggleBookmark(item)
            let folder = try #require(tabs[1].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
            #expect(folder.name == "Reading")
            #expect(folder.bookmarkIDs == tabs.compactMap(\.bookmarkID))
            #expect(manager.tabs(in: space).isEmpty)
            controller.sidebarUndo.undo()
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(Library.shared.bookmarks(in: space).isEmpty)
            #expect(manager.tabs(inGroup: groupID).map(\.id) == tabs.map(\.id))
        }
    }

    /// A group's row dropped among the pinned pages pins the whole group there as one folder, undoably.
    @Test func droppingAGroupRowAmongThePinsPinsItWhole() throws {
        try inWindow(["0", "1", "2"]) { controller, tabs, space in
            let manager = controller.tabManager
            let before = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pinned")!, title: "Pinned", to: space))
            let groupID = try #require(manager.makeGroup(with: [tabs[0], tabs[1]], name: "Two"))
            controller.listPinGroup(groupID, at: 0, in: space, folder: nil)
            let folder = try #require(tabs[0].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
            #expect(folder.name == "Two")
            #expect(folder.bookmarkIDs == [tabs[0], tabs[1]].compactMap(\.bookmarkID))
            #expect(Library.shared.bookmarks(in: space).map(\.id) == folder.bookmarkIDs + [before.id])
            // The tab outside the group stays a tab.
            #expect(manager.tabs(in: space).map(\.id) == [tabs[2].id])
            controller.sidebarUndo.undo()
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(manager.tabs(inGroup: groupID).map(\.id) == [tabs[0].id, tabs[1].id])
        }
    }

    /// Dropped in a folder's gap, the group's folder goes inside that folder.
    @Test func aGroupDroppedInAFolderNestsThere() throws {
        try inWindow(["0", "1"]) { controller, tabs, space in
            let page = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pinned")!, title: "Pinned", to: space))
            let outer = try #require(Library.shared.addFolder(named: "Outer", with: [page.id], in: space))
            let groupID = try #require(controller.tabManager.makeGroup(with: tabs, name: "Inner"))
            controller.listPinGroup(groupID, at: 1, in: space, folder: outer.id)
            let folder = try #require(tabs[0].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
            #expect(folder.parentID == outer.id)
            #expect(folder.bookmarkIDs == tabs.compactMap(\.bookmarkID))
        }
    }

    /// Dragging one tab of a group still pins only that tab, through the window too.
    @Test func droppingOneTabOfAGroupStillPinsOnlyIt() throws {
        try inWindow(["0", "1"]) { controller, tabs, space in
            let groupID = try #require(controller.tabManager.makeGroup(with: tabs, name: "Two"))
            controller.listBookmark(tabs[0], at: 0, in: space)
            let page = try #require(tabs[0].bookmarkID)
            #expect(Library.shared.pinnedGroup(containing: page) == nil)
            #expect(controller.tabManager.tabs(inGroup: groupID).map(\.id) == [tabs[1].id])
        }
    }

    // MARK: With the pinned section folded (#325)

    /// `inWindow` with the space's pinned section folded, kept off the saved defaults.
    private func inFoldedWindow(_ titles: [String], _ body: (BrowserWindowController, [Tab], UUID) throws -> Void) rethrows {
        try inWindow(titles) { controller, tabs, space in
            let before = SidebarListView.debugCollapsed
            SidebarListView.debugCollapsed = [space.uuidString]
            defer { SidebarListView.debugCollapsed = before }
            controller.sidebar.list.reload(animated: false)
            try body(controller, tabs, space)
        }
    }

    /// The pinned rows the folded list shows, top to bottom.
    private func pinnedItems(_ controller: BrowserWindowController) -> [SidebarItem] {
        controller.sidebar.list.reload(animated: false)
        return controller.sidebar.list.debugItems.filter { if case .bookmark = $0 { true } else if case .folder = $0 { true } else { false } }
    }

    /// The group pinned whole, shown in the still folded section as one folder row with its open pages under it.
    private func expectShownAsOneFolder(_ controller: BrowserWindowController, _ tabs: [Tab], _ space: UUID, named name: String) throws -> BookmarkFolder {
        let folder = try #require(tabs[0].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
        #expect(folder.name == name)
        #expect(folder.bookmarkIDs == tabs.compactMap(\.bookmarkID))
        #expect(SidebarListView.isCollapsed(space))
        let rows = pinnedItems(controller)
        let head = try #require(rows.firstIndex(of: .folder(folder.id)))
        #expect(Array(rows[(head + 1)...]) == folder.bookmarkIDs.map { .bookmark($0) })
        return folder
    }

    /// Folded, an open page shows under the folders on its way, nested ones too; closed pages and folders with no
    /// open page don't show.
    @Test func foldedPinsShowOpenPagesUnderTheirFolders() throws {
        try inFoldedWindow(["0", "1"]) { controller, tabs, space in
            let manager = controller.tabManager
            manager.bookmarkTab(tabs[0], in: space)
            manager.bookmarkTab(tabs[1], in: space)
            let open = try #require(tabs[0].bookmarkID), loose = try #require(tabs[1].bookmarkID)
            @MainActor func closed(_ title: String) throws -> UUID {
                try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/\(title)")!, title: title, to: space)).id
            }
            let shut = try closed("shut"), other = try closed("other"), top = try closed("top")
            let outer = try #require(Library.shared.addFolder(named: "Outer", with: [shut], in: space))
            let inner = try #require(Library.shared.addFolder(named: "Inner", with: [open], in: space, parent: .some(outer.id)))
            let empty = try #require(Library.shared.addFolder(named: "Closed only", with: [other], in: space))
            let rows = pinnedItems(controller)
            #expect(rows.contains(.folder(outer.id)) && rows.contains(.folder(inner.id)) && rows.contains(.bookmark(open)))
            #expect(rows.firstIndex(of: .folder(outer.id))! < rows.firstIndex(of: .folder(inner.id))!)
            #expect(rows.firstIndex(of: .folder(inner.id))! + 1 == rows.firstIndex(of: .bookmark(open))!)
            #expect(rows.contains(.bookmark(loose)))
            #expect(!rows.contains(.folder(empty.id)))
            #expect(!rows.contains(.bookmark(shut)) && !rows.contains(.bookmark(other)) && !rows.contains(.bookmark(top)))
            // Unfolded, everything shows again.
            SidebarListView.setCollapsed(space, false)
            let all = pinnedItems(controller)
            #expect(all.contains(.folder(empty.id)) && all.contains(.bookmark(top)))
        }
    }

    /// The folded rows set each page in by the folders on its way, as unfolded.
    @Test func foldedRowsAreSetInByTheirFolders() {
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [])
        var inner = BookmarkFolder(name: "Inner", bookmarkIDs: [UUID()])
        inner.parentID = outer.id
        inner.isOpen = false
        let page = inner.bookmarkIDs[0], closed = UUID()
        let shown = SidebarListView.pinnedRows(bookmarks: [page, closed], folders: [outer, inner], current: nil, folded: true) { $0 == page }
        #expect(shown.rows == [.folder(outer.id), .folder(inner.id), .bookmark(page)])
        #expect(shown.depth[.folder(outer.id)] == 0 && shown.depth[.folder(inner.id)] == 1 && shown.depth[.bookmark(page)] == 2)
    }

    /// ⌘D on a tab of a group, with the section folded: one folder row with its pages, still folded; ⌘Z undoes it.
    @Test func commandDWithPinsFoldedPinsOneFolder() throws {
        try inFoldedWindow(["0", "1", "2", "3"]) { controller, tabs, space in
            let manager = controller.tabManager
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Reading"))
            manager.select(tabs[2])
            let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.toggleBookmark(_:)), keyEquivalent: "d")
            #expect(controller.validateMenuItem(item))
            controller.toggleBookmark(item)
            let folder = try expectShownAsOneFolder(controller, tabs, space, named: "Reading")
            controller.sidebarUndo.undo()
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(manager.tabs(inGroup: groupID).map(\.id) == tabs.map(\.id))
        }
    }

    /// A group's row dropped on the folded section pins it as one folder there, undoably.
    @Test func droppingAGroupOnFoldedPinsPinsOneFolder() throws {
        try inFoldedWindow(["0", "1", "2", "3"]) { controller, tabs, space in
            let manager = controller.tabManager
            let page = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pinned")!, title: "Pinned", to: space))
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Four"))
            controller.listPinGroup(groupID, at: 0, in: space, folder: nil)
            let folder = try expectShownAsOneFolder(controller, tabs, space, named: "Four")
            #expect(Library.shared.bookmarks(in: space).map(\.id) == folder.bookmarkIDs + [page.id])
            controller.sidebarUndo.undo()
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(manager.tabs(inGroup: groupID).map(\.id) == tabs.map(\.id))
        }
    }

    /// The group's tabs picked and pinned together, with the section folded: one folder.
    @Test func pinningPickedGroupTabsWithPinsFoldedPinsOneFolder() throws {
        try inFoldedWindow(["0", "1", "2", "3"]) { controller, tabs, space in
            let groupID = try #require(controller.tabManager.makeGroup(with: tabs, name: "Picked"))
            controller.pinMarked(tabs)
            let folder = try expectShownAsOneFolder(controller, tabs, space, named: "Picked")
            controller.sidebarUndo.undo()
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(controller.tabManager.tabs(inGroup: groupID).map(\.id) == tabs.map(\.id))
        }
    }

    /// One tab of a group dropped on the folded section pins only it, and the section stays folded.
    @Test func droppingOneGroupTabOnFoldedPinsPinsOnlyIt() throws {
        try inFoldedWindow(["0", "1"]) { controller, tabs, space in
            let groupID = try #require(controller.tabManager.makeGroup(with: tabs, name: "Two"))
            controller.listBookmark(tabs[0], at: 0, in: space)
            let page = try #require(tabs[0].bookmarkID)
            #expect(Library.shared.pinnedGroup(containing: page) == nil)
            #expect(controller.tabManager.tabs(inGroup: groupID).map(\.id) == [tabs[1].id])
            #expect(SidebarListView.isCollapsed(space))
        }
    }

    /// Folders saved before group pinning decode with no group and keep their pages.
    @Test func anOlderFolderReadsWithNoGroupAndItsPages() throws {
        let page = UUID()
        let json = #"{"id":"\#(UUID())","name":"Old","bookmarkIDs":["\#(page)"],"isOpen":true}"#
        let folder = try JSONDecoder().decode(BookmarkFolder.self, from: Data(json.utf8))
        #expect(folder.groupID == nil)
        #expect(folder.name == "Old")
        #expect(folder.bookmarkIDs == [page])
    }

    // MARK: One split, in the tabs and among the pins

    /// Two, three and four tabs side by side pin as one pinned split holding every page and its shape, open again in
    /// that shape after their pages are unloaded, and unpin back to tabs in it.
    @Test(arguments: shapes) func aSplitPinsReopensAndUnpinsWhole(shape: TileShape) throws {
        try withTabs(shape.regions.indices.map(String.init)) { manager, tabs, space in
            manager.makeGroup(tabs, shape: shape)
            manager.bookmarkTab(tabs[0], in: space)
            let marks = tabs.compactMap(\.bookmarkID)
            #expect(marks.count == tabs.count)
            let pinned = try #require(Library.shared.pinnedSplit(containing: marks[0]))
            #expect(pinned.ids == marks)
            #expect(pinned.shape == shape)
            #expect(manager.tabs(in: space).isEmpty)
            // Unloaded, then opened from any page: all of it, side by side as it was.
            manager.close(tabs)
            #expect(marks.allSatisfy { manager.bookmarkTab(for: $0) == nil })
            manager.openBookmark(try #require(Library.shared.bookmark(marks[marks.count - 1])))
            let pages = marks.compactMap(manager.bookmarkTab(for:))
            #expect(pages.count == marks.count)
            let open = try #require(manager.split(for: pages[0]))
            #expect(open.ids == pages.map(\.id))
            #expect(open.shape == shape)
            // Unpinned: the same pages as tabs, the same shape.
            let back = try #require(manager.unbookmark(marks[1], toIndex: 0))
            #expect(Library.shared.pinnedSplit(containing: marks[0]) == nil)
            #expect(marks.allSatisfy { Library.shared.bookmark($0) == nil })
            let tabsBack = manager.tabs(in: space)
            #expect(tabsBack.count == marks.count && tabsBack.contains { $0 === back })
            let after = try #require(manager.split(for: back))
            #expect(after.ids == tabsBack.map(\.id))
            #expect(after.shape == shape)
        }
    }

    /// A pinned split saved by an older Zigzag, with only its two pages (and maybe their size and direction), reads as
    /// that split and is written back the same way; a group of more round-trips with its places.
    @Test func olderPinnedSplitsReadAndWriteAsBefore() throws {
        let a = UUID(), b = UUID()
        let oldest = try JSONDecoder().decode(PinnedSplit.self, from: Data(#"{"left":"\#(a)","right":"\#(b)"}"#.utf8))
        #expect(oldest.ids == [a, b] && oldest.ratio == 0.5 && !oldest.vertical && !oldest.isGroup)
        #expect(oldest.shape == TileShape(regions: [.left, .right]))
        let sized = try JSONDecoder().decode(PinnedSplit.self, from: Data(#"{"left":"\#(a)","right":"\#(b)","ratio":0.3,"vertical":true}"#.utf8))
        #expect(sized.ids == [a, b] && sized.ratio == 0.3 && sized.vertical)
        #expect(sized.shape.regions == [.top, .bottom] && sized.shape.row == 0.3)
        // Written back with the keys it always had, and read again the same.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sized)) as! [String: Any]
        #expect(Set(written.keys) == ["left", "right", "ratio", "vertical"])
        let again = try JSONDecoder().decode(PinnedSplit.self, from: JSONEncoder().encode(sized))
        #expect(again.ids == sized.ids && again.ratio == sized.ratio && again.vertical == sized.vertical)
        // Opened as tabs, it's the split it was.
        let tabs = [UUID(), UUID()]
        #expect(sized.pair(of: tabs)?.shape == sized.shape)
        // A four-page group as written now round-trips whole.
        let grid = try #require(PinnedSplit(pins(4).map(\.id), as: group(Self.shapes[4])))
        let read = try JSONDecoder().decode(PinnedSplit.self, from: JSONEncoder().encode(grid))
        #expect(read.ids == grid.ids && read.shape == grid.shape)
    }

    /// A space saved with an older pinned split reads with it, the split kept whole by the library's tidying.
    @Test func anOlderLibrarysPinnedSplitStaysWhole() throws {
        let marks = pins(3)
        let split = try JSONDecoder().decode(PinnedSplit.self, from: Data(#"{"left":"\#(marks[2].id)","right":"\#(marks[0].id)","ratio":0.6,"vertical":false}"#.utf8))
        let (bookmarks, _, splits) = Library.tidied(marks, [], [split])
        #expect(splits.count == 1 && splits[0].ids == [marks[2].id, marks[0].id] && splits[0].ratio == 0.6)
        #expect(bookmarks.map(\.id) == [marks[1].id, marks[2].id, marks[0].id])
    }

    /// A four-page split's row dragged among the pins pins it whole, in its shape; dragged back among the tabs it's
    /// the same four tabs side by side; ⌘Z steps back through both.
    @Test func aFourPageSplitDraggedToPinnedAndBack() throws {
        try inWindow(["0", "1", "2", "3"]) { controller, tabs, space in
            let manager = controller.tabManager
            let shape = Self.shapes[4]
            manager.makeGroup(tabs, shape: shape)
            // One group per step, as each drop is in the app.
            let undo = controller.sidebarUndo
            undo.groupsByEvent = false
            func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
            step { controller.listBookmark(tabs[2], at: 0, in: space) }
            let marks = tabs.compactMap(\.bookmarkID)
            #expect(marks.count == 4)
            let pinned = try #require(Library.shared.pinnedSplit(containing: marks[0]))
            #expect(pinned.ids == marks && pinned.shape == shape)
            #expect(manager.split(for: tabs[0])?.shape == shape)
            step { controller.listUnbookmark(marks[0], to: 0) }
            #expect(Library.shared.pinnedSplit(containing: marks[0]) == nil)
            #expect(manager.tabs(in: space).map(\.id) == tabs.map(\.id))
            #expect(manager.split(for: tabs[0])?.ids == tabs.map(\.id))
            #expect(manager.split(for: tabs[0])?.shape == shape)
            controller.sidebarUndo.undo()
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            controller.sidebarUndo.undo()
            #expect(Library.shared.bookmarks(in: space).isEmpty)
            #expect(manager.split(for: tabs[0])?.ids == tabs.map(\.id))
        }
    }

    /// One page out of a pinned split of three: it stays pinned on its own after the other two, which stay one
    /// pinned split, on screen too; ⌘Z puts all three back together.
    @Test func onePageLeavesAPinnedSplitOfThree() throws {
        try inWindow(["0", "1", "2"]) { controller, tabs, space in
            let manager = controller.tabManager
            manager.makeGroup(tabs, shape: Self.shapes[2])
            manager.bookmarkTab(tabs[0], in: space)
            let marks = tabs.compactMap(\.bookmarkID)
            manager.select(tabs[0])
            let menu = SidebarMenus.bookmarkMenu(for: try #require(Library.shared.bookmark(marks[1])), controller: controller)
            #expect(menu.items.contains { $0.title == SidebarMenus.removeFromSplitTitle })
            controller.leavePinnedGroupWithUndo(marks[1])
            let rest = try #require(Library.shared.pinnedSplit(containing: marks[0]))
            #expect(rest.ids == [marks[0], marks[2]])
            #expect(Library.shared.pinnedSplit(containing: marks[1]) == nil)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == [marks[0], marks[2], marks[1]])
            #expect(manager.split(for: tabs[0])?.ids == [tabs[0].id, tabs[2].id])
            #expect(manager.split(for: tabs[1]) == nil)
            controller.sidebarUndo.undo()
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            #expect(manager.split(for: tabs[0])?.ids == tabs.map(\.id))
        }
    }

    /// One page out of a pinned split of three or four in one window: another window showing it keeps the rest side by
    /// side, the page on its own, as the first window does.
    @Test(arguments: [2, 4]) func onePageLeavesAPinnedSplitShownInAnotherWindow(index: Int) throws {
        let shape = Self.shapes[index]
        try withTabs(shape.regions.indices.map(String.init)) { manager, tabs, space in
            manager.makeGroup(tabs, shape: shape)
            manager.bookmarkTab(tabs[0], in: space)
            let marks = tabs.compactMap(\.bookmarkID)
            let other = TabManager(spaceID: space)
            defer { other.invalidate() }
            other.openBookmark(try #require(Library.shared.bookmark(marks[0])))
            let pages = marks.compactMap(other.bookmarkTab(for:))
            #expect(other.split(for: pages[0])?.count == marks.count)
            manager.leavePinnedGroup(marks[1])
            let here = try #require(manager.split(for: tabs[0]))
            let there = try #require(other.split(for: pages[0]))
            #expect(there.ids.compactMap { other.tab(with: $0)?.bookmarkID } == here.ids.compactMap { manager.tab(with: $0)?.bookmarkID })
            #expect(Set(there.ids) == Set(pages.map(\.id)).subtracting([pages[1].id]))
            #expect(there.shape == here.shape)
            #expect(other.split(for: pages[1]) == nil)
        }
    }

    /// Closing one page of a pinned split unloads that page and keeps the pin whole, for four pages as for two.
    @Test(arguments: [2, 4]) func closingOnePinnedPageKeepsThePin(count: Int) throws {
        try inWindow((0..<count).map(String.init)) { controller, tabs, space in
            let manager = controller.tabManager
            manager.makeGroup(tabs, shape: count == 2 ? Self.shapes[0] : Self.shapes[4])
            manager.bookmarkTab(tabs[0], in: space)
            let marks = tabs.compactMap(\.bookmarkID)
            manager.close(tabs[1])
            #expect(manager.bookmarkTab(for: marks[1]) == nil)
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            #expect(tabs.indices.filter { $0 != 1 }.allSatisfy { manager.bookmarkTab(for: marks[$0]) === tabs[$0] })
        }
    }

    /// A pinned split's row has a tab split's × in each part: pointed at, it says Unload Page and unloads that page
    /// alone, the pin keeping every page; an unloaded part has none.
    @Test(arguments: [2, 4]) func aPinnedPartsCloseButtonUnloadsOnlyIt(count: Int) throws {
        try inWindow((0..<count).map(String.init)) { controller, tabs, space in
            let manager = controller.tabManager
            let list = controller.sidebar.list
            manager.makeGroup(tabs, shape: count == 2 ? Self.shapes[0] : Self.shapes[4])
            manager.bookmarkTab(tabs[0], in: space)
            tabs.forEach { _ = $0.ensureWebView() }
            let marks = tabs.compactMap(\.bookmarkID)
            #expect(marks.count == count)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let row = try #require(list.row(forBookmark: marks[0]) as? TabRowView)
            #expect(row.isSplit)
            row.isHovered = true
            row.debugPoint(atPart: 1)
            row.layoutSubtreeIfNeeded()
            #expect(!row.closeButton.isHidden)
            #expect(row.closeButton.toolTip == "Unload Page")
            let page = try #require(row.closingPage)
            row.onClose?()
            #expect(manager.bookmarkTab(for: try #require(page.bookmarkID)) == nil)
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            #expect(tabs.filter { $0 !== page }.allSatisfy { manager.bookmarkTab(for: $0.bookmarkID!) === $0 })
            // Unloaded now: that part has no ×, as a pinned page that isn't loaded has none on its own row.
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let after = try #require(list.row(forBookmark: marks[0]) as? TabRowView)
            after.isHovered = true
            let unloaded = try #require(marks.firstIndex(of: page.bookmarkID!))
            after.debugPoint(atPart: unloaded)
            after.layoutSubtreeIfNeeded()
            #expect(after.closeButton.isHidden)
        }
    }

    /// A split favorite's × sits on the page you point at, and unloads that page alone; the favorite keeps every page.
    @Test(arguments: [2, 4]) func aFavoriteSplitsCloseButtonUnloadsOnlyItsPage(count: Int) throws {
        try inWindow((0..<count).map(String.init)) { controller, tabs, _ in
            let manager = controller.tabManager
            manager.makeGroup(tabs, shape: count == 2 ? Self.shapes[0] : Self.shapes[4])
            manager.favoriteTab(tabs[0])
            tabs.forEach { _ = $0.ensureWebView() }
            let marks = tabs.compactMap(\.bookmarkID)
            #expect(marks.count == count)
            let favorites = controller.sidebar.favorites
            let open = Dictionary(uniqueKeysWithValues: marks.compactMap { id in manager.bookmarkTab(for: id).map { (id, $0) } })
            favorites.reload(favorites: Library.shared.favoriteTiles(in: manager.profile.id), selectedID: nil, tabs: open)
            let tile = try #require(favorites.tile(for: marks[0]) as? FavoriteTile)
            tile.frame = NSRect(x: 0, y: 0, width: 60, height: Tokens.Sidebar.favoriteHeight)
            tile.isHovered = true
            tile.debugPoint(atPage: 1)
            tile.layoutSubtreeIfNeeded()
            #expect(!tile.debugCloseButton.isHidden)
            #expect(tile.debugCloseButton.toolTip == "Unload Page")
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            tile.debugCloseButton.onClick?(event)
            #expect(manager.bookmarkTab(for: marks[1]) == nil)
            #expect(marks.enumerated().filter { $0.offset != 1 }.allSatisfy { manager.bookmarkTab(for: $0.element) != nil })
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            #expect(Library.shared.isFavorite(marks[0]))
        }
    }

    /// A tab of three or four side by side says it pins the split view, as one of two does, in its menu and the
    /// menu bar; a pinned one's says it unpins the split view.
    @Test func theItemsNameTheSplitForEveryCount() throws {
        try inWindow(["0", "1", "2", "3"]) { controller, tabs, space in
            let manager = controller.tabManager
            manager.makeGroup(tabs, shape: Self.shapes[4])
            manager.select(tabs[1])
            let pin = String(localized: "Pin Split View", comment: "Item in a tab's context menu in the sidebar. The tab is half of a split view; both pages are pinned together.")
            #expect(SidebarMenus.tabMenu(for: tabs[1], controller: controller).items.contains { $0.title == pin })
            let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.toggleBookmark(_:)), keyEquivalent: "d")
            #expect(controller.validateMenuItem(item))
            #expect(item.title == pin)
            controller.toggleBookmark(item)
            #expect(controller.validateMenuItem(item))
            #expect(item.title == String(localized: "Unpin Split View", comment: "Item in a pinned tab's context menu in the sidebar: takes both pages of a pinned split view out of Pinned."))
            _ = space
        }
    }

    /// The tab list and the pinned pages draw a split's row with the same view, laid out the same: its parts,
    /// hairlines and × in the same places.
    @Test(arguments: [2, 3, 4]) func bothSectionsDrawTheSameRow(count: Int) throws {
        try inWindow((0..<count).map(String.init)) { controller, tabs, space in
            let manager = controller.tabManager
            let list = controller.sidebar.list
            manager.makeGroup(tabs, shape: Self.shapes[count == 2 ? 0 : count == 3 ? 2 : 4])
            manager.select(tabs[0])
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let tabRow = try #require(list.row(for: tabs[0]) as? TabRowView)
            let hairline = Tokens.Metric.hairline
            // Loaded, so a pinned part has its × as a tab's part does.
            tabs.forEach { _ = $0.ensureWebView() }
            func shape(_ row: TabRowView) -> [NSRect] {
                row.isHovered = true
                row.debugPoint(atPart: 0)
                row.layoutSubtreeIfNeeded()
                var parts: [NSRect] = []
                for view in row.subviews where !view.isHidden && (view is FaviconView || view.frame.width == hairline) { parts.append(view.frame) }
                return [row.bounds, row.closeButton.frame] + parts.sorted { ($0.minX, $0.width) < ($1.minX, $1.width) }
            }
            let inTabs = shape(tabRow)
            #expect(tabRow.parts.count == count - 1)
            manager.bookmarkTab(tabs[0], in: space)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let mark = try #require(tabs[0].bookmarkID)
            let pinRow = try #require(list.row(forBookmark: mark) as? TabRowView)
            #expect(type(of: pinRow) == type(of: tabRow))
            #expect(pinRow.parts.count == count - 1)
            #expect(shape(pinRow) == inTabs)
        }
    }

    // MARK: Growing and pulling apart by drag

    /// A tab dropped on a pinned split's row joins it as a third or fourth page, where the same drop on a split of
    /// tabs puts it, every line where it was; one ⌘Z takes it back out, a tab again.
    @Test(arguments: [2, 3]) func aDropGrowsAPinnedSplitAsATabSplit(count: Int) throws {
        try inWindow((0...count).map(String.init)) { controller, all, space in
            let manager = controller.tabManager
            let tabs = Array(all.prefix(count)), extra = all[count]
            let shape = Self.shapes[count == 2 ? 0 : 2]
            manager.makeGroup(tabs, shape: shape)
            let kind = try #require(manager.joining(extra, onto: tabs[0], onRight: true))
            let asTabs = try #require(manager.split(for: tabs[0])?.adding(extra.id, kind))
            manager.bookmarkTab(tabs[0], in: space)
            let marks = tabs.compactMap(\.bookmarkID)
            let before = try #require(Library.shared.pinnedSplit(containing: marks[0]))
            #expect(manager.joining(.tab(extra.id), onto: .pinned(marks[0]), onRight: true) == kind)
            let undo = controller.sidebarUndo
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            controller.listJoinSplit(.tab(extra.id), onto: .pinned(marks[0]), onRight: true)
            undo.endUndoGrouping()
            let mark = try #require(extra.bookmarkID)
            let grown = try #require(Library.shared.pinnedSplit(containing: marks[0]))
            // In the order the pages read in their new places, as the tabs' would be.
            let markOf = Dictionary(uniqueKeysWithValues: zip(all.map(\.id), marks + [mark]))
            #expect(grown.ids == asTabs.ids.compactMap { markOf[$0] })
            #expect(grown.shape == asTabs.shape)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == grown.ids)
            #expect(manager.split(for: tabs[0])?.ids == asTabs.ids)
            #expect(manager.split(for: tabs[0])?.shape == asTabs.shape)
            #expect(!manager.tabs(in: space).contains { $0 === extra })
            undo.undo()
            #expect(Library.shared.pinnedSplit(containing: marks[0]) == before)
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.shape == before.shape)
            #expect(Library.shared.bookmark(mark) == nil)
            #expect(manager.tabs(in: space).contains { $0.id == extra.id })
            #expect(manager.split(for: tabs[0])?.ids == tabs.map(\.id))
        }
    }

    /// A pinned page on its own dropped on a pinned split of three is its fourth page, after the others, undoably.
    @Test func aPinnedPageJoinsAPinnedSplitOfThree() throws {
        try inWindow(["0", "1", "2", "x"]) { controller, all, space in
            let manager = controller.tabManager
            let tabs = Array(all.prefix(3))
            manager.makeGroup(tabs, shape: Self.shapes[2])
            manager.bookmarkTab(tabs[0], in: space)
            manager.bookmarkTab(all[3], in: space, keepingGroup: false)
            let marks = tabs.compactMap(\.bookmarkID), x = try #require(all[3].bookmarkID)
            Library.shared.moveBookmark(x, to: 0, in: space)
            let kind = try #require(manager.joining(.pinned(x), onto: .pinned(marks[0]), onRight: false))
            let expected = try #require(Library.shared.pinnedSplit(containing: marks[0])?.layout.adding(x, kind))
            controller.listJoinSplit(.pinned(x), onto: .pinned(marks[0]), onRight: false)
            let grown = try #require(Library.shared.pinnedSplit(containing: x))
            #expect(grown.ids == expected.ids && Set(grown.ids) == Set(marks + [x]))
            #expect(grown.shape == expected.shape && grown.shape.regions.count == 4)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == grown.ids)
            controller.sidebarUndo.undo()
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == [x] + marks)
        }
    }

    /// The tab list and the pinned pages offer the same drop on a split's row: the half under the pointer lit on a
    /// split of two or three, nothing at four, where the row only moves.
    @Test(arguments: [2, 3, 4]) func bothSectionsOfferTheSameDrop(count: Int) throws {
        try inWindow((0...count).map(String.init)) { controller, all, space in
            let manager = controller.tabManager
            let list = controller.sidebar.list
            let tabs = Array(all.prefix(count)), extra = all[count]
            manager.makeGroup(tabs, shape: Self.shapes[count == 2 ? 0 : count == 3 ? 2 : 4])
            let carried = SidebarItem.tab(extra.id)
            func offer(onto target: SidebarItem, row: () -> NSView?) throws -> Int? {
                list.reload(animated: false)
                list.layoutSubtreeIfNeeded()
                let offered = list.debugOfferSplit(carried, onto: target, onRight: true)
                let side = try #require(row() as? TabRowView).splitDropSide
                #expect(offered == (side != nil))
                list.debugOfferSplit(nil, onto: nil, onRight: false)
                return side
            }
            let inTabs = try offer(onto: .tab(tabs[0].id)) { list.row(for: tabs[0]) }
            #expect(manager.joining(extra, onto: tabs[0], onRight: false) == nil ? count == 4 : count < 4)
            manager.bookmarkTab(tabs[0], in: space)
            let mark = try #require(tabs[0].bookmarkID)
            let inPinned = try offer(onto: .bookmark(mark)) { list.row(forBookmark: mark) }
            #expect(inTabs == inPinned)
            #expect(inTabs == (count < 4 ? 1 : nil))
            #expect(manager.joining(.tab(extra.id), onto: .pinned(mark), onRight: false) == nil ? count == 4 : count < 4)
        }
    }

    /// One page dragged by its strip out of a pinned split of three: into Pinned it stays pinned on its own where it
    /// was let go, into the tabs it's a tab; the other two stay a pinned split, on screen too. ⌘Z puts it back.
    @Test(arguments: [true, false]) func aPagePulledOutOfAPinnedSplitOfThree(intoPinned: Bool) throws {
        let section: SidebarListView.Section = intoPinned ? .bookmarks : .tabs
        try inWindow(["0", "1", "2", "x"]) { controller, all, space in
            let manager = controller.tabManager
            let tabs = Array(all.prefix(3))
            manager.makeGroup(tabs, shape: Self.shapes[2])
            manager.bookmarkTab(tabs[0], in: space)
            manager.bookmarkTab(all[3], in: space, keepingGroup: false)
            let marks = tabs.compactMap(\.bookmarkID), x = try #require(all[3].bookmarkID)
            manager.select(tabs[1])
            #expect(controller.canMovePane(tabs[1], toListOf: controller))
            // Let go after the pinned page that follows the split, counted as the list counts it, or first among the tabs.
            controller.movePaneToList(tabs[1], of: controller, at: (section, section == .bookmarks ? 4 : 0, nil))
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == [marks[0], marks[2]])
            #expect(manager.split(for: tabs[0])?.ids == [tabs[0].id, tabs[2].id])
            #expect(manager.split(for: tabs[1]) == nil)
            if section == .bookmarks {
                #expect(Library.shared.pinnedSplit(containing: marks[1]) == nil)
                #expect(Library.shared.bookmarks(in: space).map(\.id) == [marks[0], marks[2], x, marks[1]])
                #expect(tabs[1].bookmarkID == marks[1])
            } else {
                #expect(Library.shared.bookmark(marks[1]) == nil)
                #expect(tabs[1].bookmarkID == nil)
                #expect(manager.tabs(in: space).first === tabs[1])
            }
            controller.sidebarUndo.undo()
            #expect(Library.shared.pinnedSplit(containing: marks[0])?.ids == marks)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == marks + [x])
            #expect(manager.split(for: tabs[0])?.ids == tabs.map(\.id))
        }
    }

    /// Out of a pinned split of two, the page left is a pinned page on its own, as Separate Split View leaves it.
    @Test func aPagePulledOutOfAPinnedSplitOfTwo() throws {
        try inWindow(["0", "1"]) { controller, tabs, space in
            let manager = controller.tabManager
            manager.makeGroup(tabs, shape: Self.shapes[0])
            manager.bookmarkTab(tabs[0], in: space)
            let marks = tabs.compactMap(\.bookmarkID)
            controller.movePaneToList(tabs[0], of: controller, at: (.tabs, 0, nil))
            #expect(Library.shared.pinnedSplit(containing: marks[1]) == nil)
            #expect(Library.shared.bookmarks(in: space).map(\.id) == [marks[1]])
            #expect(manager.split(for: tabs[1]) == nil)
            #expect(tabs[0].bookmarkID == nil)
            controller.sidebarUndo.undo()
            #expect(Library.shared.pinnedSplit(containing: marks[1])?.ids == marks)
        }
    }

    /// A pinned page split with a plain tab, dragged by its strip to the list, leaves the split on screen too.
    @Test(arguments: [true, false]) func aPinnedPagePulledOutOfASplitWithATab(intoPinned: Bool) throws {
        try inWindow(["0", "1"]) { controller, tabs, space in
            let manager = controller.tabManager
            manager.bookmarkTab(tabs[0], in: space)
            let mark = try #require(tabs[0].bookmarkID)
            manager.makeSplit(tabs[0], with: tabs[1])
            #expect(Library.shared.pinnedSplit(containing: mark) == nil)
            #expect(controller.canMovePane(tabs[0], toListOf: controller))
            controller.movePaneToList(tabs[0], of: controller, at: (intoPinned ? .bookmarks : .tabs, 0, nil))
            #expect(manager.split(for: tabs[0]) == nil)
            #expect(manager.split(for: tabs[1]) == nil)
            #expect(tabs[0].bookmarkID == (intoPinned ? mark : nil))
            controller.sidebarUndo.undo()
            #expect(manager.split(for: tabs[1])?.ids.count == 2)
        }
    }
}

/// How a favorite group's tile shows its pages (#203): a small icon for each, placed as the pages share the window, and
/// a click opening the page whose part of the tile it lands in.
@MainActor struct FavoriteGroupTileTests {
    private func tile(_ regions: [TileRegion]) -> (FavoriteTile, [Bookmark]) {
        let pages = regions.indices.map { Bookmark(url: URL(string: "https://example.com/\($0)")!, title: "\($0)") }
        let tile = FavoriteTile(bookmark: pages[0], partners: Array(pages.dropFirst()))
        tile.update(pages[0], partners: Array(pages.dropFirst()), regions: regions.count > 2 ? regions : nil)
        tile.frame = NSRect(x: 0, y: 0, width: 60, height: Tokens.Sidebar.favoriteHeight)
        tile.layoutSubtreeIfNeeded()
        return (tile, pages)
    }

    private func icons(of tile: FavoriteTile) -> [NSRect] {
        tile.subviews.compactMap { $0 as? FaviconView }.filter { !$0.isHidden }.map(\.frame)
    }

    @Test func aGridOfFourShowsFourIconsInTwoRowsAndColumns() {
        let (tile, pages) = tile([.topLeft, .topRight, .bottomLeft, .bottomRight])
        let frames = icons(of: tile)
        #expect(frames.count == 4)
        #expect(Set(frames.map(\.midX)).count == 2 && Set(frames.map(\.midY)).count == 2)
        // All inside the tile.
        #expect(frames.allSatisfy { tile.bounds.contains($0) })
        let top: CGFloat = tile.isFlipped ? 4 : tile.bounds.height - 4
        let bottom: CGFloat = tile.isFlipped ? tile.bounds.height - 4 : 4
        #expect(tile.page(at: NSPoint(x: 4, y: top))?.id == pages[0].id)
        #expect(tile.page(at: NSPoint(x: 56, y: top))?.id == pages[1].id)
        #expect(tile.page(at: NSPoint(x: 4, y: bottom))?.id == pages[2].id)
        #expect(tile.page(at: NSPoint(x: 56, y: bottom))?.id == pages[3].id)
    }

    @Test func aHalfSitsAcrossItsTwoCells() {
        let (tile, pages) = tile([.left, .topRight, .bottomRight])
        let frames = icons(of: tile)
        #expect(frames.count == 3)
        // The left half's icon in the middle of the tile's height, the two quarters above and below it.
        #expect(abs(frames[0].midY - tile.bounds.midY) <= 1)
        #expect(frames[1].midX == frames[2].midX && frames[1].midX > frames[0].midX)
        #expect(tile.page(at: NSPoint(x: 4, y: 4))?.id == pages[0].id)
        #expect(tile.page(at: NSPoint(x: 4, y: tile.bounds.height - 4))?.id == pages[0].id)
    }

    /// Pointing at a page of a split favorite puts the × in that page's icon's place: centered on it, its size, clear
    /// of the other icons.
    @Test(arguments: [[TileRegion.left, .right], [.left, .topRight, .bottomRight], [.topLeft, .topRight, .bottomLeft, .bottomRight]],
          [48, 60, 80] as [CGFloat])
    func aSplitsCloseButtonsSitOnTheirOwnIcons(regions: [TileRegion], width: CGFloat) {
        let (tile, _) = tile(regions)
        tile.frame.size.width = width
        let icons = Array(tile.pageIcons.prefix(regions.count))
        for page in regions.indices {
            tile.debugPoint(atPage: page)
            tile.layoutSubtreeIfNeeded()
            let close = tile.debugCloseButton.frame, own = icons[page].frame
            #expect(close.midX == own.midX && close.midY == own.midY)
            #expect(close.size == own.size)
            #expect(icons.indices.allSatisfy { $0 == page || !close.intersects(icons[$0].frame) })
        }
    }

    /// A favorite of one page keeps its × in the tile's top-right corner.
    @Test func aSingleFavoritesCloseButtonStaysInTheCorner() {
        let page = Bookmark(url: URL(string: "https://example.com/")!, title: "0")
        let tile = FavoriteTile(bookmark: page)
        tile.frame = NSRect(x: 0, y: 0, width: 60, height: Tokens.Sidebar.favoriteHeight)
        tile.layoutSubtreeIfNeeded()
        let side = Tokens.Sidebar.favoriteClose, edge = Tokens.Sidebar.favoriteCloseInset
        #expect(tile.debugCloseButton.frame == NSRect(x: 60 - side - edge, y: tile.isFlipped ? edge : tile.bounds.height - side - edge, width: side, height: side))
    }

    @Test func aPairStillShowsTwoIconsSideBySide() {
        let (tile, pages) = tile([.left, .right])
        let frames = icons(of: tile)
        #expect(frames.count == 2 && frames[0].midY == frames[1].midY)
        #expect(tile.page(at: NSPoint(x: 56, y: 10))?.id == pages[1].id)
    }
}

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

    /// A window with tabs `titles` in that order in the first space, for one test, the library put back after.
    private func withTabs(_ titles: [String], _ body: (TabManager, [Tab], UUID) throws -> Void) rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tabs = titles.enumerated().map { i, title in Tab(url: URL(string: "https://example.com/group/\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs, space)
    }

    /// Pinning any tab of a group of tabs keeps the group one thing: a folder named as the group was, holding its
    /// tabs in their order. Unpinning any page of it brings the group back, named, ordered and folded as it was.
    @Test func pinningAGroupOfTabsKeepsItWholeAsOneFolder() throws {
        try withTabs(["0", "1", "2", "3"]) { manager, tabs, space in
            let groupID = try #require(manager.makeGroup(with: tabs, name: "Reading"))
            manager.bookmarkTab(tabs[0], in: space)
            let page = try #require(tabs[0].bookmarkID)
            let folder = try #require(Library.shared.pinnedGroup(containing: page))
            #expect(folder.name == "Reading")
            #expect(folder.groupID == groupID)
            #expect(folder.bookmarkIDs == tabs.compactMap(\.bookmarkID))
            // One entry: every page is in the one folder, none a pinned split of its own.
            #expect(Library.shared.pinnedSplit(containing: page) == nil)
            #expect(Library.shared.bookmarks(in: space).filter { folder.bookmarkIDs.contains($0.id) }.map(\.id) == folder.bookmarkIDs)
            #expect(manager.tabs(in: space).isEmpty)
            // Unpinning a page brings the group back whole.
            manager.unbookmark(folder.bookmarkIDs[2], toIndex: 0)
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(manager.groups(in: space).map(\.id) == [groupID])
            #expect(manager.tabs(inGroup: groupID).map(\.id) == tabs.map(\.id))
            #expect(manager.tabs(in: space).map(\.id) == tabs.map(\.id))
        }
    }

    /// A group of one tab is a group too: it pins as a folder of one page and comes back as a group.
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

    /// A split in a group pins as a pinned split in the group's folder, and comes back side by side.
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
            // Unpinning a page of the split brings back the whole group, the split side by side.
            manager.unbookmark(pinned.ids[0], toIndex: 0)
            #expect(Library.shared.folder(folder.id) == nil)
            #expect(Set(manager.tabs(inGroup: groupID).map(\.id)) == Set(tabs.map(\.id)))
            #expect(manager.split(for: tabs[1])?.contains(tabs[2].id) == true)
        }
    }

    /// A folded group pins as a shut folder that hides its open pages, and comes back folded.
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

    /// A tab in no group still pins on its own: one page, in no folder.
    @Test func aTabOutsideAGroupStillPinsOnItsOwn() throws {
        try withTabs(["0"]) { manager, tabs, space in
            manager.bookmarkTab(tabs[0], in: space)
            let page = try #require(tabs[0].bookmarkID)
            #expect(Library.shared.pinnedGroup(containing: page) == nil)
            #expect(Library.shared.bookmarks(in: space).map(\.id).contains(page))
        }
    }

    /// A folder saved before groups could be pinned has no group, and keeps its pages: an older store still reads.
    @Test func anOlderFolderReadsWithNoGroupAndItsPages() throws {
        let page = UUID()
        let json = #"{"id":"\#(UUID())","name":"Old","bookmarkIDs":["\#(page)"],"isOpen":true}"#
        let folder = try JSONDecoder().decode(BookmarkFolder.self, from: Data(json.utf8))
        #expect(folder.groupID == nil)
        #expect(folder.name == "Old")
        #expect(folder.bookmarkIDs == [page])
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

    @Test func aPairStillShowsTwoIconsSideBySide() {
        let (tile, pages) = tile([.left, .right])
        let frames = icons(of: tile)
        #expect(frames.count == 2 && frames[0].midY == frames[1].midY)
        #expect(tile.page(at: NSPoint(x: 56, y: 10))?.id == pages[1].id)
    }
}

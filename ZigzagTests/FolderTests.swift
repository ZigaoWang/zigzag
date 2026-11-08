import Foundation
import Testing
@testable import Zigzag

/// Folders of pinned pages: they only say which pages they hold, so these check that the pages never get lost,
/// doubled or split from their folder, and that libraries from before folders still open.
struct FolderTests {
    private func pins(_ n: Int) -> [Bookmark] {
        (0..<n).map { Bookmark(url: URL(string: "https://example.com/\($0)")!, title: "\($0)") }
    }

    @Test func folderPagesStayTogether() {
        let b = pins(5)
        let folder = BookmarkFolder(name: "F", bookmarkIDs: [b[1].id, b[4].id])
        let (bookmarks, folders) = Library.tidied(b, [folder])
        #expect(bookmarks.map(\.id) == [b[0], b[1], b[4], b[2], b[3]].map(\.id))
        #expect(folders[0].bookmarkIDs == [b[1].id, b[4].id])
    }

    @Test func noPageIsLostOrDoubled() {
        let b = pins(6)
        let folders = [BookmarkFolder(name: "A", bookmarkIDs: [b[5].id, b[2].id]),
                       BookmarkFolder(name: "B", bookmarkIDs: [b[2].id, b[3].id, UUID()])]
        let (bookmarks, tidy) = Library.tidied(b, folders)
        #expect(Set(bookmarks.map(\.id)) == Set(b.map(\.id)))
        #expect(bookmarks.count == b.count)
        // A page in two folders stays in the first; one that's gone is dropped.
        #expect(tidy[0].bookmarkIDs == [b[2].id, b[5].id])
        #expect(tidy[1].bookmarkIDs == [b[3].id])
    }

    @Test func emptyFolderStays() {
        let b = pins(2)
        let (bookmarks, folders) = Library.tidied(b, [BookmarkFolder(name: "Empty")])
        #expect(bookmarks.map(\.id) == b.map(\.id))
        #expect(folders.count == 1 && folders[0].bookmarkIDs.isEmpty)
    }

    @Test func spaceFromBeforeFoldersOpens() throws {
        let space = SpaceInfo(name: "Old", color: .sage)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(space)) as! [String: Any]
        json.removeValue(forKey: "folders")
        let decoded = try JSONDecoder().decode(SpaceInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.name == "Old")
        #expect((decoded.folders ?? []).isEmpty)
    }
}

/// Pinned splits: two pinned pages kept as one split view. These check the pair stays side by side and in one folder,
/// ends cleanly when a page goes, and that libraries from before pinned splits still open.
struct PinnedSplitTests {
    private func pins(_ n: Int) -> [Bookmark] {
        (0..<n).map { Bookmark(url: URL(string: "https://example.com/\($0)")!, title: "\($0)") }
    }

    @Test func rightPageFollowsLeftIntoItsFolder() {
        let b = pins(4)
        let folder = BookmarkFolder(name: "F", bookmarkIDs: [b[1].id])
        let split = PinnedSplit(left: b[1].id, right: b[3].id)
        let (bookmarks, folders, splits) = Library.tidied(b, [folder], [split])
        #expect(bookmarks.map(\.id) == [b[0], b[1], b[3], b[2]].map(\.id))
        #expect(folders[0].bookmarkIDs == [b[1].id, b[3].id])
        #expect(splits == [split])
    }

    @Test func splitEndsWhenAPageGoes() {
        let b = pins(3)
        let gone = PinnedSplit(left: b[0].id, right: UUID())
        let (bookmarks, _, splits) = Library.tidied(b, [], [gone])
        #expect(bookmarks.map(\.id) == b.map(\.id))
        #expect(splits.isEmpty)
    }

    @Test func aPageIsInOneSplitAtMost() {
        let b = pins(3)
        let first = PinnedSplit(left: b[0].id, right: b[1].id)
        let (_, _, splits) = Library.tidied(b, [], [first, PinnedSplit(left: b[1].id, right: b[2].id), PinnedSplit(left: b[2].id, right: b[2].id)])
        #expect(splits == [first])
    }

    @Test func layoutIsSavedButNotAChange() throws {
        var split = PinnedSplit(left: UUID(), right: UUID())
        split.ratio = 0.3
        split.vertical = true
        let decoded = try JSONDecoder().decode(PinnedSplit.self, from: JSONEncoder().encode(split))
        #expect(decoded.ratio == 0.3 && decoded.vertical)
        // A resize alone doesn't make the library look changed to ⌘Z.
        #expect(decoded == PinnedSplit(left: split.left, right: split.right))
        #expect(split != PinnedSplit(left: split.right, right: split.left))
    }

    @Test func spaceFromBeforePinnedSplitsOpens() throws {
        let space = SpaceInfo(name: "Old", color: .sage)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(space)) as! [String: Any]
        json.removeValue(forKey: "pinnedSplits")
        let decoded = try JSONDecoder().decode(SpaceInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect((decoded.pinnedSplits ?? []).isEmpty)
    }
}

/// Arc's pinned folders come over as folders, nested as they were; a pinned split view is just its pages.
struct ArcFolderTests {
    @Test func foldersAndSplitViews() throws {
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["id": id, "title": id, "data": ["tab": ["savedURL": url]], "childrenIds": [String]()]
        }
        let items: [Any] = [
            ["id": "pinned", "childrenIds": ["t1", "folder", "split"], "data": ["itemContainer": [:]]],
            tab("t1", "https://example.com/1"),
            ["id": "folder", "title": "Reading", "data": ["list": [:]], "childrenIds": ["t2", "inner"]],
            tab("t2", "https://example.com/2"),
            ["id": "inner", "title": "Inner", "data": ["list": [:]], "childrenIds": ["t3"]],
            tab("t3", "https://example.com/3"),
            ["id": "split", "data": ["splitView": [:]], "childrenIds": ["t4", "t5"]],
            tab("t4", "https://example.com/4"),
            tab("t5", "https://example.com/5"),
        ]
        let root: [String: Any] = ["sidebar": ["containers": [
            ["global": [:]],
            ["spaces": ["s1", ["id": "s1", "title": "Home", "containerIDs": ["unpinned", "u", "pinned", "pinned"]]], "items": items],
        ]]]
        let (spaces, _) = try ArcImporter.parseSidebar(JSONSerialization.data(withJSONObject: root))
        let space = try #require(spaces.first)
        #expect(space.bookmarks.map(\.url.lastPathComponent) == ["1", "2", "3", "4", "5"])
        let folders = space.folders ?? []
        // Nested as in Arc: Inner inside Reading, each holding its own page.
        #expect(folders.map(\.name) == ["Reading", "Inner"])
        #expect(folders.first?.bookmarkIDs == [space.bookmarks[1].id])
        #expect(folders.last?.bookmarkIDs == [space.bookmarks[2].id])
        #expect(folders.last?.parentID == folders.first?.id)
    }

    /// Newer Arc (and Arc Sync) wraps each item as {"value": …} and writes a container's kind as an object keyed by
    /// it: the same sidebar must come over, folders and favorites included.
    @Test func newerLayoutWithWrappedItems() throws {
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["value": ["id": id, "title": id, "data": ["tab": ["savedURL": url]], "childrenIds": [String]()]]
        }
        let items: [Any] = [
            "pinned", ["value": ["id": "pinned", "childrenIds": ["t1", "folder"], "data": ["itemContainer": [:]]]],
            "t1", tab("t1", "https://example.com/1"),
            "folder", ["value": ["id": "folder", "title": "Imported From Chrome", "data": ["list": [:]], "childrenIds": ["inner"]]],
            "inner", ["value": ["id": "inner", "title": "Swift", "data": ["list": [:]], "childrenIds": ["t2"]]],
            "t2", tab("t2", "https://example.com/2"),
            "top", ["value": ["id": "top", "childrenIds": ["f1"], "data": ["itemContainer": [:]]]],
            "f1", tab("f1", "https://example.com/fav"),
        ]
        let space: [String: Any] = ["id": "s1", "containerIDs": [["unpinned": ["_0": [:]]], "u", ["pinned": ["_0": [:]]], "pinned"]]
        let root: [String: Any] = ["sidebar": ["containers": [
            ["global": [:]],
            ["spaces": ["s1", ["value": space]], "items": items, "topAppsContainerIDs": [["default": true], "top"]],
        ]]]
        let (spaces, favorites) = try ArcImporter.parseSidebar(JSONSerialization.data(withJSONObject: root))
        let first = try #require(spaces.first)
        #expect(spaces.count == 1)
        #expect(first.bookmarks.map(\.url.lastPathComponent) == ["1", "2"])
        #expect((first.folders ?? []).map(\.name) == ["Imported From Chrome", "Swift"])
        #expect(favorites.map(\.url.lastPathComponent) == ["fav"])
    }

    /// Arc with sync keeps what it shows in sidebarSyncState; the classic copy may be stale. The synced spaces, pins
    /// and favorites come over, in Arc's order, without spaces it no longer shows.
    @Test func syncedSidebarWins() throws {
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["value": ["id": id, "title": id, "data": ["tab": ["savedURL": url]], "childrenIds": [String]()]]
        }
        let synced: [Any] = [
            "pinned", ["value": ["id": "pinned", "childrenIds": ["folder"], "data": ["itemContainer": [:]]]],
            "folder", ["value": ["id": "folder", "title": "Imported From Chrome", "data": ["list": [:]], "childrenIds": ["t1"]]],
            "t1", tab("t1", "https://example.com/1"),
            "top", ["value": ["id": "top", "childrenIds": ["f1"], "data": ["itemContainer": [:]]]],
            "f1", tab("f1", "https://example.com/fav"),
        ]
        func space(_ id: String, _ title: String) -> [String: Any] {
            ["value": ["id": id, "title": title, "containerIDs": ["unpinned", "u", "pinned", "pinned"]]]
        }
        let root: [String: Any] = [
            // The classic copy: the space is there, its pins aren't.
            "sidebar": ["containers": [["global": [:]], ["spaces": ["s1", ["id": "s1", "containerIDs": ["pinned", "gone"]]], "items": [Any](), "topAppsContainerIDs": [Any]()]]],
            "sidebarSyncState": [
                "container": ["value": ["orderedSpaceIDs": ["s1"], "topAppsContainerIDs": [["default": true], "top"]]],
                "spaceModels": ["s1", space("s1", "Home"), "old", space("old", "Archived")],
                "items": synced,
            ],
        ]
        let (spaces, favorites) = try ArcImporter.parseSidebar(JSONSerialization.data(withJSONObject: root))
        #expect(spaces.map(\.name) == ["Home"])
        #expect(spaces.first?.bookmarks.map(\.url.lastPathComponent) == ["1"])
        #expect((spaces.first?.folders ?? []).map(\.name) == ["Imported From Chrome"])
        #expect(favorites.map(\.url.lastPathComponent) == ["fav"])
    }

    /// With sync off, the synced copy is a small leftover and the pins sit in a later classic container: the fullest
    /// copy wins, so the folder Arc shows comes over.
    @Test func fullestCopyWins() throws {
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["id": id, "title": id, "data": ["tab": ["savedURL": url]], "childrenIds": [String]()]
        }
        let full: [Any] = [
            ["id": "pinned", "childrenIds": ["basics", "chrome"], "data": ["itemContainer": [:]]],
            ["id": "basics", "title": "Arc Basics", "data": ["list": [:]], "childrenIds": ["t1"]],
            tab("t1", "https://example.com/1"),
            ["id": "chrome", "title": "Imported From Chrome", "data": ["list": [:]], "childrenIds": ["swift"]],
            ["id": "swift", "title": "Swift", "data": ["list": [:]], "childrenIds": ["t2", "t3"]],
            tab("t2", "https://example.com/2"),
            tab("t3", "https://example.com/3"),
        ]
        let leftover: [Any] = [
            "pinned", ["value": ["id": "pinned", "childrenIds": ["basics"], "data": ["itemContainer": [:]]]],
            "basics", ["value": ["id": "basics", "title": "Arc Basics", "data": ["list": [:]], "childrenIds": ["t1"]]],
            "t1", ["value": tab("t1", "https://example.com/1")],
        ]
        let root: [String: Any] = [
            "sidebar": ["containers": [
                ["global": [:]],
                ["spaces": ["s1", ["id": "s1", "containerIDs": ["unpinned", "u", "pinned", "pinned"]]], "items": [Any]()],
                ["global": [:]],
                ["items": full],
            ]],
            "sidebarSyncState": [
                "container": ["value": ["orderedSpaceIDs": ["s1"]]],
                "spaceModels": ["s1", ["value": ["id": "s1", "containerIDs": ["unpinned", "u", "pinned", "pinned"]]]],
                "items": leftover,
            ],
        ]
        let (spaces, _) = try ArcImporter.parseSidebar(JSONSerialization.data(withJSONObject: root))
        #expect(spaces.count == 1)
        #expect(spaces.first?.bookmarks.map(\.url.lastPathComponent) == ["1", "2", "3"])
        #expect((spaces.first?.folders ?? []).map(\.name) == ["Arc Basics", "Imported From Chrome", "Swift"])
    }

    @Test func movedFolderLandsBetweenGroups() {
        let b = (0..<6).map { _ in UUID() }
        let folders = [BookmarkFolder(name: "F", bookmarkIDs: [b[1], b[2], b[3]])]
        let splits = [PinnedSplit(left: b[4], right: b[5])]
        // Outside any group: where it was dropped.
        #expect(Library.folderDropIndex(1, in: b, folders: folders, splits: splits) == 1)
        #expect(Library.folderDropIndex(4, in: b, folders: folders, splits: splits) == 4)
        // Inside a folder: its nearer end.
        #expect(Library.folderDropIndex(2, in: b, folders: folders, splits: splits) == 1)
        #expect(Library.folderDropIndex(3, in: b, folders: folders, splits: splits) == 4)
        // Never between a pinned split's two pages.
        #expect(Library.folderDropIndex(5, in: b, folders: folders, splits: splits) == 4)
        #expect(Library.folderDropIndex(99, in: b, folders: folders, splits: splits) == 6)
    }

    /// A tree imported eight deep keeps every level; deeper pages go in the eighth, never a level left out between.
    @Test func importedFoldersKeepEightLevels() {
        let ids = (0..<3).map { _ in UUID() }
        let deep = (1...10).map { "L\($0)" }
        let folders = Library.filed(ids, paths: [Array(deep.prefix(8)), deep, Array(deep.prefix(5))], into: [])
        #expect(folders.count == Library.folderDepthLimit)
        let eighth = folders.first { $0.name == "L8" }, fifth = folders.first { $0.name == "L5" }
        #expect(eighth.map { folders.depth(of: $0.id) } == 7)
        // The page ten deep sits with the one eight deep.
        #expect(eighth?.bookmarkIDs == [ids[0], ids[1]])
        #expect(fifth?.bookmarkIDs == [ids[2]])
        #expect(!folders.contains { $0.name == "L9" || $0.name == "L10" })
    }

    /// Filing into folders already there uses them again, by their place and name, the same name elsewhere apart.
    @Test func filingReusesFoldersByPlace() {
        let a = (0..<2).map { _ in UUID() }, b = (0..<2).map { _ in UUID() }
        let first = Library.filed(a, paths: [["Work", "Docs"], ["Home", "Docs"]], into: [])
        let second = Library.filed(b, paths: [["Work", "Docs"], ["Docs"]], into: first)
        #expect(second.count == 5)
        let work = second.first { $0.name == "Work" }
        let workDocs = second.first { $0.name == "Docs" && $0.parentID == work?.id }
        #expect(workDocs?.bookmarkIDs == [a[0], b[0]])
        #expect(second.first { $0.name == "Docs" && $0.parentID == nil }?.bookmarkIDs == [b[1]])
    }

    /// What's inside a folder at any depth, and which folders hold pages somewhere in them.
    @Test func folderTreeLookups() {
        let p = (0..<2).map { _ in UUID() }
        var top = BookmarkFolder(name: "Top"), mid = BookmarkFolder(name: "Mid"), low = BookmarkFolder(name: "Low")
        let empty = BookmarkFolder(name: "Empty")
        mid.parentID = top.id; low.parentID = mid.id
        top.bookmarkIDs = [p[0]]; low.bookmarkIDs = [p[1]]
        var lone = BookmarkFolder(name: "Lone"); lone.parentID = empty.id
        let folders = [low, top, empty, mid, lone]
        #expect(Set(folders.descendants(of: top.id)) == [mid.id, low.id])
        #expect(folders.descendants(of: low.id).isEmpty)
        #expect(folders.pages(in: top.id) == Set(p))
        #expect(folders.pages(in: mid.id) == [p[1]])
        #expect(folders.holdingPages == [top.id, mid.id, low.id])
    }

    /// Rows step in a full indent for the first levels, then half as far, every level still a step in.
    @Test func deepRowsStepInLess() {
        let full = SidebarListView.folderIndent
        #expect(SidebarListView.indent(depth: 0) == 0)
        #expect(SidebarListView.indent(depth: SidebarListView.fullIndentLevels) == CGFloat(SidebarListView.fullIndentLevels) * full)
        let steps = (0...Library.folderDepthLimit).map { SidebarListView.indent(depth: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 > $0 })
        #expect(steps[Library.folderDepthLimit] < CGFloat(Library.folderDepthLimit) * full)
    }
}

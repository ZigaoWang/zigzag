import AppKit
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

/// Arc's pinned folders come over as folders, nested as they were; a pinned split view stays a pinned split view.
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

    /// An Arc space with folders three deep, pages and folders mixed, and split views at the top and in a folder.
    private static func nestedSidebar() throws -> Data {
        func tab(_ id: String) -> [String: Any] {
            ["id": id, "title": id, "data": ["tab": ["savedURL": "https://example.com/\(id)"]], "childrenIds": [String]()]
        }
        func folder(_ id: String, _ title: String, _ children: [String]) -> [String: Any] {
            ["id": id, "title": title, "data": ["list": [:]], "childrenIds": children]
        }
        let items: [Any] = [
            ["id": "pinned", "childrenIds": ["p1", "topSplit", "work", "hollow"], "data": ["itemContainer": [:]]],
            tab("p1"),
            ["id": "topSplit", "data": ["splitView": [:]], "childrenIds": ["p2", "p3"]],
            tab("p2"), tab("p3"),
            folder("work", "Work", ["p4", "docs", "inSplit", "p8"]),
            tab("p4"),
            folder("docs", "Docs", ["specs", "p9"]),
            folder("specs", "Specs", ["p10"]),
            tab("p10"), tab("p9"),
            ["id": "inSplit", "data": ["splitView": [:]], "childrenIds": ["p5", "p6", "p7"]],
            tab("p5"), tab("p6"), tab("p7"), tab("p8"),
            folder("hollow", "Hollow", ["hollowInner"]),
            folder("hollowInner", "Hollow Inner", []),
        ]
        let root: [String: Any] = ["sidebar": ["containers": [
            ["global": [:]],
            ["spaces": ["s1", ["id": "s1", "title": "Home", "containerIDs": ["unpinned", "u", "pinned", "pinned"]]], "items": items],
        ]]]
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Folders inside folders keep their names, nesting and Arc's order, shut as imports come; empty ones stay behind (#391).
    @Test func nestedFoldersKeepTheirTreeAndOrder() throws {
        let space = try #require(ArcImporter.parseSidebar(Self.nestedSidebar()).spaces.first)
        let pages = space.bookmarks.map(\.url.lastPathComponent)
        #expect(pages == ["p1", "p2", "p3", "p4", "p10", "p9", "p5", "p6", "p7", "p8"])
        let folders = space.folders ?? []
        #expect(folders.map(\.name) == ["Work", "Docs", "Specs"])
        let work = try #require(folders.first { $0.name == "Work" })
        let docs = try #require(folders.first { $0.name == "Docs" })
        let specs = try #require(folders.first { $0.name == "Specs" })
        #expect(work.parentID == nil && docs.parentID == work.id && specs.parentID == docs.id)
        func ids(_ names: [String]) -> [UUID] { names.compactMap { n in space.bookmarks.first { $0.url.lastPathComponent == n }?.id } }
        #expect(work.bookmarkIDs == ids(["p4", "p5", "p6", "p7", "p8"]))
        #expect(docs.bookmarkIDs == ids(["p9"]))
        #expect(specs.bookmarkIDs == ids(["p10"]))
        #expect(folders.allSatisfy { !$0.isOpen })
        // The sidebar's own rule leaves the tree as it came.
        let tidy = Library.tidied(space.bookmarks, folders, space.pinnedSplits ?? [])
        #expect(tidy.bookmarks.map(\.id) == space.bookmarks.map(\.id))
        #expect(tidy.folders.map(\.bookmarkIDs) == folders.map(\.bookmarkIDs))
    }

    /// Arc's pinned split views stay split views, at the top and inside a folder (#391).
    @Test func pinnedSplitViewsStaySplit() throws {
        let space = try #require(ArcImporter.parseSidebar(Self.nestedSidebar()).spaces.first)
        func ids(_ names: [String]) -> [UUID] { names.compactMap { n in space.bookmarks.first { $0.url.lastPathComponent == n }?.id } }
        let splits = space.pinnedSplits ?? []
        #expect(splits.map(\.ids) == [ids(["p2", "p3"]), ids(["p5", "p6", "p7"])])
        #expect(splits.last?.regions == [.left, .topRight, .bottomRight])
        #expect(Library.tidied(space.bookmarks, space.folders ?? [], splits).splits.count == 2)
    }

    /// Folders deeper than Zigzag keeps put their pages in the deepest folder kept, never leave them out (#391).
    @Test func foldersDeeperThanTheLimitKeepTheirPages() throws {
        let depth = Library.folderDepthLimit + 2
        var items: [Any] = [["id": "pinned", "childrenIds": ["f1"], "data": ["itemContainer": [:]]]]
        for level in 1...depth {
            let children = level < depth ? ["f\(level + 1)", "page\(level)"] : ["page\(level)"]
            items.append(["id": "f\(level)", "title": "L\(level)", "data": ["list": [:]], "childrenIds": children])
            items.append(["id": "page\(level)", "title": "page\(level)", "data": ["tab": ["savedURL": "https://example.com/\(level)"]], "childrenIds": [String]()])
        }
        let root: [String: Any] = ["sidebar": ["containers": [
            ["spaces": ["s1", ["id": "s1", "title": "Deep", "containerIDs": ["pinned", "pinned"]]], "items": items],
        ]]]
        let space = try #require(ArcImporter.parseSidebar(JSONSerialization.data(withJSONObject: root)).spaces.first)
        #expect(space.bookmarks.count == depth)
        let folders = space.folders ?? []
        #expect(folders.count == Library.folderDepthLimit)
        let deepest = try #require(folders.first { $0.name == "L\(Library.folderDepthLimit)" })
        #expect(folders.depth(of: deepest.id) == Library.folderDepthLimit - 1)
        #expect(deepest.bookmarkIDs.count == 3)
        #expect(Set(folders.flatMap(\.bookmarkIDs)) == Set(space.bookmarks.map(\.id)))
    }

    /// Importing again into a space that came over before gains Arc's pinned split views, nested folders kept (#391).
    @MainActor @Test func importingAgainGainsSplitViews() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        var incoming = try #require(ArcImporter.parseSidebar(Self.nestedSidebar()).spaces.first)
        incoming.name = "Arc Merge \(UUID().uuidString)"
        // As an import before split views came over: the same pages and folders, no splits.
        var earlier = incoming
        earlier.id = UUID()
        earlier.pinnedSplits = nil
        Library.shared.appendSpaces([earlier])
        let added = ArcImporter.merge(incoming, into: earlier.id)
        #expect(added == 0)
        let space = try #require(Library.shared.space(earlier.id))
        #expect(space.bookmarks.map(\.url) == incoming.bookmarks.map(\.url))
        let urls = (space.pinnedSplits ?? []).map { split in split.ids.compactMap { id in space.bookmarks.first { $0.id == id }?.url.lastPathComponent } }
        #expect(urls == [["p2", "p3"], ["p5", "p6", "p7"]])
        #expect((space.folders ?? []).map(\.name) == ["Work", "Docs", "Specs"])
        // A third time changes nothing.
        #expect(ArcImporter.merge(incoming, into: earlier.id) == 0)
        #expect(Library.shared.space(earlier.id)?.pinnedSplits?.count == 2)
    }

    /// Importing again never moves a page you moved: a split view whose pages aren't together any more stays apart (#391).
    @MainActor @Test func importingAgainLeavesMovedPagesApart() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        var incoming = try #require(ArcImporter.parseSidebar(Self.nestedSidebar()).spaces.first)
        incoming.name = "Arc Merge \(UUID().uuidString)"
        var earlier = incoming
        earlier.id = UUID()
        earlier.pinnedSplits = nil
        Library.shared.appendSpaces([earlier])
        let p3 = try #require(earlier.bookmarks.first { $0.url.lastPathComponent == "p3" })
        let work = try #require(earlier.folders?.first { $0.name == "Work" })
        Library.shared.setFolder(of: p3.id, to: work.id)
        let moved = try #require(Library.shared.space(earlier.id))
        ArcImporter.merge(incoming, into: earlier.id)
        let space = try #require(Library.shared.space(earlier.id))
        #expect(space.bookmarks.map(\.id) == moved.bookmarks.map(\.id))
        #expect(space.folders?.first { $0.name == "Work" }?.bookmarkIDs.contains(p3.id) == true)
        let urls = (space.pinnedSplits ?? []).map { split in split.ids.compactMap { id in space.bookmarks.first { $0.id == id }?.url.lastPathComponent } }
        #expect(urls == [["p5", "p6", "p7"]])
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

    /// Open All in Tabs takes the folder's tree in list order (#343).
    @Test func openAllTakesTheTreeInListOrder() {
        let p = (0..<6).map { _ in UUID() }
        var top = BookmarkFolder(name: "Top", bookmarkIDs: [p[1], p[4]]), mid = BookmarkFolder(name: "Mid", bookmarkIDs: [p[2]])
        var low = BookmarkFolder(name: "Low", bookmarkIDs: [p[3]])
        mid.parentID = top.id; low.parentID = mid.id
        let other = BookmarkFolder(name: "Other", bookmarkIDs: [p[5]])
        let folders = [low, other, top, mid]
        #expect(folders.pages(in: top.id, ordered: p) == [p[1], p[2], p[3], p[4]])
        #expect(folders.pages(in: mid.id, ordered: p.reversed()) == [p[3], p[2]])
        top.bookmarkIDs = []
        #expect([top].pages(in: top.id, ordered: p).isEmpty)
    }

    /// Expand All and Collapse All reach every level and nothing outside (#343).
    @Test func expandAndCollapseAllReachEveryLevel() {
        let p = (0..<3).map { _ in UUID() }
        var top = BookmarkFolder(name: "Top", bookmarkIDs: [p[0]]), mid = BookmarkFolder(name: "Mid", bookmarkIDs: [p[1]])
        var low = BookmarkFolder(name: "Low"), side = BookmarkFolder(name: "Side", bookmarkIDs: [p[2]])
        mid.parentID = top.id; low.parentID = mid.id
        mid.isOpen = false; side.isOpen = false
        let folders = [top, mid, low, side]
        #expect(folders.anyInTree(of: top.id, isOpen: false) && folders.anyInTree(of: top.id, isOpen: true))
        #expect(!folders.anyInTree(of: low.id, isOpen: false))

        let shut = folders.folding(top.id, open: false, shown: [p[1], p[2]])
        #expect(shut.filter { [top.id, mid.id, low.id].contains($0.id) }.allSatisfy { !$0.isOpen })
        #expect(!shut.anyInTree(of: top.id, isOpen: true))
        // Pages inside are hidden at any depth; the one outside stays.
        #expect(shut.first { $0.id == top.id }?.tucked == [p[1]])
        #expect(shut.first { $0.id == mid.id }?.tucked == [p[1]])
        #expect(shut.first { $0.id == low.id }?.tucked == nil)
        #expect(shut.first { $0.id == side.id } == side)

        let open = shut.folding(top.id, open: true)
        #expect(open.filter { [top.id, mid.id, low.id].contains($0.id) }.allSatisfy { $0.isOpen && $0.tucked == nil })
        #expect(!open.anyInTree(of: top.id, isOpen: false))
        #expect(open.first { $0.id == side.id } == side)
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

/// What a shut folder still shows (#94, #154): the page you're on and the pages opened since it was shut, never the
/// ones that were open when you shut it.
@MainActor
struct ShutFolderRowsTests {
    let p = (0..<4).map { _ in UUID() }

    private func rows(_ folders: [BookmarkFolder], current: UUID? = nil, open: Set<UUID> = []) -> [SidebarItem] {
        SidebarListView.pinnedRows(bookmarks: p, folders: folders, current: current, isOpen: open.contains).rows
    }

    @Test func anOpenFolderShowsAllItHolds() {
        let folder = BookmarkFolder(name: "F", bookmarkIDs: [p[0], p[1]])
        #expect(rows([folder]) == [.folder(folder.id), .bookmark(p[0]), .bookmark(p[1]), .bookmark(p[2]), .bookmark(p[3])])
    }

    @Test func shuttingHidesThePagesOpenThen() {
        // Both pages open when it's shut: shut, it shows neither.
        var folder = BookmarkFolder(name: "F", bookmarkIDs: [p[0], p[1]])
        folder.isOpen = false
        folder.tucked = [p[0], p[1]]
        #expect(rows([folder], open: [p[0], p[1]]) == [.folder(folder.id), .bookmark(p[2]), .bookmark(p[3])])
    }

    @Test func thePageYouAreOnStillShows() {
        var folder = BookmarkFolder(name: "F", bookmarkIDs: [p[0], p[1]])
        folder.isOpen = false
        folder.tucked = [p[0], p[1]]
        let shown = SidebarListView.pinnedRows(bookmarks: p, folders: [folder], current: p[1], isOpen: { _ in true })
        #expect(shown.rows == [.folder(folder.id), .bookmark(p[1]), .bookmark(p[2]), .bookmark(p[3])])
        #expect(shown.depth[.bookmark(p[1])] == 1)
    }

    @Test func aPageOpenedSinceItWasShutShows() {
        // p[1] wasn't open when the folder was shut; opened since, it shows under it, set in.
        var folder = BookmarkFolder(name: "F", bookmarkIDs: [p[0], p[1]])
        folder.isOpen = false
        folder.tucked = [p[0]]
        let shown = SidebarListView.pinnedRows(bookmarks: p, folders: [folder], current: nil, isOpen: Set([p[0], p[1]]).contains)
        #expect(shown.rows == [.folder(folder.id), .bookmark(p[1]), .bookmark(p[2]), .bookmark(p[3])])
        #expect(shown.depth[.bookmark(p[1])] == 1)
        // A folder from before #154 (nothing tucked) still shows its open pages, as #94 has it.
        folder.tucked = nil
        #expect(rows([folder], open: [p[0]]) == [.folder(folder.id), .bookmark(p[0]), .bookmark(p[2]), .bookmark(p[3])])
    }

    @Test func aShutFolderInsideHidesWhatItTucked() {
        // Outer open, inner shut over p[1]: p[1] stays hidden, p[0] in the outer one shows.
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [p[0]])
        var inner = BookmarkFolder(name: "Inner", bookmarkIDs: [p[1]])
        inner.parentID = outer.id
        inner.isOpen = false
        inner.tucked = [p[1]]
        let shown = rows([outer, inner], open: [p[1]])
        #expect(!shown.contains(.bookmark(p[1])))
        #expect(shown.contains(.folder(inner.id)) && shown.contains(.bookmark(p[0])))
    }

    @Test func aLibraryFromBeforeTuckingOpens() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BookmarkFolder(name: "F", isOpen: false))) as! [String: Any]
        json.removeValue(forKey: "tucked")
        let decoded = try JSONDecoder().decode(BookmarkFolder.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.name == "F" && !decoded.isOpen && decoded.tucked == nil)
    }
}

/// A page opened from a shut folder and closed with ⌘W or its row's × keeps its row under the folder, unloaded, until
/// you leave the space or open or shut that folder again.
@MainActor @Suite(.serialized)
struct ShutFolderClosedPinTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// A window on the first space with one tab, and a pinned page alone in a shut folder.
    private func inWindow(_ body: (BrowserWindowController, Bookmark, BookmarkFolder) throws -> Void) throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: nil, title: "Tab", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let pin = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/shut/kept")!, title: "Kept", to: space))
        let folder = try #require(Library.shared.addFolder(named: "Shut", with: [pin.id], in: space))
        Library.shared.setFolderOpen(folder.id, false)
        try body(controller, pin, folder)
    }

    /// The row of a pinned page the list shows, if it shows one.
    private func pinRow(_ controller: BrowserWindowController, _ id: UUID) -> TabRowView? {
        controller.sidebar.list.reload(animated: false)
        guard controller.sidebar.list.debugItems.contains(.bookmark(id)) else { return nil }
        controller.sidebar.layoutSubtreeIfNeeded()
        return controller.sidebar.list.row(forBookmark: id) as? TabRowView
    }

    /// Opens the page and closes it again with ⌘W or its row's ×; its row stays under the folder, unloaded.
    private func openAndClose(_ controller: BrowserWindowController, _ pin: Bookmark, _ folder: BookmarkFolder, byButton: Bool) throws {
        let manager = controller.tabManager
        #expect(pinRow(controller, pin.id) == nil)
        manager.openBookmark(pin)
        let page = try #require(manager.bookmarkTab(for: pin.id))
        if byButton { try #require(pinRow(controller, pin.id)).onClose?() } else { controller.closeTab(nil) }
        #expect(page.isClosed)
        let row = try #require(pinRow(controller, pin.id), "byButton=\(byButton)")
        #expect(row.isUnloaded)
        let items = controller.sidebar.list.debugItems
        #expect(items.firstIndex(of: .bookmark(pin.id)) == items.firstIndex(of: .folder(folder.id)).map { $0 + 1 })
    }

    @Test func aClosedPageStaysUnderItsShutFolderUntilYouLeaveTheSpace() throws {
        for byButton in [false, true] {
            try inWindow { controller, pin, folder in
                let manager = controller.tabManager
                let other = Library.shared.addSpace(name: "Other").id
                try openAndClose(controller, pin, folder, byButton: byButton)
                manager.switchToSpace(other)
                manager.switchToSpace(space)
                #expect(pinRow(controller, pin.id) == nil)
            }
        }
    }

    @Test func aClosedPageGoesWhenItsFolderIsOpenedAndShutAgain() throws {
        try inWindow { controller, pin, folder in
            try openAndClose(controller, pin, folder, byButton: false)
            controller.listSetFolderOpen(folder.id, true)
            #expect(pinRow(controller, pin.id) != nil)
            controller.listSetFolderOpen(folder.id, false)
            #expect(pinRow(controller, pin.id) == nil)
            // Expand All and Collapse All count as opening and shutting it too.
            try openAndClose(controller, pin, folder, byButton: false)
            controller.setAllFoldersOpen(in: space, true)
            controller.setAllFoldersOpen(in: space, false)
            #expect(pinRow(controller, pin.id) == nil)
        }
    }

    @Test func anotherFolderOpenedOrShutKeepsTheClosedPage() throws {
        try inWindow { controller, pin, folder in
            let elsewhere = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/shut/other")!, title: "Other", to: space))
            let second = try #require(Library.shared.addFolder(named: "Second", with: [elsewhere.id], in: space))
            try openAndClose(controller, pin, folder, byButton: false)
            controller.listSetFolderOpen(second.id, false)
            controller.listSetFolderOpen(second.id, true)
            #expect(pinRow(controller, pin.id) != nil)
        }
    }
}

/// Big imports and folder-wide actions (#343): imported folders start shut, a space's folders fold at once, and
/// Open All in Tabs opens the pages as new tabs.
@MainActor
struct FolderBulkTests {
    /// The first space with pages filed by these paths, as an import does; the library is restored after.
    private func inSpace(_ paths: [[String]], _ body: @MainActor (UUID, [Bookmark]) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let pages = Library.shared.appendBookmarks(paths.indices.map { (URL(string: "http://127.0.0.1:9/bulk/\($0)")!, "P\($0)") }, to: space, folders: paths)
        try body(space, pages)
    }

    @Test func importedFoldersStartShutAndYoursStayOpen() {
        let mine = BookmarkFolder(name: "Mine")
        let folders = Library.filed([UUID(), UUID()], paths: [["Mine", "Inner"], ["New"]], into: [mine])
        #expect(folders.first { $0.id == mine.id }?.isOpen == true)
        #expect(folders.filter { $0.id != mine.id }.map(\.name).sorted() == ["Inner", "New"])
        #expect(folders.filter { $0.id != mine.id }.allSatisfy { !$0.isOpen })
    }

    @Test func aSpacesFoldersFoldAtOnceWithTheMenuOfferingOnlyWhatChanges() throws {
        try inSpace([["A"], ["A", "B"], ["C"]]) { space, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            @MainActor func titles() -> [String] { SidebarMenus.spaceMenu(for: space, controller: controller).items.map(\.title) }
            #expect(Library.shared.folders(in: space).allSatisfy { !$0.isOpen })
            #expect(titles().contains(SidebarMenus.expandAllFoldersTitle) && !titles().contains(SidebarMenus.collapseAllFoldersTitle))

            controller.setAllFoldersOpen(in: space, true)
            #expect(Library.shared.folders(in: space).allSatisfy { $0.isOpen && $0.tucked == nil })
            #expect(titles().contains(SidebarMenus.collapseAllFoldersTitle) && !titles().contains(SidebarMenus.expandAllFoldersTitle))
            let view = NSMenuItem(title: "", action: #selector(BrowserWindowController.collapseAllFolders(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(view))

            controller.collapseAllFolders(view)
            #expect(Library.shared.folders(in: space).allSatisfy { !$0.isOpen })
            #expect(!controller.validateMenuItem(view))
        }
    }

    @Test func openAllOpensThePagesAsNewTabsInOrderAndUndoes() throws {
        try inSpace([["Work"], ["Work", "Docs"], ["Other"], ["Work"]]) { space, pages in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let existing = Tab(url: URL(string: "http://127.0.0.1:9/bulk/here")!, title: "Here", spaceID: space)
            manager.adopt([existing], in: space)
            manager.select(existing)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            let work = try #require(Library.shared.folders(in: space).first { $0.name == "Work" })

            controller.openAllInTabs(work.id)
            let opened = manager.currentTabs.filter { $0 !== existing }
            // Regular tabs side by side, in the folder's list order, the folder inside it too.
            let inWork = Library.shared.allBookmarkIDs(inFolder: work.id).compactMap { Library.shared.bookmark($0)?.url }
            #expect(Set(inWork) == Set([pages[0], pages[1], pages[3]].map(\.url)))
            #expect(opened.map(\.url) == inWork)
            #expect(opened.allSatisfy { $0.bookmarkID == nil })
            let at = try #require(manager.currentTabs.firstIndex { $0 === opened.first })
            #expect(Array(manager.currentTabs[at...].prefix(3)).map(\.id) == opened.map(\.id))
            // The first shows; the rest are loading already.
            #expect(manager.selectedTab === opened.first)
            #expect(opened.allSatisfy { $0.webView != nil })
            // The pinned pages stay as they were.
            #expect(pages.allSatisfy { manager.bookmarkTab(for: $0.id) == nil })

            controller.sidebarUndo.undo()
            #expect(manager.currentTabs.map(\.id) == [existing.id])
        }
    }

    /// ⌘Z with an undo group still open inside another (page text editing can leave one) is skipped, not an
    /// exception that quits Zigzag.
    @Test func undoWithAGroupLeftOpenIsSkippedNotACrash() {
        let undo = WindowUndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: undo) { _ in }
        undo.beginUndoGrouping()
        undo.undo()
        undo.redo()
        #expect(undo.groupingLevel == 2)
        undo.endUndoGrouping()
        undo.endUndoGrouping()
        #expect(undo.canUndo)
    }

}

import AppKit
import Testing
@testable import Zigzag

/// The whole move, not only the resolver: the pointer resolves a drop, the one place transaction changes the pages,
/// the folders and their places together, and the list draws the result. Each test is a case the user met, in the
/// order they met it (docs/plans/sidebar-regression-recovery.md, "What the user expects").
///
/// One `moved` call is one tree: the library applies it as one change, so one ⌘Z takes back all of it. A drop that
/// leaves the rows as they were answers nil, which is the only case that records no undo step at all.
@MainActor
struct SidebarPlaceTests {
    // MARK: 1. A split row at the top

    /// The split dragged to the very top, above both New Folders. It stays one row, Reading and Work stay below it, and
    /// neither empty folder moves to the bottom.
    @Test func aSplitAtTheTopKeepsBothEmptyFoldersInOrder() throws {
        var tree = PinnedDropFixture.acceptance()
        let s1 = SidebarItem.bookmark(try tree.pageID("S1"))
        let first = SidebarItem.folder(try tree.folderID("New Folder 1"))
        let second = SidebarItem.folder(try tree.folderID("New Folder 2"))
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        #expect(tree.names() == ["[New Folder 1]", "[New Folder 2]", "S1|S2", "[Reading]",
                                 "R1", "R2", "R3", "R4", "R5", "R6", "[Work]", "W1", "W2"])

        // Above the first row: the top of the section.
        #expect(tree.apply(s1, at: try tree.point(in: first, .above, x: 0)))
        #expect(tree.names() == ["S1|S2", "[New Folder 1]", "[New Folder 2]", "[Reading]",
                                 "R1", "R2", "R3", "R4", "R5", "R6", "[Work]", "W1", "W2"])
        // The split is one row, both its pages are in it, and both empty folders are still there, in their order.
        let rows = tree.rows.map(\.item)
        let s2 = try tree.pageID("S2")
        #expect(!rows.contains(.bookmark(s2)))
        #expect(rows.firstIndex(of: first)! < rows.firstIndex(of: second)!)
        #expect(rows.firstIndex(of: reading)! < rows.firstIndex(of: work)!)
    }

    // MARK: 2. A split row dropped at the same place

    /// Dropped where it already is, the split changes nothing at all: the same rows, the same stored tree, and no
    /// change for the caller to record.
    @Test func aSplitDroppedWhereItIsChangesNothing() throws {
        var tree = PinnedDropFixture.acceptance()
        let s1 = SidebarItem.bookmark(try tree.pageID("S1"))
        let second = SidebarItem.folder(try tree.folderID("New Folder 2"))
        let before = tree.place
        let names = tree.names()

        // The gap just above the split's own row.
        #expect(!tree.apply(s1, at: try tree.point(in: second, .below, x: 0)))
        #expect(tree.place == before)
        #expect(tree.names() == names)
    }

    // MARK: 3. A split row below a lone page

    /// From the top to the gap below a lone page: the split goes straight under that page, and the folder block below
    /// does not swallow it.
    @Test func aSplitBelowALonePageLandsRightUnderIt() throws {
        var tree = PinnedDropFixture()
        let s1 = tree.page("S1"), s2 = tree.page("S2")
        tree.split(s1, s2)
        let f = tree.page("F")
        let b = tree.page("B"), c = tree.page("C")
        tree.folder("Docs", holding: [b, c])
        #expect(tree.names() == ["S1|S2", "F", "[Docs]", "B", "C"])

        #expect(tree.apply(.bookmark(s1), at: try tree.point(in: .bookmark(f), .below, x: 0)))
        #expect(tree.names() == ["F", "S1|S2", "[Docs]", "B", "C"])
        let rows = tree.rows.map(\.item)
        #expect(rows[rows.firstIndex(of: .bookmark(f))! + 1] == .bookmark(s1))
    }

    // MARK: 4. A split row inside an empty folder between folders

    /// Onto the empty folder's middle: the split goes inside it, the folder keeps its place between the two folders,
    /// and no other folder moves.
    @Test func aSplitOntoAnEmptyFolderBetweenFoldersStaysThere() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), b = tree.page("B")
        tree.folder("Folder A", holding: [a])
        let empty = tree.folder("Empty")
        let folderB = tree.folder("Folder B", holding: [b])
        let s1 = tree.page("S1"), s2 = tree.page("S2")
        tree.split(s1, s2)
        tree.setRank(empty, to: 0.5)
        tree.setRank(folderB, to: 0.75)
        #expect(tree.names() == ["[Folder A]", "A", "[Empty]", "[Folder B]", "B", "S1|S2"])

        #expect(tree.apply(.bookmark(s1), at: try tree.point(in: .folder(empty), .onto)))
        #expect(tree.names() == ["[Folder A]", "A", "[Empty]", "S1|S2", "[Folder B]", "B"])
        let kept = try #require(tree.folders.first { $0.id == empty })
        #expect(kept.parentID == nil)
        #expect(kept.bookmarkIDs == [s1, s2])
    }

    // MARK: 5. A folder above and below an empty folder inside Reading

    /// Docs into Reading, above the empty New Folder: Docs goes above it, one change. Below it: Docs goes below it.
    /// The empty folder does not cross to the other side either way.
    @Test func docsAboveAndBelowTheEmptyFolderInsideReading() throws {
        func makeTree() throws -> (PinnedDropFixture, UUID, UUID, UUID) {
            var tree = PinnedDropFixture()
            let b = tree.page("B"), c = tree.page("C")
            tree.folder("Docs", holding: [b, c])
            let r1 = tree.page("R1"), r2 = tree.page("R2"), r3 = tree.page("R3")
            let reading = tree.folder("Reading", holding: [r1, r2, r3])
            let empty = tree.folder("New Folder", parent: reading)
            tree.setRank(empty, to: 4.5)
            return (tree, reading, empty, try tree.folderID("Docs"))
        }
        do {
            var (tree, _, empty, docs) = try makeTree()
            #expect(tree.names() == ["[Docs]", "B", "C", "[Reading]", "R1", "R2", "R3", "[New Folder]"])
            #expect(tree.apply(.folder(docs), at: try tree.point(in: .folder(empty), .above, x: 0)))
            #expect(tree.names() == ["[Reading]", "R1", "R2", "R3", "[Docs]", "B", "C", "[New Folder]"])
        }
        do {
            var (tree, _, empty, docs) = try makeTree()
            #expect(tree.apply(.folder(docs), at: try tree.point(in: .folder(empty), .below, x: 0)))
            #expect(tree.names() == ["[Reading]", "R1", "R2", "R3", "[New Folder]", "[Docs]", "B", "C"])
        }
    }

    // MARK: 6. A New Folder dropped between R4 and R5 inside Reading

    /// The user's last screenshot: the fresh empty folder into the gap between R4 and R5. It lands exactly there. The
    /// split at the top, the other New Folder, Reading, Work and every other row keep their places, and one change puts
    /// it all in place.
    @Test func aNewFolderBetweenR4AndR5StaysInsideReading() throws {
        var tree = PinnedDropFixture.acceptance()
        let movedID = try tree.folderID("New Folder 2")
        let moved = SidebarItem.folder(movedID)
        let kept = SidebarItem.folder(try tree.folderID("New Folder 1"))
        let split = SidebarItem.bookmark(try tree.pageID("S1"))
        let readingID = try tree.folderID("Reading")
        let reading = SidebarItem.folder(readingID)
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let r4 = SidebarItem.bookmark(try tree.pageID("R4")), r5 = SidebarItem.bookmark(try tree.pageID("R5"))
        let before = tree.rows.map(\.item)

        #expect(tree.apply(moved, at: try tree.point(in: r5, .above, x: SidebarListView.indent(depth: 1))))
        #expect(tree.names() == ["[New Folder 1]", "S1|S2", "[Reading]", "R1", "R2", "R3", "R4",
                                 "[New Folder 2]", "R5", "R6", "[Work]", "W1", "W2"])
        // The folder is inside Reading, with a place between R4 and R5.
        let folder = try #require(tree.folders.first { $0.id == movedID })
        #expect(folder.parentID == readingID)
        let after = tree.rows.map(\.item)
        let r4At = try #require(after.firstIndex(of: r4))
        #expect(after[r4At + 1] == moved)
        #expect(after[r4At + 2] == r5)
        // Every row that was not the moved folder is still there, the split still one row, and the kept rows keep
        // their order.
        let unchanged = before.filter { $0 != moved }
        let expected = [kept, split, reading, work]
        #expect(expected.allSatisfy { unchanged.contains($0) })
        for offset in 1..<expected.count {
            let previous = try #require(unchanged.firstIndex(of: expected[offset - 1]))
            let item = try #require(unchanged.firstIndex(of: expected[offset]))
            #expect(previous < item)
        }
    }

    // MARK: 7. Several empty folders with the same name

    /// Both stay, one row each, in their order. A page put above one of them goes above both, so neither vanishes
    /// behind the other and neither is drawn twice.
    @Test func twoEmptyFoldersWithTheSameNameStayApartAndInOrder() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), b = tree.page("B")
        let one = tree.folder("New Folder")
        let two = tree.folder("New Folder")
        tree.setRank(one, to: -2.5)
        tree.setRank(two, to: -1.5)
        #expect(tree.names() == ["[New Folder]", "[New Folder]", "A", "B"])

        #expect(tree.apply(.bookmark(a), at: try tree.point(in: .folder(one), .above, x: 0)))
        #expect(tree.rows.map(\.item) == [.bookmark(a), .folder(one), .folder(two), .bookmark(b)])
        #expect(tree.folders.count == 2)
        #expect(tree.folders.filter { $0.name == "New Folder" }.count == 2)
        // Their places are different, and in their order: neither shares the other's spot.
        let oneRank = try #require(tree.folders.first { $0.id == one }?.rank)
        let twoRank = try #require(tree.folders.first { $0.id == two }?.rank)
        #expect(oneRank < twoRank)
    }

    /// A page put between the two of them splits neither of them off the list: both stay on one side each, in order,
    /// and no folder is drawn twice.
    @Test func aPageBetweenTwoEmptyFoldersKeepsBothVisible() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), b = tree.page("B")
        let one = tree.folder("New Folder")
        let two = tree.folder("New Folder")
        tree.setRank(one, to: -2.5)
        tree.setRank(two, to: -1.5)
        #expect(tree.apply(.bookmark(b), at: try tree.point(in: .folder(two), .above, x: 0)))
        let rows = tree.rows.map(\.item)
        #expect(rows == [.folder(one), .bookmark(b), .folder(two), .bookmark(a)])
        #expect(Set(rows.filter { if case .folder = $0 { true } else { false } }) == [.folder(one), .folder(two)])
    }

    // MARK: The line and the transaction

    /// A page dropped above an empty folder goes above it, and the folder moves below the page in the same change: the
    /// old "raised folder" case, now part of the one transaction.
    @Test func aPageAboveAnEmptyFolderPutsTheFolderBelowIt() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), b = tree.page("B")
        let empty = tree.folder("Empty")
        tree.folder("Work", holding: [a])
        tree.page("F")
        tree.page("G")
        #expect(tree.names() == ["[Empty]", "[Work]", "A", "B", "F", "G"])

        #expect(tree.apply(.bookmark(b), at: try tree.point(in: .folder(empty), .above, x: 0)))
        let rows = tree.rows.map(\.item)
        #expect(rows.firstIndex(of: .bookmark(b))! < rows.firstIndex(of: .folder(empty))!)
    }

    /// A drop that changes nothing answers nil, the caller's signal that there is nothing to record. A drop that
    /// changes something answers the whole tree at once: the pages, every folder's parent and every place.
    @Test func theTransactionIsOneAnswerOrNone() throws {
        var tree = PinnedDropFixture.acceptance()
        let s1 = SidebarItem.bookmark(try tree.pageID("S1"))
        let second = SidebarItem.folder(try tree.folderID("New Folder 2"))
        let r5 = SidebarItem.bookmark(try tree.pageID("R5"))
        let before = tree.place

        let same = try #require(tree.drop(try tree.point(in: second, .below, x: 0), carrying: s1))
        #expect(tree.place.moved(s1, to: same) == nil)
        #expect(tree.place == before)

        let change = try #require(tree.drop(try tree.point(in: r5, .above, x: SidebarListView.indent(depth: 1)),
                                            carrying: .folder(try tree.folderID("New Folder 2"))))
        let after = try #require(tree.place.moved(.folder(try tree.folderID("New Folder 2")), to: change))
        #expect(after.pages != before.pages || after.folders != before.folders)
        #expect(after.splits == before.splits)
    }

    /// The rows the list draws come from the same folders the transaction wrote, so a folder's place is one number on
    /// one line: no row is drawn twice and no page is lost.
    @Test func aMoveLosesNoRowAndDrawsNoneTwice() throws {
        var tree = PinnedDropFixture.standard()
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let before = Set(tree.rows.map(\.item))
        let folders = tree.folders.count
        #expect(tree.apply(reading, at: try tree.point(in: work, .above, x: 0)))
        let after = tree.rows.map(\.item)
        #expect(Set(after) == before)
        #expect(after.count == Set(after).count)
        #expect(tree.folders.count == folders)
    }
}

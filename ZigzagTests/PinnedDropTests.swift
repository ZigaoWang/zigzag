import AppKit
import Testing
@testable import Zigzag

/// The pinned tree the drop resolver is tested against. It has open, shut, empty and five-deep folders, a pinned split
/// and a top-level page. Rows are laid out the way the list lays them out, so a test can place a pointer by row and band.
/// The resolver takes a small tree, with no window and no `Library.shared`.
@MainActor
struct PinnedDropFixture {
    struct Page {
        let id: UUID
        let title: String
    }

    private(set) var pages: [Page] = []
    private(set) var folders: [BookmarkFolder] = []
    private(set) var splits: [PinnedSplit] = []

    // MARK: Building

    @discardableResult
    mutating func page(_ title: String) -> UUID {
        let id = UUID()
        pages.append(Page(id: id, title: title))
        return id
    }

    @discardableResult
    mutating func folder(_ name: String, parent: UUID? = nil, open: Bool = true, holding contents: [UUID] = []) -> UUID {
        var folder = BookmarkFolder(name: name, bookmarkIDs: contents)
        folder.parentID = parent
        folder.isOpen = open
        folders.append(folder)
        return folder.id
    }

    mutating func split(_ left: UUID, _ right: UUID) {
        splits.append(PinnedSplit(left: left, right: right))
    }

    /// Work is open and holds A, E, and the subfolders Docs (B, C) and Old (D). Reading is open and holds R1 to R12.
    /// Shut is shut and holds X1 and X2. Empty has no pages. A chain five folders deep ends in P. F is a top-level page,
    /// and S1 sits beside S2 as a pinned split.
    static func standard() -> PinnedDropFixture {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), e = tree.page("E"), b = tree.page("B"), c = tree.page("C"), d = tree.page("D")
        let work = tree.folder("Work", holding: [a, e])
        tree.folder("Docs", parent: work, holding: [b, c])
        tree.folder("Old", parent: work, holding: [d])
        let reading = (1...12).map { tree.page("R\($0)") }
        tree.folder("Reading", holding: reading)
        let shut = (1...2).map { tree.page("X\($0)") }
        tree.folder("Shut", open: false, holding: shut)
        tree.folder("Empty")
        tree.page("F")
        let s1 = tree.page("S1"), s2 = tree.page("S2")
        tree.split(s1, s2)
        let p = tree.page("P")
        var parent: UUID?
        for depth in 1...5 {
            parent = tree.folder("Deep\(depth)", parent: parent, holding: depth == 5 ? [p] : [])
        }
        return tree
    }

    // MARK: Lookups

    func pageID(_ title: String) throws -> UUID { try #require(pages.first { $0.title == title }?.id) }

    func folderID(_ name: String) throws -> UUID { try #require(folders.first { $0.name == name }?.id) }

    mutating func setRank(_ folder: UUID, to rank: Double) {
        guard let at = folders.firstIndex(where: { $0.id == folder }) else { return }
        folders[at].rank = rank
    }

    func row(_ item: SidebarItem) throws -> DropRow { try #require(rows.first { $0.item == item }) }

    // MARK: What the list shows

    /// The pages that ride in a split's row and so have no row of their own.
    var riders: Set<UUID> { Set(splits.flatMap(\.riders)) }

    /// The visible rows, top to bottom: each set in by its depth, `rowGap` apart, starting at the top of the section.
    var rows: [DropRow] {
        let shown = SidebarListView.pinnedRows(bookmarks: pages.map(\.id), folders: folders, riders: riders,
                                               current: nil, isOpen: { _ in false })
        var y: CGFloat = 0
        var result: [DropRow] = []
        for item in shown.rows {
            let depth = shown.depth[item] ?? 0
            let inset = SidebarListView.indent(depth: depth)
            let frame = NSRect(x: inset, y: y, width: 240 - inset, height: item.height)
            result.append(DropRow(item: item, frame: frame, depth: depth))
            y += item.height + Tokens.Sidebar.rowGap
        }
        return result
    }

    /// A point in one of a row's bands. `above` is its top quarter, `onto` its middle half, and `below` its bottom
    /// quarter. `x` defaults to the row's own text.
    func point(in item: SidebarItem, _ band: RowBand, x: CGFloat? = nil) throws -> NSPoint {
        let row = try row(item)
        let y: CGFloat = switch band {
        case .above: row.frame.minY + row.frame.height * 0.1
        case .onto: row.frame.midY
        case .below: row.frame.maxY - row.frame.height * 0.1
        }
        return NSPoint(x: x ?? row.frame.minX + SidebarListView.folderIndent, y: y)
    }

    // MARK: What goes with a picked-up row

    /// The rows that leave the list with `item`. A folder takes its pages and subfolders, and a split takes its other
    /// half.
    func carried(_ item: SidebarItem) -> Set<SidebarItem> {
        var set: Set<SidebarItem> = [item]
        switch item {
        case .folder(let id):
            set.formUnion(folders.pages(in: id).map(SidebarItem.bookmark))
            set.formUnion(folders.descendants(of: id).map(SidebarItem.folder))
        case .bookmark(let id):
            set.formUnion((splits.first { $0.ids.contains(id) }?.ids ?? []).map(SidebarItem.bookmark))
        default:
            break
        }
        return set
    }

    /// The pinned pages in list order, without the ones that leave with the carried rows.
    func order(without carried: Set<SidebarItem> = []) -> [UUID] {
        var moving: Set<UUID> = []
        for item in carried {
            switch item {
            case .bookmark(let id): moving.formUnion(splits.first { $0.ids.contains(id) }?.ids ?? [id])
            case .folder(let id): moving.formUnion(folders.pages(in: id))
            default: break
            }
        }
        return pages.map(\.id).filter { !moving.contains($0) }
    }

    /// The resolver's answer for `item` picked up and the pointer at `point`.
    func drop(_ point: NSPoint, carrying item: SidebarItem) -> SidebarDrop? {
        snapshot(carrying: item).drop(at: point)
    }

    /// The snapshot a drag of `item` resolves against: the rows on show, the pages left without the ones that leave, and
    /// the folders they sit in. The line reads it too, so the test compares both answers from the same value.
    func snapshot(carrying item: SidebarItem) -> DragSnapshot {
        let leaving = carried(item)
        let kind: DragKind = switch item {
        case .folder: .folder
        case .tabGroup: .group
        default: .page
        }
        let folder: UUID? = if case .folder(let id) = item { id } else { nil }
        return DragSnapshot(rows: rows, order: order(without: leaving), fullOrder: pages.map(\.id), folders: folders,
                            carried: leaving, kind: kind, carriedFolder: folder)
    }
    // MARK: The place transaction

    /// The tree as the place transaction sees it: the pages in list order, the folders and the splits.
    var place: PinnedPlace { PinnedPlace(pages: pages.map(\.id), folders: folders, splits: splits) }

    /// Puts the tree back as a transaction left it. The pages keep their titles.
    mutating func set(_ place: PinnedPlace) {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pages = place.pages.compactMap { byID[$0] }
        folders = place.folders
        splits = place.splits
    }

    /// Applies a drop the way the page does: the resolver answers, then the one place transaction changes the tree.
    /// False: the drop leaves the tree as it was, so nothing changes and no undo step is recorded.
    @discardableResult
    mutating func apply(_ item: SidebarItem, at point: NSPoint) -> Bool {
        guard let drop = self.drop(point, carrying: item), let moved = place.moved(item, to: drop) else { return false }
        set(moved)
        return true
    }

    /// The rows the list shows, top to bottom, as names: a folder's name in brackets, a split's two titles joined.
    func names() -> [String] {
        rows.map(\.item).map { item in
            switch item {
            case .folder(let id): return "[" + (folders.first { $0.id == id }?.name ?? "?") + "]"
            case .bookmark(let id):
                if let split = splits.first(where: { $0.left == id }) {
                    return split.ids.compactMap { page in pages.first { $0.id == page }?.title }.joined(separator: "|")
                }
                return pages.first { $0.id == id }?.title ?? "?"
            default: return "?"
            }
        }
    }

    /// The tree the user's last test had: two empty New Folders, a pinned split above Reading and Work.
    static func acceptance() -> PinnedDropFixture {
        var tree = PinnedDropFixture()
        let s1 = tree.page("S1"), s2 = tree.page("S2")
        tree.split(s1, s2)
        let first = tree.folder("New Folder 1")
        let second = tree.folder("New Folder 2")
        // A place each, as the alphabetical sort leaves them, so their order is the one they show.
        tree.setRank(first, to: -2.5)
        tree.setRank(second, to: -1.5)
        let reading = (1...6).map { tree.page("R\($0)") }
        tree.folder("Reading", holding: reading)
        let work = (1...2).map { tree.page("W\($0)") }
        tree.folder("Work", holding: work)
        return tree
    }
}

/// The pinned drops Phase 0 records. Each is a drag the local test got wrong, and the place it should land. They fail
/// against the Phase 0 stub, which is the point. Phase 1 makes them pass.
@MainActor
struct PinnedDropTests {
    let tree = PinnedDropFixture.standard()

    /// The tree reaches the resolver as rows. The empty folder is at the top, a shut folder is one row, a split is one
    /// row, and the deep chain is set in one step per level.
    @Test func theFixtureShowsItsTreeAsRows() throws {
        let items = tree.rows.map(\.item)
        let empty = try tree.row(.folder(tree.folderID("Empty")))
        let docs = try tree.row(.folder(tree.folderID("Docs")))
        let b = try tree.row(.bookmark(tree.pageID("B")))
        let p = try tree.row(.bookmark(tree.pageID("P")))
        let s1 = try tree.pageID("S1"), s2 = try tree.pageID("S2"), x1 = try tree.pageID("X1")
        #expect(items.first == empty.item)
        #expect(docs.depth == 1)
        #expect(b.depth == 2)
        #expect(p.depth == 5)
        #expect(!items.contains(.bookmark(x1)))
        #expect(items.contains(.bookmark(s1)))
        #expect(!items.contains(.bookmark(s2)))
    }

    /// Reading picked up and held over the top of Work. The drop is a top-level gap above Work, not a gap inside it.
    @Test func aboveAnOpenFolderIsATopLevelGapAboveIt() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        let point = try tree.point(in: work, .above, x: 0)
        let drop = try #require(tree.drop(point, carrying: reading))
        #expect(drop.folder == nil)
        #expect(drop.index == 0)
        #expect(drop.place == .gap(above: empty, below: work, depth: 0))
    }

    /// Held over Work's open children, the gap is inside Work at the row's own step, whatever the pointer's x: the level
    /// comes from the rows, so the line and the drop always agree.
    @Test func overAnOpenFoldersChildrenIsInsideItAtTheRowsLevel() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let workID = try tree.folderID("Work")
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        for x in [CGFloat(0), SidebarListView.indent(depth: 1)] {
            let point = try tree.point(in: a, .above, x: x)
            let drop = try #require(tree.drop(point, carrying: reading))
            #expect(drop.folder == workID)
            #expect(drop.index == 0)
            #expect(drop.place == .gap(above: .folder(workID), below: a, depth: 1))
        }
    }

    /// The same pointer, indented to the children's own step. The gap is inside Work, at the pointer's row.
    @Test func overAnOpenFoldersChildrenIndentedGivesAGapInsideIt() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let workID = try tree.folderID("Work")
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        let point = try tree.point(in: a, .above, x: SidebarListView.indent(depth: 1))
        let drop = try #require(tree.drop(point, carrying: reading))
        #expect(drop.folder == workID)
        #expect(drop.index == 0)
        #expect(drop.place == .gap(above: .folder(workID), below: a, depth: 1))
    }

    /// Docs picked up and held above Work, its own parent. It becomes a top-level folder, not Work's first child.
    @Test func aNestedFolderMovesOutToTheTopLevel() throws {
        let docs = SidebarItem.folder(try tree.folderID("Docs"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        let point = try tree.point(in: work, .above, x: 0)
        let drop = try #require(tree.drop(point, carrying: docs))
        #expect(drop.folder == nil)
        #expect(drop.index == 0)
        #expect(drop.place == .gap(above: empty, below: work, depth: 0))
    }

    /// Work held over its own row, over Docs' row, or in a gap inside its block: what moves takes nothing there.
    @Test func aFolderCannotGoIntoItselfOrADescendant() throws {
        let workID = try tree.folderID("Work"), docsID = try tree.folderID("Docs")
        let work = SidebarItem.folder(workID), docs = SidebarItem.folder(docsID)
        // Over its own row, over a row inside it, and in a gap inside its block, what moves takes nothing: no line,
        // no highlight, and letting go changes nothing.
        #expect(tree.drop(try tree.point(in: work, .onto), carrying: work) == nil)
        #expect(tree.drop(try tree.point(in: docs, .onto), carrying: work) == nil)
        #expect(tree.drop(try tree.point(in: docs, .above), carrying: work) == nil)
    }

    /// A page over the middle of its own row takes nothing, and its own top edge is still the gap above it.
    @Test func aPageOverItsOwnRowTakesNothing() throws {
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        #expect(tree.drop(try tree.point(in: a, .onto), carrying: a) == nil)
        let above = try #require(tree.drop(try tree.point(in: a, .above), carrying: a))
        guard case .gap = above.place else {
            Issue.record("not a gap: \(above.place)")
            return
        }
    }

    /// A shut folder is one row. A drop above it is before all its pages, and one below it is after all of them.
    @Test func aShutFoldersBlockIsOneBlockBeforeAndAfter() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let shut = SidebarItem.folder(try tree.folderID("Shut"))
        let d = SidebarItem.bookmark(try tree.pageID("D"))
        let x1 = try tree.pageID("X1"), f = try tree.pageID("F")
        let order = tree.order(without: tree.carried(reading))
        let x1At = try #require(order.firstIndex(of: x1))
        let fAt = try #require(order.firstIndex(of: f))

        let abovePoint = try tree.point(in: shut, .above, x: 0)
        let above = try #require(tree.drop(abovePoint, carrying: reading))
        #expect(above.folder == nil)
        #expect(above.index == x1At)
        #expect(above.place == .gap(above: d, below: shut, depth: 0))

        let belowPoint = try tree.point(in: shut, .below, x: 0)
        let below = try #require(tree.drop(belowPoint, carrying: reading))
        #expect(below.folder == nil)
        #expect(below.index == fAt)
        #expect(below.place == .gap(above: shut, below: .bookmark(f), depth: 0))
    }

    /// The empty folder shows at the top of the section and takes a drop there. Picked up itself, it moves.
    @Test func anEmptyFolderSitsAtTheTopAndCanBeMoved() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let empty = SidebarItem.folder(try tree.folderID("Empty"))

        let topPoint = try tree.point(in: empty, .above, x: 0)
        let atTop = try #require(tree.drop(topPoint, carrying: reading))
        #expect(atTop.folder == nil)
        #expect(atTop.index == 0)
        #expect(atTop.place == .gap(above: nil, below: empty, depth: 0))

        let f = SidebarItem.bookmark(try tree.pageID("F"))
        let s1ID = try tree.pageID("S1")
        let movedPoint = try tree.point(in: f, .below, x: 0)
        let moved = try #require(tree.drop(movedPoint, carrying: empty))
        let order = tree.order(without: tree.carried(empty))
        let s1At = try #require(order.firstIndex(of: s1ID))
        #expect(moved.folder == nil)
        #expect(moved.index == s1At)
        #expect(moved.place == .gap(above: f, below: .bookmark(s1ID), depth: 0))
    }

    /// A pinned split is one row and two pages. A drop below it lands after both, never between them.
    @Test func aPinnedSplitCountsAsTwoPagesAtItsEnd() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let s1ID = try tree.pageID("S1"), s2ID = try tree.pageID("S2")
        let s1 = SidebarItem.bookmark(s1ID)
        let deep1 = SidebarItem.folder(try tree.folderID("Deep1"))
        let point = try tree.point(in: s1, .below, x: 0)
        let drop = try #require(tree.drop(point, carrying: reading))
        let order = tree.order(without: tree.carried(reading))
        let s1At = try #require(order.firstIndex(of: s1ID))
        #expect(order[s1At + 1] == s2ID)
        #expect(drop.folder == nil)
        #expect(drop.index == s1At + 2)
        #expect(drop.place == .gap(above: s1, below: deep1, depth: 0))
    }

    // MARK: The line and the drop

    /// At every gap the fixture shows, the line and the drop are one answer: the line sits where the drop's index falls,
    /// at the drop's level, with every page above it sorting before the index and every page below it at or after. Run
    /// for a folder drag and a page drag, since each takes its own path through the resolver.
    @Test func theLineAndTheDropAgreeAtEveryGap() throws {
        let readingFolder = SidebarItem.folder(try tree.folderID("Reading"))
        let bPage = SidebarItem.bookmark(try tree.pageID("B"))
        for carried in [readingFolder, bPage] {
            let shown = tree.snapshot(carrying: carried)
            let order = tree.order(without: tree.carried(carried))
            let gap = Tokens.Sidebar.rowGap
            /// The order positions a row shows: a page, or a split's two.
            func places(_ item: SidebarItem) -> [Int] {
                guard case .bookmark(let id) = item else { return [] }
                let ids = tree.splits.first { $0.ids.contains(id) }?.ids ?? [id]
                return ids.compactMap { order.firstIndex(of: $0) }
            }
            for row in shown.rows where !shown.carried.contains(row.item) {
                for band in [RowBand.above, .below] {
                    let point = NSPoint(x: 0, y: band == .above ? row.frame.minY + row.frame.height * 0.1
                                                              : row.frame.maxY - row.frame.height * 0.1)
                    let drop = try #require(shown.drop(at: point), "\(row.item) \(band): no drop")
                    guard case .gap(_, _, let depth) = drop.place else {
                        Issue.record("\(row.item) \(band): a row's edge is a gap, not \(drop.place)")
                        continue
                    }
                    let line = try #require(shown.line(for: drop, rowGap: gap), "\(row.item) \(band): no line")
                    #expect(line.depth == depth)
                    for other in shown.rows where !shown.carried.contains(other.item) {
                        let at = places(other.item)
                        guard let first = at.min(), let last = at.max() else { continue }
                        if other.frame.maxY < line.y {
                            #expect(last < drop.index, "\(row.item) \(band): \(other.item) above the line sorts after \(drop.index)")
                        } else if other.frame.minY > line.y {
                            #expect(first >= drop.index, "\(row.item) \(band): \(other.item) below the line sorts before \(drop.index)")
                        }
                    }
                }
            }
        }
    }

    /// A page held over the top of R4 (the local test's held drag): the line sits just above R4, inside Reading, and the
    /// drop lands at R4's place. Before Phase 2 the line showed one row below the pointer.
    @Test func aPageHeldOverTheTopOfR4ShowsItsLineAboveIt() throws {
        let b = SidebarItem.bookmark(try tree.pageID("B"))
        let r3 = SidebarItem.bookmark(try tree.pageID("R3")), r4 = SidebarItem.bookmark(try tree.pageID("R4"))
        let readingID = try tree.folderID("Reading")
        let shown = tree.snapshot(carrying: b)
        let point = try tree.point(in: r4, .above, x: SidebarListView.indent(depth: 1))
        let drop = try #require(shown.drop(at: point))
        let order = tree.order(without: tree.carried(b))
        let r4At = try #require(order.firstIndex(of: try tree.pageID("R4")))
        #expect(drop.folder == readingID)
        #expect(drop.index == r4At)
        #expect(drop.place == .gap(above: r3, below: r4, depth: 1))
        let line = try #require(shown.line(for: drop, rowGap: Tokens.Sidebar.rowGap))
        let frame = try tree.row(r4).frame
        #expect(line.y == frame.minY - Tokens.Sidebar.rowGap / 2)
        #expect(line.depth == 1)
    }

    // MARK: The five folder drags from the local test

    // The tree is the local test's; the window heights are not, so each drag is placed by the row and band it aimed at.
    // Each one used to land inside a folder, or below the pointer. Each now lands at the gap it aimed at.

    /// Reading above Work, over Work's name. It becomes a top-level folder above Work, not Work's first child.
    @Test func readingDroppedAboveWorkLandsAboveIt() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        let drop = try #require(tree.drop(try tree.point(in: work, .above, x: 100), carrying: reading))
        #expect(drop.folder == nil)
        #expect(drop.index == 0)
        #expect(drop.place == .gap(above: empty, below: work, depth: 0))
    }

    /// Reading dropped on the bottom strip of Work's row, over the name. It becomes Work's neighbour just after Work's
    /// whole block, not Work's child at the end. That was the local test's second drag.
    @Test func readingDroppedBelowWorkLandsAfterIt() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let x1ID = try tree.pageID("X1")
        let order = tree.order(without: tree.carried(reading))
        let x1At = try #require(order.firstIndex(of: x1ID))
        let drop = try #require(tree.drop(try tree.point(in: work, .below, x: 100), carrying: reading))
        #expect(drop.folder == nil)
        #expect(drop.index == x1At)
    }

    /// The same drag pressed 21 points in, as the local test found it had to be. The strip decides now, so the edge and
    /// the name give the same place.
    @Test func readingDroppedBelowWorkAtTheLeftEdgeLandsInTheSamePlace() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let atName = try #require(tree.drop(try tree.point(in: work, .below, x: 100), carrying: reading))
        let atEdge = try #require(tree.drop(try tree.point(in: work, .below, x: 21), carrying: reading))
        #expect(atEdge == atName)
        #expect(atEdge.folder == nil)
    }

    /// Docs above Work, its own parent, over Work's name. It leaves Work: a top-level gap above Work.
    @Test func docsDroppedAboveWorkLeavesTheFolder() throws {
        let docs = SidebarItem.folder(try tree.folderID("Docs"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        let drop = try #require(tree.drop(try tree.point(in: work, .above, x: 100), carrying: docs))
        #expect(drop.folder == nil)
        #expect(drop.index == 0)
        #expect(drop.place == .gap(above: empty, below: work, depth: 0))
    }

    /// Work onto the middle of Reading's row. The whole row used to catch it; now the middle half does, and it goes in
    /// at the end of Reading.
    @Test func workDroppedOnReadingsMiddleGoesInsideAtItsEnd() throws {
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let readingID = try tree.folderID("Reading")
        let x1ID = try tree.pageID("X1")
        let order = tree.order(without: tree.carried(work))
        let x1At = try #require(order.firstIndex(of: x1ID))
        let drop = try #require(tree.drop(try tree.point(in: reading, .onto), carrying: work))
        #expect(drop.folder == readingID)
        #expect(drop.index == x1At)
        #expect(drop.place == .onto(reading))
    }

    /// A folder row's top and bottom strips are the gaps above and below it across the whole row: over its name, or at
    /// its left edge, a dragged folder is its neighbour. The middle strip is the only place that goes inside.
    @Test func aFolderRowsStripsAreTheGapsAboveAndBelowIt() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let atName = try #require(tree.drop(try tree.point(in: work, .below, x: 100), carrying: reading))
        let atEdge = try #require(tree.drop(try tree.point(in: work, .below, x: 0), carrying: reading))
        let aboveName = try #require(tree.drop(try tree.point(in: work, .above, x: 100), carrying: reading))
        let aboveEdge = try #require(tree.drop(try tree.point(in: work, .above, x: 0), carrying: reading))
        #expect(atName == atEdge)
        #expect(aboveName == aboveEdge)
        #expect(atName.folder == nil && aboveName.folder == nil)
    }

    /// A folder's stored place puts it anywhere among its parent's children, with or without pages, and the list draws
    /// by it. Without a place, an empty folder is at the top and a folder with pages is at its first page.
    @Test func aStoredPlaceLetsAFolderSitAnywhere() throws {
        var tree = PinnedDropFixture.standard()
        let empty = try tree.folderID("Empty")
        let docs = try tree.folderID("Docs")
        let workID = try tree.folderID("Work")
        func names() -> [String] {
            SidebarListView.pinnedRows(bookmarks: tree.pages.map(\.id), folders: tree.folders, riders: tree.riders,
                                       current: nil, isOpen: { _ in false }).rows.compactMap {
                switch $0 {
                case .folder(let id): tree.folders.first { $0.id == id }?.name
                case .bookmark(let id): tree.pages.first { $0.id == id }?.title
                default: nil
                }
            }
        }
        // No place yet: the empty folder is at the top of the section, and Docs at its first page inside Work.
        let start = names()
        #expect(start.first == "Empty")
        let workAt = try #require(start.firstIndex(of: "Work"))
        #expect(start[workAt + 1] == "A")
        // Given a place, an empty folder goes anywhere, even after every page.
        tree.setRank(empty, to: Double(tree.pages.count) + 0.5)
        #expect(names().last == "Empty")
        // And a folder with pages can be put above its siblings, without moving its pages.
        tree.setRank(docs, to: -10)
        let placed = names()
        let workNow = try #require(placed.firstIndex(of: "Work"))
        #expect(placed[workNow + 1] == "Docs")
        #expect(placed[(placed.firstIndex(of: "Docs") ?? 0) + 1] == "B")
        _ = workID
    }

    /// A page's place and a folder's place are on one number line, so a drop can land above a folder that has no pages.
    @Test func anEmptyFoldersPlaceIsOnThePagesLine() throws {
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        let snapshot = tree.snapshot(carrying: reading)
        let emptyKey = try #require(snapshot.place(of: empty))
        let aKey = try #require(snapshot.place(of: a))
        // Empty sits before the first page at the top level, so a folder dropped above it has room to sit below that key.
        #expect(emptyKey < aKey)
        // Above the folder that holds that page, the drop has two different keys to sit between. With one key for both,
        // a folder dropped between them landed above the empty folder instead of between it and Work.
        let workKey = try #require(snapshot.place(of: work))
        #expect(emptyKey < workKey)
        let drop = try #require(tree.drop(try tree.point(in: empty, .above, x: 0), carrying: reading))
        #expect(drop.folder == nil)
        #expect(drop.place == .gap(above: nil, below: empty, depth: 0))
    }

    /// A stored place is on the full page line. A drag takes pages out, so the place moves with them: an empty folder
    /// between R6 and R7 stays there after B and C leave, at the reduced index, not at its full-line rank.
    @Test func anEmptyFoldersStoredPlaceMovesWithCarriedPages() throws {
        var tree = PinnedDropFixture.standard()
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        tree.setRank(try tree.folderID("Empty"), to: 10.5)
        let snapshot = tree.snapshot(carrying: .folder(try tree.folderID("Docs")))
        #expect(snapshot.place(of: empty) == 8.5)
    }

    /// The alphabetical sort puts every folder before the first page, so its ranks are negative. A drag must keep
    /// those places apart: collapsing each to -0.5 put two folders at the top in one spot, and a folder dropped in
    /// the seam between them landed below both.
    @Test func negativeStoredPlacesStayApartForADrag() throws {
        var tree = PinnedDropFixture.standard()
        let first = try tree.folderID("Empty")
        let second = tree.folder("Empty 2")
        tree.setRank(first, to: -2.5)
        tree.setRank(second, to: -1.5)
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let snapshot = tree.snapshot(carrying: reading)
        #expect(snapshot.place(of: .folder(first)) == -2.5)
        #expect(snapshot.place(of: .folder(second)) == -1.5)
        let seam = try tree.drop(tree.point(in: .folder(second), .above, x: 0), carrying: reading)
        let drop = try #require(seam)
        #expect(drop.folder == nil)
        #expect(drop.place == .gap(above: .folder(first), below: .folder(second), depth: 0))
        // Above the first of them there is still room for a folder: its place is not one shared -0.5.
        let above = tree.snapshot(carrying: reading)
        let firstPlace = try #require(above.place(of: .folder(first)))
        #expect(firstPlace < -1.5)
    }

}

import AppKit

/// What a drag carries, for the resolver. A folder goes in among folders, a page among pages, a group like a page.
nonisolated enum DragKind: Equatable {
    case folder
    case page
    case group
}

/// Where a drop lands. The place is the gap the line draws at, or the row that takes it whole.
nonisolated enum SidebarDropPlace: Equatable {
    /// A gap between two rows. `above` nil is the top of the section, and `below` nil is the end.
    case gap(above: SidebarItem?, below: SidebarItem?, depth: Int)
    /// The row itself takes the drop. It is a folder row or a split.
    case onto(SidebarItem)
}

/// One resolved target, made once per pointer position. The line and the drop both read it.
nonisolated struct SidebarDrop: Equatable {
    var section: SidebarListView.Section
    /// Pinned: index in the space's pages without the carried ones. Tabs: index in the tab list without the moving ones.
    var index: Int
    /// Destination folder for pinned rows. Nil is the top level.
    var folder: UUID?
    /// How the line or highlight is drawn.
    var place: SidebarDropPlace
}

/// A row as the resolver sees it. It has what the row shows, where it sits in the list's own coordinates, and how far
/// in it is set.
nonisolated struct DropRow: Equatable {
    var item: SidebarItem
    var frame: NSRect
    var depth: Int
}

/// Where a gap's line draws: the edge it sits at, in the rows' own coordinates, and how far in it is set.
nonisolated struct DropLine: Equatable {
    var y: CGFloat
    /// The gap's level: how far in the line is set, one step per folder.
    var depth: Int
}

/// The three parts of a row a drop can read. They are the gap above it, the row itself, and the gap below it.
nonisolated enum RowBand: Equatable {
    case above
    case onto
    case below

    /// The strip at a folder row's top and bottom that is the gap above and below it, in points. A folder's row is
    /// nearly all "inside it": dropping on its name means inside, and only the edge nearest a gap means the gap.
    static let folderEdge: CGFloat = 4

    /// The band of a row the pointer is in. With no `edge`, the top quarter, the middle half and the bottom quarter.
    /// A folder row passes `folderEdge`, so its row is mostly inside and only its very edge is a gap.
    nonisolated static func band(of point: NSPoint, in frame: NSRect, edge: CGFloat? = nil) -> RowBand {
        let strip = edge ?? frame.height * 0.25
        if point.y < frame.minY + strip { return .above }
        if point.y > frame.maxY - strip { return .below }
        return .onto
    }
}

/// Everything a pinned drag needs to resolve a pointer, worked out once per drag. It holds the rows on show, the page
/// order without the carried pages, and the maps over them, so a mouse move only searches and compares.
nonisolated struct DragSnapshot {
    /// The pinned rows on show, top to bottom, frames as the list has them. The carried rows are still here: they sit
    /// faint in their places, and the resolver steps over them.
    let rows: [DropRow]
    /// The space's pinned pages in list order, without the carried ones.
    let order: [UUID]
    let folders: [BookmarkFolder]
    let carried: Set<SidebarItem>
    let kind: DragKind
    /// The folder being dragged: a drop never goes into it or into a folder inside it.
    let carriedFolder: UUID?

    private let folderByID: [UUID: BookmarkFolder]
    /// Where each page sits in `order`.
    private let pageIndex: [UUID: Int]
    /// The folder each page is in, when it is in one.
    private let pageFolder: [UUID: UUID]
    /// The first page index of a folder and its subfolders. Empty folders take the next page after their own row.
    private let folderFirst: [UUID: Int]
    /// One past the last page index of a folder and its subfolders.
    private let folderEnd: [UUID: Int]
    /// The folder a folder is inside. A folder with no entry sits at the top level.
    private let folderParent: [UUID: UUID]
    /// How many folders a folder is inside.
    private let folderDepth: [UUID: Int]
    /// The carried folder and every folder inside it.
    private let blocked: Set<UUID>
    /// The place of an empty folder that has no stored place: the top of its parent, in the folders' own order, as the
    /// list draws it. Without this a drop beside such a folder reads its place from the page line and lands above it.
    private let emptyFolderPlace: [UUID: Double]

    init(rows: [DropRow], order: [UUID], fullOrder: [UUID] = [], folders: [BookmarkFolder], carried: Set<SidebarItem>,
         kind: DragKind, carriedFolder: UUID?) {
        self.rows = rows
        self.order = order
        self.folders = folders
        self.carried = carried
        self.kind = kind
        self.carriedFolder = carriedFolder
        // A folder's stored rank is a place on the full page line. The indexes and places below are on the line the
        // pages that stay make, so the rank moves with the carried pages: find the last page that stays before it and
        // put the folder just after that page's new index. Without this, a drop beside an empty folder inside a folder
        // reads one number line for the folder and another for the pages, and lands a slot low.
        var ranked = folders
        if !fullOrder.isEmpty {
            let staying = Set(order)
            var reduced: [UUID: Int] = [:]
            for (position, id) in order.enumerated() { reduced[id] = position }
            for index in ranked.indices {
                guard let rank = ranked[index].rank else { continue }
                // A place before the first page is already on the reduced line: no carried page can sit before it.
                // The alphabetical sort gives every folder such a place, and collapsing them to -0.5 put every folder
                // above the first page in one spot, so a drop between two of them landed below both.
                if rank < 0 { continue }
                var before: UUID?
                for (position, id) in fullOrder.enumerated() where Double(position) < rank {
                    if staying.contains(id) { before = id }
                }
                ranked[index].rank = before.flatMap { reduced[$0] }.map { Double($0) + 0.5 } ?? -0.5
            }
        }
        folderByID = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var pageIndex: [UUID: Int] = [:]
        for (position, id) in order.enumerated() { pageIndex[id] = position }
        self.pageIndex = pageIndex

        let folderParent = Dictionary(folders.compactMap { folder in folder.parentID.map { (folder.id, $0) } },
                                      uniquingKeysWith: { first, _ in first })
        self.folderParent = folderParent
        var folderDepth: [UUID: Int] = [:]
        for folder in folders {
            var depth = 0, next = folderParent[folder.id], seen: Set<UUID> = [folder.id]
            while let id = next, seen.insert(id).inserted { depth += 1; next = folderParent[id] }
            folderDepth[folder.id] = depth
        }
        self.folderDepth = folderDepth

        var pageFolder: [UUID: UUID] = [:]
        for folder in folders { for id in folder.bookmarkIDs { pageFolder[id] = folder.id } }
        self.pageFolder = pageFolder

        // A folder's first and last page, its subfolders' with it, gathered up the tree once.
        var first: [UUID: Int] = [:], end: [UUID: Int] = [:]
        for (position, id) in order.enumerated() {
            guard var folder = pageFolder[id] else { continue }
            var seen: Set<UUID> = []
            while seen.insert(folder).inserted {
                first[folder] = min(first[folder] ?? position, position)
                end[folder] = max(end[folder] ?? position + 1, position + 1)
                guard let up = folderParent[folder] else { break }
                folder = up
            }
        }
        // An empty folder with no stored place draws at the top of its parent, in the folders' own order. Work its place
        // out the same way here, so a drop beside it lands where the line shows, between the two rows.
        let carriedFolders: Set<UUID> = Set(carried.compactMap { item in
            if case .folder(let id) = item { return id }
            return nil
        })
        let grouped = Dictionary(grouping: folders, by: { $0.parentID })
        var emptyPlace: [UUID: Double] = [:]
        for folder in folders where folder.rank == nil && first[folder.id] == nil && !carriedFolders.contains(folder.id) {
            var top: Int?
            for (position, id) in order.enumerated() where pageFolder[id] == folder.parentID {
                top = top.map { min($0, position) } ?? position
            }
            for sibling in folders where sibling.parentID == folder.parentID {
                if let start = first[sibling.id] { top = top.map { min($0, start) } ?? start }
            }
            let place = (grouped[folder.parentID] ?? []).firstIndex { $0.id == folder.id } ?? 0
            emptyPlace[folder.id] = Double(top ?? order.count) - 0.5 - Double(place + 1) * 0.001
        }
        self.emptyFolderPlace = emptyPlace

        // A folder with no pages of its own sits at the top of where it is: where the next page below it goes.
        var next = order.count
        for row in rows.reversed() {
            switch row.item {
            case .bookmark(let id):
                if let position = pageIndex[id] { next = position }
            case .folder(let id):
                if let position = first[id] { next = min(next, position) }
                else if folderByID[id] != nil { first[id] = next; end[id] = next }
            default:
                continue
            }
        }
        self.folderFirst = first
        self.folderEnd = end

        // Nothing may land in the folder being dragged, nor in a folder inside it.
        var blocked: Set<UUID> = []
        if let carriedFolder {
            let inside = Dictionary(grouping: folders.filter { $0.parentID != nil }, by: { $0.parentID! })
            var queue = [carriedFolder]
            blocked.insert(carriedFolder)
            while let id = queue.popLast() {
                for child in inside[id] ?? [] where blocked.insert(child.id).inserted { queue.append(child.id) }
            }
        }
        self.blocked = blocked
    }

    /// The one place a pointer over the pinned rows lands.
    ///
    /// It follows the plan's six steps. Find the gap, then let a folder row's middle take the drop whole. Work the level
    /// out from the pointer's x, and map that level to a folder. Work the index out, then say where the line goes.
    func drop(at pointer: NSPoint) -> SidebarDrop? {
        // 0. Where the drop takes nothing: over a folder being carried and the rows inside it, at any point of that
        // block, and over the middle of a page's own row. The gaps above and below a page are still its own edges.
        if takesNothing(at: pointer) { return nil }
        // 1. The rows' midlines: every row whose middle is above the pointer is above it.
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].frame.midY < pointer.y { low = middle + 1 } else { high = middle }
        }
        let boundary = low
        let rawAbove = boundary > 0 ? rows[boundary - 1] : nil
        let rawBelow = boundary < rows.count ? rows[boundary] : nil
        guard let anchor = rawBelow ?? rawAbove else {
            return SidebarDrop(section: .bookmarks, index: 0, folder: nil, place: .gap(above: nil, below: nil, depth: 0))
        }

        // The carried rows leave, so the gap the line shows is between the nearest rows that stay.
        var stayAbove = boundary - 1
        while stayAbove >= 0, carried.contains(rows[stayAbove].item) { stayAbove -= 1 }
        var stayBelow = boundary
        while stayBelow < rows.count, carried.contains(rows[stayBelow].item) { stayBelow += 1 }
        var shownAbove: DropRow? = stayAbove >= 0 ? rows[stayAbove] : nil
        var shownBelow: DropRow? = stayBelow < rows.count ? rows[stayBelow] : nil

        // 2. The row under the pointer. A folder row's middle half takes the drop whole: the folder highlights and the
        // page or folder goes in at that folder's end. Its top and bottom bands are the gaps above and below it.
        let hitIndex = [boundary - 1, boundary].first { index in
            rows.indices.contains(index) && pointer.y >= rows[index].frame.minY && pointer.y <= rows[index].frame.maxY
        }
        let hit = hitIndex.map { rows[$0] }
        // A folder's row is nearly all inside it; only the strip at its edge is the gap above or below.
        let band: RowBand? = hit.map { row in
            if case .folder = row.item { return RowBand.band(of: pointer, in: row.frame, edge: RowBand.folderEdge) }
            return RowBand.band(of: pointer, in: row.frame)
        }
        if let hit, case .folder(let id) = hit.item, band == .onto, !blocked.contains(id) {
            return SidebarDrop(section: .bookmarks, index: folderEnd[id] ?? order.count, folder: id,
                               place: .onto(hit.item))
        }

        // 3. Above or below a row is that row's own level. There is no stepping by the pointer's x: a folder is entered
        // by its row's middle only, so the line and the drop cannot disagree about the level.
        var level: Int
        var parent: UUID?
        if let hit {
            level = hit.depth
            parent = parentOnTheWay(to: hit.item)
        } else if let rawBelow {
            level = rawBelow.depth
            parent = parentOnTheWay(to: rawBelow.item)
        } else {
            level = anchor.depth
            parent = parentOnTheWay(to: anchor.item)
        }
        // Never into the folder being carried, nor into one inside it. The drop climbs out to the nearest folder that
        // may take it, and the line shows the level it really lands at.
        while level > 0, let inside = parent, blocked.contains(inside) {
            parent = folderParent[inside]
            level -= 1
        }
        if level == 0 { parent = nil }

        // 4. The place among the pages. A folder's own top and bottom bands are the gaps above and below its whole
        // block, so its bottom band lands after every page inside it rather than after its header.
        var index: Int
        if let hitIndex, let hit, case .folder(let id) = hit.item {
            index = band == .below ? (folderEnd[id] ?? order.count) : (folderFirst[id] ?? order.count)
            if band == .below {
                var end = hitIndex
                while end + 1 < rows.count, rows[end + 1].depth > hit.depth { end += 1 }
                shownAbove = nearestShown(atOrBefore: end)
                shownBelow = nearestShown(atOrAfter: end + 1)
            } else if band == .above {
                shownAbove = nearestShown(atOrBefore: hitIndex - 1)
                shownBelow = nearestShown(atOrAfter: hitIndex)
            }
        } else {
            index = firstPage(atOrAfter: boundary) ?? order.count
        }

        // 5. The gap, set in at the level it lands at.
        return SidebarDrop(section: .bookmarks, index: index, folder: parent,
                           place: .gap(above: shownAbove?.item, below: shownBelow?.item, depth: level))
    }

    /// Whether the drop takes nothing here. A folder being carried takes nothing across its whole block, its pages'
    /// rows and the gaps between them: the pointer is over what is moving. A page takes nothing over the half of its
    /// own row that takes a drop, while its own top and bottom bands stay the gaps above and below it.
    func takesNothing(at pointer: NSPoint) -> Bool {
        if kind == .folder {
            let frames = rows.filter { carried.contains($0.item) }.map(\.frame)
            guard let top = frames.map(\.minY).min(), let bottom = frames.map(\.maxY).max() else { return false }
            return pointer.y >= top && pointer.y <= bottom
        }
        guard let row = rows.first(where: { pointer.y >= $0.frame.minY && pointer.y <= $0.frame.maxY }),
              carried.contains(row.item) else { return false }
        return RowBand.band(of: pointer, in: row.frame) == .onto
    }

    /// The rows either side of a row as the list shows them, carried rows stepped over: the gap the row sits in.
    func neighbours(of item: SidebarItem) -> (above: SidebarItem?, below: SidebarItem?) {
        guard let at = rows.firstIndex(where: { $0.item == item }) else { return (nil, nil) }
        return (nearestShown(atOrBefore: at - 1)?.item, nearestShown(atOrAfter: at + 1)?.item)
    }

    /// The nearest row that stays, at or before an index, or at or after one.
    private func nearestShown(atOrBefore index: Int) -> DropRow? {
        var at = min(index, rows.count - 1)
        while at >= 0, carried.contains(rows[at].item) { at -= 1 }
        return at >= 0 ? rows[at] : nil
    }

    private func nearestShown(atOrAfter index: Int) -> DropRow? {
        var at = max(index, 0)
        while at < rows.count, carried.contains(rows[at].item) { at += 1 }
        return at < rows.count ? rows[at] : nil
    }

    /// The folder a row sits in: a page's folder, or a folder's parent. Nil is the top level.
    private func parentOnTheWay(to item: SidebarItem) -> UUID? {
        switch item {
        case .bookmark(let id): pageFolder[id]
        case .folder(let id): folderParent[id]
        default: nil
        }
    }

    /// Where a row sits on the page's number line: a page by its index, a folder by its stored place, else just before
    /// its first page. Empty folders that have no place yet sit just before their parent's first page.
    func place(of item: SidebarItem) -> Double? {
        switch item {
        case .bookmark(let id):
            return pageIndex[id].map(Double.init)
        case .folder(let id):
            if let rank = folderByID[id]?.rank { return rank }
            // An empty folder draws at the top of its parent, not where its page line would put it.
            if let empty = emptyFolderPlace[id] { return empty }
            if let first = folderFirst[id] { return Double(first) - 0.5 }
            let top = folderParent[id].flatMap { folderFirst[$0] } ?? order.count
            return Double(top) - 0.5
        default:
            return nil
        }
    }

    /// The line a resolved gap draws: on the gap's own edge, at the gap's level. It is the row above the landed place
    /// or the row below it, both of which the resolver already worked out, so the line can never point at another gap.
    func line(for drop: SidebarDrop, rowGap: CGFloat) -> DropLine? {
        guard case .gap(let above, let below, let depth) = drop.place else { return nil }
        if let below, let down = rows.first(where: { $0.item == below }) {
            // A gap after the last row of a deeper block sits at that block's level, while the row below is one level
            // out: its own top band means the gap above it at its level. Draw this gap inside the block's last row
            // instead, the band that resolves to it, so the line and the pointer on it cannot disagree.
            if let above, let up = rows.first(where: { $0.item == above }),
               let upIndex = rows.firstIndex(of: up), let downIndex = rows.firstIndex(of: down),
               downIndex == upIndex + 1, depth > down.depth, up.depth == depth {
                return DropLine(y: up.frame.maxY - rowGap / 2, depth: depth)
            }
            return DropLine(y: down.frame.minY - rowGap / 2, depth: depth)
        }
        if let above, let row = rows.first(where: { $0.item == above }) {
            return DropLine(y: row.frame.maxY + rowGap / 2, depth: depth)
        }
        let shown = rows.filter { !carried.contains($0.item) }
        guard let first = shown.first else { return nil }
        if above == nil { return DropLine(y: first.frame.minY - rowGap / 2, depth: depth) }
        return DropLine(y: (shown.last?.frame.maxY ?? first.frame.maxY) + rowGap / 2, depth: depth)
    }

    // MARK: What the rows and folders hold

    /// The page index of the first page at or below a row: where a gap above that row lands in the page list.
    private func firstPage(atOrAfter row: Int) -> Int? {
        var index = row
        while index < rows.count {
            switch rows[index].item {
            case .bookmark(let id):
                if let position = pageIndex[id] { return position }
            case .folder(let id):
                if let position = folderFirst[id] { return position }
            default:
                break
            }
            index += 1
        }
        return nil
    }
}

/// Everything a tab drag needs to resolve a pointer, made once per drag: the tab and group rows on show with their
/// frames, the tabs each row shows, the space's tabs without the moving ones, and the tree over them. The pinned
/// resolver's sibling: it reads only what it is given, and the line and the drop both come from its answer.
nonisolated struct TabDropSnapshot {
    /// The tab rows on show, top to bottom, with their frames and how far in they are set.
    let rows: [DropRow]
    /// The tabs each row shows, in list order: a tab's split partners, or a group's tabs. One entry per row.
    let rowTabs: [[UUID]]
    /// The space's tabs in list order, without the moving ones.
    let list: [UUID]
    /// The tabs and their parents, without the carried tabs.
    let nodes: [TabTree.Node]
    /// Each tab's group, when it is in one.
    let groups: [UUID: UUID]
    /// Which tab groups are open.
    let openGroups: [UUID: Bool]
    let carried: Set<SidebarItem>
    let kind: DragKind
    let moving: Set<UUID>
    /// Whether the row being carried is one tab, which a group row can take whole. A group or a pinned page is not.
    let takesGroup: Bool

    /// Where each tab sits in `list`.
    private let positions: [UUID: Int]
    /// How far each tab is nested.
    private let levels: [UUID: Int]

    static let empty = TabDropSnapshot(rows: [], rowTabs: [], list: [], nodes: [], groups: [:], openGroups: [:],
                                       carried: [], kind: .page, moving: [], takesGroup: false)

    init(rows: [DropRow], rowTabs: [[UUID]], list: [UUID], nodes: [TabTree.Node], groups: [UUID: UUID],
         openGroups: [UUID: Bool], carried: Set<SidebarItem>, kind: DragKind, moving: Set<UUID>,
         takesGroup: Bool) {
        self.rows = rows
        self.rowTabs = rowTabs
        self.list = list
        self.nodes = nodes
        self.groups = groups
        self.openGroups = openGroups
        self.carried = carried
        self.kind = kind
        self.moving = moving
        self.takesGroup = takesGroup
        var positions: [UUID: Int] = [:]
        for (position, id) in list.enumerated() { positions[id] = position }
        self.positions = positions
        levels = TabTree.levels(nodes)
    }

    /// The one place a pointer over the tab rows lands.
    ///
    /// A tab row's middle is the split offer: the two open side by side. A group row's middle takes the tab. The top and
    /// bottom bands of either are gaps, and their level, parent and group come from the rows on either side, never from
    /// a count of rows. `allowsOnto` false is a tab carried from another window, which cannot split or join here: it
    /// takes the gap at the row's edge like any other.
    func drop(at pointer: NSPoint, allowsOnto: Bool = true) -> SidebarDrop? {
        // A folder stays among the pinned rows: it never lands among the tabs.
        guard kind != .folder, !rows.isEmpty else { return nil }

        // 1. The gap: every row whose middle sits above the pointer is above it.
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].frame.midY < pointer.y { low = middle + 1 } else { high = middle }
        }
        let boundary = low
        let rawAbove = boundary > 0 ? rows[boundary - 1] : nil
        let rawBelow = boundary < rows.count ? rows[boundary] : nil

        // 2. The middle band of a row: a tab opens side by side, and a single tab over a group row joins that group.
        // The carried rows stay in their places, faint, and take nothing. A group goes between groups and nested runs,
        // never inside one, so it has no middle-band offer.
        let hit = allowsOnto ? [rawAbove, rawBelow].compactMap { $0 }
            .first { pointer.y >= $0.frame.minY && pointer.y <= $0.frame.maxY } : nil
        if let hit, kind != .group, !carried.contains(hit.item) {
            let band: RowBand = if case .tabGroup = hit.item {
                RowBand.band(of: pointer, in: hit.frame, edge: RowBand.folderEdge)
            } else {
                RowBand.band(of: pointer, in: hit.frame)
            }
            if band == .onto {
                switch hit.item {
                case .tab(let id):
                    return SidebarDrop(section: .tabs, index: listIndex(atOrAfter: boundary), folder: nil,
                                       place: .onto(.tab(id)))
                case .tabGroup(let id) where takesGroup:
                    return SidebarDrop(section: .tabs, index: listIndex(atOrAfter: boundary), folder: nil,
                                       place: .onto(.tabGroup(id)))
                default:
                    break
                }
            }
        }

        // A group's gap moves on until it is outside every group and nested run.
        var gap = boundary
        if kind == .group {
            while gap > 0, gap < rows.count, !isTopLevelGap(at: gap) { gap += 1 }
        }

        // The carried rows leave, so the gap the line shows is between the nearest rows that stay.
        var stayAbove = gap - 1
        while stayAbove >= 0, carried.contains(rows[stayAbove].item) { stayAbove -= 1 }
        var stayBelow = gap
        while stayBelow < rows.count, carried.contains(rows[stayBelow].item) { stayBelow += 1 }
        let above = stayAbove >= 0 ? rows[stayAbove] : nil
        let below = stayBelow < rows.count ? rows[stayBelow] : nil

        // 3. Where the gap goes, from the rows on either side: the tab it goes under, and its group.
        let parent = tabGapParent(above: above?.item, below: below?.item)
        let group = tabGapGroup(above: above?.item, below: below?.item, parent: parent)

        // 4. The line's step, as the landed row would be set in: the group's step, then the parent's.
        let depth = (group == nil ? 0 : 1) + (parent.map { TabTree.shownLevel((levels[$0] ?? 0) + 1) } ?? 0)
        return SidebarDrop(section: .tabs, index: listIndex(atOrAfter: gap), folder: nil,
                           place: .gap(above: above?.item, below: below?.item, depth: depth))
    }

    /// The tab a gap goes under: right under a tab whose nested tabs show, or between two tabs of one group, it joins
    /// that group. After a group's last row the pointer picks how many levels out it lands, never further out than the
    /// row below. Nil: the top level.
    func tabGapParent(above: SidebarItem?, below: SidebarItem?) -> UUID? {
        // Just under a group row: its first slot, top level.
        if case .tabGroup? = above { return nil }
        let before: UUID? = if case .tab(let id)? = above { id } else { nil }
        let after: UUID? = if case .tab(let id)? = below { id } else { nil }
        // The level is the rows': directly under a tab is inside it, and any other gap sits at the row's own level. The
        // pointer's x does not step in or out, so the line and the drop cannot disagree.
        return TabTree.dropParent(before: before, after: after, in: nodes) { _ in false }
    }

    /// The tab group a gap goes into: under one of its tabs, right under its row, or between its tabs; after its last
    /// tab, only when indented to its level. Nil when none.
    func tabGapGroup(above: SidebarItem?, below: SidebarItem?, parent: UUID?) -> UUID? {
        if let parent { return groups[parent] }
        let groupBelow: UUID? = if case .tab(let id)? = below { groups[id] } else { nil }
        switch above {
        case .tabGroup(let id)?:
            // A folded group row shows only the tab you're on: only above that one tab does it take a gap.
            return openGroups[id] == true || groupBelow == id ? id : nil
        case .tab(let id)?:
            // Between two of the group's own tabs, or directly under its last one, it stays in the group. A gap with a
            // tab outside the group below it is the way out, as the rows say.
            guard let group = groups[id] else { return nil }
            return groupBelow == group ? group : nil
        default:
            return nil
        }
    }

    /// Whether the gap above row `row` is outside every group and nested run: a group lands only at such a gap.
    private func isTopLevelGap(at row: Int) -> Bool {
        var above = row - 1
        while above >= 0, carried.contains(rows[above].item) { above -= 1 }
        var below = row
        while below < rows.count, carried.contains(rows[below].item) { below += 1 }
        guard below < rows.count, case .tab(let id) = rows[below].item else { return true }
        if (levels[id] ?? 0) > 0 { return false }
        guard let group = groups[id] else { return true }
        guard above >= 0 else { return true }
        switch rows[above].item {
        case .tabGroup(let other): return other != group
        case .tab(let other): return groups[other] != group
        default: return true
        }
    }

    /// The line a resolved tab drop draws: the same anchor as the pinned line, the edge of the row whose first tab is at
    /// or after the drop's index, or the bottom of the last row when the gap is after every tab. A tab row's middle is
    /// the split offer, which shows no line; with no split to offer, the line shows the gap the tab would go to instead.
    func line(for drop: SidebarDrop, rowGap: CGFloat) -> DropLine? {
        switch drop.place {
        case .gap(let above, let below, let depth):
            if let below, let row = rows.first(where: { $0.item == below }) {
                return DropLine(y: row.frame.minY - rowGap / 2, depth: depth)
            }
            if let above, let row = rows.first(where: { $0.item == above }) {
                return DropLine(y: row.frame.maxY + rowGap / 2, depth: depth)
            }
            guard let first = rankedRows.first else { return nil }
            if above == nil { return DropLine(y: rows[first].frame.minY - rowGap / 2, depth: depth) }
            let last = rankedRows.last ?? first
            return DropLine(y: rows[last].frame.maxY + rowGap / 2, depth: depth)
        case .onto(let item):
            guard case .tab = item, let row = rows.first(where: { $0.item == item }) else { return nil }
            return line(at: drop.index, depth: row.depth, rowGap: rowGap)
        }
    }

    /// The rows on either side of a drop's place, read from the drop's index: for a row's middle, which is not itself a
    /// `.gap`, the same gap the tab would fall back to.
    func gap(at index: Int) -> (above: SidebarItem?, below: SidebarItem?) {
        let ranked = rankedRows
        for (position, row) in ranked.enumerated() where firstTab(of: row) >= index {
            return (position > 0 ? rows[ranked[position - 1]].item : nil, rows[row].item)
        }
        return (ranked.last.map { rows[$0].item }, nil)
    }

    /// How far a tab is nested, for the line's step under it.
    func level(of tab: UUID) -> Int? { levels[tab] }

    // MARK: The rows and the tabs

    /// The rows the line and the gap read: the ones that stay, with a tab in the list.
    private var rankedRows: [Int] {
        rows.indices.filter { !carried.contains(rows[$0].item) && firstTab(of: $0) != Int.max }
    }

    /// Where a row's first tab sits in the list. A split's row starts at its first half.
    private func firstTab(of row: Int) -> Int {
        guard rowTabs.indices.contains(row) else { return Int.max }
        var first = Int.max
        for id in rowTabs[row] { if let at = positions[id], at < first { first = at } }
        return first
    }

    /// Where a gap above `row` lands in the tab list: the first tab at or after that row that is still in the list.
    private func listIndex(atOrAfter row: Int) -> Int {
        var index = max(0, row)
        while index < rows.count {
            let first = firstTab(of: index)
            if first != Int.max { return first }
            index += 1
        }
        return list.count
    }

    private func line(at index: Int, depth: Int, rowGap: CGFloat) -> DropLine? {
        let ranked = rankedRows
        guard let below = ranked.first(where: { firstTab(of: $0) >= index }) else {
            guard let last = ranked.last else { return nil }
            return DropLine(y: rows[last].frame.maxY + rowGap / 2, depth: depth)
        }
        // A group row takes the same place in the list as its first tab. A gap inside the group at that tab sits under
        // the group row, above the tab: above the group row only when the gap is at the group's own level.
        if depth > rows[below].depth, case .tabGroup = rows[below].item, firstTab(of: below) == index {
            return DropLine(y: rows[below].frame.maxY + rowGap / 2, depth: depth)
        }
        return DropLine(y: rows[below].frame.minY - rowGap / 2, depth: depth)
    }
}

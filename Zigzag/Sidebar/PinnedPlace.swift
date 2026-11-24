import Foundation

/// The pinned rows' number line, worked out once from the pages, the folders and the pages that ride in another's row.
///
/// A page's place on the line is its index in the space's flat `pages` list. A folder's place is its stored rank, or
/// just before its first page when it has never been moved, or the top of its parent for a folder with no pages. The
/// list draws from this line and the place transaction reads it, so a row's place is worked out in one place only.
nonisolated struct PinnedLine {
    /// The space's pinned pages, in list order, the pages that ride in a split's row included.
    let pages: [UUID]
    let folders: [BookmarkFolder]
    /// The pages that ride in another's row: a split's other pages, which have no row of their own.
    let riders: Set<UUID>

    /// Where each page sits in `pages`.
    private let index: [UUID: Int]
    private let byID: [UUID: BookmarkFolder]
    /// The folders under each parent, in the folders' own order.
    private let inside: [UUID?: [BookmarkFolder]]
    /// The folder each page is in: the first folder that has it.
    let folderOf: [UUID: UUID]
    /// The first page anywhere inside each folder, its subfolders' with it.
    private let first: [UUID: Int]

    init(pages: [UUID], folders: [BookmarkFolder], riders: Set<UUID> = []) {
        self.pages = pages
        self.folders = folders
        self.riders = riders
        var index: [UUID: Int] = [:]
        for (place, id) in pages.enumerated() where index[id] == nil { index[id] = place }
        self.index = index
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byID = byID
        inside = Dictionary(grouping: folders, by: \.parentID)
        var folderOf: [UUID: UUID] = [:]
        for folder in folders { for id in folder.bookmarkIDs where folderOf[id] == nil { folderOf[id] = folder.id } }
        self.folderOf = folderOf
        // A folder's first page, its subfolders' with it, gathered up the tree once.
        var first: [UUID: Int] = [:]
        for (place, id) in pages.enumerated() {
            guard var folder = folderOf[id] else { continue }
            var seen: Set<UUID> = []
            while seen.insert(folder).inserted {
                if first[folder] == nil { first[folder] = place }
                guard let up = byID[folder]?.parentID else { break }
                folder = up
            }
        }
        self.first = first
    }

    func pageIndex(of id: UUID) -> Int? { index[id] }
    func folder(_ id: UUID) -> BookmarkFolder? { byID[id] }
    func folder(containing page: UUID) -> UUID? { folderOf[page] }
    func folders(inside parent: UUID?) -> [BookmarkFolder] { inside[parent] ?? [] }
    func firstPage(of folder: UUID) -> Int? { first[folder] }

    /// The first page at or under a parent: where the parent's children begin on the page line.
    func topPage(of parent: UUID?) -> Int? {
        var best: Int?
        for (place, id) in pages.enumerated() where folderOf[id] == parent {
            best = best.map { min($0, place) } ?? place
        }
        for folder in inside[parent] ?? [] {
            if let first = first[folder.id] { best = best.map { min($0, first) } ?? first }
        }
        return best
    }

    /// Where a folder sits on the page line: its stored place, else just before its first page, else at the top of its
    /// parent in the folders' own order.
    func place(of folder: BookmarkFolder, order: Int) -> Double {
        if let rank = folder.rank { return rank }
        if let first = first[folder.id] { return Double(first) - 0.5 }
        let top = topPage(of: folder.parentID) ?? pages.count
        return Double(top) - 0.5 - Double(order + 1) * 0.001
    }

    /// The rows under a parent, in the order the list draws them: pages at their index, folders at their place, a page
    /// first when the two land in one spot. Equal folder places keep the folders' own order, so the rows are stable.
    func children(of parent: UUID?) -> [SidebarItem] {
        var rows: [(key: Double, isPage: Bool, order: Int, item: SidebarItem)] = []
        for (place, id) in pages.enumerated() where folderOf[id] == parent && !riders.contains(id) {
            rows.append((Double(place), true, 0, .bookmark(id)))
        }
        for (order, folder) in (inside[parent] ?? []).enumerated() {
            rows.append((place(of: folder, order: order), false, order, .folder(folder.id)))
        }
        return rows.sorted {
            if $0.key != $1.key { return $0.key < $1.key }
            if $0.isPage != $1.isPage { return $0.isPage }
            return $0.order < $1.order
        }.map(\.item)
    }
}

/// A pinned tree as the place transaction sees it: the pages in list order, the folders and the splits. A drop is one
/// call and one answer: the pages leave, go in where the line showed, the parent and every sibling's place are set, all
/// together. There is no half-applied state, so a folder's place can never be read on one line and written on another.
///
/// A folder is the library's own `BookmarkFolder`, whose equality is main actor isolated, so this type is too: a test
/// compares two trees from the main actor, and the library and the list only ever use it there.
struct PinnedPlace: Equatable {
    var pages: [UUID]
    var folders: [BookmarkFolder]
    var splits: [PinnedSplit]

    var line: PinnedLine {
        PinnedLine(pages: pages, folders: folders, riders: Set(splits.flatMap(\.riders)))
    }

    /// The pages that leave the list with a row: a split takes its other half, a folder its pages everywhere inside it.
    func moving(_ item: SidebarItem) -> Set<UUID> {
        switch item {
        case .bookmark(let id): Set(splits.first { $0.contains(id) }?.ids ?? [id])
        case .folder(let id): folders.pages(in: id)
        default: []
        }
    }

    /// The tree a drop leaves, or nil when it leaves the tree as it is: the same rows under every parent, the same
    /// pages, the same order. A nil answer is the only "change nothing" there is, so the caller records no undo step.
    ///
    /// The carried row goes in at the gap the drop resolved, between the two rows the line showed. Everything else
    /// keeps its order. Each parent's folders then take their places on the page line in that order, all of them, in
    /// one pass, so no folder is left on the old line beside a page that moved.
    func moved(_ item: SidebarItem, to drop: SidebarDrop) -> PinnedPlace? {
        let line = self.line
        let carried = moving(item)
        let movingFolder: UUID?
        let movedRow: SidebarItem
        switch item {
        case .bookmark(let id):
            guard line.pageIndex(of: id) != nil else { return nil }
            movingFolder = nil
            movedRow = self.row(.bookmark(id))
        case .folder(let id):
            guard line.folder(id) != nil else { return nil }
            movingFolder = id
            movedRow = .folder(id)
        default:
            return nil
        }
        // Nothing may land in the folder being carried, nor in a folder inside it.
        if let movingFolder, let destination = drop.folder,
           destination == movingFolder || folders.descendants(of: movingFolder).contains(destination) {
            return nil
        }
        let oldParent: UUID? = if let movingFolder {
            line.folder(movingFolder)?.parentID
        } else {
            carried.compactMap { line.folderOf[$0] }.first
        }

        // The pages leave the list, then go in where the line showed.
        let reduced = pages.filter { !carried.contains($0) }
        var at = min(max(0, drop.index), reduced.count)
        // A split that stays is one row: never between its pages.
        for split in splits where !split.ids.contains(where: carried.contains) {
            let places = split.ids.compactMap { reduced.firstIndex(of: $0) }
            if let low = places.min(), let high = places.max(), at > low, at <= high { at = high + 1 }
        }
        var newPages = reduced
        newPages.insert(contentsOf: pages.filter { carried.contains($0) }, at: at)

        // A page put into a folder is in that folder now; a folder keeps its own pages.
        var newFolders = folders
        if movingFolder == nil {
            for i in newFolders.indices { newFolders[i].bookmarkIDs.removeAll { carried.contains($0) } }
            if let destination = drop.folder, let f = newFolders.firstIndex(where: { $0.id == destination }) {
                newFolders[f].bookmarkIDs.append(contentsOf: pages.filter { carried.contains($0) })
            }
        }
        if let movingFolder, let f = newFolders.firstIndex(where: { $0.id == movingFolder }) {
            newFolders[f].parentID = drop.folder
            // Dropped inside a folder, it opens, so what went in shows.
            if let destination = drop.folder, let pi = newFolders.firstIndex(where: { $0.id == destination }) {
                newFolders[pi].isOpen = true
                newFolders[pi].tucked = nil
            }
        }
        let newLine = PinnedLine(pages: newPages, folders: newFolders, riders: Set(splits.flatMap(\.riders)))

        // The rows under every parent, as they are now and as the drop leaves them.
        var parents: [UUID?] = [nil]
        parents.append(contentsOf: folders.map { Optional($0.id) })
        var desired: [UUID?: [SidebarItem]] = [:]
        for parent in parents { desired[parent] = line.children(of: parent) }
        func take(_ parent: UUID?) -> [SidebarItem] { desired[parent] ?? [] }
        func put(_ parent: UUID?, _ list: [SidebarItem]) { desired[parent] = list }
        var source = take(oldParent)
        source.removeAll { $0 == movedRow }
        put(oldParent, source)

        var destination = take(drop.folder)
        let position: Int
        switch drop.place {
        case .onto:
            // Inside the folder, at its end.
            position = destination.count
        case .gap(let above, let below, _):
            // Between the rows the line showed: after the block above, else before the block below. The gap's level is
            // the destination's, so both are that parent's children or rows inside one of them.
            if let above, let block = block(of: above, in: drop.folder, line: line),
               let index = destination.firstIndex(of: block) {
                position = index + 1
            } else if let below, let block = block(of: below, in: drop.folder, line: line),
                      let index = destination.firstIndex(of: block) {
                position = index
            } else {
                position = destination.firstIndex { self.firstPage(of: $0, in: newLine) >= at } ?? destination.count
            }
        }
        destination.insert(movedRow, at: min(max(0, position), destination.count))
        put(drop.folder, destination)

        // The same rows, in the same order, is the same tree: change nothing.
        var unchanged = newPages == pages
        if unchanged {
            for parent in parents where (desired[parent] ?? []) != line.children(of: parent) {
                unchanged = false
                break
            }
        }
        guard !unchanged else { return nil }

        // Every folder at every parent takes its place in the order the rows now have. A run of folders between two
        // pages shares the room between them, in its order, so none can cross another or land on a page's spot.
        var ranks: [UUID: Double] = [:]
        for parent in parents {
            var previous: Double = -0.5
            var pending: [UUID] = []
            func flush(upTo next: Double?) {
                guard !pending.isEmpty else { return }
                if let next, next > previous {
                    for (offset, id) in pending.enumerated() {
                        ranks[id] = previous + (next - previous) * Double(offset + 1) / Double(pending.count + 1)
                    }
                } else {
                    for (offset, id) in pending.enumerated() { ranks[id] = previous + 0.5 * Double(offset + 1) }
                }
                pending.removeAll()
            }
            for child in desired[parent] ?? [] {
                switch child {
                case .bookmark(let id):
                    let place = newLine.pageIndex(of: id).map(Double.init)
                    flush(upTo: place)
                    previous = place ?? previous
                case .folder(let id):
                    pending.append(id)
                default:
                    continue
                }
            }
            flush(upTo: nil)
        }
        for i in newFolders.indices {
            if let rank = ranks[newFolders[i].id] { newFolders[i].rank = rank }
        }
        // Each folder's pages, in the list's order.
        var ordered: [UUID: [UUID]] = [:]
        for id in newPages {
            if let owner = newLine.folderOf[id] { ordered[owner, default: []].append(id) }
        }
        for i in newFolders.indices { newFolders[i].bookmarkIDs = ordered[newFolders[i].id] ?? [] }
        return PinnedPlace(pages: newPages, folders: newFolders, splits: splits)
    }

    /// The row a drop's `above` or `below` names: a split's lead, never its rider.
    private func row(_ item: SidebarItem) -> SidebarItem {
        guard case .bookmark(let id) = item else { return item }
        return .bookmark(splits.first { $0.contains(id) }?.left ?? id)
    }

    /// The child of a parent that holds a row: the row itself when it sits there, else the folder on the way to it.
    private func block(of item: SidebarItem, in parent: UUID?, line: PinnedLine) -> SidebarItem? {
        var child = row(item)
        var up: UUID?
        switch child {
        case .bookmark(let id): up = line.folder(containing: id)
        case .folder(let id): up = line.folder(id)?.parentID
        default: return nil
        }
        while let current = up {
            if current == parent { return child }
            child = .folder(current)
            up = line.folder(current)?.parentID
        }
        return parent == nil ? child : nil
    }

    /// The first page a row has on the line, a folder's whole block counted.
    private func firstPage(of child: SidebarItem, in line: PinnedLine) -> Int {
        switch child {
        case .bookmark(let id): line.pageIndex(of: id) ?? Int.max
        case .folder(let id): line.firstPage(of: id) ?? Int.max
        default: Int.max
        }
    }
}


/// The pinned section's rows, page by page and folder by folder, off the one line. The list draws exactly this, so a
/// test can ask what the rows will be without a window, a library or the main actor.
nonisolated enum PinnedRows {
    /// `bookmarks` is the space's pinned pages in list order, the pages that ride in another's row included, so a
    /// folder's stored place and a page's index are counted on one line. `riders` are the pages with no row of their
    /// own. `folded`: the section is folded, so only open pages and the page you're on show, each under the folders on
    /// its way (#325).
    static func of(bookmarks: [UUID], folders: [BookmarkFolder], riders: Set<UUID> = [], current: UUID?,
                   folded: Bool = false,
                   isOpen: (UUID) -> Bool) -> (rows: [SidebarItem], depth: [SidebarItem: Int], pageCounts: [UUID: Int]) {
        var result: [SidebarItem] = []
        var rowDepth: [SidebarItem: Int] = [:]
        var folderPageCounts: [UUID: Int] = [:]
        // One line for the rows: where each page and folder sits, and the children of every parent by it.
        let line = PinnedLine(pages: bookmarks, folders: folders, riders: riders)
        let folderOf = line.folderOf
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var chains: [UUID: [UUID]] = [:]
        func path(to folder: UUID?) -> [UUID] {
            guard let folder else { return [] }
            if let known = chains[folder] { return known }
            var chain: [UUID] = [], next: UUID? = folder, seen: Set<UUID> = []
            while let id = next, seen.insert(id).inserted { chain.append(id); next = line.folder(id)?.parentID }
            chain.reverse()
            chains[folder] = chain
            return chain
        }
        // How many pages each folder holds, its folders' too, for its row to say.
        for folder in folders {
            var next: UUID? = folder.id, seen: Set<UUID> = []
            while let id = next, seen.insert(id).inserted { folderPageCounts[id, default: 0] += folder.bookmarkIDs.count; next = line.folder(id)?.parentID }
        }
        let tucked = Dictionary(folders.compactMap { f in f.tucked.map { (f.id, Set($0)) } }, uniquingKeysWith: { a, _ in a })
        if folded {
            var stack: [UUID] = []
            var shown: Set<UUID> = []
            for id in bookmarks where !riders.contains(id) {
                let chain = path(to: folderOf[id])
                // Hidden in a shut folder on purpose, it stays hidden here too.
                let tuckedAway = chain.contains { byID[$0]?.isOpen == false && tucked[$0]?.contains(id) == true }
                guard id == current || (isOpen(id) && !tuckedAway) else { continue }
                while !stack.isEmpty, stack.count > chain.count || Array(chain.prefix(stack.count)) != stack { stack.removeLast() }
                for folder in chain.dropFirst(stack.count) {
                    if shown.insert(folder).inserted { result.append(.folder(folder)); rowDepth[.folder(folder)] = stack.count }
                    stack.append(folder)
                }
                result.append(.bookmark(id)); rowDepth[.bookmark(id)] = stack.count
            }
            return (result, rowDepth, folderPageCounts)
        }
        // The children of a folder (nil: the top level), pages and folders together, by place. A page and a folder at
        // the same place put the page first, so a page dropped above a folder shows above it.
        func children(of parent: UUID?) -> [SidebarItem] { line.children(of: parent) }
        func tuckedAway(_ id: UUID) -> Bool {
            guard let f = folderOf[id] else { return false }
            for ancestor in path(to: f) where byID[ancestor]?.isOpen == false {
                if tucked[ancestor]?.contains(id) == true { return true }
            }
            return false
        }
        func emit(_ parent: UUID?, depth: Int, shut: Int?) {
            for item in children(of: parent) {
                switch item {
                case .folder(let id):
                    guard let folder = byID[id] else { continue }
                    if shut == nil { result.append(.folder(id)); rowDepth[.folder(id)] = depth }
                    emit(id, depth: depth + 1, shut: shut ?? (folder.isOpen ? nil : depth))
                case .bookmark(let id):
                    if let shut {
                        guard id == current || (isOpen(id) && !tuckedAway(id)) else { continue }
                        result.append(.bookmark(id)); rowDepth[.bookmark(id)] = shut + 1
                    } else {
                        result.append(.bookmark(id)); rowDepth[.bookmark(id)] = depth
                    }
                default:
                    break
                }
            }
        }
        emit(nil, depth: 0, shut: nil)
        return (result, rowDepth, folderPageCounts)
    }
}

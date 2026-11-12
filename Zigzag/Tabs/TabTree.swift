import Foundation

/// Nested tabs: a tab can sit under the tab it was opened from, as Horse does. The tab list stays one flat list in
/// sidebar order (what ⌃Tab, ⌘1–⌘9 and the overview walk); each tab only says which tab it's under. A tab's children
/// always follow it in the list, its own children right after each of them, so a tab and everything under it is one
/// unbroken run of the list. These work on that list as ids and parents, so the rules can be checked on their own.
nonisolated enum TabTree {
    struct Node: Equatable {
        var id: UUID
        var parent: UUID?
    }

    /// How many levels in the sidebar sets rows: deeper ones still nest, drawn as far in as this.
    private static let shownLevels = 2

    static func shownLevel(_ level: Int) -> Int { min(max(level, 0), shownLevels) }

    /// How deep each tab is: 0 for a tab of its own, 1 under another, and so on.
    static func levels(_ nodes: [Node]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var stack: [UUID] = []
        for node in nodes {
            while let top = stack.last, top != node.parent { stack.removeLast() }
            result[node.id] = stack.count
            stack.append(node.id)
        }
        return result
    }

    /// Takes away any parent that breaks the rule: one that isn't among the tabs just above (gone, in another space,
    /// below the tab, or a run broken by another tab). Such a tab goes to the top level, and stays where it is.
    static func repaired(_ nodes: [Node]) -> [Node] {
        var result = nodes
        var stack: [UUID] = []
        for i in result.indices {
            if let parent = result[i].parent, stack.contains(parent) {
                while let top = stack.last, top != parent { stack.removeLast() }
            } else {
                result[i].parent = nil
                stack.removeAll()
            }
            stack.append(result[i].id)
        }
        return result
    }

    /// Where the run of a tab and everything under it ends (the index just past it).
    static func subtreeEnd(at index: Int, in nodes: [Node]) -> Int {
        guard nodes.indices.contains(index) else { return index }
        var inside: Set<UUID> = [nodes[index].id]
        var end = index + 1
        while end < nodes.count, let parent = nodes[end].parent, inside.contains(parent) {
            inside.insert(nodes[end].id)
            end += 1
        }
        return end
    }

    /// Every tab under this one, at any depth, in list order.
    static func descendants(of id: UUID, in nodes: [Node]) -> [UUID] {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return [] }
        return nodes[(index + 1)..<subtreeEnd(at: index, in: nodes)].map(\.id)
    }

    /// What closing a tab closes: folded, the tab and every tab under it, in list order; open, the tab alone.
    static func closing(_ id: UUID, folded: Bool, in nodes: [Node]) -> [UUID] {
        guard nodes.contains(where: { $0.id == id }) else { return [] }
        return [id] + (folded ? descendants(of: id, in: nodes) : [])
    }

    static func hasChildren(_ id: UUID, in nodes: [Node]) -> Bool { nodes.contains { $0.parent == id } }

    /// Where a link opened from `parent` goes: after everything already under it, so a row of links stays in
    /// reading order.
    static func childIndex(of parent: UUID, in nodes: [Node]) -> Int? {
        nodes.firstIndex { $0.id == parent }.map { subtreeEnd(at: $0, in: nodes) }
    }

    /// The tabs a tab put in at `index` (before the tab there now) could be under: the ones above it it could stand
    /// beside or under. Nil (the top level) always can.
    static func ancestors(at index: Int, in nodes: [Node]) -> [UUID] {
        var stack: [UUID] = []
        for node in nodes.prefix(max(0, index)) {
            while let top = stack.last, top != node.parent { stack.removeLast() }
            stack.append(node.id)
        }
        return stack
    }

    /// Whether a tab put in at `index` under `parent` keeps every run whole: its parent is above it, and the tab
    /// after it is still under one of the tabs above it.
    static func canInsert(at index: Int, parent: UUID?, in nodes: [Node]) -> Bool {
        var stack = ancestors(at: index, in: nodes)
        if let parent {
            guard let at = stack.lastIndex(of: parent) else { return false }
            stack.removeSubrange((at + 1)...)
        } else {
            stack.removeAll()
        }
        guard index < nodes.count, let next = nodes[index].parent else { return true }
        return stack.contains(next)
    }

    /// The parent a tab put in at `index` takes when nothing asks for one: the next tab's, so it never breaks a run
    /// (it joins the group it lands in); nil at the top level or the end.
    static func parentForInsertion(at index: Int, in nodes: [Node]) -> UUID? {
        nodes.indices.contains(index) ? nodes[index].parent : nil
    }

    /// `preferred` where it keeps the runs whole, else the one that does.
    static func parent(at index: Int, preferring preferred: UUID?, in nodes: [Node]) -> UUID? {
        canInsert(at: index, parent: preferred, in: nodes) ? preferred : parentForInsertion(at: index, in: nodes)
    }

    /// Settings › Tabs, Next to Tabs from the Same Site (#188): where a new tab from `site` goes to sit with the tabs
    /// already open from it, and the tab it goes under. After the last of them, and everything under it, in its group;
    /// opened from one of them (`opener`), after the run of that site's tabs that starts there, so a row of links stays
    /// in reading order. Nil when no tab is from that site: the tab goes where it would have gone.
    static func besideSameSite(_ site: String, sites: [UUID: String], opener: UUID?, in nodes: [Node]) -> (index: Int, parent: UUID?)? {
        var anchor: Int
        if let opener, sites[opener] == site, let at = nodes.firstIndex(where: { $0.id == opener }) {
            anchor = at
        } else if let last = nodes.lastIndex(where: { sites[$0.id] == site }) {
            anchor = last
        } else {
            return nil
        }
        // The same site's tabs just after it at its level are part of the run.
        while true {
            let end = subtreeEnd(at: anchor, in: nodes)
            guard end < nodes.count, nodes[end].parent == nodes[anchor].parent, sites[nodes[end].id] == site else { break }
            anchor = end
        }
        let index = subtreeEnd(at: anchor, in: nodes)
        return (index, parent(at: index, preferring: nodes[anchor].parent, in: nodes))
    }

    /// A tab taken out of the list (closed, pinned, moved away): the tabs right under it move up a level, under its
    /// own parent, and keep their places.
    static func removing(_ id: UUID, from nodes: [Node]) -> [Node] {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return nodes }
        let parent = nodes[index].parent
        var result = nodes
        result.remove(at: index)
        for i in result.indices where result[i].parent == id { result[i].parent = parent }
        return result
    }

    /// A closed tab put back at `index`: under `parent` where that keeps the groups whole, and taking back the tabs
    /// that were under it (`children`, which moved up a level when it closed) if they still follow it, at its level.
    static func reinserting(_ id: UUID, at index: Int, parent: UUID?, children: Set<UUID>, in nodes: [Node]) -> [Node] {
        var result = nodes
        let at = min(max(index, 0), result.count)
        let placed = self.parent(at: at, preferring: parent, in: result)
        result.insert(Node(id: id, parent: placed), at: at)
        var next = at + 1
        while next < result.count, children.contains(result[next].id), result[next].parent == placed {
            result[next].parent = id
            next = subtreeEnd(at: next, in: result)
        }
        return result
    }

    /// A tab that has to stand at the top level (half of a split, which is one row of its own): the tabs right under
    /// it move up a level where they are, and a tab that was nested goes just after the group it was in, so the tabs
    /// after it in that group stay in it.
    static func liftingToTopLevel(_ id: UUID, in nodes: [Node]) -> [Node] {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return nodes }
        guard nodes[index].parent != nil else {
            var result = nodes
            for i in result.indices where result[i].parent == id { result[i].parent = nil }
            return result
        }
        let levels = self.levels(nodes)
        var root = index
        while root > 0, (levels[nodes[root].id] ?? 0) > 0 { root -= 1 }
        let rootID = nodes[root].id
        var result = removing(id, from: nodes)
        guard let rootIndex = result.firstIndex(where: { $0.id == rootID }) else { return nodes }
        result.insert(Node(id: id, parent: nil), at: subtreeEnd(at: rootIndex, in: result))
        return result
    }

    /// A tab moved with everything under it, as one run, to `index` in the list without that run, under `parent`
    /// (nil: the top level; a parent that would break a run is passed over for one that doesn't).
    static func moving(_ id: UUID, to index: Int, parent: UUID?, in nodes: [Node]) -> [Node] {
        guard let start = nodes.firstIndex(where: { $0.id == id }) else { return nodes }
        let end = subtreeEnd(at: start, in: nodes)
        var block = Array(nodes[start..<end])
        var rest = nodes
        rest.removeSubrange(start..<end)
        let at = min(max(index, 0), rest.count)
        // Never under itself or one of its own: those left with it.
        let wanted = parent.flatMap { p in rest.contains { $0.id == p } ? p : nil }
        block[0].parent = self.parent(at: at, preferring: wanted, in: rest)
        rest.insert(contentsOf: block, at: at)
        return rest
    }

    /// `index` in the list without the tab only (as a drop or the overview counts it) as an index in the list without
    /// the tab and everything under it. A place inside its own run lands just after the run.
    static func indexWithoutRun(_ index: Int, moving id: UUID, in nodes: [Node]) -> Int {
        guard let start = nodes.firstIndex(where: { $0.id == id }) else { return index }
        let end = subtreeEnd(at: start, in: nodes)
        let inside = Set(nodes[(start + 1)..<end].map(\.id))
        let withoutTab = nodes.filter { $0.id != id }
        guard index < withoutTab.count else { return nodes.count - (end - start) }
        // Before the first tab at or past `index` that isn't inside the run.
        guard let next = withoutTab[index...].first(where: { !inside.contains($0.id) }) else { return nodes.count - (end - start) }
        let rest = nodes.filter { $0.id != id && !inside.contains($0.id) }
        return rest.firstIndex { $0.id == next.id } ?? rest.count
    }

    /// Move Tab Up or Down: past the tab beside it at its own level, with everything under each. The index is in the
    /// list without the tab's own run; nil at either end of its group.
    static func siblingMoveTarget(_ id: UUID, by offset: Int, in nodes: [Node]) -> Int? {
        guard let start = nodes.firstIndex(where: { $0.id == id }) else { return nil }
        let parent = nodes[start].parent
        let end = subtreeEnd(at: start, in: nodes)
        if offset < 0 {
            // The tab above at its level: everything between is under it, so the run lands before it.
            return nodes[..<start].lastIndex { $0.parent == parent }
        }
        guard end < nodes.count, nodes[end].parent == parent else { return nil }
        return subtreeEnd(at: end, in: nodes) - (end - start)
    }

    /// The tab a drop at a gap goes under, from the rows shown on either side of it (without what's carried): right
    /// under a tab whose tabs show below it, or between two tabs of the same group, it joins that group. After a
    /// group's last row, the pointer picks how many levels out it lands, never further out than the row below:
    /// `setIn(level)` says whether the pointer is set in as far as a row at that level, as for folders.
    static func dropParent(before: UUID?, after: UUID?, in nodes: [Node], setIn: (Int) -> Bool) -> UUID? {
        let parents = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        let levels = self.levels(nodes)
        let below = after.flatMap { parents[$0] ?? nil }
        guard let before else { return nil }
        if let below, below == before { return before }
        var candidate = parents[before] ?? nil
        var seen: Set<UUID> = []
        while let id = candidate, seen.insert(id).inserted {
            if id == below { return id }
            if setIn(shownLevel((levels[id] ?? 0) + 1)) { return id }
            candidate = parents[id] ?? nil
        }
        return nil
    }
}

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

    /// Nest Tab: under the tab above it at its own level, as that tab's last, with everything under it. Nil with no
    /// tab above at its level, or one already as deep as tabs are set in.
    static func nesting(_ id: UUID, in nodes: [Node]) -> [Node]? {
        guard let start = nodes.firstIndex(where: { $0.id == id }),
              let above = nodes[..<start].last(where: { $0.parent == nodes[start].parent }),
              canNestUnder(level: levels(nodes)[above.id] ?? 0) else { return nil }
        var result = nodes
        result[start].parent = above.id
        return result
    }

    /// Unnest Tab: out from under its tab to just after that tab's run, a level up, with everything under it. Nil at
    /// the top level.
    static func unnesting(_ id: UUID, in nodes: [Node]) -> [Node]? {
        guard let start = nodes.firstIndex(where: { $0.id == id }), let parent = nodes[start].parent else { return nil }
        let end = subtreeEnd(at: start, in: nodes)
        var rest = nodes
        rest.removeSubrange(start..<end)
        guard let at = rest.firstIndex(where: { $0.id == parent }) else { return nil }
        let up = rest[at].parent
        return moving(id, to: subtreeEnd(at: at, in: rest), parent: up, in: nodes)
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

    /// Whether a tab at `level` can take tabs under it by a drag or Nest Tab: only where they'd show set in further.
    static func canNestUnder(level: Int) -> Bool { level < shownLevels }

    /// The tab a drop at a gap goes under, from the rows shown on either side of it (without what's carried): right
    /// under a tab whose tabs show below it, or between two tabs of the same group, it joins that group. Set in past
    /// the row above (`nests`), it goes under that row, as its last tab (#523). After a group's last row, the pointer
    /// picks how many levels out it lands, never further out than the row below: `setIn(level)` says whether the
    /// pointer is set in as far as a row at that level, as for folders.
    static func dropParent(before: UUID?, after: UUID?, in nodes: [Node], nests: Bool = true, setIn: (Int) -> Bool) -> UUID? {
        let parents = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        let levels = self.levels(nodes)
        let below = after.flatMap { parents[$0] ?? nil }
        guard let before else { return nil }
        if let below, below == before { return before }
        let level = levels[before] ?? 0
        if nests, canNestUnder(level: level), setIn(level + 1) { return before }
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

/// A tab group (#209): a named, foldable folder in the sidebar's Tabs section. Its tabs stay in the space's list as one
/// contiguous run, each with `groupID`.
nonisolated struct TabGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isOpen = true
}

/// Rules keeping each group one contiguous run, on ids so they're testable. Nested tabs share their parent's group; a
/// tab placed among a group's tabs joins it; split partners share their row's group; a group in two runs keeps the
/// longer.
nonisolated enum TabGroups {
    /// Normalized group per tab. `nodes`: list order. `groups`: each tab's claimed group. `riders`: tabs drawn in
    /// another's row, with that row's tab (nil: a pinned page's row, never grouped). `known`: existing groups.
    /// Ungrouped tabs omitted.
    static func settled(_ nodes: [TabTree.Node], groups: [UUID: UUID], riders: [UUID: UUID?], known: Set<UUID>) -> [UUID: UUID] {
        var result = groups.filter { known.contains($0.value) }
        let rows = nodes.filter { riders[$0.id] == nil }
        // Nested tabs take their parent's group (parents come first).
        for node in rows { if let parent = node.parent { result[node.id] = result[parent] } }
        // Top-level tabs with their nested tabs: the units groups are made of.
        var units: [[UUID]] = []
        for node in rows {
            if node.parent == nil || units.isEmpty { units.append([node.id]) } else { units[units.count - 1].append(node.id) }
        }
        var unitGroup = units.map { result[$0[0]] }
        // An ungrouped tab among a group's tabs joins it.
        var first: [UUID: Int] = [:], last: [UUID: Int] = [:]
        for (i, group) in unitGroup.enumerated() {
            guard let group else { continue }
            if first[group] == nil { first[group] = i }
            last[group] = i
        }
        for i in unitGroup.indices where unitGroup[i] == nil {
            unitGroup[i] = first.first { $0.value < i && (last[$0.key] ?? 0) > i }?.key
        }
        // A group in several runs keeps the longest (first on ties).
        var runs: [(group: UUID, range: Range<Int>)] = []
        for (i, group) in unitGroup.enumerated() {
            guard let group else { continue }
            if let previous = runs.last, previous.group == group, previous.range.upperBound == i {
                runs[runs.count - 1].range = previous.range.lowerBound..<(i + 1)
            } else {
                runs.append((group, i..<(i + 1)))
            }
        }
        var kept: [UUID: Range<Int>] = [:]
        for run in runs where run.range.count > (kept[run.group]?.count ?? 0) { kept[run.group] = run.range }
        for run in runs where kept[run.group] != run.range { for i in run.range { unitGroup[i] = nil } }
        result = [:]
        for (unit, group) in zip(units, unitGroup) { if let group { for id in unit { result[id] = group } } }
        for (rider, lead) in riders { if let lead, let group = result[lead] { result[rider] = group } }
        return result
    }

    /// Each group's tabs in list order.
    static func members(_ nodes: [TabTree.Node], groups: [UUID: UUID]) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for node in nodes { if let group = groups[node.id] { result[group, default: []].append(node.id) } }
        return result
    }

    /// For Clear: a group's tabs count as nested under its first tab, so the group is kept or closed whole. `parents`:
    /// each nested tab's parent.
    static func clearParents(_ parents: [UUID: UUID], nodes: [TabTree.Node], groups: [UUID: UUID]) -> [UUID: UUID] {
        var result = parents
        for (_, ids) in members(nodes, groups: groups) {
            for id in ids.dropFirst() where result[id] == nil { result[id] = ids[0] }
        }
        return result
    }

    /// The list with a group's tabs (`ids`) moved to `index` (counted without them), pushed past any nest or other
    /// group it would split (`groups`: each tab's).
    static func moving(_ ids: [UUID], to index: Int, in nodes: [TabTree.Node], groups: [UUID: UUID]) -> [TabTree.Node] {
        let moving = Set(ids)
        let block = nodes.filter { moving.contains($0.id) }
        let rest = nodes.filter { !moving.contains($0.id) }
        var at = min(max(index, 0), rest.count)
        let group = block.first.flatMap { groups[$0.id] }
        while at < rest.count, at > 0,
              rest[at].parent != nil || (groups[rest[at].id] != nil && groups[rest[at].id] == groups[rest[at - 1].id] && groups[rest[at].id] != group) {
            at += 1
        }
        return Array(rest[..<at]) + block + Array(rest[at...])
    }
}

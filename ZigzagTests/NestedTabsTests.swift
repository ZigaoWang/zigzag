import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Nested tabs (#58): a tab and the tabs under it are one unbroken run of the flat list, and every change keeps it so.
struct NestedTabsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()

    private func node(_ id: UUID, _ parent: UUID? = nil) -> TabTree.Node { TabTree.Node(id: id, parent: parent) }

    /// a, under it b (under it c), then d; e on its own.
    private var tree: [TabTree.Node] { [node(a), node(b, a), node(c, b), node(d, a), node(e)] }

    @Test func levelsFollowTheParents() {
        let levels = TabTree.levels(tree)
        #expect(levels[a] == 0 && levels[b] == 1 && levels[c] == 2 && levels[d] == 1 && levels[e] == 0)
    }

    @Test func deepTabsAreDrawnAtTheSecondLevel() {
        let deep = [node(a), node(b, a), node(c, b), node(d, c), node(e, d)]
        let levels = TabTree.levels(deep)
        #expect(levels[e] == 4)
        #expect(TabTree.shownLevel(levels[e]!) == 2)
        #expect(TabTree.shownLevel(levels[c]!) == 2)
        #expect(TabTree.shownLevel(levels[b]!) == 1)
        #expect(TabTree.shownLevel(0) == 0)
    }

    @Test func aLinkOpensAfterWhatItsTabAlreadyOpened() {
        // From a: after d, the last tab under it, so links stay in reading order.
        #expect(TabTree.childIndex(of: a, in: tree) == 4)
        // From b: after c.
        #expect(TabTree.childIndex(of: b, in: tree) == 3)
        // From e, with nothing under it: right below it.
        #expect(TabTree.childIndex(of: e, in: tree) == 5)
    }

    @Test func closingAParentMovesItsTabsUpALevel() {
        let closed = TabTree.removing(a, from: tree)
        #expect(closed == [node(b), node(c, b), node(d), node(e)])
        // A tab in the middle: its tab goes under its own parent.
        #expect(TabTree.removing(b, from: tree) == [node(a), node(c, a), node(d, a), node(e)])
    }

    @Test func movingAParentTakesItsTabs() {
        // a to the end: its whole run follows, after e.
        let moved = TabTree.moving(a, to: 1, parent: nil, in: tree)
        #expect(moved.map(\.id) == [e, a, b, c, d])
        #expect(moved.first { $0.id == b }?.parent == a)
        #expect(moved.first { $0.id == a }?.parent == nil)
        #expect(TabTree.repaired(moved) == moved)
    }

    @Test func aPlaceInsideItsOwnRunLandsAfterIt() {
        // Without a alone the list is b c d e; "before d" is inside a's run, so a stays put, before e.
        let at = TabTree.indexWithoutRun(2, moving: a, in: tree)
        #expect(at == 0)
        #expect(TabTree.indexWithoutRun(3, moving: a, in: tree) == 0)
        #expect(TabTree.indexWithoutRun(4, moving: a, in: tree) == 1)
    }

    @Test func draggingInMakesAChild() {
        // e dropped between b's run and d, under a.
        let moved = TabTree.moving(e, to: 3, parent: a, in: tree)
        #expect(moved.map(\.id) == [a, b, c, e, d])
        #expect(moved.first { $0.id == e }?.parent == a)
        #expect(TabTree.repaired(moved) == moved)
    }

    @Test func draggingOutMakesATabOfItsOwn() {
        // d dragged to the top level after everything.
        let moved = TabTree.moving(d, to: 4, parent: nil, in: tree)
        #expect(moved.map(\.id) == [a, b, c, e, d])
        #expect(moved.last?.parent == nil)
    }

    @Test func aParentThatWouldBreakAGroupIsPassedOver() {
        // Asked to put e at the top level between b and d: d would lose a, so e joins a's group instead.
        let moved = TabTree.moving(e, to: 1, parent: nil, in: tree)
        #expect(moved.map(\.id) == [a, e, b, c, d])
        #expect(moved.first { $0.id == e }?.parent == a)
        #expect(TabTree.repaired(moved) == moved)
        // Never under itself or a tab of its own.
        let own = TabTree.moving(a, to: 0, parent: c, in: tree)
        #expect(own.first { $0.id == a }?.parent == nil)
    }

    @Test func insertingKeepsGroupsWhole() {
        #expect(TabTree.canInsert(at: 1, parent: a, in: tree))
        #expect(!TabTree.canInsert(at: 1, parent: nil, in: tree))
        #expect(TabTree.canInsert(at: 4, parent: nil, in: tree))
        #expect(TabTree.canInsert(at: 3, parent: b, in: tree))
        #expect(TabTree.parentForInsertion(at: 3, in: tree) == a)
        #expect(TabTree.parentForInsertion(at: 5, in: tree) == nil)
        #expect(TabTree.parent(at: 1, preferring: nil, in: tree) == a)
    }

    @Test func moveUpAndDownStayAtTheirLevel() {
        // d up: past b and c, to just under a.
        #expect(TabTree.siblingMoveTarget(d, by: -1, in: tree) == 1)
        // b down: past d; in the list without b's run (a d e), after d.
        #expect(TabTree.siblingMoveTarget(b, by: 1, in: tree) == 2)
        // The first and last of a group go no further.
        #expect(TabTree.siblingMoveTarget(b, by: -1, in: tree) == nil)
        #expect(TabTree.siblingMoveTarget(d, by: 1, in: tree) == nil)
        // a down past e, with everything under it.
        #expect(TabTree.siblingMoveTarget(a, by: 1, in: tree) == 1)
    }

    @Test func aDropAtAGapPicksItsGroup() {
        let notSetIn: (Int) -> Bool = { _ in false }
        let setIn: (Int) -> Bool = { _ in true }
        // Right under a, whose tabs show: under a.
        #expect(TabTree.dropParent(before: a, after: b, in: tree, setIn: notSetIn) == a)
        // Between two of a's tabs: under a.
        #expect(TabTree.dropParent(before: c, after: d, in: tree, setIn: notSetIn) == a)
        // After a's last tab, before e: set in, it stays in a's group; out at the edge, it's a tab of its own.
        #expect(TabTree.dropParent(before: d, after: e, in: tree) { $0 <= 1 } == a)
        #expect(TabTree.dropParent(before: d, after: e, in: tree, setIn: notSetIn) == nil)
        // After c, deepest: set in only as far as b's tabs.
        #expect(TabTree.dropParent(before: c, after: d, in: tree) { $0 >= 2 } == b)
        // Below a tab with nothing under it: never nested by the gap alone.
        #expect(TabTree.dropParent(before: e, after: nil, in: tree, setIn: notSetIn) == nil)
        #expect(TabTree.dropParent(before: nil, after: a, in: tree, setIn: setIn) == nil)
    }

    @Test func setInPastTheRowAboveADropGoesUnderIt() {
        // e has nothing under it: set in a level past it, the drop goes under it (#523); not set in, beside it.
        #expect(TabTree.dropParent(before: e, after: nil, in: tree) { $0 >= 1 } == e)
        #expect(TabTree.dropParent(before: e, after: nil, in: tree) { $0 < 1 } == nil)
        // d, under a: set in a level past it, under d; only as far as d, under a.
        #expect(TabTree.dropParent(before: d, after: e, in: tree) { $0 >= 2 } == d)
        #expect(TabTree.dropParent(before: d, after: e, in: tree) { $0 == 1 } == a)
        // c is as deep as tabs are set in: nothing goes under it by a drop.
        #expect(TabTree.dropParent(before: c, after: d, in: tree) { _ in true } == b)
        #expect(!TabTree.canNestUnder(level: 2) && TabTree.canNestUnder(level: 1))
        // Asked not to nest (from another window): as before.
        #expect(TabTree.dropParent(before: e, after: nil, in: tree, nests: false) { _ in true } == nil)
        // Dropped there, e's run stays whole and the tab is e's last.
        let moved = TabTree.moving(f, to: 5, parent: e, in: tree + [node(f)])
        #expect(moved.last == node(f, e))
        #expect(TabTree.repaired(moved) == moved)
    }

    @Test func movingAcrossSetsTheCarriedRowInAndOut() {
        let step = SidebarListView.folderIndent
        // A top-level row picked up at x 100: where it was, it sets in no further than its own level.
        let still = SidebarListView.nestX(pointer: 100, grabbedAt: 100, depth: 0)
        #expect(SidebarListView.setsIn(still, depth: 0) && !SidebarListView.setsIn(still, depth: 1))
        // Past half a step right, a level in; a step and a half, two.
        let half = SidebarListView.nestX(pointer: 100 + step / 2 + 1, grabbedAt: 100, depth: 0)
        #expect(SidebarListView.setsIn(half, depth: 1) && !SidebarListView.setsIn(half, depth: 2))
        let more = SidebarListView.nestX(pointer: 100 + step * 1.5 + 1, grabbedAt: 100, depth: 0)
        #expect(SidebarListView.setsIn(more, depth: 2))
        // Less than half a step, a slip, not a move.
        #expect(!SidebarListView.setsIn(SidebarListView.nestX(pointer: 100 + step / 2 - 1, grabbedAt: 100, depth: 0), depth: 1))
        // A nested row (a level in) stays at its level where it was, and goes out past half a step left.
        let nested = SidebarListView.nestX(pointer: 60, grabbedAt: 60, depth: 1)
        #expect(SidebarListView.setsIn(nested, depth: 1) && !SidebarListView.setsIn(nested, depth: 2))
        #expect(!SidebarListView.setsIn(SidebarListView.nestX(pointer: 60 - step / 2 - 1, grabbedAt: 60, depth: 1), depth: 1))
    }

    @Test func nestTabGoesUnderTheTabAboveAtItsLevel() {
        // e under a, after d: a's last tab, its place unchanged.
        let e1 = TabTree.nesting(e, in: tree)
        #expect(e1 == [node(a), node(b, a), node(c, b), node(d, a), node(e, a)])
        // d under b, after c.
        #expect(TabTree.nesting(d, in: tree) == [node(a), node(b, a), node(c, b), node(d, b), node(e)])
        // Nothing above at its level, or the tab above as deep as tabs are set in: no change.
        #expect(TabTree.nesting(a, in: tree) == nil)
        #expect(TabTree.nesting(b, in: tree) == nil)
        let deep = [node(a), node(b, a), node(c, b), node(d, b)]
        #expect(TabTree.nesting(d, in: deep) == nil)
        // It takes its own tabs along.
        let withChild = tree + [node(f, e)]
        #expect(TabTree.nesting(e, in: withChild) == [node(a), node(b, a), node(c, b), node(d, a), node(e, a), node(f, e)])
    }

    @Test func unnestTabGoesJustAfterItsTabsRun() {
        // b out of a: after a's run, top level, with c under it; d stays under a.
        let out = TabTree.unnesting(b, in: tree)
        #expect(out == [node(a), node(d, a), node(b), node(c, b), node(e)])
        #expect(out.map(TabTree.repaired) == out)
        // c out of b: after b's run, under a.
        #expect(TabTree.unnesting(c, in: tree) == [node(a), node(b, a), node(c, a), node(d, a), node(e)])
        // At the top level: nowhere to go.
        #expect(TabTree.unnesting(a, in: tree) == nil)
        // Nest then unnest: back as it was.
        #expect(TabTree.nesting(e, in: tree).flatMap { TabTree.unnesting(e, in: $0) } == tree)
    }

    @MainActor @Test func nestAndUnnestTabUndoAndAreSaved() throws {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<4).map { Tab(url: URL(string: "https://example.com/nest/\($0)"), title: "T\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[1])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        // ⌃⇧→ on the second tab: under the first. The first tab has nothing above it.
        #expect(controller.tabManager.nestedArrangement(of: tabs[0], deeper: true) == nil)
        controller.nestTab(nil)
        #expect(tabs[1].parentID == tabs[0].id)
        // ⌘Z puts it back at the top level; ⌃⇧← does too.
        controller.sidebarUndo.undo()
        #expect(tabs[1].parentID == nil)
        manager.nest(tabs[1], deeper: true)
        controller.unnestTab(nil)
        #expect(tabs[1].parentID == nil)
        controller.sidebarUndo.undo()
        #expect(tabs[1].parentID == tabs[0].id)
        // Under a folded tab, it unfolds so the tab stays in sight.
        manager.select(tabs[2])
        tabs[0].isCollapsed = true
        controller.nestTab(nil)
        #expect(tabs[2].parentID == tabs[0].id && !tabs[0].isCollapsed)
        // A split goes under no tab.
        manager.restoreSplit(TabManager.SplitPair(left: tabs[2].id, right: tabs[3].id))
        #expect(manager.nestedArrangement(of: tabs[2], deeper: true) == nil)
        // The session keeps the nesting: saved, read back and put in a new window as it was.
        let states = manager.tabs(in: space).map { SessionState.TabState($0, parent: $0.parentID) }
        let back = try JSONDecoder().decode([SessionState.TabState].self, from: JSONEncoder().encode(states))
        let restored = back.map { state -> Tab in
            let tab = Tab(id: state.id, url: state.url, title: state.title, spaceID: space)
            state.apply(to: tab)
            return tab
        }
        let again = TabManager(spaceID: space)
        defer { again.invalidate() }
        again.adopt(restored, in: space)
        #expect(again.treeNodes(in: space) == manager.treeNodes(in: space))
        manager.tabs(in: space).forEach { $0.close() }
        restored.forEach { $0.close() }
    }

    @Test func repairDropsParentsThatBreakTheRule() {
        // f's parent is gone, d's parent is below it, and c's run is broken by e.
        let broken = [node(d, b), node(a), node(b, a), node(e), node(c, b), node(f, UUID())]
        let fixed = TabTree.repaired(broken)
        #expect(fixed.map(\.id) == broken.map(\.id))
        #expect(fixed.map(\.parent) == [nil, nil, a, nil, nil, nil])
        #expect(TabTree.repaired(tree) == tree)
    }

    @Test func descendantsAreTheWholeRun() {
        #expect(TabTree.descendants(of: a, in: tree) == [b, c, d])
        #expect(TabTree.descendants(of: b, in: tree) == [c])
        #expect(TabTree.descendants(of: e, in: tree).isEmpty)
        #expect(TabTree.hasChildren(a, in: tree) && !TabTree.hasChildren(c, in: tree))
    }

    @Test func closingManyAndPuttingThemBackKeepsTheirNesting() {
        // a, b under it, c under b, closed together (a first): each closes with its own tab lifted a level.
        var nodes = [node(a), node(b, a), node(c, b), node(e)]
        var records: [(id: UUID, index: Int, parent: UUID?, children: [UUID])] = []
        for id in [a, b, c] {
            let i = nodes.firstIndex { $0.id == id }!
            records.append((id, i, nodes[i].parent, nodes.filter { $0.parent == id }.map(\.id)))
            nodes = TabTree.removing(id, from: nodes)
        }
        #expect(nodes == [node(e)])
        // Put back in reverse, each as a new tab with a new id: the ones already back are found by the ids they have now.
        var now: [UUID: UUID] = [:]
        for record in records.reversed() {
            let id = UUID()
            nodes = TabTree.reinserting(id, at: record.index, parent: record.parent.map { now[$0] ?? $0 },
                                        children: Set(record.children.map { now[$0] ?? $0 }), in: nodes)
            now[record.id] = id
        }
        let (newA, newB, newC) = (now[a]!, now[b]!, now[c]!)
        #expect(nodes == [node(newA), node(newB, newA), node(newC, newB), node(e)])
    }

    @Test func closingAFoldedTabClosesWhatIsUnderIt() {
        // Folded (#155): a and everything under it, in list order. Unfolded: a alone, the rest move up a level.
        #expect(TabTree.closing(a, folded: true, in: tree) == [a, b, c, d])
        #expect(TabTree.closing(a, folded: false, in: tree) == [a])
        #expect(TabTree.closing(b, folded: true, in: tree) == [b, c])
        // Folded with nothing under it, or gone: as ever.
        #expect(TabTree.closing(e, folded: true, in: tree) == [e])
        #expect(TabTree.closing(f, folded: true, in: tree).isEmpty)
    }

    /// Closes these one by one as TabManager.close does (the tab you're on last), then puts them back in reverse as
    /// ⌘Z does, each as a new tab: the list it ends with, in the old ids.
    private func closeAndPutBack(_ ids: [UUID], selected: UUID?, in start: [TabTree.Node]) -> (closed: [TabTree.Node], back: [TabTree.Node]) {
        let order = ids.filter { $0 != selected } + ids.filter { $0 == selected }
        var nodes = start
        var records: [(id: UUID, index: Int, parent: UUID?, children: [UUID])] = []
        for id in order {
            let i = nodes.firstIndex { $0.id == id }!
            records.append((id, i, nodes[i].parent, nodes.filter { $0.parent == id }.map(\.id)))
            nodes = TabTree.removing(id, from: nodes)
        }
        let closed = nodes
        var now: [UUID: UUID] = [:]
        for record in records.reversed() {
            let id = UUID()
            nodes = TabTree.reinserting(id, at: record.index, parent: record.parent.map { now[$0] ?? $0 },
                                        children: Set(record.children.map { now[$0] ?? $0 }), in: nodes)
            now[record.id] = id
        }
        let old = Dictionary(uniqueKeysWithValues: now.map { ($1, $0) })
        return (closed, nodes.map { node(old[$0.id] ?? $0.id, $0.parent.map { old[$0] ?? $0 }) })
    }

    @Test func undoBringsAFoldedTabBackWithEverythingUnderIt() {
        let start = tree + [node(f, e)]
        let closing = TabTree.closing(a, folded: true, in: start)
        // On a, the folded tab: it closes last.
        let onIt = closeAndPutBack(closing, selected: a, in: start)
        #expect(onIt.closed == [node(e), node(f, e)])
        #expect(onIt.back == start)
        // On another tab, and on a tab inside the fold (it shows while you're on it).
        #expect(closeAndPutBack(closing, selected: e, in: start).back == start)
        #expect(closeAndPutBack(closing, selected: c, in: start).back == start)
    }

    @Test func aTabPutBackUnderAParentThatIsBackFirst() {
        // c closed, then b; ⇧⌘T brings b back first, then c, which goes under b again.
        var nodes = TabTree.removing(c, from: tree)
        nodes = TabTree.removing(b, from: nodes)
        let newB = UUID()
        nodes = TabTree.reinserting(newB, at: 1, parent: a, children: [], in: nodes)
        let newC = UUID()
        nodes = TabTree.reinserting(newC, at: 2, parent: newB, children: [], in: nodes)
        #expect(nodes == [node(a), node(newB, a), node(newC, newB), node(d, a), node(e)])
        #expect(TabTree.repaired(nodes) == nodes)
    }

    @Test func aSplitHalfStandsAtTheTopLevelWithoutBreakingItsGroup() {
        // b becomes half of a split: c moves up under a where it is, b goes after a's group, and d stays in it.
        let lifted = TabTree.liftingToTopLevel(b, in: tree)
        #expect(lifted == [node(a), node(c, a), node(d, a), node(b), node(e)])
        #expect(TabTree.repaired(lifted) == lifted)
        // A tab at the top level stays put; the tabs under it move up a level.
        #expect(TabTree.liftingToTopLevel(a, in: tree) == [node(a), node(b), node(c, b), node(d), node(e)])
        // A deep tab goes after the whole group it was in.
        #expect(TabTree.liftingToTopLevel(c, in: tree) == [node(a), node(b, a), node(d, a), node(c), node(e)])
        #expect(TabTree.liftingToTopLevel(f, in: tree) == tree)
    }

    // MARK: Saving

    @Test func aSessionFromBeforeNestedTabsOpens() throws {
        let json = #"{"id":"\#(a.uuidString)","title":"Old","lastActivated":0,"createdAt":0}"#
        let state = try JSONDecoder().decode(SessionState.TabState.self, from: Data(json.utf8))
        #expect(state.parentID == nil)
        #expect(state.collapsed == nil)
        #expect(state.title == "Old")
    }

    @Test func nestingIsSavedAndReadBack() throws {
        let saved = SessionState.TabState(id: b, url: URL(string: "https://example.com"), title: "B", lastActivated: Date(timeIntervalSince1970: 1),
                                          createdAt: Date(timeIntervalSince1970: 1), customTitle: nil, parentID: a, collapsed: true)
        let back = try JSONDecoder().decode(SessionState.TabState.self, from: JSONEncoder().encode(saved))
        #expect(back.parentID == a)
        #expect(back.collapsed == true)
    }

    @Test func tabsUnderAnUnsavedTabAreSavedALevelUp() {
        // b has no page yet and isn't saved: c is saved under a.
        let parents = SessionState.savedParents(tree, keeping: [a, c, d, e])
        #expect(parents == [c: a, d: a])
        #expect(SessionState.savedParents(tree, keeping: [a, b, c, d, e]) == [b: a, c: b, d: a])
    }
}

/// The sidebar's rows for nested tabs (#526).
@MainActor
struct NestedTabRowsTests {
    private func inWindow(_ count: Int, _ body: (BrowserWindowController, [Tab]) throws -> Void) throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tabs = (0..<count).map { Tab(url: URL(string: "https://example.com/nest-row/\($0)"), title: "T\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 900, height: 600))
        defer { controller.window?.close() }
        // Behind the other windows: a drag finds the list under the pointer among the windows on screen.
        controller.window?.orderBack(nil)
        controller.window?.layoutIfNeeded()
        try body(controller, tabs)
    }

    private func shownRow(_ tab: Tab, in list: SidebarListView) throws -> TabRowView {
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        return try #require(list.row(for: tab) as? TabRowView)
    }

    private func click(_ button: IconButton) throws {
        button.onClick?(try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
    }

    @Test func theChevronGoesWithTheLastTabUnderIt() throws {
        try inWindow(3) { controller, tabs in
            let manager = controller.tabManager, list = controller.sidebar.list
            manager.nest(tabs[1], deeper: true)
            manager.select(tabs[2])
            let row = try shownRow(tabs[0], in: list)
            // The chevron shows, takes the click, and folds the tab under it away.
            let chevron = try #require(row.debugNestedButton)
            #expect(row.hitTest(row.convert(NSPoint(x: chevron.frame.midX, y: chevron.frame.midY), to: row.superview)) === chevron)
            try click(chevron)
            #expect(tabs[0].isCollapsed)
            #expect(!list.debugItems.contains(.tab(tabs[1].id)))
            // Folded or not, once the last tab under it goes a level out, the chevron goes too.
            manager.select(tabs[1])
            manager.nest(tabs[1], deeper: false)
            #expect(try shownRow(tabs[0], in: list).debugNestedButton == nil)
            // Under it again: back, and it folds.
            manager.nest(tabs[1], deeper: true)
            manager.select(tabs[2])
            let again = try #require(try shownRow(tabs[0], in: list).debugNestedButton)
            if tabs[0].isCollapsed { try click(again) }
            try click(again)
            #expect(tabs[0].isCollapsed)
            #expect(!list.debugItems.contains(.tab(tabs[1].id)))
        }
    }
}

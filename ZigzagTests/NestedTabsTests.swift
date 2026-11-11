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
        #expect(TabTree.dropParent(before: d, after: e, in: tree, setIn: setIn) == a)
        #expect(TabTree.dropParent(before: d, after: e, in: tree, setIn: notSetIn) == nil)
        // After c, deepest: set in only as far as b's tabs.
        #expect(TabTree.dropParent(before: c, after: d, in: tree) { $0 >= 2 } == b)
        // Below a tab with nothing under it: never nested by the gap alone.
        #expect(TabTree.dropParent(before: e, after: nil, in: tree, setIn: setIn) == nil)
        #expect(TabTree.dropParent(before: nil, after: a, in: tree, setIn: setIn) == nil)
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

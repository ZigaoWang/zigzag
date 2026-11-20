import Foundation
import Testing
@testable import Zigzag

/// Tab groups (#209): a folder over one contiguous run of tabs that stays intact, collapses, restores with the session, and is cleared as one.
struct TabGroupRulesTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    let g = UUID(), h = UUID()

    private func node(_ id: UUID, _ parent: UUID? = nil) -> TabTree.Node { TabTree.Node(id: id, parent: parent) }

    @Test func aNestedTabIsInItsParentsGroup() {
        let nodes = [node(a), node(b, a), node(c)]
        let settled = TabGroups.settled(nodes, groups: [a: g], riders: [:], known: [g])
        #expect(settled == [a: g, b: g])
    }

    @Test func aTabPutDownAmongAGroupsTabsJoinsIt() {
        let nodes = [node(a), node(b), node(c), node(d)]
        let settled = TabGroups.settled(nodes, groups: [a: g, c: g], riders: [:], known: [g])
        #expect(settled == [a: g, b: g, c: g])
    }

    @Test func aGroupInTwoRunsKeepsTheLongerOne() {
        let nodes = [node(a), node(b), node(c), node(d)]
        // d is in g but separated by h's tab: it leaves g.
        let settled = TabGroups.settled(nodes, groups: [a: g, b: g, c: h, d: g], riders: [:], known: [g, h])
        #expect(settled == [a: g, b: g, c: h])
    }

    @Test func aGroupThatsGoneHoldsNoTabs() {
        let settled = TabGroups.settled([node(a), node(b)], groups: [a: g, b: h], riders: [:], known: [h])
        #expect(settled == [b: h])
    }

    @Test func aSplitsOtherPageIsInItsRowsGroup() {
        // b rides in a's row; c rides in a pinned page's row, in no group.
        let nodes = [node(b), node(a), node(d), node(c)]
        let riders: [UUID: UUID?] = [b: a, c: nil]
        let settled = TabGroups.settled(nodes, groups: [a: g, d: g, c: g], riders: riders, known: [g])
        #expect(settled == [a: g, b: g, d: g])
    }

    @Test func aGroupMovesWholeAndNeverIntoAnother() {
        let nodes = [node(a), node(b), node(c), node(d, c), node(e)]
        let groups = [a: g, b: g]
        // Moving between c and its child: placed after both.
        let moved = TabGroups.moving([a, b], to: 1, in: nodes, groups: groups)
        #expect(moved.map(\.id) == [c, d, a, b, e])
        // Into another group's tabs: after them.
        let other = [node(a), node(b), node(c), node(d), node(e)]
        let pushed = TabGroups.moving([e], to: 2, in: other, groups: [a: g, b: g, c: g, e: h])
        #expect(pushed.map(\.id) == [a, b, c, e, d])
    }

    @Test func clearKeepsOrClosesAGroupAsOne() {
        let nodes = [node(a), node(b), node(c), node(d)]
        let parents = TabGroups.clearParents([:], nodes: nodes, groups: [c: g, d: g])
        #expect(parents == [d: c])
        let units = TabManager.units([a, b, c, d], groups: [], parents: parents)
        #expect(units == [[a], [b], [c, d]])
        // c seen just now, d long ago: the group stays whole; only b goes.
        let minutes: [UUID: TimeInterval] = [a: 0, b: 400 * 60, c: 1 * 60, d: 500 * 60]
        let kept = TabManager.clearing([a, b, c, d], current: a, groups: [], parents: parents, busy: [], ages: minutes)
        #expect(kept.ids == [b])
        // Both stale: they go together.
        let old: [UUID: TimeInterval] = [a: 0, b: 60, c: 400 * 60, d: 500 * 60]
        let gone = TabManager.clearing([a, b, c, d], current: a, groups: [], parents: parents, busy: [], ages: old)
        #expect(gone.ids == [c, d])
    }
}

@MainActor struct TabGroupsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// A window with tabs a–e, closed after the test.
    private func window(_ body: (TabManager, [Tab]) throws -> Void) rethrows {
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<5).map { Tab(url: URL(string: "https://example.com/\($0)"), title: "\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs)
    }

    private func order(_ manager: TabManager) -> [UUID] { manager.tabs(in: space).map(\.id) }

    @Test func groupingPutsTheTabsTogetherWhereTheFirstIs() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[3], t[1]], name: "Reading"))
            #expect(order(manager) == [t[0], t[1], t[3], t[2], t[4]].map(\.id))
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[1].id, t[3].id])
            #expect(manager.group(id)?.name == "Reading")
            #expect(manager.group(id)?.isOpen == true)
            #expect(manager.groups(in: space).map(\.id) == [id])
        }
    }

    @Test func tabsGoInAndOut() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            manager.setGroup(of: t[4], to: id)
            #expect(order(manager) == [t[0], t[1], t[4], t[2], t[3]].map(\.id))
            #expect(manager.tabs(inGroup: id).count == 3)
            manager.setGroup(of: t[0], to: nil)
            // Out, just after the group.
            #expect(order(manager) == [t[1], t[4], t[0], t[2], t[3]].map(\.id))
            #expect(t[0].groupID == nil)
            // Moving out of the group leaves it; moving within stays.
            manager.move(t[1], to: 1)
            #expect(t[1].groupID == id)
            manager.move(t[4], to: 4)
            #expect(t[4].groupID == nil)
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[1].id])
        }
    }

    @Test func aTabOpenedFromTheGroupsLastTabIsInIt() throws {
        let place = TabManager.newTabPlace
        defer { TabManager.newTabPlace = place }
        TabManager.newTabPlace = .next
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            let opened = manager.newTab(url: nil, spaceID: space, select: false, opener: t[1])
            #expect(order(manager)[2] == opened.id)
            #expect(opened.groupID == id)
            // Opened from an outside tab next to it: not in the group.
            let other = manager.newTab(url: nil, spaceID: space, select: false, opener: t[4])
            #expect(other.groupID == nil)
        }
    }

    @Test func foldingAndRenaming() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[2]], name: "G"))
            manager.setGroupOpen(id, false)
            #expect(manager.group(id)?.isOpen == false)
            manager.renameGroup(id, to: "  Work ")
            #expect(manager.group(id)?.name == "Work")
            manager.renameGroup(id, to: " ")
            #expect(manager.group(id)?.name == "Work")
        }
    }

    @Test func aGroupWithNoTabsGoesAndComesBackWithThem() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[1], t[2]], name: "Trip"))
            manager.setGroupOpen(id, false)
            let closed = manager.close([t[1], t[2]])
            #expect(manager.group(id) == nil)
            #expect(manager.groups(in: space).isEmpty)
            // Undo Close Tabs restores each tab and the group with its name and collapse state.
            manager.together { for tab in closed.reversed() { manager.reopenClosedTab(tab, select: false) } }
            #expect(manager.group(id)?.name == "Trip")
            #expect(manager.group(id)?.isOpen == false)
            #expect(manager.tabs(inGroup: id).map(\.displayTitle) == ["1", "2"])
            #expect(manager.tabs(in: space).map(\.displayTitle) == ["0", "1", "2", "3", "4"])
        }
    }

    @Test func ungroupingLeavesTheTabsWhereTheyAre() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[1], t[2]], name: "G"))
            manager.ungroup(id)
            #expect(manager.group(id) == nil)
            #expect(order(manager) == t.map(\.id))
            #expect(t.allSatisfy { $0.groupID == nil })
            // Deleted: reopening one of its tabs doesn't restore it.
            manager.close(t[1])
            let back = manager.reopenClosedTab(select: false)
            #expect(back?.groupID == nil)
        }
    }

    @Test func undoPutsTheGroupsBack() throws {
        try window { manager, t in
            let before = manager.arrangement
            let id = try #require(manager.makeGroup(with: [t[3], t[4]], name: "G"))
            let after = manager.arrangement
            #expect(!before.isSame(as: after))
            manager.restore(before, undoing: after)
            #expect(manager.group(id) == nil)
            #expect(order(manager) == t.map(\.id))
            // And again.
            manager.restore(after, undoing: before)
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[3].id, t[4].id])
            // Renames are undoable.
            let named = manager.arrangement
            manager.renameGroup(id, to: "H")
            #expect(!named.isSame(as: manager.arrangement))
        }
    }

    @Test func aGroupMovesWhole() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            manager.moveGroup(id, to: 2)
            #expect(order(manager) == [t[2], t[3], t[0], t[1], t[4]].map(\.id))
            #expect(manager.tabs(inGroup: id).count == 2)
        }
    }

    @Test func aTabMovedToAnotherSpaceLeavesItsGroup() throws {
        guard Library.shared.spaces.count > 1 else { return }
        let other = Library.shared.spaces[1].id
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            manager.moveTabToSpace(t[1], spaceID: other)
            #expect(t[1].groupID == nil)
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[0].id])
            manager.moveTabToSpace(t[0], spaceID: other)
            #expect(manager.group(id) == nil)
        }
    }

    @Test func groupsComeBackWithTheSession() throws {
        let group = TabGroup(name: "Saved", isOpen: false)
        var tab = SessionState.TabState(id: UUID(), url: URL(string: "https://example.com"), title: "x", lastActivated: Date(), createdAt: Date())
        tab.groupID = group.id
        let window = SessionState.WindowState(frame: [0, 0, 800, 600], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
                                              spaces: [SessionState.SpaceTabs(spaceID: space, tabs: [tab], selectedTabID: nil)],
                                              bookmarkTabs: [], isFullScreen: nil, splits: nil, tabGroups: [group])
        let data = try JSONEncoder().encode(SessionState(windows: [window]))
        let read = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(read.windows[0].tabGroups == [group])
        #expect(read.windows[0].spaces[0].tabs[0].groupID == group.id)
        // Restored like at launch: groups first, then tabs.
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        manager.restoreGroups(read.windows[0].tabGroups ?? [])
        let restored = Tab(id: tab.id, url: tab.url, title: tab.title, spaceID: space)
        read.windows[0].spaces[0].tabs[0].apply(to: restored)
        manager.adopt([restored], in: space)
        manager.structureChanged()
        #expect(manager.group(group.id) == group)
        #expect(manager.tabs(inGroup: group.id).map(\.id) == [restored.id])
        // Pre-group sessions have none.
        let old = #"{"windows":[{"frame":[0,0,1,1],"sidebarVisible":true,"sidebarWidth":240,"currentSpaceID":"\#(space.uuidString)","spaces":[],"bookmarkTabs":[]}]}"#
        #expect(try JSONDecoder().decode(SessionState.self, from: Data(old.utf8)).windows[0].tabGroups == nil)
    }
}

/// Which tab shows after closing the one you're on (#412), as in Chrome.
@MainActor @Suite(.serialized) struct TabCloseSelectionTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// A window with tabs 0–4, links opening next to the tab they came from.
    private func window(_ body: (TabManager, [Tab]) throws -> Void) rethrows {
        let place = TabManager.newTabPlace, nests = TabManager.nestsOpenedLinks
        TabManager.newTabPlace = .next
        TabManager.nestsOpenedLinks = false
        defer { TabManager.newTabPlace = place; TabManager.nestsOpenedLinks = nests }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<5).map { Tab(url: nil, title: "\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs)
    }

    @Test func closingGoesToTheTabBelowNotTheOneYouWereOnBefore() {
        window { manager, t in
            manager.select(t[4])
            manager.select(t[2])
            manager.close(t[2])
            #expect(manager.selectedTab === t[3])
            // The last one goes up.
            manager.select(t[4])
            manager.close(t[4])
            #expect(manager.selectedTab === t[3])
        }
    }

    @Test func aLinkOpenedInFrontClosesBackToItsPage() {
        window { manager, t in
            manager.select(t[1])
            let opened = manager.newTab(url: nil, spaceID: space, select: true, opener: t[1])
            manager.close(opened)
            #expect(manager.selectedTab === t[1])
        }
    }

    @Test func linksOpenedBehindKeepTheirOrderAndCloseToTheNextOne() {
        window { manager, t in
            manager.select(t[1])
            let links = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false, opener: t[1]) }
            #expect(Array(manager.tabs(in: space)[2...4]).map(\.id) == links.map(\.id))
            // Opened in front after them: closing it goes to the last link the page opened, then up the row.
            let front = manager.newTab(url: nil, spaceID: space, select: true, opener: t[1])
            manager.close(front)
            #expect(manager.selectedTab === links[2])
        }
    }

    @Test func switchingTabsYourselfForgetsTheOpener() {
        window { manager, t in
            manager.select(t[1])
            let links = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false, opener: t[1]) }
            // Reading the results one by one: each ⌘W lands on the next, not back on the page they came from.
            manager.select(links[0])
            manager.close(links[0])
            #expect(manager.selectedTab === links[1])
            manager.close(links[1])
            #expect(manager.selectedTab === links[2])
            // Opened in front, then left and come back to: it closes to the tab below, not its page.
            let opened = manager.newTab(url: nil, spaceID: space, select: true, opener: t[0])
            manager.select(t[4])
            manager.select(opened)
            manager.close(opened)
            #expect(manager.selectedTab === t[1])
        }
    }

    @Test func aTabInAShutGroupBelowIsPassedOver() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[3], t[4]], name: "G"))
            manager.setGroupOpen(id, false)
            manager.select(t[2])
            manager.close(t[2])
            #expect(manager.selectedTab === t[1])
        }
    }
}

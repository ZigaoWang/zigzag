import Foundation
import Testing
@testable import Zigzag

/// A gap among the tab rows lands at the right place in the tab list, where a split is one row but two tabs.
struct TabDropIndexTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func noSplitsRowsAreTabs() {
        let rows = [[a], [b], [c]]
        #expect(SidebarListView.listIndex(forRow: 0, rows: rows, in: [a, b, c]) == 0)
        #expect(SidebarListView.listIndex(forRow: 2, rows: rows, in: [a, b, c]) == 2)
        #expect(SidebarListView.listIndex(forRow: 3, rows: rows, in: [a, b, c]) == 3)
    }

    @Test func belowASplitCountsBothHalves() {
        // A|B, C, D with C carried: below D is the end of A, B, D, not between B and D.
        let rows = [[a, b], [d]]
        #expect(SidebarListView.listIndex(forRow: 2, rows: rows, in: [a, b, d]) == 3)
        // Just under the split: after both its halves.
        #expect(SidebarListView.listIndex(forRow: 1, rows: rows, in: [a, b, d]) == 2)
        // Above it: before both.
        #expect(SidebarListView.listIndex(forRow: 0, rows: rows, in: [a, b, d]) == 0)
    }

    @Test func aSplitWhoseRightHalfComesFirst() {
        // The row is the left half's, but the right half sits earlier in the list: land before the pair.
        let rows = [[c], [a, b]]
        #expect(SidebarListView.listIndex(forRow: 1, rows: rows, in: [c, b, a]) == 1)
    }

    @Test func aRowWithNothingInTheListLooksFurther() {
        let rows = [[a], [b], [c]]
        #expect(SidebarListView.listIndex(forRow: 1, rows: rows, in: [a, c]) == 1)
    }
}

/// ⌘A with rows picked picks the rest of the section they're in.
struct PickAllTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var all: [SidebarItem] { [.bookmark(a), .bookmark(b), .tab(c), .tab(d)] }

    @Test func tabsPickTheTabs() {
        #expect(SidebarListView.rowsToPick(all: all, marked: [.tab(c)]) == [.tab(c), .tab(d)])
    }

    @Test func pinnedPagesPickThePinnedPages() {
        #expect(SidebarListView.rowsToPick(all: all, marked: [.bookmark(b)]) == [.bookmark(a), .bookmark(b)])
    }

    @Test func bothPickEverything() {
        #expect(SidebarListView.rowsToPick(all: all, marked: [.bookmark(a), .tab(d)]) == all)
    }
}

/// Clear closes the tabs you've drifted away from, keeping the ones you're working with now; with none, every tab
/// but yours. Never one playing sound or in a call.
struct ClearTabsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    let minute: TimeInterval = 60

    func ages(_ minutes: [UUID: Double]) -> [UUID: TimeInterval] { minutes.mapValues { $0 * minute } }

    @Test func closesWhatYouDriftedAwayFrom() {
        let result = TabManager.clearing([a, b, c, d], current: a, partner: nil, busy: [], ages: ages([a: 0, b: 1, c: 3, d: 300]))
        #expect(result.ids == [d])
        #expect(result.kind == .unused)
    }

    @Test func allRecentClosesEveryTabButYours() {
        let result = TabManager.clearing([a, b, c], current: b, partner: nil, busy: [], ages: ages([a: 1, b: 0, c: 2]))
        #expect(result.ids == [a, c])
        #expect(result.kind == .others)
    }

    @Test func keepsYourSplitTogether() {
        let result = TabManager.clearing([a, b, c, d], current: b, partner: c, busy: [], ages: ages([a: 1, b: 0, c: 500, d: 2]))
        #expect(result.ids == [a, d])
    }

    @Test func onAPinnedPageItsEveryTab() {
        #expect(TabManager.clearing([a, b], current: e, partner: nil, busy: [], ages: ages([a: 1, b: 2])).ids == [a, b])
    }

    @Test func leavesWhatsPlaying() {
        let result = TabManager.clearing([a, b, c, d], current: a, partner: nil, busy: [d], ages: ages([a: 0, b: 1, c: 400, d: 500]))
        #expect(result.ids == [c])
    }

    @Test func yoursOnlyOnceTheyAreAllThatsLeft() {
        let result = TabManager.clearing([a, b], current: a, partner: b, busy: [], ages: [:])
        #expect(result.ids == [a, b])
        #expect(result.kind == .last)
        // A tab still playing beside yours keeps yours open: Clear has nothing to do.
        #expect(TabManager.clearing([a, b], current: a, partner: nil, busy: [b], ages: [:]).ids.isEmpty)
    }

    // MARK: Splits, tile groups and nests are one unit

    let f = UUID(), p = UUID()

    func clearing(_ tabs: [UUID], current: UUID?, groups: [[UUID]] = [], parents: [UUID: UUID] = [:], busy: Set<UUID> = [],
                  minutes: [UUID: Double]) -> (ids: Set<UUID>, kind: TabManager.ClearKind) {
        TabManager.clearing(tabs, current: current, groups: groups, parents: parents, busy: busy, ages: ages(minutes))
    }

    @Test func aSplitIsAsRecentAsItsNewestPage() {
        // The page you had focus on in the split was seen a minute ago; the other half hours ago. Neither goes.
        let result = clearing([a, b, c, d, e], current: a, groups: [[c, d]], minutes: [a: 0, b: 1, c: 1, d: 500, e: 500])
        #expect(result.ids == [e] && result.kind == .unused)
    }

    @Test func aSplitLeftAloneClosesWhole() {
        let result = clearing([a, b, c, d], current: a, groups: [[c, d]], minutes: [a: 0, b: 1, c: 400, d: 500])
        #expect(result.ids == [c, d] && result.kind == .unused)
        // A tile group of three too.
        let group = clearing([a, b, c, d, e], current: a, groups: [[c, d, e]], minutes: [a: 0, b: 1, c: 400, d: 500, e: 450])
        #expect(group.ids == [c, d, e])
    }

    @Test func aSplitWithAnythingPlayingStaysWhole() {
        let result = clearing([a, b, c, d], current: a, groups: [[c, d]], busy: [d], minutes: [a: 0, b: 1, c: 400, d: 500])
        #expect(result.ids == [b] && result.kind == .others)
        // Not even the other half goes at the end.
        #expect(clearing([c, d], current: c, groups: [[c, d]], busy: [d], minutes: [:]).ids.isEmpty)
    }

    @Test func yourTileGroupStaysTillLast() {
        let groups = [[a, b, c]]
        let others = clearing([a, b, c, d, e], current: b, groups: groups, minutes: [a: 900, b: 0, c: 900, d: 1, e: 2])
        #expect(others.ids == [d, e] && others.kind == .others)
        let last = clearing([a, b, c], current: b, groups: groups, minutes: [a: 900, b: 0, c: 900])
        #expect(last.ids == [a, b, c] && last.kind == .last)
    }

    @Test func aTabBesideAPinnedPageStays() {
        // `p` is a pinned page, not among the tabs: the tab beside it is never cleared, stale or not.
        let result = clearing([a, b, c], current: a, groups: [[p, c]], minutes: [a: 0, b: 1, c: 500])
        #expect(result.ids == [b] && result.kind == .others)
        // On the pinned page, its tab is yours; the rest go.
        #expect(clearing([c, d], current: p, groups: [[p, c]], minutes: [c: 500, d: 1]).ids == [d])
        // And at the end there's nothing to close.
        #expect(clearing([c], current: p, groups: [[p, c]], minutes: [c: 500]).ids.isEmpty)
    }

    @Test func pinnedSplitsAreNeverCleared() {
        // A split of two pinned pages has no tab in the list: it changes nothing.
        let q = UUID()
        let result = clearing([a, b, c], current: a, groups: [[p, q]], minutes: [a: 0, b: 1, c: 500])
        #expect(result.ids == [c])
        #expect(!result.ids.contains(p) && !result.ids.contains(q))
    }

    @Test func aNestUsedLatelyStaysWhole() {
        // The parent was left hours ago, but a tab nested under it a minute ago: both stay.
        let fresh = clearing([a, p, b, c], current: a, parents: [b: p], minutes: [a: 0, p: 500, b: 1, c: 400])
        #expect(fresh.ids == [c] && fresh.kind == .unused)
        // A parent you used, its folded-away tabs left alone: they stay with it.
        let folded = clearing([a, p, b, c], current: a, parents: [b: p], minutes: [a: 0, p: 1, b: 500, c: 400])
        #expect(folded.ids == [c])
    }

    @Test func aNestLeftAloneClosesWhole() {
        let result = clearing([a, b, p, c, d], current: a, parents: [c: p, d: c], minutes: [a: 0, b: 1, p: 400, c: 500, d: 600])
        #expect(result.ids == [p, c, d] && result.kind == .unused)
    }

    @Test func theNestYoureInIsYours() {
        // On a tab nested under one left hours ago: that parent is part of what you're doing.
        let result = clearing([p, a, b, c], current: a, parents: [a: p], minutes: [p: 500, a: 0, b: 1, c: 400])
        #expect(result.ids == [c])
    }

    @Test func everyTabButYoursIncludesYourNest() {
        // Nothing left you've drifted from: "the other tabs" means every one, nested with yours or not.
        let result = clearing([p, a, b], current: a, parents: [a: p], minutes: [p: 1, a: 0, b: 2])
        #expect(result.ids == [p, b] && result.kind == .others)
    }

    @Test func aNestWithSomethingPlayingStays() {
        let result = clearing([a, b, p, c], current: a, parents: [c: p], busy: [c], minutes: [a: 0, b: 1, p: 400, c: 500])
        #expect(result.ids == [p, b] && result.kind == .others)
        // Once it's every tab but yours, only the one playing stays.
        #expect(!result.ids.contains(c))
    }

    @Test func aSplitAndANestTogether() {
        // A split whose half has a tab nested under it: one unit, as recent as that tab.
        let result = clearing([a, b, c, d, e, f], current: a, groups: [[c, d]], parents: [e: d],
                              minutes: [a: 0, b: 1, c: 400, d: 500, e: 2, f: 300])
        #expect(result.ids == [f])
    }

    @Test func unitsKeepListOrder() {
        #expect(TabManager.units([a, b, c, d], groups: [[d, b]], parents: [c: a]) == [[a, c], [b, d]])
        // A pinned page in a group isn't a tab: left out.
        #expect(TabManager.units([a, b], groups: [[p, b]], parents: [:]) == [[a], [b]])
    }

    // MARK: In a window

    @MainActor @Test func aSplitClosesAndComesBackWhole() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        (0..<4).forEach { _ in manager.newTab(url: nil, spaceID: space, select: false).parentID = nil }
        let tabs = manager.tabs(in: space)
        manager.select(tabs[0])
        manager.restoreSplit(TabManager.SplitPair(left: tabs[2].id, right: tabs[3].id))
        let now = Date()
        tabs[1].lastActivated = now.addingTimeInterval(-60)
        tabs[2].lastActivated = now.addingTimeInterval(-400 * 60)
        tabs[3].lastActivated = now.addingTimeInterval(-500 * 60)
        let (closing, kind) = manager.tabsToClear(in: space, now: now)
        #expect(Set(closing.map(\.id)) == [tabs[2].id, tabs[3].id] && kind == .unused)
        // Closed, then brought back as Undo does: side by side again, on the same sides, where they were.
        let ids = manager.closeLeavingSpaceEmpty(closing)
        #expect(manager.tabs(in: space).count == 2)
        let back = ids.reversed().compactMap { manager.reopenClosedTab($0, select: false) }
        guard back.count == 2 else { Issue.record("not back"); return }
        // The last closed comes back first: the right half, then the left.
        let pair = manager.split(for: back[0])
        #expect(pair?.left == back[1].id && pair?.right == back[0].id)
        #expect(manager.tabs(in: space).map(\.id) == [tabs[0].id, tabs[1].id, back[1].id, back[0].id])
        // As stale as before, so Clear would close them again, whole.
        #expect(Set(manager.tabsToClear(in: space, now: now).tabs.map(\.id)) == Set(back.map(\.id)))
        manager.tabs(in: space).forEach { $0.close() }
    }

    @MainActor @Test func aRecentPageKeepsItsTileGroup() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        (0..<5).forEach { _ in manager.newTab(url: nil, spaceID: space, select: false).parentID = nil }
        let tabs = manager.tabs(in: space)
        manager.select(tabs[0])
        let shape = TileShape(regions: [.left, .topRight, .bottomRight])
        guard let group = TabManager.SplitPair(ids: [tabs[2].id, tabs[3].id, tabs[4].id], shape: shape) else { Issue.record("no group"); return }
        manager.restoreSplit(group)
        let now = Date()
        tabs[1].lastActivated = now.addingTimeInterval(-300 * 60)
        tabs[2].lastActivated = now.addingTimeInterval(-60)
        tabs[3].lastActivated = now.addingTimeInterval(-600 * 60)
        tabs[4].lastActivated = now.addingTimeInterval(-600 * 60)
        #expect(manager.tabsToClear(in: space, now: now).tabs.map(\.id) == [tabs[1].id])
        manager.tabs(in: space).forEach { $0.close() }
    }

    @MainActor @Test func aRestoredTabKeepsWhenYouLastSawIt() throws {
        // What the session saves and reads back at launch: the time you last looked at it, not the launch.
        let seen = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        let tab = Tab(url: URL(string: "https://example.com"), title: "Example", spaceID: UUID(), lastActivated: seen)
        let state = SessionState.TabState(tab)
        let read = try JSONDecoder().decode(SessionState.TabState.self, from: JSONEncoder().encode(state))
        #expect(abs(read.lastActivated.timeIntervalSince(seen)) < 0.001)
        tab.close()
    }
}

/// The tabs you're working with now: the newest ones, up to the first clear break in how long ago they were seen.
struct KeptByActivityTests {
    func kept(minutes: [Double]) -> Int { TabManager.keptByActivity(minutes.map { $0 * 60 }) }

    @Test func aBurstOfTenAmongFiftySevenOlder() {
        let burst: [Double] = [0.5, 1, 2, 3, 5, 7, 10, 12, 15, 20]
        let older = (0..<57).map { 60 + Double($0) * 3 }
        #expect(kept(minutes: burst + older) == 10)
    }

    @Test func steadyBrowsingKeepsTheNewestFive() {
        #expect(kept(minutes: (1...30).map { Double($0) * 4 }) == 5)
        #expect(kept(minutes: (1...30).map { Double($0) }) == 5)
        #expect(kept(minutes: (1...30).map { Double($0) * 60 }) == 5)
    }

    @Test func everythingWithinTwoMinutesHasNoBreak() {
        #expect(kept(minutes: (0..<20).map { Double($0) * 0.1 }) == 5)
    }

    @Test func whatCountsAsABreakFollowsYourPace() {
        // Back after hours away: tabs a few minutes apart are one session, and the hours-old ones go.
        #expect(kept(minutes: [1, 2, 8, 9, 600, 700]) == 4)
        // A quick hour: three tabs from the last few minutes, the rest from half an hour ago. That's a break.
        #expect(kept(minutes: [1, 2, 3, 30, 40, 50]) == 3)
        // Steady through the hour: no break, the newest five.
        #expect(kept(minutes: [1, 2, 15, 20, 40, 60]) == 5)
    }

    @Test func aTabLeftMinutesAgoIsNeverUnused() {
        // Left one a minute ago, another seven: neither is one you haven't used in a while.
        #expect(kept(minutes: [1, 7]) == 2)
        #expect(kept(minutes: [1, 6, 7]) == 3)
        // A tab just opened in the background and never looked at doesn't make the ones of a quarter hour ago stale.
        #expect(kept(minutes: [0.1, 15, 16]) == 3)
        // Half an hour against a minute is a break.
        #expect(kept(minutes: [0.1, 1, 30, 40]) == 2)
    }

    @Test func twoTabs() {
        #expect(kept(minutes: [1, 120]) == 1)
        // Both recent: both stay, and Clear closes every tab but yours instead.
        #expect(kept(minutes: [1, 3]) == 2)
    }

    @Test func oneVeryOldTabAmongRecentOnes() {
        #expect(kept(minutes: [1, 2, 3, 4, 3 * 24 * 60]) == 4)
    }

    @Test func tabsOpenedInTheBackgroundCountFromWhenTheyOpened() {
        // Eight looked at in the last few minutes; twenty opened behind them 45 minutes ago and never looked at.
        #expect(kept(minutes: [0.2, 0.5, 1, 2, 3, 4, 5, 6] + Array(repeating: 45, count: 20)) == 8)
        // Ten just opened in the background are new, and stay.
        #expect(kept(minutes: Array(repeating: 0.5, count: 10) + [60, 90, 120]) == 10)
    }

    @Test func theBiggerBreakWinsOverAnEarlyOne() {
        // Seen seconds ago, then a few around ten minutes, then the rest hours ago: the hours are the break.
        #expect(kept(minutes: [0.5, 8, 9, 10, 240, 300]) == 4)
    }

    @Test func noMoreThanADozenAtOnce() {
        #expect(kept(minutes: (1...20).map { Double($0) } + [600, 700]) == 5)
    }

    @Test func none() {
        #expect(kept(minutes: []) == 0)
    }
}

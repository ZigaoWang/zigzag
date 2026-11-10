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
}

/// The tabs you're working with now: the newest ones, up to the first clear break in how long ago they were seen.
struct KeptByActivityTests {
    func kept(minutes: [Double]) -> Int { TabManager.keptByActivity(minutes.map { $0 * 60 }) }

    @Test func aBurstOfTenAmongFiftySevenOlder() {
        let burst: [Double] = [0.5, 1, 2, 3, 5, 7, 10, 12, 15, 20]
        let older = (0..<57).map { 60 + Double($0) * 3 }
        #expect(kept(minutes: burst + older) == 10)
    }

    @Test func steadyBrowsingKeepsWhatWasSeenInTheLastHalfHour() {
        // Every four minutes: the seven seen in the last half hour stay.
        #expect(kept(minutes: (1...30).map { Double($0) * 4 }) == 7)
        // Every minute: no more than a dozen at once.
        #expect(kept(minutes: (1...30).map { Double($0) }) == 12)
        // Every hour: no break and nothing recent, so the newest five.
        #expect(kept(minutes: (1...30).map { Double($0) * 60 }) == 5)
    }

    @Test func aFewMinutesApartIsNeverABreak() {
        // Two tabs, then one seen eight minutes ago: before, that was a break that kept only two.
        #expect(kept(minutes: [1, 2, 8, 9, 600, 700]) == 4)
        #expect(kept(minutes: (0..<20).map { Double($0) * 0.1 }) == 12)
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
        #expect(kept(minutes: (1...20).map { Double($0) } + [600, 700]) == 12)
    }

    @Test func none() {
        #expect(kept(minutes: []) == 0)
    }
}

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

/// Clear closes every tab but yours, however new, and never one playing sound or in a call.
struct ClearTabsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func everyTabButYours() {
        #expect(TabManager.clearing([a, b, c], current: b, partner: nil, busy: []) == [a, c])
    }

    @Test func keepsYourSplitTogether() {
        #expect(TabManager.clearing([a, b, c, d], current: b, partner: c, busy: []) == [a, d])
    }

    @Test func onAPinnedPageItsEveryTab() {
        #expect(TabManager.clearing([a, b], current: d, partner: nil, busy: []) == [a, b])
    }

    @Test func leavesWhatsPlaying() {
        #expect(TabManager.clearing([a, b, c], current: a, partner: nil, busy: [c]) == [b])
    }

    @Test func yoursOnlyOnceTheyAreAllThatsLeft() {
        #expect(TabManager.clearing([a, b], current: a, partner: b, busy: []) == [a, b])
        // A tab still playing beside yours keeps yours open: Clear has nothing to do.
        #expect(TabManager.clearing([a, b], current: a, partner: nil, busy: [b]).isEmpty)
    }
}

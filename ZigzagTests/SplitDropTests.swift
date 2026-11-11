import Foundation
import Testing
@testable import Zigzag

/// Which pages can be dropped on another's middle to open side by side, in the tab list and the favorites grid alike.
struct SplitDropTests {
    typealias Side = TabManager.SplitSide

    @Test func whatOpensSideBySide() {
        let tab = Side(kind: .tab, inSplit: false), pinned = Side(kind: .pinned, inSplit: false), favorite = Side(kind: .favorite, inSplit: false)
        #expect(TabManager.canSplit(tab, onto: tab))
        #expect(TabManager.canSplit(tab, onto: pinned))
        #expect(TabManager.canSplit(pinned, onto: tab))
        #expect(TabManager.canSplit(tab, onto: favorite))
        #expect(TabManager.canSplit(pinned, onto: favorite))
        #expect(TabManager.canSplit(favorite, onto: favorite))
        #expect(TabManager.canSplit(pinned, onto: pinned))
        #expect(!TabManager.canSplit(favorite, onto: tab))
        #expect(!TabManager.canSplit(favorite, onto: pinned))
    }

    @Test func aSplitIsNeverBrokenByADrop() {
        let split = Side(kind: .tab, inSplit: true), tab = Side(kind: .tab, inSplit: false)
        for kind in [Side.Kind.tab, .pinned, .favorite] {
            #expect(!TabManager.canSplit(split, onto: Side(kind: kind, inSplit: false)))
            #expect(!TabManager.canSplit(tab, onto: Side(kind: kind, inSplit: true)))
            #expect(!TabManager.canSplit(Side(kind: kind, inSplit: true), onto: Side(kind: .favorite, inSplit: false)))
        }
    }

    @Test func aBlankTabDoesntSplit() {
        let blank = Side(kind: .tab, inSplit: false, hasPage: false), tab = Side(kind: .tab, inSplit: false)
        #expect(!TabManager.canSplit(blank, onto: tab))
        #expect(!TabManager.canSplit(tab, onto: blank))
    }

    /// A split shows in one row: a pinned page split beside a tab carries it in its own row, so neither page shows twice.
    @Test func aSplitShowsInOneRow() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), pin = UUID()
        // Two tabs: the right one rides in the left one's row.
        #expect(SidebarListView.ridingTabs(tabs: [a, b], splits: [(a, b)], pinned: []) == [b])
        // A pinned page beside a tab, either side: the tab rides in the pinned row.
        #expect(SidebarListView.ridingTabs(tabs: [c], splits: [(pin, c)], pinned: [pin]) == [c])
        #expect(SidebarListView.ridingTabs(tabs: [c], splits: [(c, pin)], pinned: [pin]) == [c])
        // Tabs on their own keep their rows.
        #expect(SidebarListView.ridingTabs(tabs: [a, b, d], splits: [], pinned: []).isEmpty)
        // A right half whose left half isn't in this list keeps a row of its own.
        #expect(SidebarListView.ridingTabs(tabs: [b], splits: [(a, b)], pinned: []).isEmpty)
    }
}

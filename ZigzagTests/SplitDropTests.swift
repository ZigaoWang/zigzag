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
        #expect(!TabManager.canSplit(pinned, onto: pinned))
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
}

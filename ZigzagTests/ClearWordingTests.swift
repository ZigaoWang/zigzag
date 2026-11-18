import Foundation
import Testing
@testable import Zigzag

/// Clear's tooltip: no "other tabs" when on a favorite or pinned page, and a lone split named as one.
struct ClearWordingTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), favorite = UUID()

    private func text(_ kind: TabManager.ClearKind, closing: Set<UUID>, current: UUID?, groups: [[UUID]] = []) -> String {
        ClearTabsButton.tooltip(for: ClearTabsButton.step(kind: kind, closing: closing, current: current, listed: [a, b, c, d], groups: groups))
    }

    @Test func onAFavoriteItsAllTheTabs() {
        let step = ClearTabsButton.step(kind: .others, closing: [a, b], current: favorite, listed: [a, b], groups: [])
        #expect(step.kind == .all && step.pages == 2)
        #expect(ClearTabsButton.step(kind: .others, closing: [a], current: nil, listed: [a], groups: []).kind == .all)
        // On a tab, the rest are "other".
        #expect(ClearTabsButton.step(kind: .others, closing: [b], current: a, listed: [a, b], groups: []).kind == .others)
        // A pinned page split with a tab: that tab counts as current.
        #expect(ClearTabsButton.step(kind: .others, closing: [b], current: favorite, listed: [a, b], groups: [[favorite, a]]).kind == .others)
    }

    @Test func aLoneSplitIsNamedAsOne() {
        let split = [[b, c]]
        #expect(ClearTabsButton.step(kind: .others, closing: [b, c], current: a, listed: [a, b, c], groups: split).oneSplit)
        #expect(!ClearTabsButton.step(kind: .others, closing: [b, c, d], current: a, listed: [a, b, c, d], groups: split).oneSplit)
        #expect(!ClearTabsButton.step(kind: .others, closing: [b, d], current: a, listed: [a, b, d], groups: []).oneSplit)
        #expect(text(.others, closing: [b, c], current: a, groups: split) == "Close the other split view")
        #expect(text(.others, closing: [b, c], current: favorite, groups: split) == "Close the split view")
        #expect(text(.last, closing: [b, c], current: b, groups: split) == "Close this split view, leaving the space empty")
        #expect(text(.unused, closing: [b, c], current: a, groups: split) == "Close the split view you haven’t used in a while")
    }

    @Test func pagesAreCountedAsTabs() {
        #expect(text(.others, closing: [b, c, d], current: a, groups: [[b, c]]) == "Close the other 3 tabs")
        #expect(text(.others, closing: [b, c], current: favorite) == "Close all 2 tabs")
        #expect(text(.others, closing: [b], current: favorite) == "Close the tab")
        #expect(text(.others, closing: [b], current: a) == "Close the other tab")
        #expect(text(.last, closing: [a], current: a) == "Close the last tab, leaving the space empty")
    }
}

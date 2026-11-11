import Foundation
import Testing
@testable import Zigzag

/// A split pane's strip gives its own buttons away before its address or its close button.
@MainActor struct PaneHeaderTests {
    typealias Fit = PaneHeaderView.Fit
    let edge: CGFloat = 2
    let address: CGFloat = 180

    @Test func wideShowsEverything() {
        #expect(PaneHeaderView.fit(width: 700, edge: edge, address: address) == .all)
    }

    @Test func swapAndLayoutGoBeforeTheAddressIsCut() {
        // Swap and the layout go into ⋯ while the address would still be cut beside them.
        let fit = PaneHeaderView.fit(width: 330, edge: edge, address: address)
        #expect(fit == .splitInMore)
        #expect(fit.showsForward && fit.showsReload && fit.showsSeparate && fit.showsMore && !fit.showsSplitButtons)
    }

    @Test func thenSeparateForwardAndReload() {
        // Each step only to keep the address its least width.
        #expect(PaneHeaderView.fit(width: 250, edge: edge, address: address) == .splitInMore)
        #expect(PaneHeaderView.fit(width: 225, edge: edge, address: address) == .separateInMore)
        #expect(PaneHeaderView.fit(width: 200, edge: edge, address: address) == .noForward)
        #expect(PaneHeaderView.fit(width: 175, edge: edge, address: address) == .noReload)
        #expect(PaneHeaderView.fit(width: 80, edge: edge, address: address) == .noReload)
    }

    @Test func aShortAddressNeedsLessRoom() {
        #expect(PaneHeaderView.fit(width: 250, edge: edge, address: 30) == .all)
    }

    @Test func fewerButtonsAsItNarrows() {
        var last = Fit.all
        for width in stride(from: 700, through: 60, by: -10) {
            let fit = PaneHeaderView.fit(width: CGFloat(width), edge: edge, address: address)
            #expect(fit >= last)
            last = fit
        }
    }
}

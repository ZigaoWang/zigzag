import AppKit
import Testing
@testable import Zigzag

/// The edge sidebar's lens lifecycle (#363/#365): the panel and the lens are one session, each dismissal says what
/// it closes, and the lens joins another app's Space without bringing Zigzag forward.
@MainActor
struct EdgeSidebarLifecycleTests {
    @Test func thePanelStaysWhileTheLensIsHeld() {
        #expect(EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: true))
        #expect(!EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: false))
    }

    @Test func aSidebarActionClosesOnlyTheLens() {
        for reason in [EdgeLensReason.sameTab, .sidebarClick, .escape] {
            #expect(EdgeLensPolicy.dismissal(for: reason) == .lensOnly)
        }
    }

    @Test func aClosedWindowTakesTheSidebarWithTheLens() {
        for reason in [EdgeLensReason.windowClose, .featureOff] {
            #expect(EdgeLensPolicy.hidesSidebar(after: reason, pointerInEdgeZone: true, panelCanShow: true))
        }
    }

    @Test func anotherAppLeavesTheSidebarToItsProximity() {
        #expect(!EdgeLensPolicy.hidesSidebar(after: .altTab, pointerInEdgeZone: true, panelCanShow: true))
        #expect(EdgeLensPolicy.hidesSidebar(after: .altTab, pointerInEdgeZone: false, panelCanShow: true))
    }

    @Test func theLensJoinsTheSpaceWithoutActivating() {
        #expect(EdgePopoutPolicy.ordersFrontRegardless(floating: true))
    }

    @Test func aSpaceChangeKeepsTheLens() {
        #expect(EdgePeekRouting.keepsLensOnSpaceChange(peekVisible: true))
        #expect(!EdgePeekRouting.keepsLensOnSpaceChange(peekVisible: false))
    }

    @Test func aPageOpenedFromTheLensStaysInTheLens() {
        #expect(EdgePeekRouting.newPage(peekVisible: true) == .peek)
        #expect(EdgePeekRouting.newPage(peekVisible: false) == .browser)
    }
}

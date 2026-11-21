import AppKit
import Testing
@testable import Zigzag

/// The edge sidebar's popout lifecycle (#363): it stays while the panel is being used, closes when the panel goes
/// or a click lands outside it, and its own shortcuts work from a non-activating panel.
@MainActor
struct EdgeSidebarLifecycleTests {
    @Test func thePanelStaysWhileThePopoutIsHeld() {
        #expect(EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: true))
        #expect(!EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: false))
    }

    @Test func anOutsideClickClosesThePopout() {
        let mini = NSWindow()
        let panel = NSWindow()
        // A click in another app has no window here.
        #expect(EdgePopoutPolicy.closesOnOutsideClick(eventWindow: nil, mini: mini, panel: panel))
        // Its own page and the sidebar that opened it are not outside.
        #expect(!EdgePopoutPolicy.closesOnOutsideClick(eventWindow: mini, mini: mini, panel: panel))
        #expect(!EdgePopoutPolicy.closesOnOutsideClick(eventWindow: panel, mini: mini, panel: panel))
        #expect(EdgePopoutPolicy.closesOnOutsideClick(eventWindow: NSWindow(), mini: mini, panel: panel))
    }

    @Test func anInternalPageClosesOnTheFirstEscape() {
        #expect(EdgePopoutPolicy.closesOnFirstEscape(isInternalPage: true, isLeaving: false, commandBarVisible: false))
        #expect(!EdgePopoutPolicy.closesOnFirstEscape(isInternalPage: false, isLeaving: false, commandBarVisible: false))
        #expect(!EdgePopoutPolicy.closesOnFirstEscape(isInternalPage: true, isLeaving: true, commandBarVisible: false))
        #expect(!EdgePopoutPolicy.closesOnFirstEscape(isInternalPage: true, isLeaving: false, commandBarVisible: true))
    }

    @Test func commandOReturnsFromThePopout() {
        #expect(EdgePopoutPolicy.isReturnKey(command: true, key: "o"))
        #expect(EdgePopoutPolicy.isReturnKey(command: true, key: "O"))
        #expect(!EdgePopoutPolicy.isReturnKey(command: false, key: "o"))
        #expect(!EdgePopoutPolicy.isReturnKey(command: true, key: "p"))
    }

    @Test func thePopoutJoinsTheSpaceWithoutActivating() {
        #expect(EdgePopoutPolicy.ordersFrontRegardless(floating: true))
        #expect(!EdgePopoutPolicy.ordersFrontRegardless(floating: false))
    }
}

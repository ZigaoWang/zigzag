import AppKit
import WebKit
import Testing
@testable import Zigzag

/// The lens's own rules: what keeps it out while it is used, what can come back, and what a space or a new page does.
@MainActor
struct EdgePeekTests {
    @Test func theSidebarKeepsTheLensOpen() {
        #expect(EdgePeekFocusPolicy.keepsOpen(newKey: .sidebar, menuOpen: false))
    }

    @Test func aThirdPartySwitcherClosesTheLens() {
        #expect(!EdgePeekFocusPolicy.keepsOpen(newKey: .none, menuOpen: false))
        #expect(!EdgePeekFocusPolicy.keepsOpen(newKey: .other, menuOpen: false))
    }

    @Test func anOwnedSheetOrMenuKeepsItOpen() {
        #expect(EdgePeekFocusPolicy.keepsOpen(newKey: .owned, menuOpen: false))
        #expect(EdgePeekFocusPolicy.keepsOpen(newKey: .none, menuOpen: true))
    }

    @Test func aClosedTabIsNeverRestored() {
        #expect(!EdgePeekRestorePolicy.canRestore(isClosed: true, hasOrigin: true))
        #expect(!EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: false))
        #expect(EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: true))
    }

    @Test func aSelectionChangePutsThePageBackOnlyWhereItsCardStillShowsIt() {
        #expect(EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: true, reason: .selection,
                                                 cardStillShowsPage: true))
        #expect(!EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: true, reason: .selection,
                                                  cardStillShowsPage: false))
        #expect(EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: true, reason: .escape,
                                                 cardStillShowsPage: false))
    }

    @Test func anotherRowSwitchesTheLensToThatPage() {
        #expect(EdgeLensPolicy.pickAction(isVisible: false, sameTab: false) == .open)
        #expect(EdgeLensPolicy.pickAction(isVisible: true, sameTab: true) == .close)
        #expect(EdgeLensPolicy.pickAction(isVisible: true, sameTab: false) == .replace)
    }

    @Test func aSpaceSwitchKeepsTheSidebarOut() {
        #expect(!EdgeLensPolicy.hidesSidebar(after: .spaceChange, pointerInEdgeZone: false, panelCanShow: true))
    }

    @Test func aSpaceChangeEndsTheLens() {
        #expect(EdgePeekRouting.closesOnSpaceChange(peekVisible: true))
        #expect(!EdgePeekRouting.closesOnSpaceChange(peekVisible: false))
    }

    @Test func aNewPageFromTheLensStaysInTheLens() {
        #expect(EdgePeekRouting.newPage(peekVisible: true) == .peek)
        #expect(EdgePeekRouting.newPage(peekVisible: false) == .browser)
    }

    @Test func aPageOpenedFromTheLensIsAReplacementNotASelectionChange() {
        let space = UUID()
        let lens = Tab(url: URL(string: "https://example.com")!, title: "Lens", spaceID: space)
        let opened = Tab(url: URL(string: "https://example.com/next")!, title: "Next", spaceID: space,
                         configuration: WKWebViewConfiguration())
        #expect(opened.url == nil)
        opened.opener = lens
        #expect(EdgePeekRouting.selectionKeepsLens(lensTab: lens, selected: opened))
        #expect(!EdgePeekRouting.selectionKeepsLens(lensTab: lens, selected: lens))
        #expect(!EdgePeekRouting.selectionKeepsLens(lensTab: lens, selected: nil))
    }

    @Test func theLensTakesAPageOpenedBeforeItHasAnAddress() {
        let space = UUID()
        let lens = Tab(url: URL(string: "https://example.com")!, title: "Lens", spaceID: space)
        let opened = Tab(url: URL(string: "https://example.com/next")!, title: "Next", spaceID: space,
                         configuration: WKWebViewConfiguration())
        #expect(EdgePeekSwap.canTake(opened, from: lens, isClosed: false))
        #expect(!EdgePeekSwap.canTake(lens, from: lens, isClosed: false))
        #expect(!EdgePeekSwap.canTake(opened, from: lens, isClosed: true))
    }
}

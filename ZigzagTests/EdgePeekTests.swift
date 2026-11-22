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

    @Test func aPreviewWaitsForThePointerToRest() {
        // Crossing a row: nothing.
        #expect(!EdgePeekHoverPolicy.rests(now: EdgePeekHoverPolicy.dwell - 0.01, since: 0, moved: false))
        // Rested on it: the page comes.
        #expect(EdgePeekHoverPolicy.rests(now: EdgePeekHoverPolicy.dwell, since: 0, moved: false))
        #expect(EdgePeekHoverPolicy.rests(now: 0.9, since: 0.5, moved: false))
        // Moving within the row starts the wait again, however long it has been there.
        #expect(!EdgePeekHoverPolicy.rests(now: 5, since: 0, moved: true))
        #expect(!EdgePeekHoverPolicy.rests(now: EdgePeekHoverPolicy.dwell + 0.3, since: 0.5, moved: true))
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

    @Test func anotherRowSwitchesThePageAndTheSameRowLocksIt() {
        #expect(EdgeLensPolicy.pickAction(isVisible: false, sameTab: false) == .open)
        #expect(EdgeLensPolicy.pickAction(isVisible: true, sameTab: true) == .lock)
        #expect(EdgeLensPolicy.pickAction(isVisible: true, sameTab: false) == .replace)
        #expect(!EdgeLensPolicy.restoresAfterHover(locked: false))
        #expect(EdgeLensPolicy.restoresAfterHover(locked: true))
    }

    /// The panel lends the tab's own page, so Zigzag's own pages (Settings, History, the archive) have nothing to
    /// lend: their rows grey out and take no pick. A web page, local or not, is taken.
    @Test func thePanelTakesWebPagesAndNotZigzagsOwn() {
        #expect(EdgeLensPolicy.takesPage(url: URL(string: "https://example.com/page")))
        #expect(EdgeLensPolicy.takesPage(url: URL(string: "http://localhost:8080")))
        #expect(!EdgeLensPolicy.takesPage(url: URL(string: "zigzag://settings")))
        #expect(!EdgeLensPolicy.takesPage(url: URL(string: "zigzag://history")))
        #expect(!EdgeLensPolicy.takesPage(url: URL(string: "zigzag://archive")))
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

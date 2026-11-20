import AppKit
import Testing
@testable import Zigzag

/// The peek popout beside the edge sidebar: the page area inside the screen's margins, not the sidebar card's.
@MainActor
struct EdgePeekTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func thePageSitsInsideTheScreenMargins() {
        let sidebar = NSRect(x: 1160, y: 16, width: 264, height: 868)
        let page = EdgePeekLayout.pageFrame(beside: sidebar, in: screen, onRight: true)
        #expect(page.minX == screen.minX + Tokens.Space.x2)
        #expect(page.maxX == sidebar.minX - Tokens.Space.x2)
        #expect(page.minY == screen.minY + Tokens.Space.x2)
        #expect(page.maxY == screen.maxY - Tokens.Space.x2)
    }

    @Test func thePageSitsOnTheOtherSideOfALeftSidebar() {
        let sidebar = NSRect(x: 16, y: 16, width: 264, height: 868)
        let page = EdgePeekLayout.pageFrame(beside: sidebar, in: screen, onRight: false)
        #expect(page.minX == sidebar.maxX + Tokens.Space.x2)
        #expect(page.maxX == screen.maxX - Tokens.Space.x2)
        #expect(page.minY == screen.minY + Tokens.Space.x2)
        #expect(page.maxY == screen.maxY - Tokens.Space.x2)
    }

    @Test func theExpandedFrameIsTheVisibleScreenInset() {
        let frame = EdgePeekLayout.expandedFrame(in: screen, onRight: true)
        #expect(frame == screen.insetBy(dx: Tokens.Space.x2, dy: Tokens.Space.x2))
    }

    @Test func aNarrowScreenLeavesAPositivePage() {
        let small = NSRect(x: 0, y: 0, width: 300, height: 300)
        let sidebar = NSRect(x: 290, y: 10, width: 10, height: 280)
        let page = EdgePeekLayout.pageFrame(beside: sidebar, in: small, onRight: true)
        #expect(page.width >= 0)
        #expect(page.height >= 0)
    }

    @Test func theSidebarKeepsThePeekOpen() {
        #expect(EdgePeekFocusPolicy.keepsOpen(newKey: .sidebar, menuOpen: false))
    }

    @Test func aThirdPartySwitcherClosesThePeek() {
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

    @Test func aSpaceChangeEndsThePeek() {
        #expect(EdgePeekRouting.closesOnSpaceChange(peekVisible: true))
        #expect(!EdgePeekRouting.closesOnSpaceChange(peekVisible: false))
    }

    @Test func aNewPageFromThePeekStaysInThePeek() {
        #expect(EdgePeekRouting.newPage(peekVisible: true) == .peek)
        #expect(EdgePeekRouting.newPage(peekVisible: false) == .browser)
    }

    @Test func theToolbarShowsTheStateItIsGiven() {
        let toolbar = EdgePeekToolbar(frame: .zero)
        toolbar.update(state: EdgePeekToolbarState(address: "youtube.com/watch?v=1", canGoBack: true,
                                                   canGoForward: false, isLoading: true))
        #expect(toolbar.addressField.stringValue == "youtube.com/watch?v=1")
        #expect(toolbar.backButton.isEnabled)
        #expect(!toolbar.forwardButton.isEnabled)
        #expect(toolbar.reloadButton.isLoading)
    }

    @Test func anOffsetScreenKeepsThePageOnIt() {
        let offset = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        let sidebar = NSRect(x: 1512 + 1000, y: 16, width: 264, height: 768)
        let page = EdgePeekLayout.pageFrame(beside: sidebar, in: offset, onRight: true)
        #expect(offset.contains(page))
    }
}

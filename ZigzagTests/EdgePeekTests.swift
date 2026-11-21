import AppKit
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
        let opened = Tab(url: URL(string: "https://example.com/next")!, title: "Next", spaceID: space)
        opened.opener = lens
        #expect(EdgePeekRouting.selectionKeepsLens(lensTab: lens, selected: opened))
        #expect(!EdgePeekRouting.selectionKeepsLens(lensTab: lens, selected: lens))
        #expect(!EdgePeekRouting.selectionKeepsLens(lensTab: lens, selected: nil))
    }
}

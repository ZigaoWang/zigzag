import AppKit
import Testing
@testable import Zigzag

/// The page beside the edge sidebar: the rest of the screen, its top and bottom the sidebar card's.
@MainActor
struct EdgePeekTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func thePageFillsTheOtherSideOfARightSidebar() {
        let sidebar = NSRect(x: 1160, y: 16, width: 264, height: 868)
        let page = EdgePeekLayout.frame(attachedTo: sidebar, in: screen, onRight: true)
        #expect(page.minX == screen.minX + Tokens.Space.x2)
        #expect(page.maxX == sidebar.minX - Tokens.Space.x2)
        #expect(page.minY == sidebar.minY)
        #expect(page.height == sidebar.height)
        #expect(page.width > 0)
    }

    @Test func thePageFillsTheOtherSideOfALeftSidebar() {
        let sidebar = NSRect(x: 16, y: 16, width: 264, height: 868)
        let page = EdgePeekLayout.frame(attachedTo: sidebar, in: screen, onRight: false)
        #expect(page.minX == sidebar.maxX + Tokens.Space.x2)
        #expect(page.maxX == screen.maxX - Tokens.Space.x2)
        #expect(page.minY == sidebar.minY)
        #expect(page.height == sidebar.height)
        #expect(page.width > 0)
    }

    @Test func aNarrowScreenLeavesAPositivePage() {
        let small = NSRect(x: 0, y: 0, width: 300, height: 300)
        let sidebar = NSRect(x: 290, y: 10, width: 10, height: 280)
        let page = EdgePeekLayout.frame(attachedTo: sidebar, in: small, onRight: true)
        #expect(page.width >= 0)
        #expect(page.height >= 0)
    }

    @Test func anOffsetScreenKeepsThePageOnIt() {
        let offset = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        let sidebar = NSRect(x: 1512 + 1000, y: 16, width: 264, height: 768)
        let page = EdgePeekLayout.frame(attachedTo: sidebar, in: offset, onRight: true)
        #expect(offset.contains(page))
    }
}

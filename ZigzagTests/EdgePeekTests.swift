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

    @Test func anOffsetScreenKeepsThePageOnIt() {
        let offset = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        let sidebar = NSRect(x: 1512 + 1000, y: 16, width: 264, height: 768)
        let page = EdgePeekLayout.pageFrame(beside: sidebar, in: offset, onRight: true)
        #expect(offset.contains(page))
    }
}

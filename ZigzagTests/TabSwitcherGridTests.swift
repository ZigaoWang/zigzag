import AppKit
import Testing
@testable import Zigzag

@MainActor
struct TabSwitcherGridTests {
    private let wide = NSSize(width: 2000, height: 1200)

    @Test func fewCardsSitInOneRowAtFullSize() {
        let grid = TabSwitcher.grid(count: 4, room: wide, aspect: 0.6, chrome: 40, gap: 8)
        #expect(grid.columns == 4)
        #expect(grid.width == Tokens.Metric.switcherThumbWidth)
    }

    @Test func manyCardsGoIntoBalancedRowsInsteadOfShrinking() {
        let grid = TabSwitcher.grid(count: 9, room: NSSize(width: 1000, height: 1200), aspect: 0.6, chrome: 40, gap: 8)
        // Five fit across at the least width: nine make rows of five and four, never nine slivers.
        #expect(grid.columns == 5)
        #expect(grid.width >= Tokens.Metric.switcherThumbMinWidth)
    }

    @Test func rowsTooTallForTheWindowMakeCardsSmaller() {
        let grid = TabSwitcher.grid(count: 9, room: NSSize(width: 600, height: 300), aspect: 0.6, chrome: 40, gap: 8)
        let rows = (9 + grid.columns - 1) / grid.columns
        #expect(CGFloat(rows) * (grid.width * 0.6 + 40) + CGFloat(rows - 1) * 8 <= 300 + 1 || grid.width == Tokens.Metric.switcherThumbMinWidth * 0.6)
    }

    @Test func cardsMadeSmallerForHeightNeverGrowPastTheRoom() {
        let grid = TabSwitcher.grid(count: 9, room: NSSize(width: 100, height: 200), aspect: 0.6, chrome: 40, gap: 8)
        #expect(grid.width <= 100)
    }

    /// The panel the cards make, as `show` lays it out.
    private func panel(_ count: Int, on page: NSRect) -> NSSize {
        let pad: CGFloat = 4, gap: CGFloat = 8
        let grid = TabSwitcher.grid(count: count, room: TabSwitcher.room(on: page, pad: pad), aspect: 0.6, chrome: 40, gap: gap)
        let across = CGFloat(min(count, grid.columns)), rows = CGFloat((count + grid.columns - 1) / grid.columns)
        return NSSize(width: pad * 2 + across * grid.width + (across - 1) * gap, height: pad * 2 + rows * (grid.width * 0.6 + 40) + (rows - 1) * gap)
    }

    @Test func manyTabsStayOnThePageBesideTheSidebar() {
        let window = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let page = NSRect(x: 240, y: 6, width: 854, height: 748)
        for count in 2...9 {
            let frame = TabSwitcher.panelFrame(size: panel(count, on: page), page: page, window: window)
            #expect(frame.minX >= page.minX, "\(count) tabs")
            #expect(frame.maxX <= page.maxX, "\(count) tabs")
            #expect(abs(frame.midX - page.midX) <= 1, "\(count) tabs")
            #expect(abs(frame.midY - page.midY) <= 1, "\(count) tabs")
        }
    }

    @Test func withTheSidebarHiddenItCentersOnTheWindow() {
        let window = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let page = window.insetBy(dx: 6, dy: 6)
        let frame = TabSwitcher.panelFrame(size: panel(9, on: page), page: page, window: window)
        #expect(abs(frame.midX - window.midX) <= 1)
    }

    @Test func aPanelTooBigForThePageStaysInsideTheWindow() {
        let window = NSRect(x: 0, y: 0, width: 560, height: 400)
        let page = NSRect(x: 240, y: 6, width: 314, height: 388)
        let frame = TabSwitcher.panelFrame(size: NSSize(width: 400, height: 300), page: page, window: window)
        #expect(frame.minX >= window.minX && frame.maxX <= window.maxX)
        #expect(frame.minY >= window.minY && frame.maxY <= window.maxY)
    }

    @Test func aCardHeldByTheSecondPageDrawsEachPageInItsPlace() {
        // A pinned page on the left of a split isn't a tab, so Show All Tabs gives the card to the tab on the right:
        // the card draws its own page first, so the shape's regions follow, the tab's on the right still.
        let pair = TileShape(regions: [.left, .right], column: 0.4)
        let held = DeskController.shape(pair, first: 1)
        #expect(held.regions == [.right, .left] && held.column == 0.4)
        #expect(DeskController.shape(pair, first: 0) == pair)
        let three = TileShape(regions: [.left, .topRight, .bottomRight])
        #expect(DeskController.shape(three, first: 2).regions == [.bottomRight, .left, .topRight])
        #expect(DeskController.shape(three, first: 5) == three)
    }
}

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
}

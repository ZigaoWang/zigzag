import AppKit
import Testing
@testable import Zigzag

/// Draggable edges take the pointer in a band wider than the drawn line, and a drag moves the line from where it is (#362).
@MainActor
struct DragZoneTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width: CGFloat = 240

    @Test func theSidebarsEdgeReachesIntoTheSidebarAndLessOverThePagesScrollBar() {
        let reach = Tokens.Metric.dragReach, inside = Tokens.Metric.sidebarDragReach
        let left = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: false)
        #expect(left.minX == width - inside && left.maxX == width + reach && left.height == window.height)
        #expect(left.minX + BrowserRootView.resizeHandleLine(onRight: false) == width)
        // On the right the page's scroll bar is against the edge: the band keeps mostly to the sidebar.
        let edge = window.maxX - width
        let right = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: true)
        #expect(right.maxX == edge + inside && right.minX == edge - reach / 2 && right.height == window.height)
        #expect(right.minX + BrowserRootView.resizeHandleLine(onRight: true) == edge)
        // Wider than the drawn edge either way, and nowhere near the window's own edges.
        #expect(left.width > Tokens.Metric.resizeHandleWidth && right.width > Tokens.Metric.resizeHandleWidth)
        #expect(left.minX > window.minX + 100 && right.maxX < window.maxX - 100)
    }

    @Test func aSplitsLineReachesIntoBothPagesLessOnTheLeftPagesScrollBarSide() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let gap: CGFloat = 8
        let x = area.minX + floor((area.width - gap) / 2)
        let pair = TileShape(regions: [.left, .right]).dividers(in: area, gap: gap, slop: 4, leading: 2)
        #expect(pair.column == CGRect(x: x - 2, y: area.minY, width: gap + 6, height: area.height))
        let stacked = TileShape(regions: [.top, .bottom]).dividers(in: area, gap: gap, slop: 4, leading: 2)
        let y = area.minY + floor((area.height - gap) / 2)
        #expect(stacked.row == CGRect(x: area.minX, y: y - 4, width: area.width, height: gap + 8))
        // Without a leading reach, the same on both sides, as before.
        let even = TileShape(regions: [.left, .right]).dividers(in: area, gap: gap, slop: 2)
        #expect(even.column == CGRect(x: x - 2, y: area.minY, width: gap + 4, height: area.height))
    }

    @Test func aPressAwayFromTheLineMovesItFromWhereItIs() {
        // Pressed 6pt right of the line at 240, then moved 10pt: the line goes to 250, not to the pointer at 256.
        #expect(ResizeHandle.dragged(256, grab: 6) == 250)
        #expect(ResizeHandle.dragged(230, grab: -8) == 238)
    }

    @Test func theBandTakesThePointerOverTheSidebarAndThePage() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        let root = controller.root
        try #require(root.sidebarVisible)
        let edge = root.sidebarWidth
        func hit(_ dx: CGFloat) -> NSView? {
            let point = root.convert(NSPoint(x: edge + dx, y: root.bounds.midY), to: nil)
            return window.contentView?.superview?.hitTest(point)
        }
        // Inside the sidebar's empty strip, on the edge, and just over the page: the handle.
        for dx: CGFloat in [-Tokens.Metric.sidebarDragReach + 1, -3, 0, Tokens.Metric.dragReach - 1] {
            #expect(hit(dx) is ResizeHandle, "at \(dx)")
        }
        // Further in either way: the sidebar's rows, or the page.
        #expect(!(hit(-Tokens.Metric.sidebarDragReach - 4) is ResizeHandle))
        #expect(!(hit(Tokens.Metric.dragReach + 4) is ResizeHandle))
    }
}

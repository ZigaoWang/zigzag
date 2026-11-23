import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Dragging a tab onto the page, or a pane by its strip, by the mouse or a finger: the hint over the page names the
/// page coming in and where it goes, and a finger's drop does what the mouse's does.
@MainActor struct SplitDragTests {
    private func inWindow(_ titles: [String], _ body: (BrowserWindowController, [Tab]) throws -> Void) throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = titles.enumerated().map { i, title in Tab(url: URL(string: "https://example.com/drag/\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        let window = try #require(controller.window)
        // On screen for the drop's window lookup, but out of sight.
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        defer { window.orderOut(nil); window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try body(controller, tabs)
    }

    /// A point of the page area, as shares of its width and height from its top left, in window coordinates.
    private func page(_ controller: BrowserWindowController, _ x: CGFloat, _ y: CGFloat) -> NSPoint {
        let area = controller.root.cardFrame
        let top = controller.root.isFlipped ? area.minY + area.height * y : area.maxY - area.height * y
        return controller.root.convert(NSPoint(x: area.minX + area.width * x, y: top), to: nil)
    }

    private func middle(of view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }

    private func region(_ drop: TileDrop?) -> TileRegion? {
        guard case .place(let region, _)? = drop?.kind else { return nil }
        return region
    }

    // MARK: The hint

    @Test func theCardSitsInTheMiddleAndStepsAsideForThePointer() {
        let zone = CGRect(x: 0, y: 0, width: 600, height: 500), size = CGSize(width: 200, height: 54)
        let middle = SplitDropHint.cardFrame(size: size, in: zone, pointer: nil)
        #expect(middle.midX == zone.midX && abs(middle.midY - zone.midY) <= 1)
        // Far from the middle, the pointer leaves it there.
        #expect(SplitDropHint.cardFrame(size: size, in: zone, pointer: CGPoint(x: 40, y: 60)) == middle)
        // On it from below (a finger's hand comes from below): up near the top, clear of a pane's strip.
        let up = SplitDropHint.cardFrame(size: size, in: zone, pointer: CGPoint(x: 300, y: 280))
        #expect(up.minY >= zone.minY + Tokens.Pane.height && up.maxY < 280 - SplitDropHint.pointerClearance)
        // On it from above: down near the bottom.
        let down = SplitDropHint.cardFrame(size: size, in: zone, pointer: CGPoint(x: 300, y: 220))
        #expect(down.minY > 220 + SplitDropHint.pointerClearance && down.maxY <= zone.maxY)
    }

    @Test func theHintFadesAndNamesThePageComingIn() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let hint = controller.root.splitDropHint
            #expect(!hint.isShowing)
            controller.listDragOverPage(at: page(controller, 0.25, 0.5), item: .tab(tabs[1].id))
            #expect(hint.isShowing && !hint.isHidden && region(hint.drop) == .left)
            #expect(hint.incoming?.title == "B")
            controller.listDragOverPage(at: page(controller, 0.75, 0.5), item: .tab(tabs[1].id))
            #expect(region(hint.drop) == .right)
            // Off the page: it goes, and nothing is offered.
            controller.listDragOverPage(at: nil, item: .tab(tabs[1].id))
            #expect(!hint.isShowing && hint.drop == nil)
            // Back before it has faded: it stays.
            controller.listDragOverPage(at: page(controller, 0.5, 0.02), item: .tab(tabs[1].id))
            #expect(hint.isShowing && region(hint.drop) == .top)
            hint.show(nil)
        }
    }

    // MARK: A finger, from the sidebar onto the page

    @Test func aFingerCarriesATabOntoThePageAndSplitsAsTheMouseDoes() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let row = try #require(controller.sidebar.list.row(for: tabs[1]) as? InteractiveView)
            let hold = try #require(row.beginTouchHold(at: middle(of: row)))
            let left = page(controller, 0.25, 0.5)
            hold.moved(to: left)
            #expect(hold.carry != nil)
            #expect(controller.root.splitDropHint.isShowing && region(controller.root.splitDropHint.drop) == .left)
            hold.lifted(at: left)
            // As the mouse's drop on the left half: B opens on the left of A.
            #expect(controller.tabManager.split(for: tabs[0])?.ids == [tabs[1].id, tabs[0].id])
            #expect(!controller.root.splitDropHint.isShowing)
        }
    }

    @Test func aFingerPastTheMenuStillReachesThePage() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let row = try #require(controller.sidebar.list.row(for: tabs[1]) as? InteractiveView)
            let hold = try #require(row.beginTouchHold(at: middle(of: row)))
            hold.showMenu()
            let menu = try #require(MenuPanel.current)
            // On its way to the page the finger crosses the menu, lighting an item.
            hold.moved(to: menu.debugItemPoint(0))
            #expect(menu.highlightedIndex == 0)
            let right = page(controller, 0.8, 0.5)
            #expect(!menu.touchContains(right))
            hold.moved(to: right)
            #expect(hold.carry != nil && MenuPanel.current == nil)
            hold.lifted(at: right)
            #expect(controller.tabManager.split(for: tabs[0])?.ids == [tabs[0].id, tabs[1].id])
        }
    }

    @Test func theHoldRulesPastTheMenu() {
        let start = NSPoint(x: 100, y: 100), far = NSPoint(x: 400, y: 100)
        // After the menu, off it inside the list: still never a drag.
        #expect(TouchHold.step(from: start, to: far, onMenu: false, wasOnMenu: true, canDrag: true, leftHome: false) == .wait)
        // Out of the list, onto the page: picked up.
        #expect(TouchHold.step(from: start, to: far, onMenu: false, wasOnMenu: true, canDrag: true, leftHome: true) == .drag)
        // On the menu it's the menu's, wherever that is.
        #expect(TouchHold.step(from: start, to: far, onMenu: true, wasOnMenu: true, canDrag: true, leftHome: true) == .highlight)
    }

    /// The window follows the finger anywhere in it: once it has, the row's own recognizer letting go of the finger
    /// (it left the row, or the row went) doesn't call the drag off; the window's lift drops it.
    @Test func theWindowFollowsTheFingerOverThePage() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let window = try #require(controller.window)
            let row = try #require(controller.sidebar.list.row(for: tabs[1]) as? InteractiveView)
            #expect(TouchFollow.follows(row))
            let hold = try #require(row.beginTouchHold(at: middle(of: row)))
            #expect(hold.followed)
            let left = page(controller, 0.3, 0.6)
            hold.fingerMoved(to: left, in: window)
            #expect(hold.carry != nil && hold.followSeen)
            hold.pressCancelled()
            #expect(!hold.isFinished)
            hold.pressMoved(to: middle(of: row))
            #expect(region(controller.root.splitDropHint.drop) == .left)
            hold.fingerLifted(at: left, in: window)
            #expect(hold.isFinished)
            #expect(controller.tabManager.split(for: tabs[0])?.ids == [tabs[1].id, tabs[0].id])
        }
    }

    @Test func aFingerCalledOffChangesNothing() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let row = try #require(controller.sidebar.list.row(for: tabs[1]) as? InteractiveView)
            let hold = try #require(row.beginTouchHold(at: middle(of: row)))
            hold.moved(to: page(controller, 0.25, 0.5))
            #expect(controller.root.splitDropHint.isShowing)
            hold.cancelled()
            #expect(!controller.root.splitDropHint.isShowing)
            #expect(controller.tabManager.split(for: tabs[0]) == nil)
        }
    }

    // MARK: A finger on a pane's strip

    @Test func aFingerDragsAPaneByItsStripAsTheMouseDoes() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            controller.tabManager.makeSplit(tabs[0], with: tabs[1])
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let header = try #require(controller.root.paneCards.first { $0.header.tab === tabs[1] && !$0.isHidden }).header
            header.layoutSubtreeIfNeeded()
            // Its buttons and address take a finger as a tap; the rest of the strip picks the pane up.
            #expect(!header.takesTouchDrag(at: header.convert(middle(of: header.address), from: nil)))
            #expect(!header.takesTouchDrag(at: header.convert(middle(of: header.back), from: nil)))
            let start = middle(of: header.address)
            let carry = try #require(header.touchDragBegan(at: start, now: NSPoint(x: start.x - 20, y: start.y)))
            let leftEdge = page(controller, 0.02, 0.5)
            carry.move(to: leftEdge)
            let hint = controller.root.splitDropHint
            #expect(hint.isShowing && hint.move != nil && hint.incoming?.title == "B")
            carry.release(at: leftEdge)
            #expect(!hint.isShowing)
            #expect(controller.tabManager.split(for: tabs[0])?.ids.first == tabs[1].id)
        }
    }
}

import AppKit
import Foundation
import Testing
@testable import Zigzag

/// A split pane's strip gives its own buttons away before its address or its close button.
@MainActor struct PaneHeaderTests {
    typealias Fit = PaneHeaderView.Fit
    let edge: CGFloat = 2
    let address: CGFloat = 180

    @Test func wideShowsEverything() {
        #expect(PaneHeaderView.fit(width: 700, edge: edge, address: address) == .all)
    }

    @Test func swapAndLayoutGoBeforeTheAddressIsCut() {
        // Swap and the layout go into ⋯ while the address would still be cut beside them.
        let fit = PaneHeaderView.fit(width: 330, edge: edge, address: address)
        #expect(fit == .splitInMore)
        #expect(fit.showsForward && fit.showsReload && fit.showsSeparate && fit.showsMore && !fit.showsSplitButtons)
    }

    @Test func thenSeparateForwardAndReload() {
        // Each step only to keep the address its least width.
        #expect(PaneHeaderView.fit(width: 250, edge: edge, address: address) == .splitInMore)
        #expect(PaneHeaderView.fit(width: 225, edge: edge, address: address) == .separateInMore)
        #expect(PaneHeaderView.fit(width: 200, edge: edge, address: address) == .noForward)
        #expect(PaneHeaderView.fit(width: 175, edge: edge, address: address) == .noReload)
        #expect(PaneHeaderView.fit(width: 80, edge: edge, address: address) == .noReload)
    }

    @Test func aShortAddressNeedsLessRoom() {
        #expect(PaneHeaderView.fit(width: 250, edge: edge, address: 30) == .all)
    }

    @Test func fewerButtonsAsItNarrows() {
        var last = Fit.all
        for width in stride(from: 700, through: 60, by: -10) {
            let fit = PaneHeaderView.fit(width: CGFloat(width), edge: edge, address: address)
            #expect(fit >= last)
            last = fit
        }
    }

    /// Up where a title bar would be, the window server starts moving the window on a press before the app sees it.
    /// A strip on the page keeps its whole area out of that, after it moves too; a strip up in the bar, and the rest
    /// of the band, still move the window (#160).
    @Test func aStripOnThePageNeverMovesTheWindow() {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        // Out of sight: unseen, and off every screen once it's in.
        window.alphaValue = 0
        let content = MovesWindowView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = content
        let header = PaneHeaderView(frame: NSRect(x: 300, y: 500 - PaneHeaderView.height, width: 480, height: PaneHeaderView.height))
        content.addSubview(header)
        header.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        defer { window.orderOut(nil); window.close() }
        func moves(_ x: CGFloat, _ y: CGFloat) -> Bool? {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            return DebugBridge.windowServerMoves(window, at: NSPoint(x: x, y: y))
        }
        // AppKit's own region, unpublished: where it can't be read, nothing to check.
        guard moves(150, 490) != nil else { return }
        let top = 500 - PaneHeaderView.height / 2
        #expect(moves(150, top) == true)
        for x: CGFloat in [304, 420, 540, 776] { #expect(moves(x, top) == false, "x \(x)") }
        #expect(moves(540, 500 - PaneHeaderView.height + 0.5) == false)

        header.frame.origin.x = 20
        #expect(moves(100, top) == false)
        #expect(moves(480, top) == false)
        #expect(moves(700, top) == true)

        header.isInBar = true
        #expect(moves(100, top) == true)
    }
}

/// The page area's ground, which moves the window wherever nothing on it takes the press.
private final class MovesWindowView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

import AppKit
import Testing
import WebKit
@testable import Zigzag

/// The window a page is told it's in (#161): never one of no size, and the page's own place rather than the whole
/// window, so `outerWidth / innerWidth` reads as no zoom beside the sidebar.
@MainActor
struct PageWindowFrameTests {
    @Test func onScreenItsThePagesPlace() {
        let page = NSRect(x: 356.4, y: 120, width: 1040, height: 805)
        let frame = PageWindowFrame.frame(pageOnScreen: page, pageSize: page.size, hostWindowFrame: NSRect(x: 100, y: 100, width: 1280, height: 900))
        #expect(frame == page.integral)
        #expect(frame.width >= 1040)
    }

    @Test func outOfAWindowItsThePagesSizeAtTheWindow() {
        let frame = PageWindowFrame.frame(pageOnScreen: nil, pageSize: NSSize(width: 1040, height: 805), hostWindowFrame: NSRect(x: 100, y: 50, width: 1280, height: 900))
        #expect(frame == NSRect(x: 100, y: 50, width: 1040, height: 805))
    }

    @Test func withNoWindowAtAllStillThePagesSize() {
        let frame = PageWindowFrame.frame(pageOnScreen: nil, pageSize: NSSize(width: 800, height: 600), hostWindowFrame: nil)
        #expect(frame == NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func anEmptyRectOnScreenFallsBackToTheSize() {
        let frame = PageWindowFrame.frame(pageOnScreen: .zero, pageSize: NSSize(width: 800, height: 600), hostWindowFrame: nil)
        #expect(frame.size == NSSize(width: 800, height: 600))
    }

    @Test func aWebViewInAWindowGetsItsRectOnScreen() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        let webView = WKWebView(frame: NSRect(x: 240, y: 0, width: 660, height: 650))
        window.contentView?.addSubview(webView)
        let frame = PageWindowFrame.frame(of: webView, hostWindow: window)
        #expect(frame.size == NSSize(width: 660, height: 650))
        #expect(frame.minX == window.frame.minX + 240)
    }

    /// WebKit only asks a delegate that answers to its exact name.
    @Test func tabsAndPopupsAnswerWebKit() {
        let selector = NSSelectorFromString("_webView:getWindowFrameWithCompletionHandler:")
        #expect(Tab.instancesRespond(to: selector))
        #expect(PopupWindowController.instancesRespond(to: selector))
    }

    /// Sheets' own reading of it, on a Safari before 26.4: the window against the page, snapped to a zoom level,
    /// times the pixel ratio. A window 0 wide snapped to a quarter; the page's place reads as no zoom.
    @Test func sheetsReadsNoZoom() {
        let levels = [0.25, 1 / 3.0, 0.5, 0.6659, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
        func snapped(_ ratio: Double) -> Double { levels.min { abs($0 - ratio) < abs($1 - ratio) }! }
        let innerWidth = 1040.0
        #expect(snapped(0 / innerWidth) == 0.25)
        let frame = PageWindowFrame.frame(pageOnScreen: NSRect(x: 356, y: 65, width: 1040, height: 805), pageSize: .zero, hostWindowFrame: nil)
        #expect(snapped(frame.width / innerWidth) == 1)
    }
}

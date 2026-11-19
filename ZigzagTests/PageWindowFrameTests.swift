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

/// A pop-up window's page takes the page commands a tab does, and can move into a tab.
@MainActor struct PopupWindowTests {
    private func popup() -> PopupWindowController {
        PopupWindowController.asking(configuration: WKWebViewConfiguration(), features: WKWindowFeatures(), parent: nil, opener: nil)
    }

    private func validates(_ popup: PopupWindowController, _ action: Selector, hidden: Bool = false) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.isHidden = hidden
        guard popup.responds(to: action) else { return false }
        return popup.validateMenuItem(item)
    }

    /// Print, Reload, Find, Zoom, Close and the Web Inspector are on with a pop-up in front; nothing beeps.
    @Test func pageCommandsWorkInAPopup() {
        let popup = popup()
        defer { popup.discardHeldPage() }
        let on: [Selector] = [
            #selector(BrowserWindowController.reloadPage(_:)), #selector(BrowserWindowController.reloadPageFromOrigin(_:)),
            #selector(BrowserWindowController.showFindBar(_:)), #selector(BrowserWindowController.useSelectionForFind(_:)),
            #selector(BrowserWindowController.zoomIn(_:)), #selector(BrowserWindowController.zoomOut(_:)),
            #selector(BrowserWindowController.actualSize(_:)), #selector(BrowserWindowController.closeTab(_:)),
            #selector(BrowserWindowController.showWebInspector(_:)), #selector(BrowserWindowController.showJavaScriptConsole(_:)),
            #selector(BrowserWindowController.inspectElement(_:)),
        ]
        for action in on { #expect(validates(popup, action), "\(action)") }
        #expect(popup.responds(to: #selector(BrowserWindowController.printPage(_:))))
        #expect(popup.responds(to: #selector(BrowserWindowController.copyPageURL(_:))))
    }

    /// What has nothing to act on is off, not beeping: no page behind or ahead, no address yet, no search.
    @Test func commandsWithNothingToDoAreOff() {
        let popup = popup()
        defer { popup.discardHeldPage() }
        #expect(!validates(popup, #selector(BrowserWindowController.goBack(_:))))
        #expect(!validates(popup, #selector(BrowserWindowController.goForward(_:))))
        #expect(!validates(popup, #selector(BrowserWindowController.copyPageURL(_:))))
        #expect(!validates(popup, #selector(BrowserWindowController.findNextMatch(_:))))
    }

    /// ⌘O is Open in New Tab while a pop-up is in front, as it's Open in for Zigzag Mini.
    @Test func openFileBecomesOpenInNewTab() {
        let popup = popup()
        defer { popup.discardHeldPage() }
        let item = NSMenuItem(title: BrowserWindowController.openFileTitle, action: #selector(BrowserWindowController.openDocument(_:)), keyEquivalent: "o")
        #expect(!popup.validateMenuItem(item))
        #expect(item.title == PopupWindowController.openInTabTitle)
    }

    /// Only a web or file address moves into a tab: a blank page or an extension's own has nothing to load there.
    @Test func whatMovesIntoATab() {
        #expect(PopupWindowController.movableURL(URL(string: "https://secure9.store.apple.com/print/invoice")) != nil)
        #expect(PopupWindowController.movableURL(URL(string: "http://localhost:8080/a")) != nil)
        #expect(PopupWindowController.movableURL(URL(string: "about:blank")) == nil)
        #expect(PopupWindowController.movableURL(URL(string: "data:text/html,hi")) == nil)
        #expect(PopupWindowController.movableURL(URL(string: "webkit-extension://abc/popup.html")) == nil)
        #expect(PopupWindowController.movableURL(nil) == nil)
    }

    /// Open in New Tab with no address leaves the pop-up as it is: a sign-in is never moved by accident.
    @Test func openInTabWithNoAddressStays() {
        let popup = popup()
        defer { popup.discardHeldPage() }
        popup.openInTab()
        #expect(!popup.isClosed)
    }
}

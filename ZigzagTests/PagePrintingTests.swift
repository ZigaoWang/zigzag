import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A page's own Print button reaches Zigzag: WebKit looks for these (unpublished) delegate methods on the web view's UI
/// delegate, and does nothing with `window.print()` without them.
@MainActor struct PagePrintingTests {
    @Test func aTabAnswersAPagesPrintRequest() {
        #expect(Tab.instancesRespond(to: NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")))
        #expect(Tab.instancesRespond(to: NSSelectorFromString("_webView:printFrame:")))
    }

    /// Popups answer a page's print() as tabs do (Zigzag Mini, installed apps and Peek pages are tabs).
    @Test func aPopupAnswersAPagesPrintRequest() {
        #expect(PopupWindowController.instancesRespond(to: NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")))
        #expect(PopupWindowController.instancesRespond(to: NSSelectorFromString("_webView:printFrame:")))
    }

    /// File › Print… (⌘P) reaches every kind of window with a page in front.
    @Test func everyPageWindowTakesPrint() {
        let print = #selector(BrowserWindowController.printPage(_:))
        #expect(BrowserWindowController.instancesRespond(to: print))
        #expect(PopupWindowController.instancesRespond(to: print))
        #expect(MiniWindowController.instancesRespond(to: print))
        #expect(WebAppWindowController.instancesRespond(to: print))
    }

    /// With a popup window in front, Print… is on: the popup takes it and doesn't turn it off.
    @Test func printIsOnWithAPopupInFront() {
        let popup = PopupWindowController.asking(configuration: WKWebViewConfiguration(), features: WKWindowFeatures(), parent: nil, opener: nil)
        defer { popup.discardHeldPage() }
        let item = NSMenuItem(title: "Print…", action: #selector(BrowserWindowController.printPage(_:)), keyEquivalent: "p")
        #expect(popup.window?.delegate === popup)
        #expect(popup.responds(to: item.action!))
        #expect((popup as NSObject as? NSMenuItemValidation)?.validateMenuItem(item) ?? true)
    }

    /// One print sheet per window: asking again while it's up gets nothing until it closes.
    @Test func oneSheetAtATime() {
        let window = NSWindow()
        let id = ObjectIdentifier(window)
        #expect(PagePrinting.claim(id))
        #expect(!PagePrinting.claim(id))
        PagePrinting.release(id)
        #expect(PagePrinting.claim(id))
        PagePrinting.release(id)
    }

    @Test func printingLaysAPageOutAsPrintDoes() {
        let info = PagePrinting.info()
        #expect(info.horizontalPagination == .fit)
        #expect(info.topMargin == 36 && info.leftMargin == 36)
    }

    /// A page's print() in a background tab (its page has no window) never gets a sheet: it's finished at once.
    @Test func aBackgroundTabsPrintFinishesAtOnce() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(!PagePrinting.isShown(webView, in: nil))
        var finished = false
        PagePrinting.printForPage(webView, frame: nil, in: nil) { finished = true }
        #expect(finished)
    }

    /// A page asking again just after its sheet closed is let be; after the pause it may ask again.
    @Test func printingAgainStraightAwayIsLetBe() {
        let now = Date()
        #expect(PagePrinting.mayPrint(shown: true, lastClosed: nil, now: now))
        #expect(!PagePrinting.mayPrint(shown: false, lastClosed: nil, now: now))
        #expect(!PagePrinting.mayPrint(shown: true, lastClosed: now.addingTimeInterval(-1), now: now))
        #expect(PagePrinting.mayPrint(shown: true, lastClosed: now.addingTimeInterval(-PagePrinting.pause - 0.1), now: now))
    }
}

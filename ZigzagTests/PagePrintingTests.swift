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

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
}

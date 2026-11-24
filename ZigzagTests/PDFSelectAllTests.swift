import AppKit
import CoreText
import Testing
import WebKit
@testable import Zigzag

/// PDF dark mode follows the dark pages setting, site choice and the window's appearance, not the system's; the moon toggle overrides all.
@MainActor
struct PDFDarkPagesTests {
    @Test func darkFollowsTheWindowAndDarkPages() {
        // Dark pages off (default): light in light and dark windows.
        #expect(!PDFViewerView.isDark(chosen: nil, mode: .off, windowIsDark: false, site: nil))
        #expect(!PDFViewerView.isDark(chosen: nil, mode: .off, windowIsDark: true, site: nil))
        // "When the Mac is dark" follows the window, so a light window on a dark Mac stays light.
        #expect(!PDFViewerView.isDark(chosen: nil, mode: .system, windowIsDark: false, site: nil))
        #expect(PDFViewerView.isDark(chosen: nil, mode: .system, windowIsDark: true, site: nil))
        #expect(PDFViewerView.isDark(chosen: nil, mode: .always, windowIsDark: false, site: nil))
        // The site choice overrides the setting.
        #expect(!PDFViewerView.isDark(chosen: nil, mode: .always, windowIsDark: true, site: false))
        #expect(PDFViewerView.isDark(chosen: nil, mode: .off, windowIsDark: false, site: true))
        // The moon overrides everything.
        #expect(PDFViewerView.isDark(chosen: true, mode: .off, windowIsDark: false, site: false))
        #expect(!PDFViewerView.isDark(chosen: false, mode: .always, windowIsDark: true, site: true))
    }
}

/// Edit › Select All (⌘A) on a PDF from the web, in WebKit's own viewer (#219). WebKit's viewer takes it only once
/// its plugin has the page's focus, which a click gives it; a PDF just opened has none, so ⌘A selected nothing.
@MainActor
@Suite(.serialized)
struct PDFSelectAllTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A one-page PDF with a line of text on it.
    private static func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func page() async -> (BrowserWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeFirstResponder(webView)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.load(Self.pdf("Zigzag selects all"), mimeType: "application/pdf", characterEncodingName: "", baseURL: URL(string: "https://example.com/paper.pdf")!)
        }
        // The viewer's plugin comes up a moment after the load.
        let end = Date().addingTimeInterval(5)
        while Date() < end, await tag(of: webView) == nil { try? await Task.sleep(for: .milliseconds(50)) }
        return (webView, window)
    }

    /// The tag of what has the page's focus, or nil before the PDF's plugin is there.
    private func tag(of webView: WKWebView) async -> String? {
        let result = try? await webView.callAsyncJavaScript(
            "return document.querySelector('embed') ? document.activeElement.tagName : null", arguments: [:], in: nil, contentWorld: .defaultClient)
        return result as? String
    }

    private func settle(_ webView: WKWebView, until done: () async -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while Date() < end, await !done() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func selectAllGivesThePDFTheFocusFirst() async {
        let (webView, window) = await page()
        defer { window.close() }
        // As WebKit opens it: the page has the focus, not the PDF.
        #expect(await tag(of: webView) == "BODY")
        webView.isPDF = true
        webView.selectAll(nil)
        await settle(webView) { await tag(of: webView) == "EMBED" }
        #expect(await tag(of: webView) == "EMBED")
    }

    @Test func anOrdinaryPageSelectsAllAtOnce() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<p>Every word</p>", baseURL: nil)
        }
        #expect(!webView.isPDF)
        webView.selectAll(nil)
        await settle(webView) { (try? await webView.evaluateJavaScript("String(getSelection())") as? String) == "Every word" }
        #expect(try await webView.evaluateJavaScript("String(getSelection())") as? String == "Every word")
    }
}

extension PDFDarkPagesTests {
    /// A PDF whose Content-Length exceeds the limit goes to WebKit's viewer before copying; unknown length (-1) is read as before.
    @Test func aPDFSaidToBeTooLargeIsNeverCopied() {
        #expect(PDFViewerView.isTooLarge(said: Int64(PDFLimits.maxInputBytes) + 1))
        #expect(!PDFViewerView.isTooLarge(said: Int64(PDFLimits.maxInputBytes)))
        #expect(!PDFViewerView.isTooLarge(said: -1))
        #expect(!PDFViewerView.isTooLarge(said: 0))
    }
}

extension PDFDarkPagesTests {
    /// Titles are capped by UTF-16 length, so stacked combining marks count; the helper cuts at a character boundary.
    @Test func titlesAreCappedByTheirUTF16Length() {
        let piled = "a" + String(repeating: "\u{301}", count: 5_000)
        #expect(piled.count == 1)
        let size = Data([300.0, 400.0].flatMap { value in withUnsafeBytes(of: value) { Array($0) } })
        #expect(!RemotePDFInfo(pageCount: 1, sizes: size, title: piled, outline: [], allowsCopying: true).isWellFormed)
        #expect(!RemoteOutlineEntry(title: piled, level: 0, page: 0, y: .nan).isWellFormed(pages: 1))
        #expect(RemotePDFInfo(pageCount: 1, sizes: size, title: "Report", outline: [], allowsCopying: true).isWellFormed)

        #expect(PDFLimits.clippedTitle("Report") == "Report")
        #expect(PDFLimits.clippedTitle(piled).isEmpty)
        let emoji = String(repeating: "😀", count: 700)
        let clipped = PDFLimits.clippedTitle(emoji)
        #expect(clipped.utf16.count == PDFLimits.maxTitle)
        #expect(clipped == String(repeating: "😀", count: 500))
        #expect(RemoteOutlineEntry(title: clipped, level: 0, page: 0, y: .nan).isWellFormed(pages: 1))
    }
}

extension PDFDarkPagesTests {
    /// A selection stays forward, or empty, when the text shrinks.
    @Test func aSelectionNeverRunsBackwards() {
        #expect(ZigzagPDFView.run(from: 2, to: 6, length: 10) == 2..<6)
        #expect(ZigzagPDFView.run(from: 2, to: 60, length: 10) == 2..<10)
        #expect(ZigzagPDFView.run(from: 40, to: 60, length: 10) == nil)
        #expect(ZigzagPDFView.run(from: 12, to: 11, length: 10) == nil)
        #expect(ZigzagPDFView.run(from: 0, to: 5, length: 0) == nil)
        #expect(ZigzagPDFView.run(from: -3, to: 2, length: 10) == 0..<2)
    }
}

/// The PDF viewer's tile ranges never trap (#507).
struct PDFChunkRangeTests {
    /// A sliver thinner than the edge allowance made the end of the range come before its start.
    @Test func aSliverOfAPageGivesOneTileNotACrash() throws {
        let range = try #require(ZigzagPDFView.chunkRange(of: CGRect(x: 512, y: 100, width: 0.0004, height: 0.0004),
                                                          pageSize: CGSize(width: 612, height: 792), side: 256))
        #expect(range.columns == 2...2)
        #expect(range.rows == 0...0)
    }

    @Test func aPageCoveredWholeGivesEveryTile() throws {
        let range = try #require(ZigzagPDFView.chunkRange(of: CGRect(x: 0, y: 0, width: 612, height: 792),
                                                          pageSize: CGSize(width: 612, height: 792), side: 256))
        #expect(range.columns == 0...2)
        #expect(range.rows == 0...3)
    }

    @Test func aSizeThatIsntRealGivesNothing() {
        let page = CGSize(width: 612, height: 792), rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ZigzagPDFView.chunkRange(of: rect, pageSize: page, side: 0) == nil)
        #expect(ZigzagPDFView.chunkRange(of: rect, pageSize: page, side: CGFloat.nan) == nil)
        #expect(ZigzagPDFView.chunkRange(of: rect, pageSize: page, side: CGFloat.infinity) == nil)
        _ = ZigzagPDFView.chunkRange(of: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), pageSize: page, side: 256)
        #expect(ZigzagPDFView.chunkRange(of: CGRect(x: 700, y: 0, width: 10, height: 10), pageSize: page, side: 256) == nil)
    }
}

import AppKit
import CoreText
import Testing
import WebKit
@testable import Zigzag

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

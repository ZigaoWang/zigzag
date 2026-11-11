import AppKit
import Testing
import WebKit
@testable import Zigzag

/// YouTube's page script (Resources/YouTubeAds.js): a dialog it hides must not leave YouTube's dimmed backdrop over
/// the page, which takes every click.
@MainActor
struct YouTubeAdsTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A page at youtube.com with the script in it (no answer from Zigzag, so it blocks), a backdrop over it, and the
    /// given dialog.
    private func page(dialog: String) async throws -> WKWebView {
        let source = try #require(Bundle.main.url(forResource: "YouTubeAds", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) })
        let configuration = WKWebViewConfiguration()
        // A web view never shown draws no frames and counts as hidden: it's told it shows, so the script's light
        // check runs as it does in a tab you're looking at.
        configuration.userContentController.addUserScript(WKUserScript(source: "Object.defineProperty(document, 'visibilityState', { get: () => 'visible' })",
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        let html = """
        <html><body style="overflow: hidden"><p>Video</p>
        <tp-yt-iron-overlay-backdrop style="position: fixed; inset: 0; display: block; background: rgba(0,0,0,.5)"></tp-yt-iron-overlay-backdrop>
        <ytd-popup-container>\(dialog)</ytd-popup-container></body></html>
        """
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/watch?v=test"))
        }
        try await Task.sleep(for: .milliseconds(700))
        withExtendedLifetime(loading) {}
        return webView
    }

    private func look(_ webView: WKWebView) async throws -> (backdrop: String, overflow: String) {
        let backdrop = try await webView.callAsyncJavaScript("return getComputedStyle(document.querySelector('tp-yt-iron-overlay-backdrop')).display",
                                                             arguments: [:], in: nil, contentWorld: .page) as? String ?? ""
        let overflow = try await webView.callAsyncJavaScript("return document.body.style.overflow", arguments: [:], in: nil, contentWorld: .page) as? String ?? ""
        return (backdrop, overflow)
    }

    @Test func aHiddenBlockerWarningLeavesNoBackdrop() async throws {
        let webView = try await page(dialog: "<tp-yt-paper-dialog><ytd-enforcement-message-view-model>Ad blockers are not allowed</ytd-enforcement-message-view-model></tp-yt-paper-dialog>")
        let seen = try await look(webView)
        #expect(seen.backdrop == "none")
        #expect(seen.overflow == "")
    }

    @Test func aDialogYouTubeShowsKeepsItsBackdrop() async throws {
        let webView = try await page(dialog: "<tp-yt-paper-dialog style=\"display: block; width: 300px; height: 200px\">Share</tp-yt-paper-dialog>")
        let seen = try await look(webView)
        #expect(seen.backdrop == "block")
        #expect(seen.overflow == "hidden")
    }
}

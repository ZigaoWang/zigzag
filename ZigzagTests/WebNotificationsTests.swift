import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The page script that stands in for web notifications.
@MainActor
struct WebNotificationsTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Notes each uncaught error in a frame's window, where it lasts from one document to the next.
    private static let errors = WKUserScript(source: """
    window.__errors = window.__errors || [];
    window.addEventListener('error', (e) => window.__errors.push(e.message));
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    private func page(_ html: String) async -> (WKWebView, Loading) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(Self.errors)
        WebNotifications.attach(to: configuration, alwaysDenies: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, loading)
    }

    /// A frame written with document.open() (Cloudflare's Turnstile does) gets a new document in the same window,
    /// and WebKit runs the script there again: it leaves what it set up alone instead of failing on it, which the
    /// diagnostics showed as "Script error." every time such a frame loaded.
    @Test func aFrameWrittenAgainKeepsNotificationsWithoutAnError() async throws {
        let (webView, _) = await page("""
        <iframe></iframe>
        <script>
          const doc = frames[0].document;
          doc.open(); doc.write('<p>written</p>'); doc.close();
        </script>
        """)
        let errors = try await webView.evaluateJavaScript("frames[0].__errors") as? [String]
        #expect(errors == [])
        let kind = try await webView.evaluateJavaScript("typeof frames[0].Notification + ' ' + typeof frames[0].__zigzagNotification") as? String
        #expect(kind == "function function")
    }

    /// A page knows its own answer before scripts run, and nothing about other sites; answers stay in Zigzag's content world.
    @Test func aPageKnowsOnlyItsOwnAnswer() async throws {
        let decisions = ["https://example.com": true, "https://secret.example": true, "https://blocked.example": false]
        #expect(!WebNotifications.pageSource(alwaysDenies: false).contains("secret.example"))
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: WebNotifications.answerSource(decisions: decisions), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: WebNotifications.world))
        controller.addUserScript(WKUserScript(source: WebNotifications.pageSource(alwaysDenies: false), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.addScriptMessageHandler(WebNotifications.shared, contentWorld: .page, name: WebNotifications.messageName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<script>window.first = Notification.permission;</script>", baseURL: URL(string: "https://example.com/"))
        }
        let seen = try await webView.evaluateJavaScript("[window.first, typeof window.__zigzagNotificationAnswers, document.documentElement.outerHTML.includes('secret')]") as? [Any]
        #expect(seen?[0] as? String == "granted")
        #expect(seen?[1] as? String == "undefined")
        #expect(seen?[2] as? Bool == false)
        withExtendedLifetime(loading) {}
    }

    /// Asking (`Notification.requestPermission()`) returns a promise instead of throwing, as app.zoom.us does on load (#551).
    @Test func askingReturnsAPromise() async throws {
        let configuration = WKWebViewConfiguration()
        WebNotifications.attach(to: configuration, alwaysDenies: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<title>page</title>", baseURL: URL(string: "https://example.com/"))
        }
        let asked = try await webView.callAsyncJavaScript("""
            try { return typeof Notification.requestPermission().then; } catch (e) { return e.message; }
            """, contentWorld: .page) as? String
        #expect(asked == "function")
        withExtendedLifetime(loading) {}
    }
}

import Foundation
import Testing
import WebKit
@testable import Zigzag

/// What a tab keeps of what you typed, for when its page loads again: plain text only, never a password (even one
/// shown with "Show password"), a card's details or a one-time code.
@MainActor
struct PageStatePrivacyTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String) async -> (WKWebView, Loading) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageState.script)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, loading)
    }

    private static let form = """
    <form>
      <input id="note" name="subject">
      <textarea id="reply" name="body"></textarea>
      <input id="pw" type="password">
      <input id="shown" type="text">
      <input id="card" autocomplete="cc-number">
      <input id="cvv" name="cvv" autocomplete="off">
      <input id="otp" name="code" autocomplete="one-time-code">
      <input id="pin" aria-label="PIN">
      <input id="dots" style="-webkit-text-security: disc">
      <input id="ship" name="shipping_city">
    </form>
    """

    @Test func onlyPlainTextIsKept() async throws {
        let (webView, _) = await page(Self.form)
        // As if you'd typed in every field; the one shown with "Show password" was a password while you typed.
        _ = try await webView.evaluateJavaScript("""
        for (const el of document.querySelectorAll('input, textarea')) { el.value = 'typed ' + el.id; window.__zigzagTyped.add(el); }
        window.__zigzagSecret.add(document.getElementById('shown'));
        true
        """, in: nil, contentWorld: .defaultClient)
        let result = try await webView.evaluateJavaScript(PageState.reader, in: nil, contentWorld: .defaultClient)
        let state = try #require(PageState(result, url: URL(string: "https://example.com/")))
        #expect(state.fields.map(\.selector) == ["#note", "#reply", "#ship"])
        #expect(state.fields.map(\.value) == ["typed note", "typed reply", "typed ship"])
    }

    @Test func restoringNeverFillsAFieldThatIsNowSecret() async throws {
        let (webView, _) = await page(Self.form)
        let arguments = PageState(url: try #require(URL(string: "https://example.com/")), scroll: .zero,
                                  fields: [.init(selector: "#pw", value: "hello"), .init(selector: "#card", value: "hello"),
                                           .init(selector: "#note", value: "hello")]).restoreArguments
        _ = try await webView.callAsyncJavaScript(PageState.restorer, arguments: arguments, in: nil, contentWorld: .defaultClient)
        let values = try await webView.evaluateJavaScript("['pw', 'card', 'note'].map((id) => document.getElementById(id).value)") as? [String]
        #expect(values == ["", "", "hello"])
    }
}

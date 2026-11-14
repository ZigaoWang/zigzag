import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The Apple Store's checkout drew the Apple Pay logo over the Apple logo and Pay in text (#235): on apple.com, with
/// Apple Pay coming from Apple's script for other browsers, only the text is drawn.
@MainActor
struct ApplePayMarkTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// The checkout's Apple Pay option and its own rules for it, as the store has them.
    private static func checkout(_ classes: String) -> String {
        """
        <html class="\(classes)"><head><style>
        .rf-paymentoptions-image-applepay { background-image: -webkit-named-image(apple-pay-logo-black); display: block; height: 28px; width: 76px }
        html.supports-applepay-ac .rf-paymentoptions-image-applepay:after { content: "Pay" }
        </style></head><body><span class="rf-paymentoptions-image rf-paymentoptions-image-applepay"></span></body></html>
        """
    }

    private func logo(_ html: String, at address: String) async -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PageScripts.applePayMark)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: address))
        }
        withExtendedLifetime(loading) {}
        return try? await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.rf-paymentoptions-image-applepay')).backgroundImage") as? String
    }

    @Test func theStoreShowsOneMarkWithApplePayFromItsScript() async {
        #expect(await logo(Self.checkout("no-supports-applepay supports-applepay-ac"), at: "https://www.apple.com/shop/checkout") == "none")
        #expect(await logo(Self.checkout("supports-applepay-ac"), at: "https://secure.store.apple.com/shop/checkout") == "none")
    }

    /// Safari's Apple Pay, when WebKit gives it: the logo stays, and is the only mark.
    @Test func theLogoStaysWithoutTheTextMark() async {
        let drawn = await logo(Self.checkout("supports-applepay"), at: "https://www.apple.com/shop/checkout")
        #expect(drawn?.contains("apple-pay-logo-black") == true)
    }

    @Test func otherSitesAreLeftAsTheyAre() async {
        let drawn = await logo(Self.checkout("supports-applepay-ac"), at: "https://notapple.com/shop/checkout")
        #expect(drawn?.contains("apple-pay-logo-black") == true)
    }

    @Test func everyPageGetsIt() {
        #expect(PageScripts.all.contains(PageScripts.applePayMark))
    }
}

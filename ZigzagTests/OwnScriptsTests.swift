import Testing
import WebKit
@testable import Zigzag

/// Taking Zigzag's own page scripts out of a web view leaves everyone else's exactly as they were (#178). A web view's
/// set also holds what extensions inject; taking all out and putting the rest back made copies of those, the set grew
/// with every page, and WebKit crashed sending it to a new page's process.
@MainActor
struct OwnScriptsTests {
    private static func script(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    @Test func onlyTheScriptsPickedAreTakenOut() {
        let controller = WKUserContentController()
        let extensionScript = Self.script("/* an extension's content script */")
        let ours = Self.script("/* ours */ 1")
        controller.addUserScript(extensionScript)
        controller.addUserScript(ours)
        controller.addUserScript(Self.script("/* ours */ 2"))

        #expect(OwnScripts.remove(from: controller, where: { $0.source.hasPrefix("/* ours */") }) == 2)
        #expect(controller.userScripts.count == 1)
        // The very script that was there, not a copy put back in its place.
        #expect(controller.userScripts.first === extensionScript)
        #expect(OwnScripts.remove(from: controller, where: { $0.source.hasPrefix("/* ours */") }) == 0)
    }

    @Test func pagesComingAndGoingNeverGrowTheSet() {
        let controller = WKUserContentController()
        controller.addUserScript(Self.script("/* an extension's content script */"))
        for _ in 0..<50 {
            controller.addUserScript(PageFullScreen.script())
            OwnScripts.remove(from: controller, where: PageFullScreen.isOurs)
        }
        #expect(controller.userScripts.count == 1)
    }

    @Test func aSiteFiltersClearLeavesOtherScripts() {
        let controller = WKUserContentController()
        let extensionScript = Self.script("/* an extension's content script */")
        controller.addUserScript(extensionScript)
        for script in PageFilters.scripts(for: AdInjection(page: ["1"], isolated: ["2"], styles: "a { }"), host: "www.youtube.com") {
            controller.addUserScript(script)
        }
        #expect(controller.userScripts.count == 4)
        PageFilters.clear(controller)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first === extensionScript)
    }
}

/// Zigzag's scripts never grant a page a user gesture: a `navigator.userAgent` getter that calls window.open gets no popup.
@MainActor
struct OwnScriptGestureTests {
    private final class Page: NSObject, WKUIDelegate, WKNavigationDelegate {
        var opened = 0
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Zigzag allows only click-opened windows (PopupNotice.allows).
            if PopupNotice.isUserInitiated(navigationAction) { opened += 1 }
            return nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Traps on everything Zigzag's scripts might touch, each opening a window.
    private static let trap = """
    <html><head><link rel="icon" href="/favicon.ico"></head><body><video></video><script>
    window.calls = 0;
    const open = () => { window.calls++; window.open('https://example.org/popup', '_blank'); return 'trap'; };
    Object.defineProperty(Navigator.prototype, 'userAgent', { get: open, configurable: true });
    Object.defineProperty(Document.prototype, 'contentType', { get: open, configurable: true });
    const all = Document.prototype.querySelectorAll;
    Document.prototype.querySelectorAll = function (...a) { open(); return all.apply(this, a); };
    Array.from = function () { open(); return []; };
    window.getSelection = function () { open(); return null; };
    </script></body></html>
    """

    private func load() async -> (WKWebView, Page) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let page = Page()
        webView.uiDelegate = page
        webView.navigationDelegate = page
        await withCheckedContinuation { done in
            page.done = done
            webView.loadHTMLString(Self.trap, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, page)
    }

    @Test func readingThePageOpensNothing() async throws {
        #expect(WKWebView.runsScriptsWithoutGesture)
        let (webView, page) = await load()
        // What a tab runs on every page load.
        let type = try await webView.runOwnScript(Tab.pdfCheckScript) as? String
        #expect(type == "text/html")
        let icons = try await webView.runOwnScript(PageScripts.iconLinks) as? [[String: String]]
        #expect(icons?.first?["href"] == "https://example.com/favicon.ico")
        _ = try await webView.runOwnScript(Tab.elementMuting(true))
        _ = try await webView.runOwnScript("window.getSelection().toString()")
        // The user agent comes from the web view, not the page.
        #expect(webView.sentUserAgent?.contains("AppleWebKit") == true)
        let calls = try await webView.evaluateJavaScript("window.calls", in: nil, contentWorld: .page) as? Int
        #expect(calls == 0)
        #expect(page.opened == 0)
        withExtendedLifetime(page) {}
    }

    @Test func aScriptInThePagesWorldCarriesNoClick() async throws {
        let (webView, page) = await load()
        // In the page world (consent check, full screen toggle) the getter runs, but window.open is refused without a click.
        _ = try await webView.runOwnScript("navigator.userAgent", world: .page)
        _ = try await webView.runOwnScript("return navigator.userAgent", asFunction: true, world: .page)
        let calls = try await webView.evaluateJavaScript("window.calls", in: nil, contentWorld: .page) as? Int
        #expect(calls == 2)
        #expect(page.opened == 0)
        // For comparison, plain evaluateJavaScript counts as a click and the window opens.
        _ = try await webView.evaluateJavaScript("navigator.userAgent")
        #expect(page.opened == 1)
        withExtendedLifetime(page) {}
    }
}

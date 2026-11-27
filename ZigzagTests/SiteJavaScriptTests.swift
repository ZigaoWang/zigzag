import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Global and per-site JavaScript (#282): the decision, per-site storage, private window choices, and Zigzag pages always running scripts.
@MainActor
@Suite(.serialized)
struct SiteJavaScriptTests {
    private let site = "https://news.example.com/story"

    private func withDefaults(_ body: () async throws -> Void) async throws {
        let suite = "zigzag-javascript-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SiteJavaScript.defaults
        SiteJavaScript.defaults = defaults
        defer {
            SiteJavaScript.defaults = before
            defaults.removeScratchSuite(suite)
        }
        try await body()
    }

    @Test func theDecision() {
        // Default, and with the setting off.
        #expect(SiteJavaScript.allows(setting: true, kept: nil, here: nil))
        #expect(!SiteJavaScript.allows(setting: false, kept: nil, here: nil))
        // A site choice wins either way.
        #expect(SiteJavaScript.allows(setting: false, kept: true, here: nil))
        #expect(!SiteJavaScript.allows(setting: true, kept: false, here: nil))
        // A private tab's choice comes first.
        #expect(SiteJavaScript.allows(setting: true, kept: false, here: true))
        #expect(!SiteJavaScript.allows(setting: true, kept: true, here: false))
    }

    @Test func allowedUnlessTurnedOff() async throws {
        try await withDefaults {
            #expect(SiteJavaScript.isAllowed)
            #expect(SiteJavaScript.allows(URL(string: site), in: nil))
            SiteJavaScript.isAllowed = false
            #expect(!SiteJavaScript.allows(URL(string: site), in: nil))
            // Local files follow the setting too.
            #expect(!SiteJavaScript.allows(URL(fileURLWithPath: "/tmp/page.html"), in: nil))
        }
    }

    @Test func aSiteOverridesTheSettingBothWays() async throws {
        try await withDefaults {
            SiteJavaScript.choose(false, for: URL(string: site), in: nil)
            #expect(!SiteJavaScript.allows(URL(string: site), in: nil))
            // Subdomains inherit; other sites don't.
            #expect(!SiteJavaScript.allows(URL(string: "https://www.news.example.com/a"), in: nil))
            #expect(!SiteJavaScript.allows(URL(string: "https://m.news.example.com/a"), in: nil))
            #expect(SiteJavaScript.allows(URL(string: "https://example.com"), in: nil))
            #expect(SiteJavaScript.isOwn(URL(string: site), in: nil))

            SiteJavaScript.isAllowed = false
            SiteJavaScript.choose(true, for: URL(string: site), in: nil)
            #expect(SiteJavaScript.allows(URL(string: site), in: nil))
            #expect(!SiteJavaScript.allows(URL(string: "https://example.com"), in: nil))
            // The most specific choice wins: the site over its parent domain.
            SiteJavaScript.setChoice(false, forSite: "example.com")
            SiteJavaScript.setChoice(true, forSite: "news.example.com")
            #expect(SiteJavaScript.allows(URL(string: site), in: nil))
            #expect(!SiteJavaScript.allows(URL(string: "https://shop.example.com"), in: nil))
        }
    }

    @Test func whatsKeptReadsBack() async throws {
        try await withDefaults {
            SiteJavaScript.setChoice(false, for: URL(string: "https://www.news.example.com"))
            SiteJavaScript.setChoice(true, for: URL(string: "http://localhost:3000"))
            // Read back from storage, as on next launch.
            #expect(SiteJavaScript.defaults.stringArray(forKey: "JavaScriptOffSites") == ["news.example.com"])
            #expect(SiteJavaScript.defaults.stringArray(forKey: "JavaScriptOnSites") == ["localhost"])
            #expect(SiteJavaScript.choice(forSite: "news.example.com") == false)
            #expect(SiteJavaScript.choice(forSite: "localhost") == true)
            #expect(SiteJavaScript.choice(forSite: "example.com") == nil)
            // Choosing again moves the site between lists.
            SiteJavaScript.setChoice(true, for: URL(string: site))
            #expect(SiteJavaScript.sitesOff.isEmpty)
            #expect(SiteJavaScript.sitesOn == ["news.example.com", "localhost"])
            // Forget and Reset All.
            SiteJavaScript.forget(site: "news.example.com")
            #expect(SiteJavaScript.choice(forSite: "news.example.com") == nil)
            #expect(SiteJavaScript.sitesOn == ["localhost"])
            SiteJavaScript.forgetAll()
            #expect(SiteJavaScript.sitesOn.isEmpty && SiteJavaScript.sitesOff.isEmpty)
            SiteJavaScript.isAllowed = false
            #expect(SiteJavaScript.defaults.object(forKey: "JavaScriptAllowed") as? Bool == false)
        }
    }

    @Test func aPrivateWindowKeepsNothing() async throws {
        try await withDefaults {
            let tab = Tab(url: URL(string: site), title: "News", spaceID: UUID())
            tab.privateStore = .nonPersistent()
            SiteJavaScript.choose(false, for: URL(string: site), in: tab)
            #expect(!SiteJavaScript.allows(URL(string: site), in: tab))
            #expect(SiteJavaScript.isOwn(URL(string: site), in: tab))
            // Nothing kept for the site or other tabs.
            #expect(SiteJavaScript.sitesOff.isEmpty && SiteJavaScript.sitesOn.isEmpty)
            #expect(SiteJavaScript.allows(URL(string: site), in: Tab(url: URL(string: site), spaceID: UUID())))
            // Follows choices kept for other sites.
            SiteJavaScript.setChoice(false, forSite: "other.example.org")
            #expect(!SiteJavaScript.allows(URL(string: "https://other.example.org"), in: tab))
            // Its popup keeps the choices after it closes.
            let kept = tab.javaScriptHere
            #expect(!SiteJavaScript.allows(URL(string: site), here: kept))
        }
    }

    @Test func zigzagsOwnPagesAlwaysRunTheirs() async throws {
        try await withDefaults {
            SiteJavaScript.isAllowed = false
            for page in ["zigzag://history", "zigzag://settings", "webkit-extension://abc/popup.html", "about:blank", "zigzag-webapp://x"] {
                #expect(SiteJavaScript.allows(URL(string: page), in: nil), "\(page)")
            }
            // An error page for a disabled site.
            SiteJavaScript.setChoice(false, for: URL(string: site))
            #expect(!SiteJavaScript.allows(URL(string: site), here: nil))
            #expect(SiteJavaScript.allows(URL(string: site), here: nil, errorPage: true))
            // Nothing kept for pages without a site.
            SiteJavaScript.choose(true, for: URL(string: "zigzag://history"), in: nil)
            #expect(SiteJavaScript.sitesOn.isEmpty)
        }
    }

    /// WebKit's switch: page scripts stop, Zigzag's user and evaluated scripts still run.
    @Test func pageScriptsStopAndZigzagsRun() async throws {
        try await withDefaults {
            SiteJavaScript.setChoice(false, for: URL(string: site))
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(WKUserScript(source: "document.documentElement.dataset.zigzag = 'ran'",
                                                                           injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
            let deciding = Deciding()
            webView.navigationDelegate = deciding
            let off = try await Self.load(in: webView, base: site)
            #expect(off.page == "none")
            #expect(off.zigzag == "ran")
            SiteJavaScript.setChoice(true, for: URL(string: site))
            let on = try await Self.load(in: webView, base: site)
            #expect(on.page == "ran")
            #expect(on.zigzag == "ran")
        }
    }

    private final class Deciding: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            if navigationAction.targetFrame?.isMainFrame == true {
                SiteJavaScript.apply(to: preferences, for: navigationAction.request.url, here: nil, errorPage: false)
            }
            return (.allow, preferences)
        }
    }

    /// Loads a page and reports which ran: the page's script and Zigzag's user script.
    private static func load(in webView: WKWebView, base: String) async throws -> (page: String?, zigzag: String?) {
        let token = UUID().uuidString
        webView.loadHTMLString("<p id='\(token)'>hi</p><script>document.documentElement.dataset.page = 'ran'</script>", baseURL: URL(string: base))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await webView.evaluateJavaScript("!!document.getElementById('\(token)')")) as? Bool == true { break }
        }
        let page = try await webView.evaluateJavaScript("document.documentElement.dataset.page || 'none'") as? String
        let zigzag = try await webView.evaluateJavaScript("document.documentElement.dataset.zigzag || 'none'") as? String
        return (page, zigzag)
    }
}

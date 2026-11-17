import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Boosts: the selectors Zap Element makes, what's kept for a site, a private window's own copy, and the style sheet
/// pages get.
@MainActor
@Suite(.serialized)
struct SiteBoostsTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func withDefaults(_ body: () async throws -> Void) async throws {
        let suite = "zigzag-boosts-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SiteBoosts.defaults
        SiteBoosts.defaults = defaults
        defer {
            SiteBoosts.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    private func load(_ html: String, in webView: WKWebView, at address: String = "https://example.com/") async {
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: address))
        }
        withExtendedLifetime(loading) {}
    }

    private static let page = """
    <html><body>
      <div id="promo">Promo</div>
      <div id="ember4821" class="banner">Generated id</div>
      <section class="css-1q2w3e sc-bdVaJa card">Hashed classes</section>
      <section class="card">Another card</section>
      <ul id="list"><li>One</li><li>Two</li><li>Three</li></ul>
      <main><article><p>First</p><p>Second</p></article><article><p>Third</p></article></main>
      <button class="is-active"><svg width="10" height="10"><path id="p" d="M0 0h10v10z"/></svg></button>
      <div class="md:flex">Escaped</div>
    </body></html>
    """

    /// The selector the picker makes for the element `query` finds, and whether it finds that element alone.
    private func selector(for query: String, in webView: WKWebView) async throws -> (String?, Bool) {
        let script = PageBoosts.selectorSource + """

        (() => {
          const element = \(query);
          const selector = window.ZigzagBoostSelector(element);
          if (!selector) return JSON.stringify([null, false]);
          const found = document.querySelectorAll(selector);
          return JSON.stringify([selector, found.length === 1 && found[0] === element]);
        })()
        """
        let json = try #require(try await webView.evaluateJavaScript(script) as? String)
        let pair = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        return (pair[0] as? String, pair[1] as? Bool ?? false)
    }

    @Test func selectorsAreUniqueAndLasting() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        await load(Self.page, in: webView)
        // A stable id is the selector.
        #expect(try await selector(for: "document.getElementById('promo')", in: webView) == ("#promo", true))
        // A generated id is passed over for the element's class.
        #expect(try await selector(for: "document.querySelector('.banner')", in: webView) == ("div.banner", true))
        // Generated classes are left out; with another card on the page, its place among its siblings tells them apart.
        let card = try await selector(for: "document.querySelector('.sc-bdVaJa')", in: webView)
        #expect(card.1)
        #expect(card.0 == "section.card:nth-of-type(1)")
        // A list item by its place, under the list's id.
        #expect(try await selector(for: "document.querySelectorAll('#list li')[1]", in: webView) == ("#list > li:nth-of-type(2)", true))
        // Deeper, with no ids or classes: up through the parents to a landmark, never a bare tag and place.
        #expect(try await selector(for: "document.querySelectorAll('p')[2]", in: webView) == ("main > article:nth-of-type(2) > p", true))
        // Part of a drawing is the drawing; a state class (is-active) isn't kept, so it goes up to the body.
        #expect(try await selector(for: "document.getElementById('p')", in: webView) == ("body > button > svg", true))
        // A class with a character CSS needs escaped.
        #expect(try await selector(for: "document.querySelector('[class=\"md:flex\"]')", in: webView) == ("div.md\\:flex", true))
        // The page itself is never zapped.
        #expect(try await selector(for: "document.body", in: webView) == (nil, false))
        #expect(try await selector(for: "document.documentElement", in: webView) == (nil, false))
    }

    @Test func tooDeepWithoutAnAnchorIsNotNamed() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let deep = String(repeating: "<div>", count: 14) + "<span>a</span>" + String(repeating: "</div>", count: 14)
        await load("<html><body>\(deep)\(deep)</body></html>", in: webView)
        #expect(try await selector(for: "document.querySelectorAll('span')[1]", in: webView) == (nil, false))
    }

    @Test func zapsAreKeptForTheSite() async throws {
        try await withDefaults {
            let site = try #require(SiteBoosts.site(of: URL(string: "https://www.example.com/a")))
            #expect(site == "example.com")
            #expect(SiteBoosts.zap("#promo", forSite: site))
            #expect(SiteBoosts.zap("div.banner", forSite: site))
            // The same one again is kept once.
            #expect(SiteBoosts.zap("#promo", forSite: site))
            #expect(SiteBoosts.boost(for: URL(string: "https://example.com/b")).zaps == ["#promo", "div.banner"])
            #expect(SiteBoosts.sites == ["example.com"])
            // Only web pages have boosts: never Zigzag's own pages, files or extensions.
            #expect(SiteBoosts.site(of: URL(string: "zigzag-history://history")) == nil)
            #expect(SiteBoosts.site(of: URL(string: "file:///tmp/a.html")) == nil)
            #expect(SiteBoosts.site(of: URL(string: "webkit-extension://abc/popup.html")) == nil)
            SiteBoosts.restoreZaps(forSite: site)
            #expect(SiteBoosts.boost(forSite: site).isEmpty)
            #expect(SiteBoosts.sites.isEmpty)
            SiteBoosts.zap("#a", forSite: "a.com")
            SiteBoosts.zap("#b", forSite: "b.com")
            SiteBoosts.forget(site: "a.com")
            #expect(SiteBoosts.sites == ["b.com"])
            SiteBoosts.forgetAll()
            #expect(SiteBoosts.sites.isEmpty)
        }
    }

    @Test func aPrivateWindowKeepsItsOwnCopy() async throws {
        try await withDefaults {
            SiteBoosts.zap("#kept", forSite: "example.com")
            let window = WKWebsiteDataStore.nonPersistent()
            // A private window starts from what's kept.
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).zaps == ["#kept"])
            SiteBoosts.zap("#mine", forSite: "example.com", privateStore: window)
            SiteBoosts.zap("#other", forSite: "other.com", privateStore: window)
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).zaps == ["#kept", "#mine"])
            // Nothing it did is kept, nor seen by other windows.
            #expect(SiteBoosts.all == ["example.com": SiteBoost(zaps: ["#kept"])])
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: .nonPersistent()).zaps == ["#kept"])
            // Restore All there shows them in that window only.
            SiteBoosts.restoreZaps(forSite: "example.com", privateStore: window)
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).isEmpty)
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#kept"])
        }
    }

    @Test func selectorsCantWriteCSS() {
        #expect(SiteBoosts.isPlainSelector("#list > li:nth-of-type(2)"))
        #expect(SiteBoosts.isPlainSelector("div.md\\:flex"))
        for bad in ["", "a { color: red }", "a}body{display:none", "a; @import url(x)", "a /* b", "a</style>", "a\nb", "[x=\"y\"]",
                    String(repeating: "a", count: 600)] {
            #expect(!SiteBoosts.isPlainSelector(bad), "\(bad)")
            #expect(!SiteBoosts.zap(bad, forSite: "example.com", privateStore: .nonPersistent()))
        }
        #expect(SiteBoosts.css(for: SiteBoost(zaps: ["#a", "a{b", "li:nth-of-type(2)"]))
                == "#a { display: none !important; }\nli:nth-of-type(2) { display: none !important; }")
    }

    @Test func pagesHideWhatWasZapped() async throws {
        try await withDefaults {
            SiteBoosts.zap("#promo", forSite: "example.com")
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let url = try #require(URL(string: "https://www.example.com/"))
            PageBoosts.prepare(webView, for: url, privateStore: nil, errorPage: false)
            await load(Self.page, in: webView, at: url.absoluteString)
            let shown = "getComputedStyle(document.getElementById('promo')).display"
            #expect(try await webView.evaluateJavaScript(shown) as? String == "none")
            #expect(try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.banner')).display") as? String == "block")
            // Another site has none, and an error page none either.
            PageBoosts.prepare(webView, for: URL(string: "https://other.com/"), privateStore: nil, errorPage: false)
            await load(Self.page, in: webView, at: "https://other.com/")
            #expect(try await webView.evaluateJavaScript(shown) as? String == "block")
            PageBoosts.prepare(webView, for: url, privateStore: nil, errorPage: true)
            #expect(!webView.configuration.userContentController.userScripts.contains(where: PageBoosts.isOurs))
        }
    }

    @Test func thePickerLeavesThePageAsItWas() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        await load("<html><body><button id='b' onclick='window.clicks = (window.clicks || 0) + 1'>Go</button></body></html>", in: webView)
        // Each ends on a value: WebKit's async call throws on undefined.
        func run(_ script: String, in world: WKContentWorld = .page) async throws {
            _ = try await webView.evaluateJavaScript(script + "\n;true", in: nil, contentWorld: world)
        }
        try await run(PageBoosts.pickerSource(accent: "#3366ff", hint: "Pick"), in: PageBoosts.world)
        // While picking, the page doesn't hear the click.
        try await run("document.getElementById('b').click()", in: PageBoosts.world)
        #expect(try await webView.evaluateJavaScript("window.clicks || 0") as? Int == 0)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('zigzag-zap').length") as? Int == 1)
        try await run(PageBoosts.stopSource, in: PageBoosts.world)
        // Once it's stopped, the page has its clicks again and nothing of the picker is left.
        try await run("document.getElementById('b').click()")
        #expect(try await webView.evaluateJavaScript("window.clicks || 0") as? Int == 1)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('zigzag-zap').length") as? Int == 0)
        #expect(try await webView.evaluateJavaScript("document.documentElement.style.cursor") as? String == "")
    }
}

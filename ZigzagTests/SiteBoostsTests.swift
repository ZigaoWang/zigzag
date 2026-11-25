import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Boosts: Zap Element selectors, per-site storage, private window copies, and the injected style sheet.
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

    /// The selector the picker makes for `query`'s element, and whether it matches only that element.
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
        // A stable id is used.
        #expect(try await selector(for: "document.getElementById('promo')", in: webView) == ("#promo", true))
        // Generated ids are skipped for a class.
        #expect(try await selector(for: "document.querySelector('.banner')", in: webView) == ("div.banner", true))
        // Generated classes are skipped; sibling position tells cards apart.
        let card = try await selector(for: "document.querySelector('.sc-bdVaJa')", in: webView)
        #expect(card.1)
        #expect(card.0 == "section.card:nth-of-type(1)")
        // A list item by position under the list's id.
        #expect(try await selector(for: "document.querySelectorAll('#list li')[1]", in: webView) == ("#list > li:nth-of-type(2)", true))
        // No ids or classes: climbs to a landmark, never a bare tag and position.
        #expect(try await selector(for: "document.querySelectorAll('p')[2]", in: webView) == ("main > article:nth-of-type(2) > p", true))
        // Inside an SVG, the SVG is chosen; state classes (is-active) are dropped, so it climbs to body.
        let drawing = try await webView.evaluateJavaScript(PageBoosts.selectorSource + """

        (() => { try { return String(window.ZigzagBoostSelector(document.getElementById('p'))); } catch (e) { return 'threw ' + e; } })()
        """) as? String
        #expect(drawing == "body > button > svg")
        #expect(try await selector(for: "document.querySelector('svg')", in: webView) == ("body > button > svg", true))
        // Classes with characters CSS needs escaped.
        #expect(try await selector(for: "document.querySelector('[class=\"md:flex\"]')", in: webView) == ("div.md\\:flex", true))
        // Never the body.
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
            // Duplicates are kept once.
            #expect(SiteBoosts.zap("#promo", forSite: site))
            #expect(SiteBoosts.boost(for: URL(string: "https://example.com/b")).zaps == ["#promo", "div.banner"])
            #expect(SiteBoosts.sites == ["example.com"])
            // Only web pages: never Zigzag pages, files or extensions.
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
            // Private windows start from kept boosts.
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).zaps == ["#kept"])
            SiteBoosts.zap("#mine", forSite: "example.com", privateStore: window)
            SiteBoosts.zap("#other", forSite: "other.com", privateStore: window)
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).zaps == ["#kept", "#mine"])
            // Nothing persists or reaches other windows.
            #expect(SiteBoosts.all == ["example.com": SiteBoost(zaps: ["#kept"])])
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: .nonPersistent()).zaps == ["#kept"])
            // Restore All there applies to that window only.
            SiteBoosts.restoreZaps(forSite: "example.com", privateStore: window)
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).isEmpty)
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#kept"])
        }
    }

    @Test func zapsHaveShortNames() {
        let names = ["#promo": "#promo", "div.banner": "div.banner", "#list > li:nth-of-type(2)": "#list › li",
                     "main > article:nth-of-type(2) > p": "main › p", "body > button > svg": "svg", "div.md\\:flex": "div.md:flex",
                     "#\\31 23 > span": "#123 › span", "aside.cookie-banner.big:nth-of-type(1)": "aside.cookie-banner",
                     "div#x.y": "#x", ".a .b:not(.c)": ".b", "section.card ~ div:nth-of-type(3)": "section.card › div",
                     "DIV.Box": "div.Box", "div:nth-of-type(3)": "div", "*": "*"]
        for (selector, name) in names { #expect(SiteBoosts.label(forZap: selector) == name, "\(selector)") }
        #expect(SiteBoosts.selectorSteps("#\\31 23 > span  .a") == ["#\\31 23", "span", ".a"])
    }

    @Test func oneZapComesOffAndTheRestStayInOrder() async throws {
        try await withDefaults {
            for selector in ["#a", "#b", "#c"] { SiteBoosts.zap(selector, forSite: "example.com") }
            SiteBoosts.unzap("#b", forSite: "example.com")
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#a", "#c"])
            SiteBoosts.unzap("#missing", forSite: "example.com")
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#a", "#c"])
            // Zapping again appends to the same list.
            SiteBoosts.zap("#b", forSite: "example.com")
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#a", "#c", "#b"])
            // A private window removes from its own copy only.
            let window = WKWebsiteDataStore.nonPersistent()
            SiteBoosts.unzap("#a", forSite: "example.com", privateStore: window)
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).zaps == ["#c", "#b"])
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#a", "#c", "#b"])
            SiteBoosts.unzap("#c", forSite: "example.com")
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).zaps == ["#c", "#b"])
            // The last one gone leaves nothing kept for the site.
            SiteBoosts.unzap("#a", forSite: "example.com")
            SiteBoosts.unzap("#b", forSite: "example.com")
            #expect(SiteBoosts.sites.isEmpty)
        }
    }

    @Test func removingAZapRefreshesThePage() async throws {
        try await withDefaults {
            SiteBoosts.zap("#promo", forSite: "example.com")
            SiteBoosts.zap("div.banner", forSite: "example.com")
            let tab = Tab(url: URL(string: "https://example.com/")!, title: "Example", spaceID: UUID())
            var refreshed: [Tab] = []
            ZapPicker.unzap("#promo", site: "example.com", in: tab) { refreshed.append($0) }
            #expect(refreshed.count == 1 && refreshed.first === tab)
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["div.banner"])
            // The next load hides only what's left.
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let url = try #require(URL(string: "https://example.com/"))
            PageBoosts.prepare(webView, for: url, privateStore: nil, errorPage: false)
            await load(Self.page, in: webView, at: url.absoluteString)
            #expect(try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('promo')).display") as? String == "block")
            #expect(try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.banner')).display") as? String == "none")
        }
    }

    @Test func aZapRowKeepsItsButtonWhenLaidOutBeforeItHasAWidth() throws {
        let group = PanelGroup()
        group.rows = [PanelRow.zap("#list > li:nth-of-type(2)") {}]
        group.layoutSubtreeIfNeeded()
        group.frame = NSRect(x: 0, y: 0, width: 260, height: PanelRow.height)
        group.layoutSubtreeIfNeeded()
        let row = try #require(group.rows.first)
        row.layoutSubtreeIfNeeded()
        let button = try #require(row.subviews.compactMap { $0 as? IconButton }.first)
        #expect(button.frame.width == Tokens.Metric.compactIconButton)
        #expect(button.frame.maxX == row.bounds.width)
        #expect(button.accessibilityLabel() == SiteBoosts.restoreLabel("#list › li"))
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
            // Other sites and error pages get none.
            PageBoosts.prepare(webView, for: URL(string: "https://other.com/"), privateStore: nil, errorPage: false)
            await load(Self.page, in: webView, at: "https://other.com/")
            #expect(try await webView.evaluateJavaScript(shown) as? String == "block")
            PageBoosts.prepare(webView, for: url, privateStore: nil, errorPage: true)
            #expect(!webView.configuration.userContentController.userScripts.contains(where: PageBoosts.isOurs))
        }
    }

    @Test func stylesArePlainCSSOnly() {
        // Plain CSS, including data: images and same-page fragments.
        for good in ["", "body { color: red; }", ".ad { display: none !important }", "a::before { content: \"<3 a > b\"; }",
                     "div { background: url(data:image/png;base64,AAAA) }", "svg { fill: url(#grad) }", "@media (max-width: 600px) { nav { display: none } }",
                     "p { background-image: linear-gradient(red, blue) }"] {
            #expect(SiteBoosts.styleProblem(good) == nil, "\(good)")
        }
        // Nothing that parses as HTML, however written.
        for tag in ["</style><script>alert(1)</script>", "a{}</STYLE >", "\\3c /style>", "<!-- x -->"] {
            #expect(SiteBoosts.styleProblem(tag) == .tag, "\(tag)")
        }
        // No remote loads: @import, url() and similar, plain, escaped or split by comments.
        for remote in ["@import url(https://evil.example/x.css);", "@IMPORT 'x.css';", "@\\69mport 'x.css';",
                       "a { background: url(https://t.example/p.gif) }", "a { background: url('//t.example/p') }", "a { background: url(/beacon) }",
                       "a { background: \\75 rl(https://t.example) }", "a { background: u\\rl(https://t.example) }",
                       "a { background: image-set('https://t.example/a.png' 1x) }", "a { background: -webkit-image-set(\"x.png\" 1x) }",
                       "@font-face { font-family: x; src: url(https://f.example/f.woff) }", "a { cursor: url( \"https://t.example/c\" ), auto }",
                       "input[value^=a] { background: URL(https://t.example/?a) }"] {
            #expect(SiteBoosts.styleProblem(remote) == .loads, "\(remote)")
        }
        // A comment splits a token, as the browser reads it: u/**/rl( isn't url(.
        #expect(SiteBoosts.styleProblem("a { x: u/**/rl(https://t.example) }") == nil)
        #expect(SiteBoosts.styleProblem(String(repeating: "a", count: SiteBoosts.maxStyle + 1)) == .tooLong)
    }

    @Test func stylesAreKeptAndPrivateOnesArent() async throws {
        try await withDefaults {
            #expect(SiteBoosts.setStyle("body { color: red }", forSite: "example.com"))
            #expect(!SiteBoosts.setStyle("@import 'x.css';", forSite: "example.com"))
            #expect(SiteBoosts.boost(forSite: "example.com").style == "body { color: red }")
            SiteBoosts.zap("#promo", forSite: "example.com")
            #expect(SiteBoosts.css(for: SiteBoosts.boost(forSite: "example.com")) == "#promo { display: none !important; }\nbody { color: red }")
            // Private windows keep their own style.
            let window = WKWebsiteDataStore.nonPersistent()
            SiteBoosts.setStyle("p { color: blue }", forSite: "example.com", privateStore: window)
            SiteBoosts.setStyle("p { color: green }", forSite: "private.com", privateStore: window)
            #expect(SiteBoosts.boost(forSite: "example.com", privateStore: window).style == "p { color: blue }")
            #expect(SiteBoosts.boost(forSite: "example.com").style == "body { color: red }")
            #expect(SiteBoosts.sites == ["example.com"])
            // Empty disables it; with no zaps left, the site has nothing stored.
            SiteBoosts.setStyle("  \n", forSite: "example.com")
            SiteBoosts.restoreZaps(forSite: "example.com")
            #expect(SiteBoosts.sites.isEmpty)
        }
    }

    @Test func boostsKeptBeforeStylesStillRead() throws {
        let old = try JSONDecoder().decode(SiteBoost.self, from: Data(##"{"zaps":["#a"]}"##.utf8))
        #expect(old == SiteBoost(zaps: ["#a"]))
        let round = try JSONDecoder().decode(SiteBoost.self, from: JSONEncoder().encode(SiteBoost(zaps: ["#b"], style: "a{}")))
        #expect(round.style == "a{}")
    }

    @Test func pagesShowTheirStyle() async throws {
        try await withDefaults {
            SiteBoosts.setStyle("#promo { color: rgb(1, 2, 3) }", forSite: "example.com")
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let url = try #require(URL(string: "https://example.com/"))
            PageBoosts.prepare(webView, for: url, privateStore: nil, errorPage: false)
            await load(Self.page, in: webView, at: url.absoluteString)
            let color = "getComputedStyle(document.getElementById('promo')).color"
            #expect(try await webView.evaluateJavaScript(color) as? String == "rgb(1, 2, 3)")
            // Rerunning replaces the sheet instead of adding another.
            let again = PageBoosts.source(css: "#promo { color: rgb(4, 5, 6) }", site: "example.com") + "\n;true"
            _ = try await webView.evaluateJavaScript(again, in: nil, contentWorld: PageBoosts.world)
            #expect(try await webView.evaluateJavaScript(color) as? String == "rgb(4, 5, 6)")
            #expect(try await webView.evaluateJavaScript("document.querySelectorAll('style').length") as? Int == 1)
        }
    }

    @Test func thePickerLeavesThePageAsItWas() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        await load("<html><body><button id='b' onclick='window.clicks = (window.clicks || 0) + 1'>Go</button></body></html>", in: webView)
        // Each ends with a value: WebKit's async call throws on undefined.
        func run(_ script: String, in world: WKContentWorld = .page) async throws {
            _ = try await webView.evaluateJavaScript(script + "\n;true", in: nil, contentWorld: world)
        }
        try await run(PageBoosts.pickerSource(accent: "#3366ff", hint: "Pick"), in: PageBoosts.world)
        // While picking, the page doesn't get the click.
        try await run("document.getElementById('b').click()", in: PageBoosts.world)
        #expect(try await webView.evaluateJavaScript("window.clicks || 0") as? Int == 0)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('zigzag-zap').length") as? Int == 1)
        try await run(PageBoosts.stopSource, in: PageBoosts.world)
        // After stopping, clicks reach the page and the picker is gone.
        try await run("document.getElementById('b').click()")
        #expect(try await webView.evaluateJavaScript("window.clicks || 0") as? Int == 1)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('zigzag-zap').length") as? Int == 0)
        #expect(try await webView.evaluateJavaScript("document.documentElement.style.cursor") as? String == "")
    }

    @Test func zapsAreNamedByWhatTheElementSays() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        await load("""
        <html><body>
          <div id="a" aria-label="  Cookie
            notice "><p>We use cookies</p></div>
          <iframe id="b" title="Advertisement"></iframe>
          <img id="c" alt="Sale banner" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
          <section id="d"><h2>Sign up for our newsletter</h2><p>Every week</p></section>
          <div id="e">
            <p>Free shipping today</p>
            <p>Ends soon</p>
          </div>
          <div id="f"></div>
          <svg id="g" aria-label="Logo"><path id="h" d="M0 0h10v10z"/></svg>
        </body></html>
        """, in: webView)
        func name(_ id: String) async throws -> String? {
            let result = try await webView.evaluateJavaScript(PageBoosts.selectorSource + "\nString(window.ZigzagBoostName(document.getElementById('\(id)')))")
            return (result as? String).flatMap { $0 == "null" ? nil : $0 }
        }
        #expect(try await name("a") == "Cookie notice")
        #expect(try await name("b") == "Advertisement")
        #expect(try await name("c") == "Sale banner")
        #expect(try await name("d") == "Sign up for our newsletter")
        #expect(try await name("e") == "Free shipping today")
        #expect(try await name("f") == nil)
        // Inside an SVG, the SVG's own name.
        #expect(try await name("h") == "Logo")
    }

    @Test func zapNamesAreOneShortLine() {
        #expect(SiteBoosts.zapName("  Cookie\n\tnotice ") == "Cookie notice")
        #expect(SiteBoosts.zapName(" \n ") == nil)
        #expect(SiteBoosts.zapName(nil) == nil)
        let long = SiteBoosts.zapName(String(repeating: "word ", count: 20))
        #expect(long?.count == SiteBoosts.maxZapName)
        #expect(long?.hasSuffix("…") == true)
        #expect(long?.contains(" …") == false)
    }

    @Test func aZapKeepsItsNameUntilItComesOff() async throws {
        try await withDefaults {
            #expect(SiteBoosts.zap("div.consent", name: "Cookie notice", forSite: "example.com"))
            #expect(SiteBoosts.zap("#promo", name: "  ", forSite: "example.com"))
            #expect(SiteBoosts.zap("aside.newsletter", forSite: "example.com"))
            var boost = SiteBoosts.boost(forSite: "example.com")
            #expect(boost.names == ["div.consent": "Cookie notice"])
            #expect(boost.name(forZap: "div.consent") == "Cookie notice")
            // Without a name, one is made from the selector.
            #expect(boost.name(forZap: "#promo") == "#promo")
            #expect(boost.name(forZap: "aside.newsletter") == "aside.newsletter")
            // Taking one off keeps the others and their names.
            SiteBoosts.unzap("div.consent", forSite: "example.com")
            boost = SiteBoosts.boost(forSite: "example.com")
            #expect(boost.zaps == ["#promo", "aside.newsletter"])
            #expect(boost.names.isEmpty)
            SiteBoosts.zap("div.consent", name: "Cookie notice", forSite: "example.com")
            SiteBoosts.restoreZaps(forSite: "example.com")
            #expect(SiteBoosts.sites.isEmpty)
            // The oldest zaps past the limit take their names with them.
            SiteBoosts.zap("#first", name: "First", forSite: "example.com")
            for i in 0..<SiteBoosts.maxZaps { SiteBoosts.zap("#z\(i)", name: "Zap \(i)", forSite: "example.com") }
            boost = SiteBoosts.boost(forSite: "example.com")
            #expect(boost.zaps.count == SiteBoosts.maxZaps && !boost.zaps.contains("#first"))
            #expect(boost.names["#first"] == nil && boost.names.count == SiteBoosts.maxZaps)
        }
    }

    @Test func zapsKeptBeforeNamesStillRead() throws {
        let old = try JSONDecoder().decode(SiteBoost.self, from: Data(##"{"zaps":["#list > li:nth-of-type(2)"],"style":""}"##.utf8))
        #expect(old.names.isEmpty)
        #expect(old.name(forZap: "#list > li:nth-of-type(2)") == "#list › li")
        // A names field that isn't a list of names is left out, not the whole boost.
        let odd = try JSONDecoder().decode(SiteBoost.self, from: Data(##"{"zaps":["#a"],"names":[1]}"##.utf8))
        #expect(odd.zaps == ["#a"] && odd.names.isEmpty)
        let round = try JSONDecoder().decode(SiteBoost.self, from: JSONEncoder().encode(SiteBoost(zaps: ["#a"], names: ["#a": "Banner"])))
        #expect(round.names == ["#a": "Banner"])
    }

    @Test func removingAZapShowsItOnTheOpenPage() async throws {
        try await withDefaults {
            SiteBoosts.zap("#promo", name: "Promo", forSite: "example.com")
            SiteBoosts.zap("div.banner", forSite: "example.com")
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let url = try #require(URL(string: "https://example.com/"))
            PageBoosts.prepare(webView, for: url, privateStore: nil, errorPage: false)
            await load(Self.page, in: webView, at: url.absoluteString)
            let promo = "getComputedStyle(document.getElementById('promo')).display"
            let banner = "getComputedStyle(document.querySelector('.banner')).display"
            #expect(try await webView.evaluateJavaScript(promo) as? String == "none")
            SiteBoosts.unzap("#promo", forSite: "example.com")
            // What `PageBoosts.refresh` runs: the sheet's rules are replaced, no reload.
            let css = SiteBoosts.css(for: SiteBoosts.boost(forSite: "example.com"))
            _ = try await webView.evaluateJavaScript(PageBoosts.source(css: css, site: "example.com") + "\n;true", in: nil, contentWorld: PageBoosts.world)
            #expect(try await webView.evaluateJavaScript(promo) as? String == "block")
            #expect(try await webView.evaluateJavaScript(banner) as? String == "none")
            #expect(try await webView.evaluateJavaScript("document.querySelectorAll('style').length") as? Int == 1)
        }
    }

    @Test func aZapRowShowsItsNameAndSelector() throws {
        let named = PanelRow.zap("div.consent-wrap > div:nth-of-type(2)", name: "Cookie notice") {}
        #expect(named.accessibilityLabel() == "Cookie notice")
        #expect(named.accessibilityValue() as? String == "div.consent-wrap > div:nth-of-type(2)")
        #expect(named.toolTip == "div.consent-wrap > div:nth-of-type(2)")
        let selector = try #require(named.subviews.compactMap { $0 as? Label }.first { $0.stringValue == "div.consent-wrap > div:nth-of-type(2)" })
        #expect(!selector.isHidden && selector.lineBreakMode == .byTruncatingMiddle)
        #expect(selector.font == Tokens.Font.code(Tokens.TypeSize.small))
        // An old zap with no name is named from its selector.
        #expect(PanelRow.zap("#list > li:nth-of-type(2)") {}.accessibilityLabel() == "#list › li")
    }

    @Test func settingsListsEachZapWithItsOwnRemove() async throws {
        try await withDefaults {
            SiteBoosts.zap("div.consent", name: "Cookie notice", forSite: "example.com")
            SiteBoosts.zap("#promo", forSite: "example.com")
            let settings = SettingsView(pane: .privacy)
            settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
            settings.debugReadNow()
            var rows = settings.debugSiteFormRows
            let notice = try #require(rows.first { $0.debugTitle == "Cookie notice" })
            #expect(notice.debugDetail.stringValue == "div.consent")
            #expect(notice.debugDetail.font == Tokens.Font.code(Tokens.TypeSize.label))
            // Newest first.
            let titles = rows.map(\.debugTitle)
            let promo = try #require(titles.firstIndex(of: "#promo"))
            #expect(promo < (titles.firstIndex(of: "Cookie notice") ?? 0))
            let remove = try #require(notice.control as? IconButton)
            #expect(remove.accessibilityPerformPress())
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == ["#promo"])
            rows = settings.debugSiteFormRows
            #expect(!rows.contains { $0.debugTitle == "Cookie notice" })
            #expect(rows.contains { $0.debugTitle == "#promo" })
        }
    }
}

/// Compatibility mode (#497): one switch sets a site's extensions, blockers, zaps and style aside, keeping each choice.
@MainActor
@Suite(.serialized)
struct SiteCompatibilityTests {
    private let site = URL(string: "https://example.com/page")!
    private let other = URL(string: "https://other.com/")!

    /// Each store on defaults of its own, or put back as it was.
    private func withStores(_ body: () async throws -> Void) async throws {
        let suite = "zigzag-compat-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let boosts = SiteBoosts.defaults, banners = CookieBanners.defaults
        let blocking = ContentBlocker.isEnabled, allowed = ContentBlocker.allowedSites
        let profile = Profiles.shared.profile(Profile.defaultID)
        let off = ExtensionStore.extensionsOffSites(in: profile)
        SiteBoosts.defaults = defaults
        CookieBanners.defaults = defaults
        ContentBlocker.isEnabled = true
        ContentBlocker.allowedSites = []
        defer {
            SiteBoosts.defaults = boosts
            CookieBanners.defaults = banners
            ContentBlocker.isEnabled = blocking
            ContentBlocker.allowedSites = allowed
            ExtensionStore.setExtensionsOffSites(off, in: profile)
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    /// An extension asking for every site, with a content script on all of them.
    private func probeContext() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0","host_permissions":["*://*/*"],"content_scripts":[{"matches":["<all_urls>"],"js":["c.js"]}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("".utf8).write(to: folder.appendingPathComponent("c.js"))
        return WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
    }

    @Test func onSetsEverythingAsideForThatSiteOnly() async throws {
        try await withStores {
            SiteBoosts.zap("#promo", forSite: "example.com")
            SiteBoosts.zap("#promo", forSite: "other.com")
            SiteCompatibility.set(true, for: site)
            #expect(SiteCompatibility.isOn(for: site))
            #expect(SiteCompatibility.isOn(for: URL(string: "https://news.example.com/")))
            #expect(!SiteCompatibility.isOn(for: other))
            // Ad blocking and cookie banners.
            #expect(!ContentBlocker.blocks(on: site))
            #expect(ContentBlocker.blocks(on: other))
            #expect(!CookieBanners.runs(on: site))
            #expect(CookieBanners.runs(on: other))
            // Zaps and style.
            #expect(PageBoosts.applied(site: "example.com", privateStore: nil).isEmpty)
            #expect(!PageBoosts.applied(site: "other.com", privateStore: nil).isEmpty)
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            PageBoosts.prepare(webView, for: site, privateStore: nil, errorPage: false)
            #expect(!webView.configuration.userContentController.userScripts.contains(where: PageBoosts.isOurs))
            // Extensions: denied the site, so their content scripts stay out, as with Extensions off for it.
            let profile = Profiles.shared.profile(Profile.defaultID)
            let offSites = ExtensionStore.extensionsOffSitesInEffect(in: profile)
            #expect(offSites.contains("example.com") && !offSites.contains("other.com"))
            let context = try await probeContext()
            let all = try WKWebExtension.MatchPattern(string: "*://*/*")
            ExtensionHost.applySiteAccess(nil, approved: [all], sites: [], offSites: offSites, approvesActiveTab: false, to: context)
            #expect(context.permissionStatus(for: site) == .deniedExplicitly)
            #expect([.grantedExplicitly, .grantedImplicitly].contains(context.permissionStatus(for: other)))
        }
    }

    @Test func offRestoresTheChoicesExactly() async throws {
        try await withStores {
            let profile = Profiles.shared.profile(Profile.defaultID)
            let ads = URL(string: "https://ads.example.com/")
            ContentBlocker.setAllowed(true, on: ads)
            CookieBanners.setChoice(false, for: site)
            ExtensionStore.setExtensionsOffSites(["example.com"], in: profile)
            SiteBoosts.zap("#promo", name: "Promo", forSite: "example.com")
            SiteBoosts.setStyle("body { color: red }", forSite: "example.com")
            let boost = SiteBoosts.boost(forSite: "example.com")
            let allowed = ContentBlocker.allowedSites, handled = CookieBanners.sitesHandled, left = CookieBanners.sitesLeft
            SiteCompatibility.set(true, for: site)
            // Nothing underneath changes while it's on.
            #expect(ContentBlocker.allowedSites == allowed)
            #expect(CookieBanners.sitesHandled == handled && CookieBanners.sitesLeft == left)
            #expect(ExtensionStore.extensionsOffSites(in: profile) == ["example.com"])
            #expect(SiteBoosts.boost(forSite: "example.com").zaps == boost.zaps)
            SiteCompatibility.set(false, for: site)
            #expect(!SiteCompatibility.isOn(for: site))
            #expect(SiteBoosts.boost(forSite: "example.com") == boost)
            #expect(ContentBlocker.allowedSites == allowed)
            #expect(ContentBlocker.blocks(on: site))
            #expect(!ContentBlocker.blocks(on: ads))
            #expect(CookieBanners.choice(for: site) == false && CookieBanners.runs(on: site))
            #expect(ExtensionStore.extensionsOffSitesInEffect(in: profile) == ["example.com"])
            #expect(PageBoosts.applied(site: "example.com", privateStore: nil) == SiteBoosts.css(for: boost))
        }
    }

    /// Off on a subdomain a parent's switch covers takes the parent's off too, as allowing ads does.
    @Test func offOnASubdomainTakesTheCoveringSiteOff() async throws {
        try await withStores {
            SiteCompatibility.set(true, for: site)
            SiteCompatibility.set(false, for: URL(string: "https://news.example.com/"))
            #expect(!SiteCompatibility.isOn(for: site))
        }
    }

    @Test func itIsKeptAndListedInSettings() async throws {
        try await withStores {
            SiteCompatibility.set(true, for: site)
            let data = try #require(SiteBoosts.defaults.data(forKey: SiteBoosts.key))
            let kept = try JSONDecoder().decode([String: SiteBoost].self, from: data)
            #expect(kept["example.com"]?.compatible == true)
            let settings = SettingsView(pane: .privacy)
            settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
            settings.debugReadNow()
            let row = try #require(settings.debugSiteFormRows.first { $0.debugTitle == SitePanel.compatibilityTitle })
            #expect(row.isIndented)
            // × there, and Forget, take it off.
            SiteCompatibility.set(false, forSite: "example.com")
            #expect(SiteBoosts.sites.isEmpty)
            SiteCompatibility.set(true, forSite: "example.com")
            SiteBoosts.forget(site: "example.com")
            #expect(!SiteCompatibility.isOn(for: site))
        }
    }

    @Test func privateWindowsFollowItAndKeepNothing() async throws {
        try await withStores {
            var context = SitePanelRows.Context()
            #expect(SitePanelRows.rows(context).contains(.compatibility))
            context.isPrivate = true
            #expect(!SitePanelRows.rows(context).contains(.compatibility))
            SiteCompatibility.set(true, for: site)
            let kept = SiteBoosts.defaults.data(forKey: SiteBoosts.key)
            let window = WKWebsiteDataStore.nonPersistent()
            // Zapping there keeps its own copy; the kept switch still holds for its pages.
            SiteBoosts.zap("#mine", forSite: "example.com", privateStore: window)
            #expect(PageBoosts.applied(site: "example.com", privateStore: window).isEmpty)
            #expect(SiteBoosts.defaults.data(forKey: SiteBoosts.key) == kept)
            #expect(!ContentBlocker.blocks(on: site) && !CookieBanners.runs(on: site))
        }
    }

    @Test func overriddenRowsShowOffAndDimmed() async throws {
        try await withStores {
            CookieBanners.setChoice(false, for: site)
            let tab = Tab(url: site, title: "Example", spaceID: UUID())
            let first = try #require(SitePanel.forTesting(tab: tab))
            let before = first.debugState["rows"] as? [String] ?? []
            first.close()
            #expect(before.contains("Ad blocking: on"))
            #expect(before.contains("\(SitePanel.compatibilityTitle): off"))
            SiteCompatibility.set(true, for: site)
            let panel = try #require(SitePanel.forTesting(tab: tab))
            let rows = panel.debugState["rows"] as? [String] ?? []
            panel.close()
            #expect(rows.contains("Ad blocking: off, dimmed"))
            #expect(rows.contains("Cookie banners: off, dimmed"))
            #expect(rows.contains("\(SitePanel.compatibilityTitle): on"))
        }
    }

    @Test func siteControlsShowsItInTheAccent() async throws {
        try await withStores {
            let button = IconButton(symbol: "slider.horizontal.3", toolTip: "Site Controls")
            SitePanel.markCompatibility(button, url: site)
            #expect(button.tint == Tokens.Color.icon)
            SiteCompatibility.set(true, for: site)
            SitePanel.markCompatibility(button, url: site)
            #expect(button.tint != Tokens.Color.icon)
            #expect(button.toolTip != PaneHeaderView.siteControlsTitle)
            #expect(button.accessibilityValue() as? String == SitePanel.compatibilityTitle)
            SitePanel.markCompatibility(button, url: other)
            #expect(button.tint == Tokens.Color.icon)
        }
    }

    @Test func boostsSavedBeforeCompatibilityStillRead() throws {
        let old = try JSONDecoder().decode([String: SiteBoost].self, from: Data(##"{"example.com":{"zaps":["#a"],"style":""}}"##.utf8))
        #expect(old["example.com"]?.compatible == false && old["example.com"]?.zaps == ["#a"])
        // A switch that isn't one is off, and the rest still reads.
        let odd = try JSONDecoder().decode(SiteBoost.self, from: Data(##"{"zaps":["#a"],"compatible":"yes"}"##.utf8))
        #expect(!odd.compatible && odd.zaps == ["#a"])
        // Off, it isn't written, so files for sites without it stay as they were.
        let plain = String(decoding: try JSONEncoder().encode(SiteBoost(zaps: ["#a"])), as: UTF8.self)
        #expect(!plain.contains("compatible"))
        let round = try JSONDecoder().decode(SiteBoost.self, from: JSONEncoder().encode(SiteBoost(compatible: true)))
        #expect(round.compatible && !round.isEmpty)
    }
}

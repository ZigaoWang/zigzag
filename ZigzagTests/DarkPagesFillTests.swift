import AppKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Zigzag

/// Dark sites that still draw parts of themselves light (#134): the bar takes the page's own dark, a dark site's light
/// panels are filled in dark while its own colors are left alone, and Force dark darkens a site that looks dark.
@MainActor
@Suite(.serialized)
struct DarkPagesFillTests {
    private func withDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = "DarkPagesFillTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        let delay = DarkPages.paletteDelay
        DarkPages.defaults = UserDefaults(suiteName: name)!
        DarkPages.paletteDelay = 30
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
            DarkPages.paletteDelay = delay
            DarkPages.refreshAll()
        }
        return try await body()
    }

    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let dark = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)

    // MARK: The bar

    /// A page dark on its own colors the bar with its own dark, though its theme color is white; a light page left
    /// alone takes the background under it, else its theme color.
    @Test func aDarkPagesOwnDarkBeatsAWhiteThemeColor() {
        let native = DarkPages.State(darkened: false, native: true, color: Self.dark, site: "example.com")
        #expect(Tab.pageColor(dark: native, under: Self.white, theme: Self.white) == Self.dark)
        let darkened = DarkPages.State(darkened: true, native: false, color: Self.dark, site: "example.com")
        #expect(Tab.pageColor(dark: darkened, under: Self.white, theme: Self.white) == Self.dark)
        let light = DarkPages.State(darkened: false, native: false, color: Self.white, site: "example.com")
        #expect(Tab.pageColor(dark: light, under: nil, theme: Self.white) == Self.white)
        #expect(Tab.pageColor(dark: light, under: Self.dark, theme: Self.white) == Self.dark)
        #expect(Tab.pageColor(dark: nil, under: nil, theme: Self.white) == Self.white)
        // Dark, but no color heard: what's under the page, else the theme color.
        let unknown = DarkPages.State(darkened: false, native: true, color: nil, site: "example.com")
        #expect(Tab.pageColor(dark: unknown, under: nil, theme: Self.white) == Self.white)
    }

    /// Past a dark page's edges, its own dark; past any other where dark pages are wanted, the ground.
    @Test func aDarkPageShowsItsOwnDarkPastItsEdges() {
        let ground = DarkPages.underPageColor
        let native = DarkPages.State(darkened: false, native: true, color: Self.dark, site: "example.com")
        #expect(DarkPages.underPage(native, site: "example.com", ground: ground) == Self.dark)
        // The last site's, still heard as the next one loads: the ground.
        #expect(DarkPages.underPage(native, site: "example.org", ground: ground) == ground)
        let forced = DarkPages.State(darkened: true, native: true, color: Self.dark, site: "example.com")
        #expect(DarkPages.underPage(forced, site: "example.com", ground: ground) == ground)
        #expect(DarkPages.underPage(nil, site: "example.com", ground: ground) == ground)
    }

    // MARK: Force dark

    @Test func forceDarkTurnsDarkPagesOnAndGoesWithIt() async {
        await withDefaults {
            DarkPages.mode = .off
            let url = URL(string: "https://www.bing.com/search?q=a")
            DarkPages.setForced(true, for: url)
            #expect(DarkPages.sitesForced == ["bing.com"])
            #expect(DarkPages.isForced(URL(string: "https://cn.bing.com/")))
            #expect(DarkPages.wants(url))
            #expect(DarkPages.config(for: nil, url: url)["sitesForced"] as? [String] == ["bing.com"])
            // Dark page off for the site lets go of it too.
            DarkPages.setChoice(false, for: url)
            #expect(DarkPages.sitesForced.isEmpty && !DarkPages.wants(url))
            DarkPages.setForced(true, for: url)
            DarkPages.setForced(false, for: url)
            #expect(DarkPages.sitesForced.isEmpty && DarkPages.wants(url))
            DarkPages.setForced(true, for: url)
            DarkPages.forgetAll()
            #expect(DarkPages.sitesForced.isEmpty && DarkPages.sitesOn.isEmpty)
        }
    }

    // MARK: Fills kept

    @Test func aFillIsKeptApartFromAPalette() {
        let fill = DarkPalettes.merged(nil, origin: "https://a.test", black: false, fingerprint: "f1", rules: ["x"], invert: false, fill: true)
        #expect(fill.isFill && fill.verified)
        #expect(DarkPalettes.fileName(origin: "https://a.test", black: false, fill: true) != DarkPalettes.fileName(origin: "https://a.test", black: false))
        #expect(DarkPalettes.origin(ofFile: DarkPalettes.fileName(origin: "https://a.test", black: false, fill: true)) == "https://a.test")
        #expect(DarkPages.paletteKey(fill) == "https://a.test|false|1|fill")
        #expect(DarkPages.paletteChanged(given: "https://a.test|false|1|fill", now: nil, origin: "https://a.test"))
        let scope = "test-\(UUID().uuidString)"
        DarkPalettes.store(fill, scope: scope)
        DarkPalettes.settle()
        DarkPalettes.reload()
        #expect(DarkPalettes.entry(origin: "https://a.test", black: false, scope: scope, fill: true) == fill)
        #expect(DarkPalettes.entry(origin: "https://a.test", black: false, scope: scope) == nil)
        DarkPalettes.forget(scope: scope)
        DarkPalettes.settle()
    }

    // MARK: Writing a fill

    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("var P = " + DarkPages.resource("dark-palette").trimmingCharacters(in: .whitespacesAndNewlines) + ";")
        #expect(context.exception == nil)
        return context
    }

    /// Only what doesn't fit the dark is mapped: a light panel goes dark and is marked, the ink on it turns light only
    /// inside a marked panel, and the site's own dark colors and light text, and what the page showed is overridden,
    /// are left alone.
    @Test func aFillMapsOnlyTheLightParts() throws {
        let c = try context()
        c.evaluateScript("""
            const decl = (o) => Object.assign(Object.keys(o), { getPropertyValue(n) { return o[n] || ''; } });
            const state = P.start();
            P.add(state, [
              { selectorText: ':root', style: decl({ '--surface': '#ffffff', '--page': '#1b1a19' }) },
              { selectorText: '.panel', style: decl({ 'background-color': '#ffffff', 'border-top-color': '#e5e5e5', color: '#222222' }) },
              { selectorText: '.item', style: decl({ color: '#333333' }) },
              { selectorText: '.card', style: decl({ 'background-color': 'var(--surface)' }) },
              { selectorText: '.own', style: decl({ 'background-color': '#202020', color: '#eeeeee' }) },
              { selectorText: '.input', style: decl({ 'background-color': '#ffffff', color: '#111111' }) },
            ], []);
            P.collect(state, () => true);
            const candidates = P.fillCandidates(state).map((x) => x.selector + ' ' + x.name + ' ' + x.kind);
            const out = P.generateFill(state, false, new Set(['5|background-color'])).rules;
            """)
        #expect(c.exception == nil)
        let candidates = c.evaluateScript("candidates").toArray() as? [String] ?? []
        #expect(Set(candidates) == [":root --surface light", ".panel background-color light", ".input background-color light"])
        let out = c.evaluateScript("out").toArray() as? [String] ?? []
        #expect(out.contains(":root:not(#zigzag-dark) { --surface: #121212 !important }"))
        #expect(out.contains { $0.hasPrefix(".panel:not(#zigzag-dark) { background-color: #121212 !important") && $0.contains("--zigzag-dark-fill: 1") && !$0.contains("color: #222222") })
        #expect(out.contains { $0.hasPrefix("@container style(--zigzag-dark-fill: 1) { .item:not(#zigzag-dark) { color: #") })
        // A rule painting with a surface the fill made dark is marked, so its ink turns light too.
        #expect(out.contains(".card:not(#zigzag-dark) { --zigzag-dark-fill: 1 !important }"))
        // The site's own dark colors and light text, and a declaration the page overrides with its own dark: untouched.
        #expect(!out.contains { $0.contains("--page") || $0.contains(".own") })
        #expect(!out.contains { $0.hasPrefix(".input") })
        #expect(out.contains { $0.hasPrefix("@container style(--zigzag-dark-fill: 1) { .input") })
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String, at origin: String) async -> WKWebView {
        DarkPages.mode = .always
        DarkPages.pureBlack = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        DarkPages.attach(to: webView)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: origin + "/"))
        }
        return webView
    }

    private func until(_ seconds: Double = 10, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    private func state(_ webView: WKWebView) async throws -> [String: Any] {
        let json = try await webView.callAsyncJavaScript("return JSON.stringify(window.__zigzagDark.state())", arguments: [:], in: nil, contentWorld: DarkPages.world) as? String
        return try JSONSerialization.jsonObject(with: Data((json ?? "{}").utf8)) as? [String: Any] ?? [:]
    }

    private func js(_ webView: WKWebView, _ source: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    /// A dark search page whose suggestion list is white, as Bing's is, and comes after the page has loaded; and a
    /// box the site paints white in its light look and dark in its own dark one.
    private static let search = """
    <html class="dark"><head><style>
    body { margin: 0; background: #1b1a19; color: #e8e6e3; font: 16px -apple-system; }
    .box { background-color: #ffffff; color: #111111; padding: 8px; }
    html.dark .box { background-color: #2b2a33; color: #eeeeee; }
    .sa_ul { background-color: #ffffff; border: 1px solid #e5e5e5; padding: 6px 0; margin: 0; list-style: none; }
    .sa_sg { color: #222222; padding: 8px 16px; }
    </style></head><body>
    <p id="note">A page dark on its own, with enough words on it to read as one.</p>
    <div class="box" id="box">The search box</div>
    <div id="sw_as"></div>
    </body></html>
    """

    private static let addPanel = """
        document.getElementById('sw_as').innerHTML = '<ul class="sa_ul" id="panel"><li class="sa_sg" id="item">shanghai weather</li></ul>';
        const s = (id) => getComputedStyle(document.getElementById(id));
        return [s('panel').backgroundColor, s('item').color, getComputedStyle(document.body).backgroundColor, s('box').backgroundColor, s('box').color, s('note').color]
        """

    /// The suggestion list that comes late is drawn dark with light words, on the visit the fill is made and from the
    /// first frame of the next, while the page's own dark colors stay exactly as they are.
    @Test func aDarkPagesLatePanelIsFilledInDark() async throws {
        try await withDefaults {
            let origin = "https://fill-\(UUID().uuidString.prefix(8).lowercased()).test"
            let first = await page(Self.search, at: origin)
            let made = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default", fill: true) != nil }
            let seen = try await state(first)
            #expect(made, "\(seen)")
            #expect(seen["native"] as? Bool == true && seen["darkened"] as? Bool == false, "\(seen)")
            let filled = await until { (try? await self.state(first)["fill"] as? Bool) == true }
            #expect(filled)
            let looks = try await js(first, Self.addPanel) as? [String]
            #expect(looks?[0] == "rgb(18, 18, 18)", "\(String(describing: looks))")
            #expect(looks?[1] != "rgb(34, 34, 34)", "\(String(describing: looks))")
            #expect(looks?[2] == "rgb(27, 26, 25)")
            #expect(looks?[3] == "rgb(43, 42, 51)")
            #expect(looks?[4] == "rgb(238, 238, 238)")
            #expect(looks?[5] == "rgb(232, 230, 227)")
            // The bar's color: the page's own dark.
            #expect(seen["color"] as? String == "#1b1a19")

            let second = await page(Self.search, at: origin)
            #expect(try await state(second)["fill"] as? Bool == true)
            let again = try await js(second, Self.addPanel) as? [String]
            #expect(again?[0] == "rgb(18, 18, 18)", "\(String(describing: again))")
            #expect(again?[3] == "rgb(43, 42, 51)")
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// A dark page with nothing light gets no rules worth keeping, and a dark page left alone gets no fill.
    @Test func aDarkPageWithNothingLightIsLeftAsItIs() async throws {
        try await withDefaults {
            let origin = "https://plain-\(UUID().uuidString.prefix(8).lowercased()).test"
            let html = "<html><head><style>body { background: #111; color: #eee } .x { background-color: #222 }</style></head><body><p class='x'>Dark already, all of it.</p></body></html>"
            let webView = await page(html, at: origin)
            let kept = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default", fill: true) != nil }
            #expect(kept)
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default", fill: true)?.rules.isEmpty == true)
            let seen = try await state(webView)
            #expect(seen["fill"] as? Bool == false)
            let own = try await js(webView, "return getComputedStyle(document.querySelector('.x')).backgroundColor") as? String
            #expect(own == "rgb(34, 34, 34)")
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// Forced dark, a page that looks dark on its own is darkened all the same, and gets no fill.
    @Test func aForcedSiteIsDarkenedThoughItLooksDark() async throws {
        try await withDefaults {
            let host = "forced-\(UUID().uuidString.prefix(8).lowercased()).test"
            DarkPages.sitesForced = [host]
            let webView = await page(Self.search, at: "https://" + host)
            let darkened = await until { (try? await self.state(webView)["darkened"] as? Bool) == true }
            let seen = try await state(webView)
            #expect(darkened, "\(seen)")
            #expect(seen["fill"] as? Bool == false)
            DarkPalettes.forget(scope: "default", site: host)
        }
    }
}

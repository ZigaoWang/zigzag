import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Dark pages on Dark Reader (#134): its site fixes read and matched as Dark Reader does, the theme and ground for
/// Pure black, the bar's color, Force dark, and pages drawn by it: a light one darkened (written in rgb() or in oklch()
/// and light-dark(), as Cloudflare's dashboard is), a dark one and one with its own dark theme left alone, a forced one
/// darkened anyway, frames on their own, and its proxy run in the page's world.
@MainActor
@Suite(.serialized)
struct DarkReaderTests {
    private func withDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = "DarkReaderTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
            DarkPages.refreshAll()
        }
        return try await body()
    }

    // MARK: Site fixes

    private static let config = """
    *

    INVERT
    .logo

    CSS
    .everywhere { color: red; }

    ================================

    example.com
    *.example.org

    INVERT
    .a
    .b

    CSS
    .x {
        background: ${white} !important;
    }

    IGNORE INLINE STYLE
    .picker

    ================================

    docs.example.com/guide

    IGNORE IMAGE ANALYSIS
    .hero

    IGNORE CSS URL
    ^https://cdn.example.com/

    ================================

    /^https://regex\\.test/a/

    INVERT
    .r

    ================================

    no-commands.test
    """

    @Test func blocksAreReadAsDarkReaderReadsThem() {
        let fixes = DarkReaderFixes.parse(Self.config)
        #expect(fixes.count == 4)
        #expect(fixes[0].url == ["*"] && fixes[0].invert == [".logo"] && fixes[0].css == ".everywhere { color: red; }")
        #expect(fixes[1].url == ["example.com", "*.example.org"])
        #expect(fixes[1].invert == [".a", ".b"])
        #expect(fixes[1].css == ".x {\n    background: ${white} !important;\n}")
        #expect(fixes[1].ignoreInlineStyle == [".picker"])
        #expect(fixes[2].ignoreImageAnalysis == [".hero"] && fixes[2].ignoreCSSUrl == ["^https://cdn.example.com/"])
        #expect(fixes[3].url == ["/^https://regex\\.test/a/"])
    }

    /// Dark Reader's patterns: a site covers its www, not its other subdomains; "*." covers them; a path narrows it;
    /// "^"/"$" make the host or path exact; a scheme or port must match; slashes make a regular expression.
    @Test func addressesAreMatchedAsDarkReaderMatchesThem() {
        func m(_ url: String, _ pattern: String) -> Bool { DarkReaderFixes.matches(URL(string: url)!, pattern) }
        #expect(m("https://example.com/", "example.com"))
        #expect(m("https://www.example.com/a/b", "example.com"))
        #expect(!m("https://docs.example.com/", "example.com"))
        #expect(m("https://docs.example.com/", "*.example.com"))
        #expect(m("https://a.b.example.com/", "*.example.com"))
        #expect(!m("https://example.net/", "example.com"))
        #expect(m("https://example.com/", "*"))
        #expect(m("https://docs.example.com/guide/intro", "docs.example.com/guide"))
        #expect(!m("https://docs.example.com/api", "docs.example.com/guide"))
        #expect(m("https://docs.example.com/guide", "docs.example.com/guide$"))
        #expect(!m("https://docs.example.com/guide/intro", "docs.example.com/guide$"))
        #expect(m("https://google.co.uk/", "google.*.*"))
        #expect(m("https://github.com/", "github.*"))
        #expect(!m("https://www.example.com/", "^example.com"))
        #expect(m("http://example.com:8080/", "example.com:8080"))
        #expect(!m("http://example.com/", "example.com:8080"))
        #expect(m("https://example.com/", "https://example.com"))
        #expect(!m("http://example.com/", "https://example.com"))
        #expect(m("https://regex.test/a/b", "/^https://regex\\.test/a/"))
        #expect(!m("https://regex.test/b", "/^https://regex\\.test/a/"))
        #expect(!m("https://example.com/", ""))
    }

    /// A page gets the fix for every address, then each block matching it, as one; a frame the one for every address.
    @Test func aPageGetsTheCommonFixAndItsSitesTogether() {
        let fixes = DarkReaderFixes.parse(Self.config)
        let own = DarkReaderFixes.combined(DarkReaderFixes.fixes(for: URL(string: "https://www.example.com/"), in: fixes))
        #expect(own.invert == [".logo", ".a", ".b"])
        #expect(own.css == ".everywhere { color: red; }\n.x {\n    background: ${white} !important;\n}")
        #expect(own.ignoreInlineStyle == [".picker"])
        let docs = DarkReaderFixes.combined(DarkReaderFixes.fixes(for: URL(string: "https://docs.example.com/guide"), in: fixes))
        #expect(docs.invert == [".logo"] && docs.ignoreImageAnalysis == [".hero"])
        #expect(DarkReaderFixes.combined(DarkReaderFixes.fixes(for: nil, in: fixes)).invert == [".logo"])
        #expect(DarkReaderFixes.combined(DarkReaderFixes.fixes(for: URL(string: "https://other.test/"), in: fixes)).css == ".everywhere { color: red; }")
    }

    /// The bundled list: Dark Reader's own, with its fix for every address and its fixes for sites.
    @Test func theBundledFixesAreRead() {
        let everywhere = DarkReaderFixes.fix(for: nil)
        #expect(!everywhere.invert.isEmpty && !everywhere.css.isEmpty)
        let cloudflare = DarkReaderFixes.fix(for: URL(string: "https://dash.cloudflare.com/login"))
        #expect(cloudflare.invert.count > everywhere.invert.count)
        #expect(cloudflare.css.hasPrefix(everywhere.css))
        #expect(DarkPages.config(for: nil, url: URL(string: "https://dash.cloudflare.com/"))["fix"] as? [String: Any] != nil)
    }

    // MARK: Theme and ground

    private func gray(_ color: NSColor?) -> Int {
        Int(((color?.usingColorSpace(.sRGB)?.redComponent ?? -1) * 255).rounded())
    }

    @Test func pureBlackIsOffUntilChosenAndIsTheThemesBackground() async {
        await withDefaults {
            #expect(!DarkPages.pureBlack)
            #expect((DarkPages.config(for: nil)["theme"] as? [String: Any])?["darkSchemeBackgroundColor"] as? String == "#181a1b")
            DarkPages.pureBlack = true
            #expect(DarkPages.pureBlack)
            #expect((DarkPages.config(for: nil)["theme"] as? [String: Any])?["darkSchemeBackgroundColor"] as? String == "#000000")
            #expect(DarkPages.config(for: nil)["prepaint"] as? String == DarkPages.prepaintCSS(black: true))
        }
        #expect(gray(DarkPages.background(black: true)) == 0)
        #expect(gray(DarkPages.background(black: false)) == 0x18)
    }

    @Test func thePrepaintIsADarkSchemeAndGroundWithTheBodyClear() {
        let dark = DarkPages.prepaintCSS(black: false)
        #expect(dark.contains(":root { color-scheme: dark !important; background-color: #181a1b !important; }"))
        #expect(dark.contains("body { background-color: transparent !important; }"))
        #expect(DarkPages.prepaintCSS(black: true).contains("background-color: #000000 !important"))
        #expect(DarkPages.prepaintCSS(black: false, color: "#0d1117").contains("#0d1117"))
    }

    /// A web view whose pages are darkened draws no white of WebKit's own under them: before a page has drawn
    /// anything the dark behind it shows instead. Where pages aren't darkened it draws its background as always.
    @Test func aDarkenedWebViewDrawsNoWhiteOfItsOwn() async {
        await withDefaults {
            DarkPages.mode = .always
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
            DarkPages.attach(to: webView)
            #expect(webView.value(forKey: "drawsBackground") as? Bool == false)
            #expect(gray(webView.underPageBackgroundColor) == 0x18)
            DarkPages.mode = .off
            #expect(webView.value(forKey: "drawsBackground") as? Bool == true)
            #expect(webView.underPageBackgroundColor == nil || webView.appearance == nil)
        }
    }

    // MARK: The bar

    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let dark = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)

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
        let unknown = DarkPages.State(darkened: false, native: true, color: nil, site: "example.com")
        #expect(Tab.pageColor(dark: unknown, under: nil, theme: Self.white) == Self.white)
        // Dark on its own but light at the top, with no dark found to give: no white from it.
        let lightTop = DarkPages.State(darkened: false, native: true, color: Self.white, site: "example.com")
        #expect(Tab.pageColor(dark: lightTop, under: Self.dark, theme: Self.white) == Self.dark)
    }

    /// With dark pages off, a page dark on its own still says so, and its dark, for the bar above it (#134), from the
    /// plain script with no Dark Reader in it; turned on, Dark Reader's script takes over from it.
    @Test func aDarkPageSaysItsDarkWithDarkPagesOff() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .off
            let html = "<html style='background:#fff'><head><style>body { background: #111; color: #eee; margin: 0; min-height: 600px }</style></head><body><p>Dark.</p></body></html>"
            let webView = await page(html)
            let seen = await until { (try? await state(webView))?["native"] as? Bool == true }
            #expect(seen)
            let found = try await state(webView)
            #expect(found["plain"] as? Bool == true && found["darkened"] as? Bool == false && found["color"] as? String == "#111111")
            DarkPages.mode = .always
            let tookOver = await until { (try? await state(webView))?["plain"] as? Bool == false }
            #expect(tookOver)
        }
    }

    /// Past a dark page's edges, its own dark; past any other where dark pages are wanted, the ground.
    @Test func aDarkPageShowsItsOwnDarkPastItsEdges() {
        let ground = DarkPages.background(black: false)
        let native = DarkPages.State(darkened: false, native: true, color: Self.dark, site: "example.com")
        #expect(DarkPages.underPage(native, site: "example.com", ground: ground) == Self.dark)
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
            #expect(DarkPages.config(for: nil, url: url)["topForced"] as? Bool == true)
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

    // MARK: Fetching for it

    @Test func onlyStyleAndPicturesOnTheWebAreFetched() {
        #expect(DarkPages.fetchable(URL(string: "https://cdn.example.com/a.css")))
        #expect(!DarkPages.fetchable(URL(string: "file:///etc/hosts")))
        #expect(!DarkPages.fetchable(URL(string: "http://localhost:8080/a.css")))
        #expect(!DarkPages.fetchable(URL(string: "http://192.168.1.1/a.css")))
        #expect(!DarkPages.fetchable(URL(string: "http://10.0.0.2/a.css")))
        #expect(DarkPages.fetchableType("text/css; charset=utf-8"))
        #expect(DarkPages.fetchableType("image/png"))
        #expect(!DarkPages.fetchableType("text/html"))
        #expect(!DarkPages.fetchableType("application/json"))
    }

    /// An SVG picture is drawn for Dark Reader to look at, at its own size (Hacker News's vote arrow); anything else,
    /// or too much, isn't.
    @Test func anSVGIsDrawnForDarkReader() throws {
        let svg = ##"<svg height="32" viewBox="0 0 32 16" width="32" xmlns="http://www.w3.org/2000/svg"><path d="m2 27 14-29 14 29z" fill="#999"/></svg>"##
        let base64 = try #require(DarkPages.rasterize("data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()))
        #expect(base64.width == 32 && base64.height == 32)
        let png = try #require(Data(base64Encoded: base64.png))
        #expect(NSBitmapImageRep(data: png)?.pixelsWide == 32)
        let escaped = try #require(DarkPages.rasterize("data:image/svg+xml," + (svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        #expect(escaped.width == 32)
        #expect(DarkPages.rasterize("data:image/png;base64,iVBORw0KGgo=") == nil)
        #expect(DarkPages.rasterize("data:image/svg+xml;base64,bm90IGFuIHN2Zw==") == nil)
        #expect(DarkPages.rasterize("data:image/svg+xml," + String(repeating: "a", count: DarkPages.maxImageBytes)) == nil)
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String, at origin: String = "https://dark-reader-\(UUID().uuidString.prefix(8).lowercased()).test") async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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

    private func js(_ webView: WKWebView, _ source: String, in frame: WKFrameInfo? = nil) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: frame, contentWorld: .page)
    }

    private func state(_ webView: WKWebView) async throws -> [String: Any] {
        let json = try await webView.callAsyncJavaScript("return JSON.stringify(window.__zigzagDark.state())", arguments: [:], in: nil, contentWorld: DarkPages.world) as? String
        return try JSONSerialization.jsonObject(with: Data((json ?? "{}").utf8)) as? [String: Any] ?? [:]
    }

    /// The sRGB lightness of a computed color, read by drawing it (oklch() and the rest included).
    private func lightness(_ webView: WKWebView, _ expression: String) async throws -> Double {
        try await js(webView, """
        const c = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
        c.fillStyle = \(expression); c.fillRect(0, 0, 1, 1);
        const d = c.getImageData(0, 0, 1, 1).data;
        return (0.2126 * d[0] + 0.7152 * d[1] + 0.0722 * d[2]) / 255;
        """) as? Double ?? -1
    }

    /// A light page written in oklch() and light-dark(), as Cloudflare's dashboard is: its surfaces come out dark
    /// and its text light, not left as they were (#134).
    @Test func aPageInOklchAndLightDarkIsDarkenedWholly() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let html = """
            <html><head><style>
            :root { color-scheme: light; --canvas: light-dark(oklch(98.75% 0 0), oklch(10% 0 0)); --text: light-dark(oklch(21% 0.006 285.885), oklch(97% 0 0)); }
            [data-mode="dark"] { color-scheme: dark; }
            body { background: var(--canvas); color: var(--text); margin: 0; min-height: 600px; font: 16px sans-serif }
            .menu { background: oklch(100% 0 0); color: oklch(20.5% 0 0); padding: 20px; }
            </style></head><body><h1 id="h">Shipping today?</h1><div class="menu" id="menu">Light mode</div></body></html>
            """
            let webView = await page(html)
            let drawn = await until { (try? await js(webView, "return document.documentElement.getAttribute('data-darkreader-mode')") as? String) == "dynamic" }
            #expect(drawn)
            try? await Task.sleep(for: .milliseconds(500))
            #expect(try await lightness(webView, "getComputedStyle(document.body).backgroundColor") < 0.2)
            #expect(try await lightness(webView, "getComputedStyle(document.getElementById('menu')).backgroundColor") < 0.2)
            #expect(try await lightness(webView, "getComputedStyle(document.getElementById('h')).color") > 0.7)
            #expect(try await lightness(webView, "getComputedStyle(document.getElementById('menu')).color") > 0.7)
            let found = try await state(webView)
            #expect(found["darkened"] as? Bool == true && found["native"] as? Bool == false)
        }
    }

    /// A page dark on its own in oklch() is seen as dark, and left alone.
    @Test func aDarkPageInOklchIsLeftAlone() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let html = "<html><head><style>body { background: oklch(17% 0 0); color: oklch(97% 0 0); min-height: 600px }</style></head><body><p>Dark.</p></body></html>"
            let webView = await page(html)
            let decided = await until { (try? await state(webView))?["native"] as? Bool == true }
            #expect(decided)
            #expect(try await js(webView, "return document.documentElement.hasAttribute('data-darkreader-mode')") as? Bool == false)
        }
    }

    /// Force dark: a page that's dark on its own is drawn by Dark Reader anyway.
    @Test func aForcedPageIsDarkenedThoughItLooksDark() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let origin = "https://forced-\(UUID().uuidString.prefix(8).lowercased()).test"
            DarkPages.setForced(true, for: URL(string: origin))
            let html = "<html><head><meta name='color-scheme' content='dark'></head><body style='background:#111;color:#eee'><p>Dark.</p></body></html>"
            let webView = await page(html, at: origin)
            let drawn = await until { (try? await js(webView, "return document.documentElement.getAttribute('data-darkreader-mode')") as? String) == "dynamic" }
            #expect(drawn)
            try? await Task.sleep(for: .milliseconds(800))
            #expect(try await state(webView)["darkened"] as? Bool == true)
        }
    }

    /// Dark Reader's proxy runs in the page's own world, asked for by an event rather than an inline script a page's
    /// Content-Security-Policy would block.
    @Test func theProxyRunsInThePagesWorldUnderAStrictPolicy() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let html = """
            <html><head><meta http-equiv="Content-Security-Policy" content="script-src 'nonce-a'">
            <script nonce="a">window.proxied = false; document.addEventListener('__darkreader__inlineScriptsAllowed', () => { window.proxied = true; });</script>
            </head><body style="background:#fff;color:#111"><p>Strict.</p></body></html>
            """
            let webView = await page(html)
            let proxied = await until { (try? await js(webView, "return window.proxied") as? Bool) == true }
            #expect(proxied)
        }
    }

    /// A page whose policy lets no image load a data: URL, with the same picture in two rules (Hacker News's vote
    /// arrows): Dark Reader still gets to look at it, and neither rule loses its background.
    @Test func picturesKeepTheirPlaceUnderAStrictImagePolicy() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let svg = ##"<svg height="32" viewBox="0 0 32 16" width="32" xmlns="http://www.w3.org/2000/svg"><path d="m2 27 14-29 14 29z" fill="#999"/></svg>"##
            let icon = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
            let html = """
            <html><head><meta http-equiv="Content-Security-Policy" content="img-src 'self'"><style>
            body { background: #fff; color: #111; min-height: 600px }
            .arrow { width: 10px; height: 10px; background: url("\(icon)"), linear-gradient(transparent, transparent) no-repeat; background-size: 10px; }
            @media screen { .arrow { background: url("\(icon)"), linear-gradient(transparent, transparent) no-repeat; background-size: 10px; } }
            </style></head><body><p>Strict.</p><div class="arrow" id="a"></div></body></html>
            """
            let webView = await page(html)
            let drawn = await until { (try? await js(webView, "return document.documentElement.getAttribute('data-darkreader-mode')") as? String) == "dynamic" }
            #expect(drawn)
            try? await Task.sleep(for: .milliseconds(1500))
            let image = try await js(webView, "return getComputedStyle(document.getElementById('a')).backgroundImage") as? String ?? ""
            #expect(image.contains("url("), "\(image)")
        }
    }

    /// Dark Reader's first pass runs after a frame is drawn, even in a page that gets no frames (a tab behind others),
    /// and its rough dark meanwhile is taken off once the pass is done.
    @Test func aLightPageIsDrawnRoughlyDarkBeforeDarkReadersPass() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let html = """
            <html><head><style>body { background: #fff; color: #111; min-height: 600px }</style>
            </head><body><p>Light.</p></body></html>
            """
            let webView = await page(html)
            let drawn = await until { (try? await js(webView, "return document.documentElement.getAttribute('data-darkreader-mode')") as? String) == "dynamic" }
            #expect(drawn)
            // Taken off once the pass is done.
            let cleared = await until { (try? await js(webView, "return !document.querySelector('.zigzag-dark-fallback')") as? Bool) == true }
            #expect(cleared)
        }
    }

    /// A light frame in a dark page darkens itself; the page around it is left as it is.
    @Test func aLightFrameInADarkPageDarkensItself() async throws {
        try await withDefaults { () async throws in
            DarkPages.mode = .always
            let html = """
            <html><head><meta name="color-scheme" content="dark"><style>body { background: #111; color: #eee }</style></head>
            <body><iframe id="f" style="width:600px;height:300px" srcdoc="<html><body style='background:#fff;color:#111;min-height:280px'><p>Light widget</p></body></html>"></iframe></body></html>
            """
            let webView = await page(html)
            let darkened = await until {
                (try? await js(webView, "const d = document.getElementById('f').contentDocument; return d && d.documentElement.getAttribute('data-darkreader-mode')") as? String) == "dynamic"
            }
            #expect(darkened)
            #expect(try await js(webView, "return document.documentElement.hasAttribute('data-darkreader-mode')") as? Bool == false)
        }
    }
}

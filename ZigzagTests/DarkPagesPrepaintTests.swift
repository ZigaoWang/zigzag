import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Dark pages never showing white first (#134): the dark behind a page about to be darkened, the plain dark ground a
/// page last seen dark starts on, and a palette that leaves a page light giving way at once rather than once it's idle.
@MainActor
@Suite(.serialized)
struct DarkPagesPrepaintTests {
    private func withDefaults<T>(paletteDelay: Int = 30, _ body: () async throws -> T) async rethrows -> T {
        let name = "DarkPagesPrepaintTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        let delay = DarkPages.paletteDelay
        DarkPages.defaults = UserDefaults(suiteName: name)!
        DarkPages.paletteDelay = paletteDelay
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
            DarkPages.paletteDelay = delay
            DarkPages.refreshAll()
        }
        return try await body()
    }

    private func gray(_ color: NSColor) -> Int {
        Int((color.usingColorSpace(.sRGB)!.redComponent * 255).rounded())
    }

    // MARK: The dark behind the page

    @Test func theGroundIsTheDarkThePagesWhiteBecomes() {
        // The filter turns white into 8% gray, or black; a palette into the bottom of its ramp.
        #expect(gray(DarkPages.ground(black: false, palette: false)) == 20)
        #expect(gray(DarkPages.ground(black: true, palette: false)) == 0)
        #expect(gray(DarkPages.ground(black: false, palette: true)) == 18)
        #expect(gray(DarkPages.ground(black: true, palette: true)) == 0)
    }

    @Test func onlyAPaletteInUseCountsAsOne() {
        let made = DarkPalettes.merged(nil, origin: "https://a.test", black: false, fingerprint: "f", rules: ["a { color: red !important }"], invert: false)
        #expect(DarkPages.drawsWithPalette(made))
        #expect(!DarkPages.drawsWithPalette(nil))
        let refused = DarkPalettes.verified(made, fingerprint: "f", ok: false)
        #expect(!DarkPages.drawsWithPalette(refused))
    }

    /// A web view whose pages are darkened draws no white of WebKit's own under them: before a page has drawn
    /// anything (a new tab, a tab that slept coming back) the dark behind it shows instead. Where pages aren't
    /// darkened it draws its background as always.
    @Test func aDarkenedWebViewDrawsNoWhiteOfItsOwn() async {
        await withDefaults {
            DarkPages.mode = .always
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
            DarkPages.attach(to: webView)
            #expect(webView.value(forKey: "drawsBackground") as? Bool == false)
            DarkPages.mode = .off
            #expect(webView.value(forKey: "drawsBackground") as? Bool == true)
            DarkPages.setChoice(true, for: URL(string: "https://example.org/"))
            webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.org/"))
            let followed = await until { webView.value(forKey: "drawsBackground") as? Bool == false }
            #expect(followed)
            #expect(gray(webView.underPageBackgroundColor) == 20)
        }
    }

    // MARK: The plain dark ground

    @Test func thePrepaintIsADarkSchemeAndGroundWithTheBodyClear() {
        let dark = DarkPages.prepaintCSS(black: false)
        #expect(dark.contains(":root { color-scheme: dark !important; background-color: #121212 !important; }"))
        #expect(dark.contains("body { background-color: transparent !important; }"))
        #expect(DarkPages.prepaintCSS(black: true).contains("background-color: #000000 !important"))
        // Never a filter: under the page's filter it would come out light.
        #expect(!dark.contains("filter"))
    }

    @Test func pagesAreGivenThePrepaint() async {
        await withDefaults {
            DarkPages.pureBlack = true
            #expect(DarkPages.config(for: nil)["prepaint"] as? String == DarkPages.prepaintCSS(black: true))
        }
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String, at origin: String) async -> WKWebView {
        DarkPages.mode = .always
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

    /// What the page's first script sees, before its body: the ground it starts on.
    private static let early = """
    <script>window.early = { prepaint: !!document.querySelector('style[data-zigzag-dark=prepaint]'),
      scheme: getComputedStyle(document.documentElement).colorScheme,
      ground: getComputedStyle(document.documentElement).backgroundColor };</script>
    """

    /// A site last seen dark starts on the plain dark ground, not WebKit's white; once it's looked at the ground goes
    /// and the page keeps its own colors.
    @Test func aSiteSeenDarkStartsOnTheDarkGroundAndKeepsItsOwnColors() async throws {
        try await withDefaults {
            let site = "prepaint-dark-\(UUID().uuidString.prefix(8).lowercased()).test"
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: nil, site: site), in: "default")
            defer { DarkPages.learn(DarkPages.State(darkened: true, native: false, color: nil, site: site), in: "default") }
            let html = "<html><head>\(Self.early)<style>body { background: #202830; color: #eee }</style></head><body><p>Dark on its own.</p></body></html>"
            let webView = await page(html, at: "https://" + site)
            let early = try await js(webView, "return [window.early.prepaint, window.early.scheme, window.early.ground]") as? [Any]
            #expect(early?[0] as? Bool == true)
            #expect(early?[1] as? String == "dark")
            #expect(early?[2] as? String == "rgb(18, 18, 18)")
            let gone = await until { (try? await js(webView, "return !document.querySelector('style[data-zigzag-dark=prepaint]')") as? Bool) == true }
            #expect(gone)
            #expect(try await js(webView, "return getComputedStyle(document.body).backgroundColor") as? String == "rgb(32, 40, 48)")
            let seen = try await state(webView)
            #expect(seen["darkened"] as? Bool == false)
            #expect(seen["native"] as? Bool == true)
        }
    }

    /// A light page on a site last seen dark starts on the dark ground too, then is darkened, and the ground goes.
    @Test func aLightPageOnASiteSeenDarkIsDarkenedAfterTheGround() async throws {
        try await withDefaults {
            let site = "prepaint-light-\(UUID().uuidString.prefix(8).lowercased()).test"
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: nil, site: site), in: "default")
            defer { DarkPages.learn(DarkPages.State(darkened: true, native: false, color: nil, site: site), in: "default") }
            let html = "<html><head>\(Self.early)</head><body style='background:#fff;color:#111'><p>Light after all.</p></body></html>"
            let webView = await page(html, at: "https://" + site)
            #expect(try await js(webView, "return window.early.prepaint") as? Bool == true)
            let darkened = await until { (try? await state(webView)["darkened"] as? Bool) == true }
            #expect(darkened)
            #expect(try await js(webView, "return !document.querySelector('style[data-zigzag-dark=prepaint]')") as? Bool == true)
            let filter = try await js(webView, "return getComputedStyle(document.documentElement).filter") as? String
            #expect(filter?.contains("invert") == true)
        }
    }

    /// A page darkened from the start needs no ground of its own: the filter, or the palette, is there from its first
    /// moment, and a page of a site not seen before gets no prepaint over it.
    @Test func aPageDarkenedFromTheStartHasNoPrepaint() async throws {
        try await withDefaults {
            let origin = "https://prepaint-none-\(UUID().uuidString.prefix(8).lowercased()).test"
            let html = "<html><head>\(Self.early)</head><body style='background:#fff'><p>Light.</p></body></html>"
            let webView = await page(html, at: origin)
            let early = try await js(webView, "return window.early.prepaint") as? Bool
            #expect(early == false)
            let filter = try await js(webView, "return getComputedStyle(document.documentElement).filter") as? String
            #expect(filter?.contains("invert") == true)
        }
    }

    // MARK: A palette that leaves the page light

    private static let sheetSite = """
    <html><head><style>
    body { background: #ffffff; color: #1f2328; margin: 0; font: 16px -apple-system; }
    header { background-color: #f6f8fa; padding: 16px; } a { color: #0969da; }
    .card { background: #ffffff; border: 1px solid #d0d7de; padding: 16px; min-height: 480px; }
    </style></head><body><header>Site <a href="#">Link</a></header>
    <main class="card"><p>Some text that's long enough to read.</p></main></body></html>
    """

    /// The same sheets, but most of the page painted light by HTML attributes, which a palette can't reach (as on
    /// Hacker News): the white a palette would leave there is caught as the page comes in.
    private static let attributeSite = """
    <html><head><style>
    body { background: #ffffff; color: #1f2328; margin: 0; font: 16px -apple-system; }
    header { background-color: #f6f8fa; padding: 16px; } a { color: #0969da; }
    .card { background: #ffffff; border: 1px solid #d0d7de; padding: 16px; min-height: 480px; }
    </style></head><body><table bgcolor="#f6f6ef" width="100%" height="900"><tr><td><font color="#000">Painted by
    attributes.</font></td></tr></table></body></html>
    """

    /// The first visit tries the palette it made on the page there and then: one that covers the page takes over at
    /// once, and the site's palette is kept as checked.
    @Test func aPaletteThatCoversThePageTakesOverOnTheFirstVisit() async throws {
        try await withDefaults {
            let origin = "https://swap-\(UUID().uuidString.prefix(8).lowercased()).test"
            let first = await page(Self.sheetSite, at: origin)
            let before = try await state(first)
            #expect(before["palette"] as? Bool == false)
            let swapped = await until { (try? await state(first)["palette"] as? Bool) == true }
            #expect(swapped)
            #expect(try await js(first, "return getComputedStyle(document.documentElement).filter") as? String == "none")
            let kept = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default")?.verified == true }
            #expect(kept)
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default")?.invert == false)
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// A palette made on one page of a site, opening another it leaves light: back to the filter as the page comes
    /// in, long before the page is idle, and the site keeps the filter once it is.
    @Test func aPaletteThatLeavesAnotherPageLightGivesWayAtOnce() async throws {
        try await withDefaults(paletteDelay: 30) {
            let origin = "https://early-\(UUID().uuidString.prefix(8).lowercased()).test"
            let first = await page(Self.sheetSite, at: origin)
            let made = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default")?.verified == true }
            let seen = try await state(first)
            #expect(made, "\(seen) \(DarkPages.lastAnalysis)")
            // Idle checks far off, so only the early one can have done it.
            DarkPages.paletteDelay = 60_000
            let second = await page(Self.attributeSite, at: origin)
            let shown = try await state(second)
            #expect(shown["refused"] as? Bool == true, "\(shown)")
            #expect(shown["palette"] as? Bool == false)
            let filter = try await js(second, "return getComputedStyle(document.documentElement).filter") as? String
            #expect(filter?.contains("invert") == true)
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// Refused as it came in, a palette is tried again once the page is idle, and the site told: here it still leaves
    /// the page light, so the site keeps the filter from now on.
    @Test func anEarlyRefusalIsCheckedOnceIdleAndKept() async throws {
        try await withDefaults {
            let origin = "https://early-kept-\(UUID().uuidString.prefix(8).lowercased()).test"
            let first = await page(Self.sheetSite, at: origin)
            let made = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default")?.verified == true }
            let seen = try await state(first)
            #expect(made, "\(seen) \(DarkPages.lastAnalysis)")
            let second = await page(Self.attributeSite, at: origin)
            let marked = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default")?.invert == true }
            #expect(marked)
            #expect(try await state(second)["palette"] as? Bool == false)
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }
}

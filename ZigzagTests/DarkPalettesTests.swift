import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Dark pages' palettes (#134): a light site's own colors turned dark once, kept for the site in its profile, and
/// drawn from the first frame on later visits, with the invert filter where a palette doesn't cover the page.
@MainActor
@Suite(.serialized)
struct DarkPalettesTests {
    private func withDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = "DarkPalettesTests-\(UUID().uuidString)"
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

    // MARK: Keeping them

    private func entry(_ origin: String = "https://example.test", rules: [String] = ["a { color: red !important }"]) -> DarkPalettes.Entry {
        DarkPalettes.merged(nil, origin: origin, black: false, fingerprint: "f1", rules: rules, invert: false)
    }

    @Test func aNewPaletteIsUnverifiedAndCounts() {
        let made = entry()
        #expect(made.fingerprints == ["f1"])
        #expect(!made.verified && !made.invert)
        #expect(made.revision == 1)
        #expect(made.css == "a { color: red !important }")
    }

    /// Another page of the site adds what it needed; the newest rules come last, so they win.
    @Test func anotherPageOfTheSiteAddsItsRules() {
        let first = entry(rules: ["base", "a", "b"])
        let second = DarkPalettes.merged(first, origin: first.origin, black: false, fingerprint: "f2", rules: ["base", "c", "a"], invert: false)
        #expect(second.rules == ["b", "base", "c", "a"])
        #expect(second.fingerprints == ["f1", "f2"])
        #expect(second.revision == 2)
        #expect(!second.verified)
    }

    @Test func onlyTheLastFewStylesAreRemembered() {
        var made = entry()
        for n in 2...9 { made = DarkPalettes.merged(made, origin: made.origin, black: false, fingerprint: "f\(n)", rules: ["r\(n)"], invert: false) }
        #expect(made.fingerprints == ["f4", "f5", "f6", "f7", "f8", "f9"])
    }

    /// Too big together: the latest page's palette alone.
    @Test func aPaletteTooBigOnItsOwnIsTheFilter() {
        let big = String(repeating: "x", count: DarkPalettes.maxBytes + 1)
        let made = entry(rules: [big])
        #expect(made.invert && made.rules.isEmpty)
    }

    @Test func aPaletteTooBigTogetherIsTheLatestAlone() {
        let big = String(repeating: "x", count: DarkPalettes.maxBytes / 2 + 10)
        let first = entry(rules: [big + "1"])
        let second = DarkPalettes.merged(first, origin: first.origin, black: false, fingerprint: "f2", rules: [big + "2"], invert: false)
        #expect(second.rules == [big + "2"])
    }

    /// Drawn and found to leave the page light: the filter from then on, until the site's style changes; a new
    /// reading of it starts afresh, without the rules that didn't work.
    @Test func aPaletteThatDidntCoverThePageGivesWayToTheFilter() {
        let made = entry()
        let bad = DarkPalettes.verified(made, fingerprint: "f1", ok: false)
        #expect(bad.invert && bad.verified && bad.rules.isEmpty)
        let good = DarkPalettes.verified(made, fingerprint: "f1", ok: true)
        #expect(good.verified && !good.invert && good.rules == made.rules)
        // Not for a style it wasn't made from, and once verified it stays.
        #expect(DarkPalettes.verified(made, fingerprint: "other", ok: false) == made)
        #expect(DarkPalettes.verified(good, fingerprint: "f1", ok: true) == good)
        let again = DarkPalettes.merged(bad, origin: made.origin, black: false, fingerprint: "f2", rules: ["new"], invert: false)
        #expect(again.rules == ["new"] && !again.invert)
    }

    @Test func aSitesOriginIsWhatThePageCallsIt() {
        #expect(DarkPalettes.origin(of: URL(string: "https://GitHub.com/a/b?c")) == "https://github.com")
        #expect(DarkPalettes.origin(of: URL(string: "http://example.com:80/")) == "http://example.com")
        #expect(DarkPalettes.origin(of: URL(string: "https://example.com:8443/")) == "https://example.com:8443")
        #expect(DarkPalettes.origin(of: URL(string: "file:///tmp/a.html")) == nil)
        #expect(DarkPalettes.origin(of: URL(string: "about:blank")) == nil)
    }

    @Test func eachSiteHasAFileNamedAfterIt() {
        let name = DarkPalettes.fileName(origin: "https://example.com:8443", black: true)
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(DarkPalettes.origin(ofFile: name) == "https://example.com:8443")
        #expect(DarkPalettes.fileName(origin: "https://example.com", black: false) != DarkPalettes.fileName(origin: "https://example.com", black: true))
        #expect(DarkPalettes.site(ofOrigin: "https://www.example.com") == "example.com")
    }

    /// A web view going to a site with a palette other than the one its script has gets the script again; going
    /// anywhere else it doesn't, unless the site it had one for lost it.
    @Test func theScriptIsPutInAgainOnlyForAnotherPalette() {
        #expect(DarkPages.paletteChanged(given: nil, now: "https://a.test|false|1", origin: "https://a.test"))
        #expect(!DarkPages.paletteChanged(given: "https://a.test|false|1", now: "https://a.test|false|1", origin: "https://a.test"))
        #expect(DarkPages.paletteChanged(given: "https://a.test|false|1", now: "https://a.test|false|2", origin: "https://a.test"))
        #expect(!DarkPages.paletteChanged(given: "https://a.test|false|1", now: nil, origin: "https://b.test"))
        #expect(DarkPages.paletteChanged(given: "https://a.test|false|1", now: nil, origin: "https://a.test"))
        #expect(!DarkPages.paletteChanged(given: nil, now: nil, origin: "https://a.test"))
    }

    @Test func onlySheetsOnTheWebAreFetched() {
        #expect(DarkPalettes.fetchable(URL(string: "https://cdn.example.com/site.css")))
        for address in ["http://localhost/a.css", "http://192.168.1.1/a.css", "http://10.0.0.2/a.css", "http://127.0.0.1/a.css",
                        "http://172.20.0.1/a.css", "http://printer.local/a.css", "file:///etc/a.css", "data:text/css,a{}"] {
            #expect(!DarkPalettes.fetchable(URL(string: address)), "\(address)")
        }
    }

    /// Kept on disk for each profile, read back, and gone when the site's data or History is cleared.
    @Test func palettesAreKeptForEachProfileAndClearedWithTheSite() throws {
        let scope = "test-\(UUID().uuidString)"
        let other = "test-\(UUID().uuidString)"
        let a = entry("https://a.example.org"), b = entry("https://www.b.example.org")
        DarkPalettes.store(a, scope: scope)
        DarkPalettes.store(b, scope: scope)
        DarkPalettes.settle()
        DarkPalettes.reload()
        #expect(DarkPalettes.entry(origin: a.origin, black: false, scope: scope) == a)
        #expect(DarkPalettes.entry(origin: a.origin, black: true, scope: scope) == nil)
        #expect(DarkPalettes.entry(origin: a.origin, black: false, scope: other) == nil)
        #expect(DarkPalettes.entry(origin: a.origin, black: false, scope: nil) == nil)
        DarkPalettes.forget(scope: scope, site: "b.example.org")
        DarkPalettes.settle()
        DarkPalettes.reload()
        #expect(DarkPalettes.entry(origin: b.origin, black: false, scope: scope) == nil)
        #expect(DarkPalettes.entry(origin: a.origin, black: false, scope: scope) == a)
        DarkPalettes.forget(scope: scope, since: Date().addingTimeInterval(-60))
        DarkPalettes.settle()
        DarkPalettes.reload()
        #expect(DarkPalettes.entry(origin: a.origin, black: false, scope: scope) == nil)
        DarkPalettes.store(a, scope: scope)
        DarkPalettes.forget(scope: scope)
        DarkPalettes.settle()
        DarkPalettes.reload()
        #expect(DarkPalettes.entry(origin: a.origin, black: false, scope: scope) == nil)
        let folder = try #require(DarkPalettes.folder(scope))
        #expect(folder.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test func aPrivateWindowIsNeverGivenOneNorLearnsOne() {
        let store = WKWebsiteDataStore.nonPersistent()
        #expect(DarkPages.config(for: store, url: URL(string: "https://a.example.org"))["learn"] as? Bool == false)
        #expect(DarkPages.config(for: store, url: URL(string: "https://a.example.org"))["palette"] is NSNull)
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String, at origin: String, store: WKWebsiteDataStore = .default(), black: Bool = false) async -> WKWebView {
        DarkPages.mode = .always
        DarkPages.pureBlack = black
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        // A web view in no window is a tab in the background, whose timers WebKit slows more and more: not here.
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

    private static let photo = "data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="

    private static let site = """
    <html><head><style>
    :root { --bg: #ffffff; --text: #1f2328; --muted: #656d76; --link: #0969da; --line: #d0d7de; }
    body { background: var(--bg); color: var(--text); margin: 0; font: 16px -apple-system; }
    header { background-color: #f6f8fa; border-bottom: 1px solid var(--line); padding: 16px; }
    a { color: var(--link); }
    .muted { color: var(--muted); }
    .button { background-color: #1f883d; color: #fff; padding: 4px 8px; }
    .card { background: linear-gradient(#ffffff, #f6f8fa); border: 1px solid #d0d7de; padding: 16px; min-height: 380px; }
    </style></head><body>
    <header>Site <a href="#">Link</a> <span class="button">Go</span></header>
    <main class="card" id="card"><p id="text">Some text that's long enough to read.</p><p class="muted">Quieter.</p>
    <img id="pic" src="\(photo)" width="80" height="80"></main>
    </body></html>
    """

    /// The first visit is drawn by the filter and reads the site's colors once it's idle; the next is drawn with the
    /// palette from the start: dark surfaces, light text, no filter on the page or its pictures.
    @Test func aSiteSeenOnceIsDrawnWithItsPaletteNextTime() async throws {
        try await withDefaults {
            let origin = "https://palette-\(UUID().uuidString.prefix(8).lowercased()).test"
            let first = await page(Self.site, at: origin)
            #expect(try await state(first)["palette"] as? Bool == false)
            let made = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default") != nil }
            #expect(made)
            let entry = try #require(DarkPalettes.entry(origin: origin, black: false, scope: "default"))
            #expect(!entry.invert)
            #expect(entry.css.contains("--bg: #121212 !important"))
            #expect(entry.css.contains("background-color: #"))
            let stats = DarkPages.lastAnalysis
            #expect((stats["ms"] as? Double ?? 999) < 200, "\(stats)")

            let second = await page(Self.site, at: origin)
            let shown = try await state(second)
            #expect(shown["palette"] as? Bool == true, "\(shown)")
            #expect(shown["darkened"] as? Bool == true)
            let looks = try await js(second, """
                const s = (id) => getComputedStyle(document.getElementById(id));
                return [getComputedStyle(document.documentElement).filter, getComputedStyle(document.body).backgroundColor,
                        s('pic').filter, s('text').color]
                """) as? [String]
            #expect(looks?[0] == "none")
            #expect(looks?[1] == "rgb(18, 18, 18)")
            #expect(looks?[2] == "none")
            #expect(looks?[3] != "rgb(31, 35, 40)")
            // It covered the page: kept as it is from now on.
            let verified = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default")?.verified == true }
            #expect(verified)
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default")?.invert == false)
            #expect(try await state(second)["palette"] as? Bool == true)
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// Pure black has a palette of its own, with black surfaces.
    @Test func pureBlackHasItsOwnPalette() async throws {
        try await withDefaults {
            let origin = "https://black-\(UUID().uuidString.prefix(8).lowercased()).test"
            let first = await page(Self.site, at: origin, black: true)
            let made = await until { DarkPalettes.entry(origin: origin, black: true, scope: "default") != nil }
            let seen = try await state(first)
            #expect(made, "\(seen) \(DarkPages.lastAnalysis)")
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default") == nil)
            let second = await page(Self.site, at: origin, black: true)
            let bg = try await js(second, "return getComputedStyle(document.body).backgroundColor") as? String
            #expect(bg == "rgb(0, 0, 0)")
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// A page whose light comes from somewhere the sheets don't say (here, inline styles) isn't covered by its
    /// palette: it's tried on the page as soon as it's made, so the first visit stays with the filter, and so does the
    /// site, until its style changes. The next visit never starts with a palette that would leave it white.
    @Test func aPaletteThatLeavesThePageLightGivesWayToTheFilter() async throws {
        try await withDefaults {
            let origin = "https://inline-\(UUID().uuidString.prefix(8).lowercased()).test"
            let html = """
            <html><head><style>body { background: #fff; color: #222; margin: 0 } p { color: #333 }</style></head><body>
            <div style="background:#fff;color:#111;position:fixed;inset:0"><p>All of it painted white inline.</p></div></body></html>
            """
            let first = await page(html, at: origin)
            let marked = await until { DarkPalettes.entry(origin: origin, black: false, scope: "default")?.invert == true }
            let seen = try await state(first)
            #expect(marked, "\(seen) \(DarkPages.lastAnalysis)")
            #expect(seen["palette"] as? Bool == false)
            let filter = try await js(first, "return getComputedStyle(document.documentElement).filter") as? String
            #expect(filter?.contains("invert") == true)
            let second = await page(html, at: origin)
            let shown = try await state(second)
            #expect(shown["palette"] as? Bool == false)
            #expect(shown["refused"] as? Bool == false)
            #expect(try await js(second, "return getComputedStyle(document.documentElement).filter") as? String == filter)
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// A big site's style (8,000 rules, 48,000 colors) is read in idle slices inside the time it's allowed, and isn't
    /// written into a sheet that big.
    @Test func aBigSitesStyleIsReadQuickly() async throws {
        try await withDefaults {
            let origin = "https://big-\(UUID().uuidString.prefix(8).lowercased()).test"
            let rules = (0..<8000).map { i in
                ".c\(i) { color: #\(String(format: "%06x", (i * 2654435) & 0xffffff)); background-color: rgb(\(240 + i % 16), 245, 250); border: 1px solid #d0d7de; }"
            }.joined(separator: "\n")
            let html = "<html><head><style>:root { --bg: #fff; --fg: #222 } body { background: var(--bg); color: var(--fg) }\n\(rules)</style></head><body><p>Big</p></body></html>"
            let webView = await page(html, at: origin)
            let made = await until(30) { DarkPalettes.entry(origin: origin, black: false, scope: "default") != nil }
            let seen = try await state(webView)
            #expect(made, "\(seen)")
            let stats = DarkPages.lastAnalysis
            print("dark palette analysis, 8000 rules: \(stats)")
            #expect(stats["finished"] as? Bool == true, "\(stats)")
            #expect(stats["declarations"] as? Int == 48003, "\(stats)")
            #expect((stats["ms"] as? Double ?? 999) < 400, "\(stats)")
            #expect((stats["rules"] as? Int ?? 0) > 8000)
            // Overrides for 48,000 colors would come to megabytes: too much to put in each page, so the site keeps the filter.
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default")?.invert == true)
            DarkPalettes.forget(scope: "default", site: DarkPalettes.site(ofOrigin: origin))
        }
    }

    /// A private window reads nothing and keeps nothing.
    @Test func aPrivateWindowMakesNoPalette() async throws {
        try await withDefaults {
            let origin = "https://private-\(UUID().uuidString.prefix(8).lowercased()).test"
            let store = WKWebsiteDataStore.nonPersistent()
            let webView = await page(Self.site, at: origin, store: store)
            try await Task.sleep(for: .milliseconds(800))
            #expect(try await state(webView)["analysis"] is NSNull)
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default") == nil)
        }
    }

    /// A dark site is left alone and gets no palette.
    @Test func aDarkSiteGetsNoPalette() async throws {
        try await withDefaults {
            let origin = "https://dark-\(UUID().uuidString.prefix(8).lowercased()).test"
            let webView = await page("<html><body style='background:#111;color:#eee'><p>Dark already</p></body></html>", at: origin)
            try await Task.sleep(for: .milliseconds(800))
            #expect(try await state(webView)["darkened"] as? Bool == false)
            #expect(DarkPalettes.entry(origin: origin, black: false, scope: "default") == nil)
        }
    }
}

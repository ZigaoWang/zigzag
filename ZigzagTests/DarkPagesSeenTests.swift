import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A site dark on its own never shows white first (#134): what's learned of it (that it's dark, its own dark, the mark
/// its dark look sets) is kept for each profile across restarts and cleared with its data, and its pages start on it;
/// a page that turns dark on its own is let go of by Dark Reader.
@MainActor
@Suite(.serialized)
struct DarkPagesSeenTests {
    private func withDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = "DarkPagesSeenTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removeScratchSuite(name)
            DarkPages.defaults = saved
            DarkPages.refreshAll()
        }
        return try await body()
    }

    private static let navy = NSColor(srgbRed: 13 / 255, green: 17 / 255, blue: 23 / 255, alpha: 1)

    private func site() -> String { "seen-\(UUID().uuidString.prefix(8).lowercased()).test" }

    // MARK: Kept

    /// Seen dark, a site is kept with its own dark and its mark, read back after a restart, and only for its profile.
    @Test func aSiteSeenDarkIsKeptAcrossRestarts() {
        let scope = UUID().uuidString, other = UUID().uuidString, name = site()
        #expect(DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name, marker: "class:dark"), in: scope))
        DarkSeen.settle()
        DarkSeen.reload()
        let kept = DarkSeen.site(name, in: scope)
        #expect(kept?.color == "#0d1117")
        #expect(kept?.marker == "class:dark")
        #expect(DarkPages.nativeSites(in: scope).contains(name))
        #expect(DarkSeen.site(name, in: other) == nil)
        // Heard again without a mark: kept as it was; with "" the mark is let go.
        #expect(!DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), in: scope))
        #expect(DarkSeen.site(name, in: scope)?.marker == "class:dark")
        DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name, marker: ""), in: scope)
        #expect(DarkSeen.site(name, in: scope)?.marker == nil)
        // A light color isn't a dark to start on; a page forced dark isn't the site's own look.
        DarkPages.learn(DarkPages.State(darkened: true, native: true, color: .white, site: name, marker: "class:dark"), in: scope)
        #expect(DarkSeen.site(name, in: scope)?.color == "#0d1117")
        #expect(DarkSeen.site(name, in: scope)?.marker == nil)
        // Seen light, it goes, from disk too.
        #expect(DarkPages.learn(DarkPages.State(darkened: true, native: false, color: nil, site: name), in: scope))
        DarkSeen.settle()
        DarkSeen.reload()
        #expect(DarkSeen.site(name, in: scope) == nil)
    }

    /// A private window learns nothing and is given nothing, now that it's written down.
    @Test func aPrivateWindowKeepsNothing() {
        let name = site()
        #expect(!DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name, marker: "class:dark"), in: nil))
        #expect(DarkSeen.sites(in: nil).isEmpty)
        #expect(DarkPages.seen(for: .nonPersistent(), url: URL(string: "https://\(name)/")) == nil)
        #expect(DarkPages.config(for: .nonPersistent(), url: URL(string: "https://\(name)/"))["marker"] is NSNull)
    }

    /// Cleared with the site's data, with History since a time, and with all of it.
    @Test func whatsKeptIsClearedWithTheSite() {
        let scope = UUID().uuidString
        let a = "a-" + site(), b = "b-" + site()
        for name in [a, "www." + b, "docs." + b] {
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), in: scope)
        }
        DarkSeen.forget(scope: scope, site: b)
        #expect(Set(DarkSeen.sites(in: scope).keys) == [a])
        DarkSeen.forget(scope: scope, since: Date().addingTimeInterval(3600))
        #expect(Set(DarkSeen.sites(in: scope).keys) == [a])
        DarkSeen.forget(scope: scope, since: Date().addingTimeInterval(-60))
        #expect(DarkSeen.sites(in: scope).isEmpty)
        DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: a), in: scope)
        DarkSeen.forget(scope: scope)
        DarkSeen.settle()
        DarkSeen.reload()
        #expect(DarkSeen.sites(in: scope).isEmpty)
    }

    // MARK: Where dark pages leave a site alone (#250)

    private static let aqua = NSAppearance.Name.aqua.rawValue, darkAqua = NSAppearance.Name.darkAqua.rawValue

    /// A natively dark site is remembered per appearance once inspected; seen light, that appearance is dropped.
    @Test func aSitesOwnDarkIsKeptForTheLookItWasSeenIn() {
        let scope = UUID().uuidString, name = site()
        // Still loading, or in a private window: nothing kept.
        DarkPages.learnLook(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name, looked: false), look: .aqua, in: scope)
        DarkPages.learnLook(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), look: .aqua, in: nil)
        #expect(DarkSeen.site(name, in: scope) == nil)
        DarkPages.learnLook(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), look: .aqua, in: scope)
        DarkSeen.settle()
        DarkSeen.reload()
        #expect(DarkSeen.site(name, in: scope)?.looks == [Self.aqua: "#0d1117"])
        // Not natively dark: inspected like any site.
        #expect(!DarkPages.nativeSites(in: scope).contains(name))
        #expect(DarkSeen.site(name, in: scope)?.color == nil)
        // A light color isn't a dark ground.
        DarkPages.learnLook(DarkPages.State(darkened: false, native: true, color: .white, site: name), look: .darkAqua, in: scope)
        #expect(DarkSeen.site(name, in: scope)?.looks == [Self.aqua: "#0d1117"])
        DarkPages.learnLook(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), look: .darkAqua, in: scope)
        #expect(DarkSeen.site(name, in: scope)?.looks == [Self.aqua: "#0d1117", Self.darkAqua: "#0d1117"])
        // Light in one appearance drops it; in the last, the site.
        DarkPages.learnLook(DarkPages.State(darkened: false, native: false, color: .white, site: name), look: .aqua, in: scope)
        #expect(DarkSeen.site(name, in: scope)?.looks == [Self.darkAqua: "#0d1117"])
        DarkPages.learnLook(DarkPages.State(darkened: false, native: false, color: .white, site: name), look: .darkAqua, in: scope)
        DarkSeen.settle()
        DarkSeen.reload()
        #expect(DarkSeen.site(name, in: scope) == nil)
    }

    /// Appearances and native-dark membership are tracked separately.
    @Test func aSitesLooksAndItsSeenDarkAreKeptApart() {
        let scope = UUID().uuidString, name = site()
        DarkPages.learnLook(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), look: .aqua, in: scope)
        #expect(DarkSeen.site(name, in: scope)?.isNative == false)
        // Natively dark: added, appearance kept.
        #expect(DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), in: scope))
        #expect(DarkPages.nativeSites(in: scope).contains(name))
        #expect(DarkSeen.site(name, in: scope)?.looks == [Self.aqua: "#0d1117"])
        // Light: removed, appearance kept.
        #expect(DarkPages.learn(DarkPages.State(darkened: true, native: false, color: nil, site: name), in: scope))
        #expect(!DarkPages.nativeSites(in: scope).contains(name))
        #expect(DarkSeen.site(name, in: scope)?.looks == [Self.aqua: "#0d1117"])
        #expect(DarkSeen.site(name, in: scope)?.color == nil)
        #expect(!DarkPages.learn(DarkPages.State(darkened: true, native: false, color: nil, site: name), in: scope))
        DarkSeen.forget(scope: scope, site: name)
        #expect(DarkSeen.site(name, in: scope) == nil)
    }

    /// Loading ground for an untouched page: the site's dark until inspected, then the page's, or WebKit's if light.
    @Test func whatAPageLeftAloneLoadsOn() {
        let name = "example.com"
        let dark = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        #expect(DarkPages.loadingGround(nil, site: name, seen: nil) == nil)
        #expect(DarkPages.loadingGround(DarkPages.State(darkened: false, native: true, color: dark, site: name), site: name, seen: nil) == nil)
        // Not inspected yet, or another site's state: the site's dark.
        #expect(DarkPages.loadingGround(nil, site: name, seen: Self.navy) == Self.navy)
        #expect(DarkPages.loadingGround(DarkPages.State(darkened: false, native: false, color: .white, site: name, looked: false), site: name, seen: Self.navy) == Self.navy)
        #expect(DarkPages.loadingGround(DarkPages.State(darkened: false, native: false, color: .white, site: "other.com"), site: name, seen: Self.navy) == Self.navy)
        // Inspected: its own dark, or WebKit's.
        #expect(DarkPages.loadingGround(DarkPages.State(darkened: false, native: true, color: dark, site: name), site: name, seen: Self.navy) == dark)
        #expect(DarkPages.loadingGround(DarkPages.State(darkened: false, native: false, color: .white, site: name), site: name, seen: Self.navy) == nil)
        #expect(DarkPages.loadingGround(DarkPages.State(darkened: false, native: true, color: .white, site: name), site: name, seen: Self.navy) == nil)
    }

    /// A dark site turned off loads on its dark next time; light in the requested appearance is never kept.
    @Test func aDarkSiteTurnedOffLoadsOnItsOwnDark() async throws {
        try await withDefaults { () async throws in
            let name = site(), light = site()
            defer { DarkSeen.forget(scope: "default", site: name); DarkSeen.forget(scope: "default", site: light) }
            for each in [name, light] { DarkPages.setSiteChoice(.off, for: URL(string: "https://\(each)/")) }
            let html = "<html><head><style>body { background: #0d1117; color: #eee }</style></head><body><p>Dark.</p></body></html>"
            let first = await page(html, at: "https://" + name)
            #expect(first.appearance?.name == .aqua)
            let learned = await until { DarkSeen.site(name, in: "default")?.looks?[Self.aqua] == "#0d1117" }
            #expect(learned)
            #expect(!DarkPages.nativeSites(in: "default").contains(name))
            let second = await page(html, at: "https://" + name)
            #expect(second.underPageBackgroundColor.map(DarkPages.hex) == "#0d1117")
            #expect(second.value(forKey: "drawsBackground") as? Bool == false)

            let follows = """
            <html><head><style>body { background: #fff; color: #111 } @media (prefers-color-scheme: dark) { body { background: #0d1117; color: #eee } }</style>
            </head><body><p>Either.</p></body></html>
            """
            let other = await page(follows, at: "https://" + light)
            try? await Task.sleep(for: .milliseconds(500))
            #expect(DarkSeen.site(light, in: "default") == nil)
            #expect(other.value(forKey: "drawsBackground") as? Bool == true)
            #expect(other.underPageBackgroundColor.map(DarkPages.hex) != "#0d1117")
        }
    }

    /// A light site with a dark top bar (star-history.com) isn't kept as dark; a stale dark entry is dropped once inspected.
    @Test func aLightSiteWithADarkBarIsNotKeptDark() async throws {
        try await withDefaults { () async throws in
            let name = site(), kept = site()
            defer { DarkSeen.forget(scope: "default", site: name); DarkSeen.forget(scope: "default", site: kept) }
            for each in [name, kept] { DarkPages.setSiteChoice(.off, for: URL(string: "https://\(each)/")) }
            let html = """
            <html><head><style>body { margin: 0; color: #333 } header { height: 56px; background: #2b2b2b; color: #eee }
            main { min-height: 900px }</style></head><body><header>Nav</header><main><p>Light.</p></main></body></html>
            """
            let first = await page(html, at: "https://" + name)
            let looked = await until { (try? await first.callAsyncJavaScript("return window.__zigzagDark.state().native", arguments: [:], in: nil,
                                                                              contentWorld: DarkPages.world)) as? Bool == false }
            #expect(looked)
            try? await Task.sleep(for: .milliseconds(2500))
            #expect(DarkSeen.site(name, in: "default") == nil)
            #expect(first.value(forKey: "drawsBackground") as? Bool == true)

            DarkSeen.set(kept, DarkSeen.Site(color: nil, marker: nil, looks: [Self.aqua: "#181a1b"], onlyLooks: true, date: Date()), in: "default")
            let second = await page(html, at: "https://" + kept)
            let forgotten = await until { DarkSeen.site(kept, in: "default") == nil }
            #expect(forgotten)
            let light = await until { second.value(forKey: "drawsBackground") as? Bool == true }
            #expect(light)
        }
    }

    // MARK: What a page starts with

    @Test func thePrepaintIsTheSitesOwnDark() {
        #expect(DarkPages.prepaintCSS(black: false, color: "#0d1117").contains("background-color: #0d1117 !important"))
        // Only a dark, and only a color: anything else is the usual ground.
        #expect(DarkPages.prepaintCSS(black: false, color: "#f6f8fa").contains("#181a1b"))
        #expect(DarkPages.prepaintCSS(black: true, color: "red; } * { color: red").contains("#000000"))
        #expect(!DarkPages.prepaintCSS(black: true, color: "red; } * { color: red").contains("color: red"))
    }

    /// Only the marks a dark look is known by, set to dark: never anything else a page might say.
    @Test func onlyKnownMarksAreKept() {
        #expect(DarkPages.marker("class:dark") == "class:dark")
        #expect(DarkPages.marker("attr:data-theme=dark") == "attr:data-theme=dark")
        #expect(DarkPages.marker("attr:data-bs-theme=dark") == "attr:data-bs-theme=dark")
        #expect(DarkPages.marker("") == "")
        #expect(DarkPages.marker("class:evil") == nil)
        #expect(DarkPages.marker("attr:onload=dark") == nil)
        #expect(DarkPages.marker("attr:data-theme=light") == nil)
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// `in window`: drawn, off screen, so the page gets its frames (a web view in no window gets none).
    private func page(_ html: String, at origin: String, in window: NSWindow? = nil) async -> WKWebView {
        DarkPages.mode = .always
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        if let window {
            // Off screen it counts as hidden, and gets no frames, unless WebKit is told not to look.
            let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if webView.responds(to: occlusion) {
                typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(webView.method(for: occlusion), to: SetBool.self)(webView, occlusion, false)
            }
            window.contentView = webView
            window.orderFrontRegardless()
        }
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

    private func js(_ webView: WKWebView, _ source: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    private static let early = """
    <script>window.early = { ground: getComputedStyle(document.documentElement).backgroundColor,
      dark: document.documentElement.classList.contains('dark') };</script>
    """

    /// A site seen dark starts on its own dark, not a gray of Zigzag's.
    @Test func aSiteSeenDarkStartsOnItsOwnDark() async throws {
        try await withDefaults { () async throws in
            let name = site()
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), in: "default")
            defer { DarkSeen.forget(scope: "default", site: name) }
            let html = "<html><head>\(Self.early)<style>body { background: #0d1117; color: #eee }</style></head><body><p>Dark.</p></body></html>"
            let webView = await page(html, at: "https://" + name)
            #expect(try await js(webView, "return window.early.ground") as? String == "rgb(13, 17, 23)")
        }
    }

    /// A darkened page that turns dark on its own (an app drawn after a light loading screen) is let go of: Dark
    /// Reader's theme comes off and the page keeps its own dark.
    @Test func aPageTurningDarkIsLetGoOf() async throws {
        try await withDefaults { () async throws in
            let name = site()
            defer { DarkSeen.forget(scope: "default", site: name) }
            let html = """
            <html><head><style>body { background: #fff; color: #111; min-height: 500px } body.dark { background: #0d1117; color: #eee }</style></head>
            <body><p>Loading.</p><script>addEventListener('load', () => setTimeout(() => {
              window.before = document.documentElement.getAttribute('data-darkreader-mode');
              document.body.classList.add('dark');
            }, 300));</script></body></html>
            """
            let webView = await page(html, at: "https://" + name)
            let turned = await until { (try? await js(webView, "return window.before !== undefined") as? Bool) == true }
            #expect(turned)
            #expect(try await js(webView, "return window.before") as? String == "dynamic")
            let letGo = await until { (try? await js(webView, "return !document.documentElement.hasAttribute('data-darkreader-mode')") as? Bool) == true }
            #expect(letGo)
            #expect(try await js(webView, "return getComputedStyle(document.body).backgroundColor") as? String == "rgb(13, 17, 23)")
        }
    }

    /// A site whose dark look is a class its script puts on the root: seen doing so, the next page of the site starts
    /// with it, so its dark style applies before that script runs.
    @Test func aSitesOwnDarkMarkIsLearnedAndStartedWith() async throws {
        try await withDefaults { () async throws in
            let name = site()
            defer { DarkSeen.forget(scope: "default", site: name) }
            let html = """
            <html><head>\(Self.early)<style>body { background: #fff; color: #111 } .dark body { background: #0d1117; color: #eee }</style></head>
            <body><p>Marked.</p><script>document.documentElement.classList.add('dark');</script></body></html>
            """
            let first = await page(html, at: "https://" + name)
            #expect(try await js(first, "return window.early.dark") as? Bool == false)
            let learned = await until { DarkSeen.site(name, in: "default")?.marker == "class:dark" }
            #expect(learned)
            let second = await page(html, at: "https://" + name)
            #expect(try await js(second, "return window.early.dark") as? Bool == true)
            // The site set it again itself, so it stays the site's and stays known.
            try? await Task.sleep(for: .milliseconds(2500))
            #expect(try await js(second, "return document.documentElement.classList.contains('dark')") as? Bool == true)
            #expect(DarkSeen.site(name, in: "default")?.marker == "class:dark")
        }
    }

    /// A mark the site's script doesn't set any more is taken off once the page has loaded, and forgotten.
    @Test func aMarkTheSiteNoLongerSetsIsTakenOffAndForgotten() async throws {
        try await withDefaults { () async throws in
            let name = site()
            defer { DarkSeen.forget(scope: "default", site: name) }
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name, marker: "class:dark"), in: "default")
            let html = """
            <html><head>\(Self.early)<style>body { background: #0d1117; color: #eee }</style></head><body><p>Dark without it.</p></body></html>
            """
            let webView = await page(html, at: "https://" + name)
            #expect(try await js(webView, "return window.early.dark") as? Bool == true)
            let off = await until(6) { (try? await js(webView, "return !document.documentElement.classList.contains('dark')") as? Bool) == true }
            #expect(off)
            let forgotten = await until { DarkSeen.site(name, in: "default")?.marker == nil }
            #expect(forgotten)
            #expect(DarkSeen.site(name, in: "default") != nil)
        }
    }

    /// A mark is never put where the root has one of its own already, light or dark.
    @Test func aMarkIsNeverPutOverTheSitesOwn() async throws {
        try await withDefaults { () async throws in
            let name = site()
            defer { DarkSeen.forget(scope: "default", site: name) }
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name, marker: "attr:data-theme=dark"), in: "default")
            let html = """
            <html data-theme="light"><head><script>window.served = document.documentElement.getAttribute('data-theme');</script>
            <style>body { background: #0d1117; color: #eee }</style></head><body><p>Its own.</p></body></html>
            """
            let webView = await page(html, at: "https://" + name)
            #expect(try await js(webView, "return window.served") as? String == "light")
        }
    }
}

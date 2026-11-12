import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A site dark on its own never shows white first (#134): what's learned of it (that it's dark, its own dark, the mark
/// its dark look sets) is kept for each profile across restarts and cleared with its data, and its pages start on it;
/// a dark page seen for the first time loses the filter before its first frame with style is drawn.
@MainActor
@Suite(.serialized)
struct DarkPagesSeenTests {
    private func withDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = "DarkPagesSeenTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        let delay = DarkPages.paletteDelay
        DarkPages.defaults = UserDefaults(suiteName: name)!
        DarkPages.paletteDelay = 60_000
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
            DarkPages.paletteDelay = delay
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
        DarkPalettes.settle()
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
        DarkPalettes.settle()
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

    /// Cleared with the site's data, with History since a time, and with all of it, as palettes are.
    @Test func whatsKeptIsClearedWithTheSite() {
        let scope = UUID().uuidString
        let a = "a-" + site(), b = "b-" + site()
        for name in [a, "www." + b, "docs." + b] {
            DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: name), in: scope)
        }
        DarkPalettes.forget(scope: scope, site: b)
        #expect(Set(DarkSeen.sites(in: scope).keys) == [a])
        DarkPalettes.forget(scope: scope, since: Date().addingTimeInterval(3600))
        #expect(Set(DarkSeen.sites(in: scope).keys) == [a])
        DarkPalettes.forget(scope: scope, since: Date().addingTimeInterval(-60))
        #expect(DarkSeen.sites(in: scope).isEmpty)
        DarkPages.learn(DarkPages.State(darkened: false, native: true, color: Self.navy, site: a), in: scope)
        DarkPalettes.forget(scope: scope)
        DarkPalettes.settle()
        DarkSeen.reload()
        #expect(DarkSeen.sites(in: scope).isEmpty)
    }

    // MARK: What a page starts with

    @Test func thePrepaintIsTheSitesOwnDark() {
        #expect(DarkPages.prepaintCSS(black: false, color: "#0d1117").contains("background-color: #0d1117 !important"))
        // Only a dark, and only a color: anything else is the usual ground.
        #expect(DarkPages.prepaintCSS(black: false, color: "#f6f8fa").contains("#121212"))
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
            defer { DarkPalettes.forget(scope: "default", site: name) }
            let html = "<html><head>\(Self.early)<style>body { background: #0d1117; color: #eee }</style></head><body><p>Dark.</p></body></html>"
            let webView = await page(html, at: "https://" + name)
            #expect(try await js(webView, "return window.early.ground") as? String == "rgb(13, 17, 23)")
        }
    }

    /// A darkened page that turns dark on its own (an app drawn after a light loading screen) is let go of in the
    /// frame it does, before that frame is drawn, rather than after a timer with its dark shown through the filter as
    /// white: the page's own frame callback, which runs after Zigzag's, already sees no filter.
    @Test func aPageTurningDarkLosesTheFilterInThatFrame() async throws {
        try await withDefaults { () async throws in
            let name = site()
            defer { DarkPalettes.forget(scope: "default", site: name) }
            let html = """
            <html><head><style>body { background: #fff; color: #111; min-height: 500px } body.dark { background: #0d1117; color: #eee }</style></head>
            <body><p>Loading.</p><script>addEventListener('load', () => setTimeout(() => {
              window.before = getComputedStyle(document.documentElement).filter;
              document.body.classList.add('dark');
              requestAnimationFrame(() => { window.first = getComputedStyle(document.documentElement).filter; });
            }, 300));</script></body></html>
            """
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let webView = await page(html, at: "https://" + name, in: window)
            let seen = await until { (try? await js(webView, "return window.first !== undefined") as? Bool) == true }
            #expect(seen)
            #expect((try await js(webView, "return window.before") as? String)?.contains("invert") == true)
            #expect(try await js(webView, "return window.first") as? String == "none")
        }
    }

    /// A site whose dark look is a class its script puts on the root: seen doing so, the next page of the site starts
    /// with it, so its dark style applies before that script runs.
    @Test func aSitesOwnDarkMarkIsLearnedAndStartedWith() async throws {
        try await withDefaults { () async throws in
            let name = site()
            defer { DarkPalettes.forget(scope: "default", site: name) }
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
            defer { DarkPalettes.forget(scope: "default", site: name) }
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
            defer { DarkPalettes.forget(scope: "default", site: name) }
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

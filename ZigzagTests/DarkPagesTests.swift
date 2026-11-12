import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Dark pages: when a page is drawn dark (the setting, the Mac's appearance and the site's own choice), and that only
/// a page still light after being told dark is preferred gets Zigzag's dark style.
@MainActor
@Suite(.serialized)
struct DarkPagesTests {
    // MARK: Deciding

    @Test func settingAndMacDecideWithoutASiteChoice() {
        #expect(!DarkPages.wants(mode: .off, systemIsDark: false, site: nil))
        #expect(!DarkPages.wants(mode: .off, systemIsDark: true, site: nil))
        #expect(!DarkPages.wants(mode: .system, systemIsDark: false, site: nil))
        #expect(DarkPages.wants(mode: .system, systemIsDark: true, site: nil))
        #expect(DarkPages.wants(mode: .always, systemIsDark: false, site: nil))
        #expect(DarkPages.wants(mode: .always, systemIsDark: true, site: nil))
    }

    @Test func aSiteChoiceWinsOverTheSetting() {
        for mode in DarkPages.Mode.allCases {
            for dark in [false, true] {
                #expect(DarkPages.wants(mode: mode, systemIsDark: dark, site: true))
                #expect(!DarkPages.wants(mode: mode, systemIsDark: dark, site: false))
            }
        }
    }

    @Test func onlyALightPageIsDarkened() {
        #expect(DarkPages.darkens(wants: true, pageIsDark: false))
        // Not looked at yet: darkened from the start, so it never shows white first.
        #expect(DarkPages.darkens(wants: true, pageIsDark: nil))
        #expect(!DarkPages.darkens(wants: true, pageIsDark: true))
        for page in [nil, false, true] as [Bool?] { #expect(!DarkPages.darkens(wants: false, pageIsDark: page)) }
    }

    @Test func everyCombination() {
        // setting × Mac × site choice × page already dark
        for mode in DarkPages.Mode.allCases {
            for macDark in [false, true] {
                for site in [nil, false, true] as [Bool?] {
                    for pageDark in [false, true] {
                        let wanted = site ?? (mode == .always || mode == .system && macDark)
                        let darkened = DarkPages.darkens(wants: DarkPages.wants(mode: mode, systemIsDark: macDark, site: site), pageIsDark: pageDark)
                        #expect(darkened == (wanted && !pageDark), "\(mode) mac dark \(macDark) site \(String(describing: site)) page dark \(pageDark)")
                    }
                }
            }
        }
    }

    // MARK: A site's choice

    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DarkPagesTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
        }
        try body()
    }

    @Test func aSiteChoiceCoversItsSubdomainsAndCanBeForgotten() {
        withDefaults {
            DarkPages.mode = .off
            DarkPages.setChoice(true, for: URL(string: "https://www.example.com/a"))
            #expect(DarkPages.sitesOn == ["example.com"])
            #expect(DarkPages.choice(for: URL(string: "https://docs.example.com/")) == true)
            #expect(DarkPages.choice(for: URL(string: "https://example.org/")) == nil)
            #expect(DarkPages.wants(URL(string: "https://example.com/")))
            DarkPages.setChoice(nil, for: URL(string: "https://example.com/"))
            #expect(DarkPages.sitesOn.isEmpty)
            #expect(!DarkPages.wants(URL(string: "https://example.com/")))
        }
    }

    @Test func aChoiceTheSameAsTheSettingIsNotKept() {
        withDefaults {
            DarkPages.mode = .always
            DarkPages.setChoice(true, for: URL(string: "https://example.com/"))
            #expect(DarkPages.sitesOn.isEmpty)
            DarkPages.setChoice(false, for: URL(string: "https://example.com/"))
            #expect(DarkPages.sitesOff == ["example.com"])
            #expect(!DarkPages.wants(URL(string: "https://example.com/")))
            // Turned on again, it simply follows Always.
            DarkPages.setChoice(true, for: URL(string: "https://example.com/"))
            #expect(DarkPages.sitesOff.isEmpty && DarkPages.sitesOn.isEmpty)
        }
    }

    @Test func aSubdomainsChoiceTakesThePlaceOfItsSites() {
        withDefaults {
            DarkPages.mode = .system
            DarkPages.setChoice(true, for: URL(string: "https://example.com/"))
            DarkPages.setChoice(false, for: URL(string: "https://docs.example.com/"))
            #expect(DarkPages.sitesOn.isEmpty)
            #expect(DarkPages.sitesOff == ["docs.example.com"])
            #expect(DarkPages.choice(for: URL(string: "https://example.com/")) == nil)
        }
    }

    @Test func readsThePageScriptsColors() {
        let color = DarkPages.color(hex: "#1e1e1e")?.usingColorSpace(.sRGB)
        #expect(color.map { abs($0.redComponent - 30.0 / 255) < 0.001 && abs($0.blueComponent - 30.0 / 255) < 0.001 } == true)
        #expect(DarkPages.color(hex: "ffffff") != nil)
        #expect(DarkPages.color(hex: "#fff") == nil)
        #expect(DarkPages.color(hex: "rgb(0, 0, 0)") == nil)
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// The page script's own view of a page, once it has loaded and been looked at.
    private func state(of html: String) async throws -> [String: Any] {
        let name = "DarkPagesTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
            DarkPages.refreshAll()
        }
        DarkPages.mode = .always
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        DarkPages.attach(to: webView)
        #expect(webView.appearance?.name == .darkAqua)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://dark-pages.test/"))
        }
        try await Task.sleep(for: .milliseconds(300))
        let state = try await webView.callAsyncJavaScript("return window.__zigzagDark.state()", arguments: [:], in: nil, contentWorld: DarkPages.world)
        let engine = try await webView.callAsyncJavaScript("return document.documentElement.getAttribute('data-darkreader-mode') || ''", arguments: [:], in: nil, contentWorld: .page)
        let body = try await webView.callAsyncJavaScript("return getComputedStyle(document.body).backgroundColor", arguments: [:], in: nil, contentWorld: .page)
        var result = state as? [String: Any] ?? [:]
        result["engine"] = engine as? String ?? ""
        result["body"] = body as? String ?? ""
        return result
    }

    @Test func aLightPageIsDarkened() async throws {
        let state = try await state(of: "<html><body style='background:#fff;color:#222'><main><p>Light page</p></main></body></html>")
        #expect(state["darkened"] as? Bool == true)
        #expect(state["native"] as? Bool == false)
        // Dark Reader's dynamic theme, its own dark under the page.
        #expect(state["engine"] as? String == "dynamic")
        #expect(state["body"] as? String == "rgb(24, 26, 27)")
    }

    @Test func aDarkPageIsLeftAlone() async throws {
        let state = try await state(of: "<html><body style='background:#111;color:#eee'><main><p>Dark page</p></main></body></html>")
        #expect(state["darkened"] as? Bool == false)
        #expect(state["native"] as? Bool == true)
        #expect(state["engine"] as? String == "")
        #expect(state["body"] as? String == "rgb(17, 17, 17)")
    }

    @Test func aPageWithItsOwnDarkThemeUsesIt() async throws {
        let html = """
        <html><head><meta name="color-scheme" content="light dark">
        <style>body { background: #fff; } @media (prefers-color-scheme: dark) { body { background: #181818; color: #ddd; } }</style>
        </head><body><p>Both themes</p></body></html>
        """
        let state = try await state(of: html)
        #expect(state["darkened"] as? Bool == false)
        #expect(state["native"] as? Bool == true)
    }

    @Test func aPageDeclaringColorSchemeDarkIsLeftAlone() async throws {
        let state = try await state(of: "<html><head><meta name='color-scheme' content='dark'></head><body><p>Dark by declaration</p></body></html>")
        #expect(state["darkened"] as? Bool == false)
        #expect(state["native"] as? Bool == true)
    }

    // MARK: What a page says

    private final class Heard: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    /// What the page script tells Zigzag about a page loaded with dark pages on Always, with these sites turned off.
    private func heard(loading load: (WKWebView) -> Void, sitesOff: [String] = []) async throws -> [[String: Any]] {
        let name = "DarkPagesTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
        }
        DarkPages.mode = .always
        DarkPages.sitesOff = Set(sitesOff)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let heard = Heard()
        configuration.userContentController.add(heard, contentWorld: DarkPages.world, name: DarkPages.messageName)
        configuration.userContentController.addUserScript(DarkPages.script(for: configuration.websiteDataStore))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            load(webView)
        }
        try await Task.sleep(for: .milliseconds(300))
        return heard.messages
    }

    /// A page on a site turned off says it isn't darkened: the tab would otherwise keep the darkened look of the page
    /// before it, and the bar above it that look's color.
    @Test func aPageOnASiteTurnedOffSaysItIsNotDarkened() async throws {
        let messages = try await heard(loading: { $0.loadHTMLString("<html><body><p>Light</p></body></html>", baseURL: URL(string: "https://off.test/")) },
                                       sitesOff: ["off.test"])
        #expect(!messages.isEmpty)
        #expect(messages.allSatisfy { $0["darkened"] as? Bool == false })
    }

    @Test func aPictureOnItsOwnSaysItIsNotDarkened() async throws {
        let png = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let data = try #require(png.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let messages = try await heard(loading: { $0.load(data, mimeType: "image/png", characterEncodingName: "", baseURL: URL(string: "https://picture.test/a.png")!) })
        #expect(messages.contains { $0["darkened"] as? Bool == false })
        #expect(!messages.contains { $0["darkened"] as? Bool == true })
    }

    // MARK: Sites seen dark

    /// Whether a page was darkened from its first moment is something the page can see, so the sites seen dark in
    /// one profile are never given to another's pages, or to a private window's.
    @Test func sitesSeenDarkAreKeptForEachProfile() {
        let one = UUID().uuidString, other = UUID().uuidString
        #expect(DarkPages.nativeScope(of: .nonPersistent()) == nil)
        #expect(DarkPages.nativeScope(of: .default()) == "default")
        let dark = DarkPages.State(darkened: false, native: true, color: nil, site: "seen-dark-\(UUID().uuidString).test")
        #expect(DarkPages.learn(dark, in: one))
        #expect(DarkPages.nativeSites(in: one).contains(dark.site))
        #expect(!DarkPages.nativeSites(in: other).contains(dark.site))
        // A private window learns nothing and is given nothing.
        #expect(!DarkPages.learn(dark, in: nil))
        #expect(DarkPages.nativeSites(in: nil).isEmpty)
        #expect((DarkPages.config(for: .nonPersistent())["native"] as? [String])?.isEmpty == true)
        // Seen light again, it leaves that profile's list.
        #expect(DarkPages.learn(DarkPages.State(darkened: true, native: false, color: nil, site: dark.site), in: one))
        #expect(!DarkPages.nativeSites(in: one).contains(dark.site))
    }

    // MARK: Its script among the others (#89)

    /// The page script is known by its first line; a big script that merely talks about it isn't taken for it.
    @Test func thePageScriptIsKnownByItsFirstLine() {
        #expect(DarkPages.isOurs(DarkPages.script(for: nil)))
        let mentions = WKUserScript(source: "// reads window.__zigzagDark\n" + String(repeating: "x", count: 1000),
                                    injectionTime: .atDocumentStart, forMainFrameOnly: true)
        #expect(!DarkPages.isOurs(mentions))
    }

    /// A new tab next to a megabyte of other scripts gets its page script at once, and only one, however often it's
    /// put in: telling the scripts apart once searched every one of them and held each new tab up.
    @Test func puttingTheScriptInIsQuickAndLeavesOne() {
        withDefaults {
            DarkPages.mode = .always
            let configuration = WKWebViewConfiguration()
            let big = WKUserScript(source: "/* other */" + String(repeating: "let a = 1; // window.__zigzag\n", count: 40_000),
                                   injectionTime: .atDocumentStart, forMainFrameOnly: false)
            for _ in 0..<4 { configuration.userContentController.addUserScript(big) }
            let webView = WKWebView(frame: .zero, configuration: configuration)
            DarkPages.attach(to: webView)
            let started = Date()
            for _ in 0..<5 { DarkPages.attach(to: webView) }
            let each = Date().timeIntervalSince(started) / 5
            let scripts = configuration.userContentController.userScripts
            // The page script and Dark Reader's proxy, once each.
            #expect(scripts.filter(DarkPages.isOurs).count == 2)
            #expect(scripts.count == 6)
            #expect(each < 0.05, "attaching took \(Int(each * 1000)) ms")
            // Where dark pages aren't wanted, Dark Reader isn't put in at all.
            DarkPages.mode = .off
            DarkPages.attach(to: webView)
            #expect(configuration.userContentController.userScripts.filter(DarkPages.isOurs).isEmpty)
            DarkPages.mode = .always
        }
    }
}

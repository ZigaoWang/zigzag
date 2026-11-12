import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Full screen in the page (#168): where a site's full screen goes (the setting, a site's own choice), and the page
/// script on a real page: the element fills the viewport, the page is told it's in full screen as WebKit would tell
/// it, Esc and exitFullscreen leave, and everything is given back as it was.
@MainActor
@Suite(.serialized)
struct PageFullScreenTests {
    // MARK: Deciding

    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "PageFullScreenTests-\(UUID().uuidString)"
        let saved = PageFullScreen.defaults
        PageFullScreen.defaults = UserDefaults(suiteName: name)!
        defer {
            PageFullScreen.defaults.removePersistentDomain(forName: name)
            PageFullScreen.defaults = saved
        }
        try body()
    }

    @Test func theWholeScreenUntilChanged() {
        withDefaults {
            #expect(PageFullScreen.fill == .screen)
            #expect(PageFullScreen.fills(for: URL(string: "https://www.youtube.com/watch?v=1")) == .screen)
        }
    }

    @Test func aSiteChoiceWinsOverTheSetting() {
        for setting in PageFullScreen.Fill.allCases {
            #expect(PageFullScreen.fills(setting: setting, site: nil) == setting)
            for site in PageFullScreen.Fill.allCases { #expect(PageFullScreen.fills(setting: setting, site: site) == site) }
        }
    }

    @Test func aSiteChoiceCoversItsSubdomainsAndCanBeForgotten() {
        withDefaults {
            PageFullScreen.setChoice(.page, for: URL(string: "https://www.youtube.com/watch?v=1"))
            #expect(PageFullScreen.pageSites == ["youtube.com"])
            #expect(PageFullScreen.defaults.stringArray(forKey: "FullScreenPageSites") == ["youtube.com"])
            #expect(PageFullScreen.choice(for: URL(string: "https://m.youtube.com/")) == .page)
            #expect(PageFullScreen.fills(for: URL(string: "https://youtube.com/")) == .page)
            #expect(PageFullScreen.choice(for: URL(string: "https://notyoutube.com/")) == nil)
            #expect(PageFullScreen.fills(for: URL(string: "https://vimeo.com/")) == .screen)
            PageFullScreen.setChoice(nil, for: URL(string: "https://youtube.com/"))
            #expect(PageFullScreen.pageSites.isEmpty)
            #expect(PageFullScreen.fills(for: URL(string: "https://youtube.com/")) == .screen)
        }
    }

    @Test func aChoiceTheSameAsTheSettingIsntKept() {
        withDefaults {
            PageFullScreen.setChoice(.screen, for: URL(string: "https://example.com/"))
            #expect(PageFullScreen.screenSites.isEmpty)
            PageFullScreen.fill = .page
            PageFullScreen.setChoice(.screen, for: URL(string: "https://example.com/"))
            #expect(PageFullScreen.screenSites == ["example.com"])
            #expect(PageFullScreen.fills(for: URL(string: "https://example.com/")) == .screen)
            #expect(PageFullScreen.fills(for: URL(string: "https://example.org/")) == .page)
            // The other way, the site's choice moves from one list to the other.
            PageFullScreen.fill = .screen
            PageFullScreen.setChoice(.page, for: URL(string: "https://example.com/"))
            #expect(PageFullScreen.screenSites.isEmpty)
            #expect(PageFullScreen.pageSites == ["example.com"])
            PageFullScreen.forgetAll()
            #expect(PageFullScreen.pageSites.isEmpty && PageFullScreen.screenSites.isEmpty)
        }
    }

    @Test func aSubdomainsChoiceReplacesItsParents() {
        withDefaults {
            PageFullScreen.setChoice(.page, for: URL(string: "https://example.com/"))
            PageFullScreen.setChoice(.screen, for: URL(string: "https://video.example.com/"))
            #expect(PageFullScreen.pageSites.isEmpty)
            #expect(PageFullScreen.fills(for: URL(string: "https://video.example.com/")) == .screen)
        }
    }

    @Test func offeredOnWebPagesOutsidePrivateWindows() {
        #expect(PageFullScreen.isOffered(for: URL(string: "https://youtube.com/"), isPrivate: false))
        #expect(!PageFullScreen.isOffered(for: URL(string: "https://youtube.com/"), isPrivate: true))
        #expect(!PageFullScreen.isOffered(for: URL(string: "file:///tmp/a.html"), isPrivate: false))
        #expect(!PageFullScreen.isOffered(for: nil, isPrivate: false))
    }

    // MARK: The script

    @Test func theScriptCarriesTheChoices() throws {
        let config = PageFullScreen.config(fill: .page, pageSites: ["youtube.com", "a.com"], screenSites: ["b.org"])
        let source = PageFullScreen.source(config: config)
        #expect(source.hasPrefix(PageFullScreen.scriptMark))
        #expect(!source.contains("__CONFIG__"))
        #expect(source.contains(#"{"fill":"page","page":["a.com","youtube.com"],"screen":["b.org"]}"#))
        let script = PageFullScreen.script(config: config)
        #expect(PageFullScreen.isOurs(script))
        #expect(!script.isForMainFrameOnly)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(!PageFullScreen.isOurs(WKUserScript(source: "1", injectionTime: .atDocumentStart, forMainFrameOnly: true)))
        #expect(PageFullScreen.applyCall(config).contains(#"Symbol.for('zigzag.fullscreen')"#))
    }

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private final class Heard: NSObject, WKScriptMessageHandler {
        var said: [Bool] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let on = message.body as? Bool { said.append(on) }
        }
    }

    /// A page laid out as a video site's is: the player inside a column that has a transform and a stacking order of
    /// its own (which would hold a fixed child inside it), a bar fixed over the page, and a rule for :fullscreen.
    private static let page = """
    <html><head><style>body{margin:0;height:3000px} header{position:fixed;top:0;left:0;right:0;height:56px;z-index:2020;background:#fff}
    #column{position:relative;z-index:1;transform:translateZ(0);margin:80px 40px;width:640px}
    #player{position:relative;width:640px;height:360px;padding:4px} video{width:100%;height:100%}
    #player:fullscreen .bar{color:rgb(1, 2, 3)} #player:-webkit-full-screen .label{color:rgb(4, 5, 6)}</style></head>
    <body><header>Bar</header><div id="column"><div id="player" style="color: red"><video muted></video>
    <div class="bar">Bar</div><div class="label">Label</div></div></div></body></html>
    """

    private func load(_ html: String, fill: PageFullScreen.Fill, sites: Set<String> = [], heard: Heard? = nil) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(PageFullScreen.script(config: PageFullScreen.config(fill: fill, pageSites: sites, screenSites: [])))
        if let heard { configuration.userContentController.add(heard, contentWorld: .page, name: PageFullScreen.messageName) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://videos.test/watch"))
        }
        return webView
    }

    @discardableResult
    private func page(_ source: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test func theElementFillsThePageAndThePageIsTold() async throws {
        let heard = Heard()
        let webView = await load(Self.page, fill: .page, heard: heard)
        let before = try await page("return document.documentElement.outerHTML", in: webView) as? String
        let entered = try await page("""
        window.events = [];
        for (const name of ['fullscreenchange', 'webkitfullscreenchange']) document.addEventListener(name, () => events.push(name + ':' + (document.fullscreenElement && document.fullscreenElement.id)));
        await document.getElementById('player').requestFullscreen();
        const r = document.getElementById('player').getBoundingClientRect();
        const look = getComputedStyle(document.getElementById('player'));
        return [document.fullscreenElement.id, document.webkitFullscreenElement.id, document.webkitIsFullScreen, document.fullscreen,
                r.left, r.top, r.width, r.height, look.position, look.zIndex, events.join(','),
                getComputedStyle(document.querySelector('.bar')).color, getComputedStyle(document.querySelector('.label')).color,
                getComputedStyle(document.getElementById('column')).transform, getComputedStyle(document.body).overflow,
                document.elementFromPoint(500, 20).closest('#player') !== null]
        """, in: webView) as? [Any]
        let values = try #require(entered)
        #expect(values[0] as? String == "player")
        #expect(values[1] as? String == "player")
        #expect(values[2] as? Bool == true)
        #expect(values[3] as? Bool == true)
        #expect((values[4] as? Double) == 0 && (values[5] as? Double) == 0)
        #expect((values[6] as? Double) == 1000 && (values[7] as? Double) == 700)
        #expect(values[8] as? String == "fixed")
        #expect(values[9] as? String == "2147483647")
        #expect(values[10] as? String == "fullscreenchange:player,webkitfullscreenchange:player")
        // The page's own :fullscreen rules, its webkit name too, are matched.
        #expect(values[11] as? String == "rgb(1, 2, 3)")
        #expect(values[12] as? String == "rgb(4, 5, 6)")
        // What held it inside the column is let go of, and it's over the bar fixed above the page.
        #expect(values[13] as? String == "none")
        #expect(values[14] as? String == "hidden")
        #expect(values[15] as? Bool == true)
        #expect(heard.said.last == true)

        let left = try await page("""
        await document.exitFullscreen();
        return [document.fullscreenElement, document.webkitIsFullScreen, events.length, document.documentElement.outerHTML]
        """, in: webView) as? [Any]
        let after = try #require(left)
        #expect(after[0] is NSNull)
        #expect(after[1] as? Bool == false)
        #expect(after[2] as? Int == 4)
        // The page is given back exactly as it was, the player's own style included.
        #expect((after[3] as? String)?.replacingOccurrences(of: #" style="color: red;""#, with: #" style="color: red""#) == before)
        #expect(heard.said.last == false)
    }

    @Test func escLeavesAndSoDoesZigzag() async throws {
        let webView = await load(Self.page, fill: .page)
        let viaEsc = try await page("""
        await document.getElementById('player').webkitRequestFullScreen();
        let heard = false;
        document.addEventListener('keydown', () => { heard = true; });
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        await new Promise(r => setTimeout(r, 10));
        return [document.webkitFullscreenElement, heard]
        """, in: webView) as? [Any]
        #expect(viaEsc?[0] is NSNull)
        // Esc is the full screen's, as WebKit's is: the page doesn't hear it.
        #expect(viaEsc?[1] as? Bool == false)
        try await page("await document.getElementById('player').requestFullscreen()", in: webView)
        let left = try await webView.evaluateJavaScript(PageFullScreen.exitCall, in: nil, contentWorld: .page) as? Bool
        #expect(left == true)
        #expect(try await page("return document.fullscreenElement", in: webView) is NSNull)
    }

    @Test func aVideosOwnFullScreenFillsThePageToo() async throws {
        let webView = await load(Self.page, fill: .page)
        let result = try await page("""
        const v = document.querySelector('video');
        const events = [];
        v.addEventListener('webkitbeginfullscreen', () => events.push('begin'));
        v.addEventListener('webkitendfullscreen', () => events.push('end'));
        v.webkitEnterFullscreen();
        const inside = [v.webkitDisplayingFullscreen, document.fullscreenElement === v, getComputedStyle(v).position, getComputedStyle(v).objectFit];
        v.webkitExitFullscreen();
        return inside.concat([v.webkitDisplayingFullscreen, events.join(',')])
        """, in: webView) as? [Any]
        let values = try #require(result)
        #expect(values[0] as? Bool == true)
        #expect(values[1] as? Bool == true)
        #expect(values[2] as? String == "fixed")
        #expect(values[3] as? String == "contain")
        #expect(values[4] as? Bool == false)
        #expect(values[5] as? String == "begin,end")
    }

    @Test func theWholeScreenLeavesItToWebKit() async throws {
        let webView = await load(Self.page, fill: .screen)
        let result = try await page("""
        try { await document.getElementById('player').requestFullscreen(); } catch (e) {}
        await new Promise(r => setTimeout(r, 10));
        return document.getElementById('player').hasAttribute('data-zigzag-fullscreen')
        """, in: webView) as? Bool
        #expect(result == false)
    }

    @Test func aSitesChoiceAndAChangeReachThePage() async throws {
        // The page is videos.test: its own choice fills the page though the setting is the whole screen.
        let webView = await load(Self.page, fill: .screen, sites: ["videos.test"])
        try await page("await document.getElementById('player').requestFullscreen()", in: webView)
        #expect(try await page("return document.fullscreenElement && document.fullscreenElement.id", in: webView) as? String == "player")
        // The choice taken back: the page leaves, and the next request is WebKit's again.
        _ = try await webView.evaluateJavaScript(PageFullScreen.applyCall(PageFullScreen.config(fill: .screen, pageSites: [], screenSites: [])), in: nil, contentWorld: .page)
        #expect(try await page("return document.getElementById('player').hasAttribute('data-zigzag-fullscreen')", in: webView) as? Bool == false)
    }

    @Test func aFrameFillsThePageWithItself() async throws {
        let inner = "<html><body style='margin:0'><div id='p' style='width:200px;height:100px'>video</div></body></html>"
        let html = """
        <html><body style="margin:0"><div style="transform:translateZ(0);margin:50px"><iframe id="f" allowfullscreen style="width:300px;height:150px"
        srcdoc="\(inner.replacingOccurrences(of: "'", with: "&#39;"))"></iframe></div></body></html>
        """
        let webView = await load(html, fill: .page)
        let result = try await page("""
        const f = document.getElementById('f');
        await new Promise(r => { if (f.contentDocument && f.contentDocument.readyState === 'complete') r(); else f.onload = r; });
        await f.contentDocument.getElementById('p').requestFullscreen.call(f.contentDocument.getElementById('p'));
        await new Promise(r => setTimeout(r, 50));
        const r = f.getBoundingClientRect();
        const inside = f.contentDocument.getElementById('p').getBoundingClientRect();
        const was = [document.fullscreenElement === f, r.width, r.height, inside.width, inside.height];
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        await new Promise(r => setTimeout(r, 50));
        return was.concat([document.fullscreenElement, f.contentDocument.fullscreenElement])
        """, in: webView) as? [Any]
        let values = try #require(result)
        #expect(values[0] as? Bool == true)
        #expect((values[1] as? Double) == 1000 && (values[2] as? Double) == 700)
        #expect((values[3] as? Double) == 1000 && (values[4] as? Double) == 700)
        #expect(values[5] is NSNull)
        #expect(values[6] is NSNull)
    }
}

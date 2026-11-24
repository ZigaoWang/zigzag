import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Full screen in the page (#168, #462): where a site's full screen goes is the browser's choice (the setting, a
/// site's own choice), and the page script on a real page: the element fills the viewport, the page is told it's in
/// full screen as WebKit would tell it, Esc and exitFullscreen leave, and everything is given back as it was. The
/// expand button is the one explicit hand-off to WebKit's own full screen.
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

    @Test func aChoiceChangeTellsTheWindow() {
        withDefaults {
            final class Counter { var value = 0 }
            let heard = Counter()
            let token = PageFullScreen.changed.observe { heard.value += 1 }
            PageFullScreen.fill = .page
            PageFullScreen.setChoice(.page, for: URL(string: "https://example.com/"))
            PageFullScreen.forgetAll()
            token.cancel()
            #expect(heard.value == 3)
        }
    }

    // MARK: The script

    @Test func theScriptIsOurs() {
        let script = PageFullScreen.script()
        #expect(PageFullScreen.isOurs(script))
        #expect(!script.isForMainFrameOnly)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(PageFullScreen.source().hasPrefix(PageFullScreen.scriptMark))
        // The script carries no setting or site list: the browser owns where the page's full screen goes.
        #expect(!PageFullScreen.source().contains("__CONFIG__"))
        #expect(!PageFullScreen.isOurs(WKUserScript(source: "1", injectionTime: .atDocumentStart, forMainFrameOnly: true)))
    }

    @Test func fillingThePageNeedsAClick() async throws {
        let webView = await load(Self.page)
        // Without a user gesture WebKit refuses and the page isn't filled.
        _ = try? await webView.runOwnScript("try { await document.getElementById('player').requestFullscreen(); } catch (e) {} await new Promise(r => setTimeout(r, 10)); return 0",
                                            asFunction: true, world: .page)
        #expect(try await page("return document.getElementById('player').hasAttribute('data-zigzag-fullscreen')", in: webView) as? Bool == false)
        _ = try? await webView.runOwnScript("document.querySelector('video').webkitEnterFullscreen()", world: .page)
        #expect(try await page("return document.querySelector('video').hasAttribute('data-zigzag-fullscreen')", in: webView) as? Bool == false)
    }

    @Test func aFrameWithoutAllowFullscreenCantFillThePage() async throws {
        let inner = "<html><body style='margin:0'><div id='p' style='width:200px;height:100px'>video</div></body></html>"
        let html = """
        <html><body style="margin:0"><iframe id="f" style="width:300px;height:150px" srcdoc="\(inner.replacingOccurrences(of: "'", with: "&#39;"))"></iframe></body></html>
        """
        let webView = await load(html)
        let result = try await page("""
        const f = document.getElementById('f');
        await new Promise(r => { if (f.contentDocument && f.contentDocument.readyState === 'complete') r(); else f.onload = r; });
        try { await f.contentDocument.getElementById('p').requestFullscreen.call(f.contentDocument.getElementById('p')); } catch (e) {}
        // Its message alone, as any frame could send it, doesn't either.
        f.contentWindow.parent.postMessage({ __zigzagFullScreen: 'enter' }, '*');
        f.contentWindow.eval("parent.postMessage({ __zigzagFullScreen: 'enter' }, '*')");
        await new Promise(r => setTimeout(r, 50));
        return [f.hasAttribute('data-zigzag-fullscreen'), document.fullscreenElement === f]
        """, in: webView) as? [Any]
        let values = try #require(result)
        #expect(values[0] as? Bool == false)
        #expect(values[1] as? Bool == false)
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

    /// WebKit's own requestFullscreen, captured by the page script before the page runs: a test can see whether a
    /// request was left to WebKit or filled by the script.
    private static let nativeProbe = """
    window.__nativeFullScreenRequests = 0;
    Element.prototype.requestFullscreen = function () {
      window.__nativeFullScreenRequests++;
      return Promise.reject(new Error('WebKit\\'s own full screen'));
    };
    """

    private func load(_ html: String, probe: String? = nil, heard: Heard? = nil) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        if let probe {
            configuration.userContentController.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        configuration.userContentController.addUserScript(PageFullScreen.script())
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
        let webView = await load(Self.page, heard: heard)
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
        let webView = await load(Self.page)
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
        let webView = await load(Self.page)
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

    /// Whatever the setting says, the page's request is the page script's: The Whole Screen is the browser taking
    /// its own space, not WebKit taking the page to a window of its own (#462).
    @Test func thePageScriptAlwaysFillsThePage() async throws {
        let webView = await load(Self.page, probe: Self.nativeProbe)
        let result = try await page("""
        await document.getElementById('player').requestFullscreen();
        return [document.getElementById('player').hasAttribute('data-zigzag-fullscreen'),
                document.fullscreenElement && document.fullscreenElement.id,
                window.__nativeFullScreenRequests]
        """, in: webView) as? [Any]
        let values = try #require(result)
        #expect(values[0] as? Bool == true)
        #expect(values[1] as? String == "player")
        #expect(values[2] as? Int == 0)
    }

    /// The one place WebKit gets the page: the expand button. The script leaves its fill first, then hands the same
    /// element to WebKit's own full screen.
    @Test func theExpandButtonHandsTheElementToWebKitsFullScreen() async throws {
        let webView = await load(Self.page, probe: Self.nativeProbe)
        try await page("await document.getElementById('player').requestFullscreen()", in: webView)
        #expect(try await page("return document.getElementById('player').hasAttribute('data-zigzag-fullscreen')", in: webView) as? Bool == true)
        let handed = try await webView.evaluateJavaScript(PageFullScreen.expandCall, in: nil, contentWorld: .page) as? Bool
        #expect(handed == true)
        let after = try await page("""
        return [window.__nativeFullScreenRequests,
                document.getElementById('player').hasAttribute('data-zigzag-fullscreen'),
                document.fullscreenElement]
        """, in: webView) as? [Any]
        let values = try #require(after)
        #expect(values[0] as? Int == 1)
        #expect(values[1] as? Bool == false)
        #expect(values[2] is NSNull)
    }

    @Test func aFrameFillsThePageWithItself() async throws {
        let inner = "<html><body style='margin:0'><div id='p' style='width:200px;height:100px'>video</div></body></html>"
        let html = """
        <html><body style="margin:0"><div style="transform:translateZ(0);margin:50px"><iframe id="f" allowfullscreen style="width:300px;height:150px"
        srcdoc="\(inner.replacingOccurrences(of: "'", with: "&#39;"))"></iframe></div></body></html>
        """
        let webView = await load(html)
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

/// The layout rules around The Whole Screen (#462): the browser takes its own space only for a page on its own, the
/// space goes when the page is no longer alone, and the address stays in the bar while the page has it.
@MainActor
struct WholeScreenLayoutTests {
    @Test func theWholeScreenTakesTheBrowserSpaceOnlyAlone() {
        #expect(BrowserWindowController.wholeScreenFor(fill: .screen, inSplit: false))
        #expect(!BrowserWindowController.wholeScreenFor(fill: .screen, inSplit: true))
        #expect(!BrowserWindowController.wholeScreenFor(fill: .page, inSplit: false))
        #expect(!BrowserWindowController.wholeScreenFor(fill: .page, inSplit: true))
    }

    @Test func theWholeScreenEndsWhenThePageIsNoLongerAlone() {
        #expect(!BrowserWindowController.wholeScreenEnds(selectedIsFull: true, inSplit: false))
        #expect(BrowserWindowController.wholeScreenEnds(selectedIsFull: true, inSplit: true))
        #expect(BrowserWindowController.wholeScreenEnds(selectedIsFull: false, inSplit: false))
    }

    @Test func theAddressStaysInTheBarWhileThePageHasTheWholeScreen() {
        #expect(BrowserWindowController.addressBelongsInBar(abovePage: false, wholeScreen: true))
        #expect(BrowserWindowController.addressBelongsInBar(abovePage: true, wholeScreen: true))
        #expect(!BrowserWindowController.addressBelongsInBar(abovePage: false, wholeScreen: false))
        #expect(BrowserWindowController.addressBelongsInBar(abovePage: true, wholeScreen: false))
    }

    /// The bar comes down at the top edge, stays while the pointer is on it, and goes once it's past, unless a panel
    /// or the keyboard keeps it.
    @Test func theBarComesDownFromTheTop() {
        let bar = NSRect(x: 0, y: 0, width: 1000, height: TopBarView.height)
        let below = NSPoint(x: 500, y: bar.maxY + 40)
        #expect(BrowserRootView.topBarRevealed(at: NSPoint(x: 500, y: 0), bar: bar, revealed: false, kept: { false }))
        #expect(!BrowserRootView.topBarRevealed(at: NSPoint(x: 500, y: bar.midY), bar: bar, revealed: false, kept: { false }))
        #expect(BrowserRootView.topBarRevealed(at: NSPoint(x: 500, y: bar.midY), bar: bar, revealed: true, kept: { false }))
        #expect(!BrowserRootView.topBarRevealed(at: below, bar: bar, revealed: true, kept: { false }))
        #expect(BrowserRootView.topBarRevealed(at: below, bar: bar, revealed: true, kept: { true }))
        #expect(!BrowserRootView.topBarRevealed(at: below, bar: bar, revealed: false, kept: { true }))
    }

    /// Only a window that is windowed, and not on its way anywhere, enters the browser's space for the page.
    @Test func theSpaceIsTakenOnlyFromAWindowedWindow() {
        #expect(BrowserWindowController.wholeScreenTakesSpace(phase: .windowed, inFullScreen: false))
        #expect(!BrowserWindowController.wholeScreenTakesSpace(phase: .fullScreen, inFullScreen: true))
        #expect(!BrowserWindowController.wholeScreenTakesSpace(phase: .entering, inFullScreen: false))
        #expect(!BrowserWindowController.wholeScreenTakesSpace(phase: .windowed, inFullScreen: true))
    }

    /// The window is told when a page fills and when it leaves: without that, The Whole Screen would never start and
    /// the page would keep the chrome (#462).
    @Test func theWindowHearsWhenAPageFillsAndLeaves() {
        final class Host: TabHost {
            var heard: [Bool] = []
            var hostWindow: NSWindow? { nil }
            func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender) {}
            func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     features: WKWindowFeatures) -> WKWebView? { nil }
            func tabDidRequestClose(_ tab: Tab) {}
            func tabWantsToReturnToOpener(_ tab: Tab) {}
            func tab(_ tab: Tab, hoveringLink url: URL?) {}
            func tabWantsToBeShown(_ tab: Tab) {}
            func tab(_ tab: Tab, pageFullScreenChanged on: Bool) { heard.append(on) }
        }
        let host = Host()
        let tab = Tab(url: URL(string: "https://example.com/"), spaceID: UUID())
        tab.host = host
        tab.isInPageFullScreen = true
        tab.isInPageFullScreen = false
        // Setting it to what it already is says nothing.
        tab.isInPageFullScreen = false
        #expect(host.heard == [true, false])
    }
}

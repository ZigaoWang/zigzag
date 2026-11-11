import AppKit
import Testing
import WebKit
@testable import Zigzag

/// YouTube's page script (Resources/YouTubeAds.js): it takes ads out of what YouTube sends, at the places YouTube keeps
/// them and nowhere else, passes on anything it can't read exactly as it came, hides only the places ads take, and
/// leaves YouTube's own dialogs, overlays and scrolling alone (#86, #113, #129).
@MainActor
struct YouTubeAdsTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Zigzag's answer to "is ad blocking on here", as the app would give it.
    private final class Answer: NSObject, WKScriptMessageHandlerWithReply {
        let blocking: Bool
        init(blocking: Bool) { self.blocking = blocking }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            (blocking, nil)
        }
    }

    private static var source: String {
        get throws { try #require(Bundle.main.url(forResource: "YouTubeAds", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) }
    }

    /// A page at youtube.com with the script in it. `before` runs first (YouTube's own functions, faked); `answer`
    /// is Zigzag's, or none (then it blocks).
    private func page(_ body: String = "<p>Video</p>", before: String? = nil, answer: Bool? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        if let before { controller.addUserScript(WKUserScript(source: before, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        controller.addUserScript(WKUserScript(source: try Self.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let answer { controller.addScriptMessageHandler(Answer(blocking: answer), contentWorld: .page, name: "zigzagAds") }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://www.youtube.com/watch?v=test"))
        }
        try await Task.sleep(for: .milliseconds(300))
        withExtendedLifetime(loading) {}
        return webView
    }

    private func run(_ webView: WKWebView, _ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func object(_ text: String) throws -> NSObject {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? NSObject)
    }

    // MARK: Fixtures, as YouTube shapes them

    /// A player response (youtubei/v1/player, ytInitialPlayerResponse) with every kind of ad, and things beside them
    /// that only look like ads: a title that says the words, a key of the same name somewhere else, the heartbeat.
    static let player = #"""
    {"responseContext":{"serviceTrackingParams":[{"service":"GFEEDBACK","params":[{"key":"e","value":"1"}]}]},
     "playabilityStatus":{"status":"OK","playableInEmbed":true},
     "streamingData":{"expiresInSeconds":"21540","formats":[{"itag":18,"mimeType":"video/mp4"}]},
     "playerAds":[{"playerLegacyDesktopWatchAdsRenderer":{"playerAdParams":{"enabledEngageTypes":"3,6"}}}],
     "adPlacements":[{"adPlacementRenderer":{"config":{"adPlacementConfig":{"kind":"AD_PLACEMENT_KIND_START"}}}}],
     "adSlots":[{"adSlotRenderer":{"adSlotMetadata":{"slotType":"SLOT_TYPE_PLAYER_BYTES"}}}],
     "adBreakHeartbeatParams":"Q0FBJTNE",
     "auxiliaryUi":{"messageRenderers":{"enforcementMessageViewModel":{"title":"Ad blockers are not allowed on YouTube"},
                                        "bkaEnforcementMessageViewModel":{"isVisible":true},
                                        "upsellDialogRenderer":{"keep":true}}},
     "videoDetails":{"videoId":"abc123","title":"adPlacements, playerAds and adSlots explained","adPlacements":"not where ads go"},
     "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[]}}}
    """#

    /// What the player response should become: the ads out, the rest exactly as it was.
    static func withoutAds(_ value: NSObject) -> NSObject {
        guard let dictionary = (value as? NSDictionary)?.mutableCopy() as? NSMutableDictionary else { return value }
        dictionary.removeObjects(forKeys: ["playerAds", "adPlacements", "adSlots"])
        if let ui = (dictionary["auxiliaryUi"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary,
           let messages = (ui["messageRenderers"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
            messages.removeObjects(forKeys: ["enforcementMessageViewModel", "bkaEnforcementMessageViewModel"])
            ui["messageRenderers"] = messages
            dictionary["auxiliaryUi"] = ui
        }
        return dictionary
    }

    // MARK: What YouTube sends

    @Test func aPlayerResponseLosesItsAdsAndNothingElse() async throws {
        let webView = try await page()
        let out = try #require(try await run(webView, "return JSON.stringify(JSON.parse(text))", ["text": Self.player]) as? String)
        let expected = Self.withoutAds(try object(Self.player))
        #expect(try object(out) == expected)
        // What wasn't the player's ads is still there, word for word.
        #expect(out.contains("\"adBreakHeartbeatParams\":\"Q0FBJTNE\""))
        #expect(out.contains("\"adPlacements\":\"not where ads go\""))
        #expect(out.contains("upsellDialogRenderer"))
    }

    /// get_watch answers with a list: the player response is in one of its items.
    @Test func aPlayerResponseInAListLosesItsAds() async throws {
        let webView = try await page()
        let text = "[{\"playerResponse\":\(Self.player)},{\"response\":{\"contents\":{\"adSlots\":\"kept: not a player's\"}}}]"
        let out = try #require(try await run(webView, "return JSON.stringify(JSON.parse(text))", ["text": text]) as? String)
        let items = try #require(try object(out) as? [NSDictionary])
        #expect(items.count == 2)
        #expect(items[0]["playerResponse"] as? NSObject == Self.withoutAds(try object(Self.player)))
        #expect(((items[1]["response"] as? NSDictionary)?["contents"] as? NSDictionary)?["adSlots"] as? String == "kept: not a player's")
    }

    /// Shapes the script doesn't expect (nothing where it looks, the wrong kind of thing) are left as they are, and
    /// what isn't JSON fails as it would have.
    @Test func oddShapesAreLeftAsTheyAre() async throws {
        let webView = try await page()
        let odd = [
            #"{"auxiliaryUi":null,"playerResponse":"text","videoDetails":{"videoId":"x"}}"#,
            #"{"auxiliaryUi":{"messageRenderers":"not an object"}}"#,
            #"{"playerResponse":[1,2,3],"entries":"none"}"#,
            #"[null,1,"two",{"playerResponse":null}]"#,
            #"{"reelWatchSequenceResponse":{"entries":[{"command":null},{"command":{"reelWatchEndpoint":{}}}]}}"#,
            "42", "null", "\"adPlacements\"",
        ]
        for text in odd {
            let out = try await run(webView, "return JSON.stringify(JSON.parse(text))", ["text": text]) as? String
            #expect(try object(out ?? "") == object(text), "\(text)")
        }
        let error = try await run(webView, "try { JSON.parse(text); return 'parsed'; } catch (e) { return e.name; }", ["text": #"{"adPlacements": ["#]) as? String
        #expect(error == "SyntaxError")
    }

    /// A Short that's an ad leaves the list of Shorts; the others stay, in order.
    @Test func aShortThatIsAnAdLeavesTheList() async throws {
        let webView = try await page()
        let text = #"""
        {"entries":[{"command":{"reelWatchEndpoint":{"videoId":"one"}}},
                    {"command":{"reelWatchEndpoint":{"videoId":"ad","adClientParams":{"isAd":true}}}},
                    {"command":{"reelWatchEndpoint":{"videoId":"two","adClientParams":{"isAd":false}}}}],
         "continuationEndpoint":{"token":"t"}}
        """#
        let out = try #require(try await run(webView, "return JSON.stringify(JSON.parse(text).entries.map((e) => e.command.reelWatchEndpoint.videoId))", ["text": text]) as? String)
        #expect(out == #"["one","two"]"#)
    }

    /// The data built into the page is set by YouTube's own script as it loads.
    @Test func theDataBuiltIntoThePageLosesItsAds() async throws {
        let webView = try await page("<script>var ytInitialPlayerResponse = \(Self.player);</script>")
        let out = try #require(try await run(webView, "return JSON.stringify(window.ytInitialPlayerResponse)") as? String)
        #expect(try object(out) == Self.withoutAds(try object(Self.player)))
    }

    /// fetch, as YouTube asks for a player response: the page reads it without the ads, and with YouTube's status and
    /// headers. Other requests, and responses that aren't JSON, come back as the very response YouTube sent.
    @Test func fetchedResponsesLoseTheirAdsOnly() async throws {
        // YouTube's servers, faked: every request answers with the text in window.reply.
        let fake = """
        window.fetch = (input) => Promise.resolve(new Response(window.reply, { status: window.status || 200,
          headers: { 'content-type': 'application/json; charset=UTF-8', 'x-test': 'kept' } }));
        """
        let webView = try await page(before: fake)
        let read = """
        window.reply = text; window.status = status;
        const response = await fetch(url, { method: 'POST' });
        return JSON.stringify({ text: await response.text(), status: response.status, type: response.headers.get('content-type'),
                                test: response.headers.get('x-test') });
        """
        func fetched(_ url: String, _ text: String, status: Int = 200) async throws -> [String: Any] {
            let out = try #require(try await run(webView, read, ["url": url, "text": text, "status": status]) as? String)
            return try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        }
        let player = try await fetched("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", Self.player)
        #expect(try object(player["text"] as? String ?? "") == Self.withoutAds(try object(Self.player)))
        #expect(player["status"] as? Int == 200)
        #expect(player["type"] as? String == "application/json; charset=UTF-8")
        #expect(player["test"] as? String == "kept")
        // Not a request that brings ads: as it came.
        let browse = try await fetched("https://www.youtube.com/youtubei/v1/browse?prettyPrint=false", Self.player)
        #expect(browse["text"] as? String == Self.player)
        // Not JSON, or not all of it: as it came, and so is its status.
        for text in [#"{"adPlacements": [{"#, ")]}'\n" + Self.player, "<html>adPlacements</html>", ""] {
            let odd = try await fetched("https://www.youtube.com/youtubei/v1/player", text, status: 503)
            #expect(odd["text"] as? String == text)
            #expect(odd["status"] as? Int == 503)
        }
        // A request that fails fails as it would have, with YouTube's error.
        let failed = try await run(webView, """
            window.reply = null;
            const original = Response;
            window.Response = function () { throw new TypeError('offline'); };
            try { await fetch('https://www.youtube.com/youtubei/v1/player'); return 'answered'; }
            catch (e) { return e.message; } finally { window.Response = original; }
            """) as? String
        #expect(failed == "offline")
    }

    /// XHR, as YouTube's older pages ask: the finished response reads without the ads, as text and as JSON.
    @Test func xhrResponsesLoseTheirAdsOnly() async throws {
        // A request that's done as soon as it's sent, answering with window.reply.
        let fake = """
        XMLHttpRequest.prototype.open = function () {};
        XMLHttpRequest.prototype.send = function () { this.sent = true; };
        Object.defineProperty(XMLHttpRequest.prototype, 'readyState', { configurable: true, get() { return this.sent ? 4 : 1; } });
        Object.defineProperty(XMLHttpRequest.prototype, 'responseText', { configurable: true, get() { return window.reply; } });
        Object.defineProperty(XMLHttpRequest.prototype, 'response', { configurable: true,
          get() { return this.responseType === 'json' ? JSON.parse(window.reply) : window.reply; } });
        """
        let webView = try await page(before: fake)
        let read = """
        window.reply = text;
        const request = new XMLHttpRequest();
        request.open('GET', url);
        request.responseType = type;
        const early = request.responseText;
        request.send();
        return JSON.stringify({ early, text: type === 'json' ? JSON.stringify(request.response) : request.responseText,
                                again: type === 'json' ? '' : request.response });
        """
        func requested(_ url: String, _ text: String, type: String = "") async throws -> [String: String] {
            let out = try #require(try await run(webView, read, ["url": url, "text": text, "type": type]) as? String)
            return try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: String])
        }
        let player = try await requested("/youtubei/v1/player?key=x", Self.player)
        #expect(try object(player["text"] ?? "") == Self.withoutAds(try object(Self.player)))
        #expect(player["again"] == player["text"])
        // Before it's done, what it says is left alone.
        #expect(player["early"] == Self.player)
        let json = try await requested("https://www.youtube.com/watch?v=abc&pbj=1", "[{\"playerResponse\":\(Self.player)}]", type: "json")
        let items = try #require(try object(json["text"] ?? "") as? [NSDictionary])
        #expect(items.first?["playerResponse"] as? NSObject == Self.withoutAds(try object(Self.player)))
        let other = try await requested("/youtubei/v1/log_event", Self.player)
        #expect(other["text"] == Self.player)
        let broken = try await requested("/youtubei/v1/player", #"{"adPlacements":"#)
        #expect(broken["text"] == #"{"adPlacements":"#)
    }

    /// With ad blocking off for the page (ads allowed on YouTube, or an ad blocker extension handling it), nothing
    /// is taken out or hidden.
    @Test func withBlockingOffNothingChanges() async throws {
        let webView = try await page("<ytd-ad-slot-renderer style=\"display: block\">Ad</ytd-ad-slot-renderer>", answer: false)
        let out = try #require(try await run(webView, "return JSON.stringify(JSON.parse(text))", ["text": Self.player]) as? String)
        #expect(try object(out) == object(Self.player))
        let shown = try await run(webView, "return getComputedStyle(document.querySelector('ytd-ad-slot-renderer')).display") as? String
        #expect(shown == "block")
    }

    // MARK: What shows

    /// YouTube's dialogs, swallowing the wheel while one is open, as tp-yt-paper-dialog does.
    private static let youTubeDialogs = """
        <script>
          customElements.define('tp-yt-paper-dialog', class extends HTMLElement {
            connectedCallback() { this.opened = true; this.setAttribute('opened', ''); }
            close() { this.opened = false; this.removeAttribute('opened'); }
          });
        </script>
        """

    /// The places ads take are hidden; YouTube's own dialog about blockers, its dimmed backdrop, its toast and its
    /// scroll lock are all left exactly as YouTube made them, so the dialog shows whole and can be closed.
    @Test func onlyThePlacesAdsTakeAreHidden() async throws {
        let body = Self.youTubeDialogs + """
        <ytd-rich-grid-renderer>
          <ytd-rich-item-renderer id="ad-cell"><div id="content"><ytd-ad-slot-renderer>Ad</ytd-ad-slot-renderer></div></ytd-rich-item-renderer>
          <ytd-rich-item-renderer id="video-cell"><div id="content"><ytd-rich-grid-media>A video</ytd-rich-grid-media></div></ytd-rich-item-renderer>
        </ytd-rich-grid-renderer>
        <div id="masthead-ad">Banner</div>
        <ytd-in-feed-ad-layout-renderer>Ad</ytd-in-feed-ad-layout-renderer>
        <tp-yt-iron-overlay-backdrop style="position: fixed; inset: 0; display: block; background: rgba(0,0,0,.5)"></tp-yt-iron-overlay-backdrop>
        <ytd-popup-container>
          <tp-yt-paper-dialog style="display: block; width: 300px; height: 200px">
            <ytd-enforcement-message-view-model style="display: block">Ad blockers are not allowed on YouTube</ytd-enforcement-message-view-model>
          </tp-yt-paper-dialog>
          <tp-yt-paper-toast style="display: block">Experiencing interruptions? <a href="https://support.google.com/youtube">Find out why</a></tp-yt-paper-toast>
        </ytd-popup-container>
        <script>document.body.style.overflow = 'hidden';</script>
        """
        let webView = try await page(body)
        try await Task.sleep(for: .milliseconds(500))
        let out = try #require(try await run(webView, """
            const shown = (selector) => getComputedStyle(document.querySelector(selector)).display;
            return JSON.stringify({ adCell: shown('#ad-cell'), videoCell: shown('#video-cell'), masthead: shown('#masthead-ad'),
              inFeed: shown('ytd-in-feed-ad-layout-renderer'), backdrop: shown('tp-yt-iron-overlay-backdrop'),
              dialog: shown('tp-yt-paper-dialog'), warning: shown('ytd-enforcement-message-view-model'), toast: shown('tp-yt-paper-toast'),
              opened: document.querySelector('tp-yt-paper-dialog').opened, overflow: document.body.style.overflow,
              marked: document.querySelectorAll('[data-zigzag-quiet], [data-zigzag-freed]').length,
              styled: [...document.querySelectorAll('tp-yt-paper-dialog, tp-yt-iron-overlay-backdrop, tp-yt-paper-toast')].map((e) => e.style.getPropertyValue('display')) });
            """) as? String)
        let seen = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(seen["adCell"] as? String == "none")
        #expect(seen["masthead"] as? String == "none")
        #expect(seen["inFeed"] as? String == "none")
        #expect(seen["videoCell"] as? String == "inline")
        #expect(seen["backdrop"] as? String == "block")
        #expect(seen["dialog"] as? String == "block")
        #expect(seen["warning"] as? String == "block")
        #expect(seen["toast"] as? String == "block")
        #expect(seen["opened"] as? Bool == true)
        #expect(seen["overflow"] as? String == "hidden")
        #expect(seen["marked"] as? Int == 0)
        #expect(seen["styled"] as? [String] == ["block", "block", "block"])
    }

    /// Hiding is the stylesheet's alone: the script has no code that reaches YouTube's dialogs, overlays or scroll.
    @Test func theScriptNeverReachesYouTubesOwnUI() throws {
        let code = try Self.source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for reach in ["paper-dialog", "iron-overlay", "paper-toast", "popup-container", "enforcement-message-view-model", "overflow",
                      ".close(", "opened", "style.setProperty", "removeProperty", "textContent ||", "preventDefault", "stopPropagation"] {
            #expect(!code.contains(reach), "\(reach)")
        }
    }

    // MARK: If one plays anyway

    /// A player as YouTube's, with the video at your own speed and sound.
    private static func player(adShowing: Bool, badge: Bool) -> String {
        """
        <div class="html5-video-player\(adShowing ? " ad-showing" : "")">
          <video></video>
          \(badge ? "<div class=\"ytp-ad-player-overlay-layout\"><span class=\"ytp-ad-badge\">Sponsored</span></div>" : "")
          <button class="ytp-skip-ad-button" onclick="window.skipped = (window.skipped || 0) + 1">Skip</button>
          <button class="ytp-chapter-skip" aria-label="Skip navigation" onclick="window.other = 1">Skip navigation</button>
        </div>
        <script>const v = document.querySelector('video'); v.muted = false; v.playbackRate = 1.5;</script>
        """
    }

    private func video(_ webView: WKWebView) async throws -> (muted: Bool, rate: Double) {
        let out = try #require(try await run(webView, "const v = document.querySelector('video'); return JSON.stringify([v.muted, v.playbackRate])") as? String)
        let values = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Any])
        return (values[0] as? Bool ?? false, (values[1] as? NSNumber)?.doubleValue ?? 0)
    }

    @Test func anAdThatPlaysIsMutedSpedUpSkippedAndPutBackExactly() async throws {
        let webView = try await page(Self.player(adShowing: true, badge: true))
        _ = try await run(webView, "document.querySelector('video').dispatchEvent(new Event('playing')); return 1")
        var seen = try await video(webView)
        #expect(seen.muted == true)
        #expect(seen.rate == 16)
        #expect(try await run(webView, "return window.skipped || 0") as? Int ?? 0 >= 1)
        #expect(try await run(webView, "return window.other || 0") as? Int == 0)
        // The ad ends: the video's own sound and speed come back as they were.
        _ = try await run(webView, """
            document.querySelector('.html5-video-player').classList.remove('ad-showing');
            document.querySelector('video').dispatchEvent(new Event('timeupdate')); return 1
            """)
        seen = try await video(webView)
        #expect(seen.muted == false)
        #expect(seen.rate == 1.5)
    }

    /// YouTube's mark left on the player with no ad in it (no badge, no countdown) never touches the video.
    @Test func theVideoItselfIsNeverSpedUp() async throws {
        let webView = try await page(Self.player(adShowing: true, badge: false))
        _ = try await run(webView, "document.querySelector('video').dispatchEvent(new Event('playing')); return 1")
        let seen = try await video(webView)
        #expect(seen.muted == false)
        #expect(seen.rate == 1.5)
        #expect(try await run(webView, "return window.skipped || 0") as? Int == 0)
    }

    /// Sound you turned on during the ad stays on after it.
    @Test func soundTurnedOnDuringAnAdStaysOn() async throws {
        let webView = try await page(Self.player(adShowing: true, badge: true))
        _ = try await run(webView, """
            const v = document.querySelector('video'); v.dispatchEvent(new Event('playing')); v.muted = false;
            document.querySelector('.html5-video-player').classList.remove('ad-showing'); v.dispatchEvent(new Event('timeupdate')); return 1
            """)
        let seen = try await video(webView)
        #expect(seen.muted == false)
        #expect(seen.rate == 1.5)
    }

    // MARK: Stepping aside for an ad blocker extension

    @Test func knownAdBlockersAreFoundByTheirStoreIDs() {
        #expect(AdBlockers.active(among: ["ddkjiahejlhfcafbddmgiahcphecmpfh"]) == "uBlock Origin Lite")
        #expect(AdBlockers.active(among: ["cjpalhdlnbpafiamejdnhcphjbkeiagm"]) == "uBlock Origin")
        #expect(AdBlockers.active(among: ["bgnkhhnnamicmpeenaelnjfhikgbkllg"]) == "AdGuard")
        #expect(AdBlockers.active(among: ["gighmmpiobklfepjocnamgkkbiglidom"]) == "AdBlock")
        #expect(AdBlockers.active(among: ["cfhdojbkjhnklbpkdaibdccddilifddb"]) == "Adblock Plus")
        #expect(AdBlockers.active(among: ["mlomiejdfkolichcflejclcbmpeaniij"]) == "Ghostery")
        // Not an ad blocker (1Password), or none at all: Zigzag handles YouTube.
        #expect(AdBlockers.active(among: ["aeblfdkhhhdcdjpifhhbdiojplfjncoa"]) == nil)
        #expect(AdBlockers.active(among: []) == nil)
        // Several: the same one every time.
        #expect(AdBlockers.active(among: ["mlomiejdfkolichcflejclcbmpeaniij", "ddkjiahejlhfcafbddmgiahcphecmpfh"]) == "Ghostery")
        #expect(AdBlockers.active(among: ["ddkjiahejlhfcafbddmgiahcphecmpfh", "mlomiejdfkolichcflejclcbmpeaniij"]) == "Ghostery")
    }

    /// Only an ad blocker that may run on YouTube takes it over: one kept off YouTube leaves it to Zigzag.
    @Test func anAdBlockerStepsInOnlyWhereItRunsOnYouTube() {
        #expect(AdBlockers.reachesYouTube(access: .all, approved: nil, sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .all, approved: ["<all_urls>"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .all, approved: ["*://*/*"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .all, approved: ["https://*.youtube.com/*"], sites: [], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .all, approved: [], sites: [], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .all, approved: ["https://github.com/*", "http://*/*"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .sites, approved: ["<all_urls>"], sites: ["youtube.com"], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .sites, approved: ["<all_urls>"], sites: ["github.com"], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .click, approved: ["<all_urls>"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .click, approved: ["<all_urls>"], sites: ["youtube.com"], offSites: []))
        // Extensions off on YouTube.
        #expect(!AdBlockers.reachesYouTube(access: .all, approved: ["<all_urls>"], sites: [], offSites: ["youtube.com"]))
    }

    /// Stepping aside takes out Zigzag's YouTube script and nothing else, in order; stepping back puts it back once.
    @Test func steppingAsideKeepsThePagesOtherScripts() {
        let controller = WKUserContentController()
        let before = WKUserScript(source: "window.a = 1", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        let after = WKUserScript(source: "window.b = 1", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(before)
        controller.addUserScript(ContentBlocker.youTubeScript)
        controller.addUserScript(after)
        ContentBlocker.setYouTube(false, in: controller)
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.first === before)
        #expect(controller.userScripts.last === after)
        ContentBlocker.setYouTube(false, in: controller)
        #expect(controller.userScripts.count == 2)
        ContentBlocker.setYouTube(true, in: controller)
        ContentBlocker.setYouTube(true, in: controller)
        #expect(controller.userScripts.filter { $0 === ContentBlocker.youTubeScript }.count == 1)
        #expect(controller.userScripts.count == 3)
    }

    /// A web view no profile's store matches (a private window's) keeps Zigzag's own YouTube script.
    @Test func aPrivatePageKeepsZigzagsScript() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(ContentBlocker.youTubeScript)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #expect(ContentBlocker.youTubeBlocker(for: webView) == nil)
        ContentBlocker.applyYouTube(to: webView)
        #expect(configuration.userContentController.userScripts.contains { $0 === ContentBlocker.youTubeScript })
    }
}

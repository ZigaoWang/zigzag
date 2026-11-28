import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The mini player's page script on a real page: only the video shows while it's in the card (a site's own player
/// controls and overlays, and the page around it, made invisible), and the page is given back exactly as it was.
@MainActor
@Suite(.serialized)
struct MiniPlayerPageTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A page laid out as YouTube's watch page is: the video in a player with its own control bar, title and end card
    /// over it, an article beside it.
    private static let page = """
    <html><head><style>body{margin:0;background:#fff} #movie_player{position:relative;width:640px;height:360px;background:#000}
    video{width:640px;height:360px} .ytp-chrome-bottom,.ytp-chrome-top{position:absolute;left:0;right:0;height:40px}
    .ytp-chrome-bottom{bottom:0} .ytp-chrome-top{top:0} .ytp-gradient-bottom{position:absolute;inset:0}
    #movie_player::after{content:'';position:absolute;inset:0}</style></head>
    <body><div id="page"><div id="movie_player"><div class="html5-video-container"><video controls="controls" style="left:0"></video></div>
    <div class="ytp-gradient-bottom"></div><div class="ytp-chrome-top">Title</div><div class="ytp-chrome-bottom"><button>CC</button></div>
    <div class="ytp-ce-element">Next</div></div><article><p>Article text beside the video</p></article></div>
    </body></html>
    """

    private func load(_ html: String) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageVideos.script)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://videos.test/"))
        }
        return webView
    }

    @discardableResult
    private func script(_ source: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private func visibility(_ selector: String, in webView: WKWebView, pseudo: String = "") async throws -> String {
        try await script("return getComputedStyle(document.querySelector('\(selector)'), '\(pseudo)' || null).visibility", in: webView) as? String ?? ""
    }

    @Test func onlyTheVideoShowsAndThePageComesBackExactly() async throws {
        let webView = await load(Self.page)
        let before = try await script("return document.documentElement.outerHTML", in: webView) as? String
        try await script("window.__zigzagVideos.report(); return window.__zigzagVideos.isolate(0)", in: webView)
        #expect(try await visibility("video", in: webView) == "visible")
        for overlay in [".ytp-chrome-bottom", ".ytp-chrome-bottom button", ".ytp-chrome-top", ".ytp-gradient-bottom", ".ytp-ce-element", "article p"] {
            #expect(try await visibility(overlay, in: webView) == "hidden", "\(overlay)")
        }
        #expect(try await visibility("#movie_player", in: webView, pseudo: "::after") == "hidden")
        // The player it sits in stays, on black.
        #expect(try await script("return getComputedStyle(document.body).backgroundColor", in: webView) as? String == "rgb(0, 0, 0)")
        // Native controls are off in the card so they don't overlap its own (#230).
        #expect(try await script("return document.querySelector('video').controls", in: webView) as? Bool == false)
        // Nothing moved: the video is where it was.
        #expect(try await script("return document.querySelector('video').getBoundingClientRect().width", in: webView) as? Double == 640)

        // Again for the same video: nothing changes.
        #expect(try await script("return window.__zigzagVideos.isolate(0)", in: webView) as? Bool == true)
        #expect(try await script("return document.querySelectorAll('[data-zigzag-mini=\"style\"]').length", in: webView) as? Int == 1)

        #expect(try await script("return window.__zigzagVideos.unisolate()", in: webView) as? Bool == true)
        #expect(try await script("return document.documentElement.outerHTML", in: webView) as? String == before)
        #expect(try await visibility(".ytp-chrome-bottom", in: webView) == "visible")
        #expect(try await script("return document.querySelector('video').controls", in: webView) as? Bool == true)
        #expect(try await script("return window.__zigzagVideos.unisolate()", in: webView) as? Bool == false)
    }

    /// A homepage's video card plays its preview inside the link to the video's page; a video the page plays by
    /// itself, with no press or key from you, isn't one you started (#156).
    @Test func aLinksPreviewAndAVideoNoOneStartedAreToldApart() async throws {
        let html = """
        <html><body><a href="/video/1"><video id="preview" muted style="width:290px;height:163px"></video></a>
        <video id="main" style="width:640px;height:360px"></video></body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageVideos.script)
        configuration.userContentController.add(PageVideos.shared, contentWorld: .defaultClient, name: PageVideos.messageName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://videos.test/"))
        }
        // The page plays and turns up its own videos: no one pressed anything.
        _ = try await webView.callAsyncJavaScript("document.querySelectorAll('video').forEach((v) => { v.volume = 0.5; v.dispatchEvent(new Event('play')); }); return true",
                                              arguments: [:], in: nil, contentWorld: .page)
        try await script("return window.__zigzagVideos.report()", in: webView)
        var videos: [PageVideo] = []
        for _ in 0..<40 where videos.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
            videos = PageVideos.shared.frames(in: webView).first(where: \.isMain)?.videos ?? []
        }
        #expect(videos.count == 2)
        #expect(videos.first?.isInLink == true)
        #expect(videos.last?.isInLink == false)
        #expect(videos.allSatisfy { !$0.isStartedByUser })
        configuration.userContentController.removeScriptMessageHandler(forName: PageVideos.messageName, contentWorld: .defaultClient)
    }

    @Test func aVideoThePageMovesIsShownAloneWhereItWent() async throws {
        let webView = await load(Self.page)
        try await script("window.__zigzagVideos.report(); return window.__zigzagVideos.isolate(0)", in: webView)
        // The site lays its player out again somewhere else (theater mode, a new layout).
        try await script("document.querySelector('article').appendChild(document.querySelector('video')); return true", in: webView)
        #expect(try await visibility("video", in: webView) == "hidden")
        try await script("return window.__zigzagVideos.isolate(0)", in: webView)
        #expect(try await visibility("video", in: webView) == "visible")
        #expect(try await visibility("article p", in: webView) == "hidden")
        try await script("return window.__zigzagVideos.unisolate()", in: webView)
        #expect(try await script("return document.querySelectorAll('[data-zigzag-mini]').length", in: webView) as? Int == 0)
    }

    /// A page's Web Audio that only outputs silence (a call app's idle graph) isn't playing sound to WebKit, so it
    /// never keeps a covered window's page on screen; any sound at all is (#199).
    @Test func silentWebAudioIsNotPlayingSound() async throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let key = "_isPlayingAudio"
        guard webView.responds(to: NSSelectorFromString(key)) else { return }
        window.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        // In the page's own world. A source held at zero; then a step far below hearing (-120 dB).
        let page = "<html><body><script>window.ctx = new AudioContext(); window.s = ctx.createConstantSource(); s.offset.value = 0; s.connect(ctx.destination); s.start(); ctx.resume();</script></body></html>"
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(page, baseURL: URL(string: "https://audio.test/"))
        }
        func playing(after wait: Int) async throws -> Bool {
            try await Task.sleep(for: .milliseconds(wait))
            return webView.value(forKey: key) as? Bool ?? false
        }
        #expect(try await webView.evaluateJavaScript("ctx.state") as? String == "running")
        #expect(try await !playing(after: 1500))
        _ = try await webView.evaluateJavaScript("s.offset.value = 0.000001; 1")
        #expect(try await playing(after: 1500))
        _ = try await webView.evaluateJavaScript("ctx.close(); 1")
    }

    /// A sound that started with a video playing is over shortly after the video stops, however long WebKit says it
    /// plays; one that started without (Web Audio) lasts as long as WebKit says.
    @Test func aSoundFromAVideoEndsOnceItStops() {
        let start = Date()
        var sound = PageSound()
        #expect(sound.update(webKit: true, media: true, now: start) == (true, nil))
        #expect(sound.update(webKit: true, media: false, now: start + 5) == (true, PageSound.hold))
        #expect(sound.update(webKit: true, media: false, now: start + 6).playing)
        #expect(sound.update(webKit: true, media: false, now: start + 5 + PageSound.hold) == (false, nil))
        #expect(sound.update(webKit: true, media: true, now: start + 20) == (true, nil))
        #expect(sound.update(webKit: false, media: false, now: start + 21) == (false, nil))

        // The video's report comes just after WebKit's.
        #expect(sound.update(webKit: true, media: false, now: start + 30) == (true, nil))
        #expect(sound.update(webKit: true, media: true, now: start + 30.5) == (true, nil))
        #expect(sound.update(webKit: true, media: false, now: start + 40 + PageSound.hold).playing)
        #expect(sound.update(webKit: true, media: false, now: start + 45) == (false, nil))
        _ = sound.update(webKit: false, media: false, now: start + 50)

        // Web Audio: a video played and paused later on doesn't end it.
        #expect(sound.update(webKit: true, media: false, now: start + 60) == (true, nil))
        #expect(sound.update(webKit: true, media: true, now: start + 70) == (true, nil))
        #expect(sound.update(webKit: true, media: false, now: start + 80) == (true, nil))
        #expect(sound.update(webKit: true, media: false, now: start + 90) == (true, nil))
    }

    /// Serves a page on a.test with a frame from b.test, another site.
    private final class TwoSites: NSObject, WKURLSchemeHandler {
        static let media = """
        function wav(seconds) { const rate = 8000, n = rate * seconds, b = new ArrayBuffer(44 + n * 2), v = new DataView(b);
          const s = (o, t) => { for (let i = 0; i < t.length; i++) v.setUint8(o + i, t.charCodeAt(i)); };
          s(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); s(8, 'WAVE'); s(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true);
          v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
          s(36, 'data'); v.setUint32(40, n * 2, true);
          return URL.createObjectURL(new Blob([b], { type: 'audio/wav' })); }
        window.a = document.createElement('audio'); a.loop = true; a.src = wav(30); document.documentElement.appendChild(a);
        window.webAudio = () => { window.c = new AudioContext(); c.createMediaElementSource(a).connect(c.destination); return 1; };
        addEventListener('message', (e) => { if (e.source === parent) parent.postMessage(String(eval(e.data)), '*'); });
        """

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let body = url.host == "a.test" ? "<iframe id=f src='zz://b.test/'></iframe>" : ""
            let data = Data("<html><body>\(body)<script>\(Self.media)</script></body></html>".utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    /// A paused audio whose sound went through Web Audio, on the page and in another site's frame: WebKit may go on
    /// saying the page plays, but the tab's sound ends. The page is muted and its audio is silence.
    @Test func aPausedAudioThroughWebAudioEndsTheSound() async throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(TwoSites(), forURLScheme: "zz")
        configuration.userContentController.addUserScript(PageVideos.script)
        configuration.userContentController.add(PageVideos.shared, contentWorld: .defaultClient, name: PageVideos.messageName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let key = "_isPlayingAudio"
        guard webView.responds(to: NSSelectorFromString(key)), webView.setPageAudioMuted(true) == true else { return }
        window.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.load(URLRequest(url: URL(string: "zz://a.test/")!))
        }
        try await Task.sleep(for: .milliseconds(500))
        func page(_ source: String) async throws {
            _ = try await webView.evaluateJavaScript(source)
        }
        func frame(_ source: String) async throws {
            let ask = "return await new Promise((r) => { addEventListener('message', (e) => r(e.data), { once: true }); document.getElementById('f').contentWindow.postMessage(source, '*'); })"
            _ = try await webView.callAsyncJavaScript(ask, arguments: ["source": source], contentWorld: .page)
        }
        func sounds(after wait: Int, _ sound: inout PageSound) async throws -> (webKit: Bool, media: Bool, playing: Bool) {
            let start = Date()
            var result = (webKit: false, media: false, playing: false)
            for step in 0...(wait / 250) {
                if step > 0 { try await Task.sleep(for: .milliseconds(250)) }
                let webKit = webView.value(forKey: key) as? Bool ?? false
                let media = PageVideos.shared.playsSound(in: webView)
                result = (webKit, media, sound.update(webKit: webKit, media: media, now: start + Double(step) * 0.25).playing)
            }
            return result
        }
        for run in [page, frame] {
            var sound = PageSound()
            try await run("a.play(); 1")
            #expect(try await sounds(after: 1500, &sound) == (true, true, true))
            // Played straight out, WebKit says it stopped.
            try await run("a.pause(); 1")
            #expect(try await sounds(after: 1000, &sound) == (false, false, false))
            try await run("webAudio(); a.play(); 1")
            #expect(try await sounds(after: 1500, &sound) == (true, true, true))
            try await run("a.pause(); 1")
            let paused = try await sounds(after: 2500, &sound)
            #expect(!paused.media && !paused.playing)
            try await run("c.close(); 1")
        }
    }

    /// WebKit is told whether a covered window hides the page, as `Tab` does while it plays (#199).
    @Test func aPageCanBeLeftOnScreenInACoveredWindow() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let key = "_windowOcclusionDetectionEnabled"
        guard webView.responds(to: NSSelectorFromString(key)) else { return }
        #expect(webView.value(forKey: key) as? Bool == true)
        Tab.setWatchesCover(false, of: webView)
        #expect(webView.value(forKey: key) as? Bool == false)
        Tab.setWatchesCover(true, of: webView)
        #expect(webView.value(forKey: key) as? Bool == true)
    }

    /// A page out of the window counts as hidden, where WebKit won't load or start a playlist's next song; kept in the
    /// window, out of sight, it counts as on screen (#199).
    @Test func aPageKeptOutOfSightInTheWindowCountsAsOnScreen() async throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let webView = await load("<html><body><audio></audio></body></html>")
        // Off screen it would count as hidden whatever its place, unless WebKit is told not to look.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: SetBool.self)(webView, occlusion, false)
        }
        let holder = PageHolder(holding: webView)
        let parking = MiniPlayerParking()
        root.addSubview(parking)
        func state() async throws -> String { try await script("return document.visibilityState", in: webView) as? String ?? "" }
        func becomes(_ wanted: String) async throws -> Bool {
            for _ in 0..<100 {
                if try await state() == wanted { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        #expect(try await becomes("hidden"))
        parking.park(holder)
        #expect(try await becomes("visible"))
        parking.release(holder)
        #expect(try await becomes("hidden"))
    }

    // MARK: Which video follows you out (#582)

    /// Plays every video on the page from a canvas (no sound track, so nothing is ever heard), as the page's own
    /// script would; `muted` marks a feed that autoplays muted.
    private static func playing(_ body: String) -> String {
        """
        <html><head><style>body{margin:0} video{display:block;object-fit:cover}</style></head><body>\(body)
        <script>
        const c = document.createElement('canvas'); c.width = 640; c.height = 360;
        const g = c.getContext('2d'); let n = 0;
        setInterval(() => { g.fillStyle = `hsl(${n++ % 360} 60% 50%)`; g.fillRect(0, 0, 640, 360); }, 30);
        window.stream = c.captureStream(30);
        window.start = (v) => { v.srcObject = window.stream; return v.play(); };
        document.querySelectorAll('video[data-autoplay]').forEach((v) => window.start(v));
        document.querySelectorAll('video[data-click]').forEach((v) => v.addEventListener('pointerdown', () => window.start(v)));
        </script></body></html>
        """
    }

    /// A page in an offscreen window, so the pointer can press on it, with the videos' reports reaching `PageVideos`.
    private func open(_ html: String) async -> (WKWebView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(PageVideos.script)
        configuration.userContentController.add(PageVideos.shared, contentWorld: .defaultClient, name: PageVideos.messageName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        window.contentView = webView
        window.orderFrontRegardless()
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://videos.test/"))
        }
        return (webView, window)
    }

    private func close(_ webView: WKWebView, _ window: NSWindow) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PageVideos.messageName, contentWorld: .defaultClient)
        window.orderOut(nil)
    }

    /// The page's videos once `count` of them play.
    private func playingVideos(_ count: Int, in webView: WKWebView) async throws -> [PageVideo] {
        var videos: [PageVideo] = []
        for _ in 0..<80 {
            videos = PageVideos.shared.frames(in: webView).first(where: \.isMain)?.videos ?? []
            if videos.filter(\.isPlaying).count >= count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return videos
    }

    private func followed(in webView: WKWebView) -> PageVideo? {
        PageVideos.shared.followed(in: webView, leavingPage: false)?.video
    }

    /// A feed whose clips autoplay muted as you scroll (x.com): a press on the page as you go doesn't make any of them
    /// one you started, and none follows you out.
    @Test func aMutedAutoplayFeedNeverFollows() async throws {
        let (webView, window) = await open(Self.playing((0..<3).map { _ in
            "<article style='height:420px'><video data-autoplay muted playsinline style='width:516px;height:290px'></video></article>"
        }.joined()))
        defer { close(webView, window) }
        let videos = try await playingVideos(3, in: webView)
        #expect(videos.filter(\.isPlaying).count == 3)
        #expect(videos.allSatisfy { $0.isMuted && !$0.isStartedByUser && $0.heardSince == nil })
        #expect(followed(in: webView) == nil)
    }

    /// A shop's product video beside its pictures, playing with its sound on by itself (Taobao): it's heard, but it's
    /// small and no one started it, so it never follows.
    @Test func aSmallProductVideoNeverFollows() async throws {
        let (webView, window) = await open(Self.playing("""
        <div style='display:flex;gap:12px;padding:40px'><video data-autoplay playsinline style='width:300px;height:170px'></video>
        <img style='width:300px;height:300px;background:#ddd'></div>
        """))
        defer { close(webView, window) }
        let videos = try await playingVideos(1, in: webView)
        #expect(videos.first?.isPlaying == true)
        #expect(videos.first?.isMuted == false)
        #expect(videos.first?.heardSince != nil)
        #expect(videos.first?.isStartedByUser == false)
        #expect(followed(in: webView) == nil)
    }

    /// A video you press play on yourself (YouTube, Bilibili): it's yours, and it follows you out at once. A press
    /// somewhere else on the page before another one starts doesn't count for that one.
    @Test func aVideoYouStartedFollows() async throws {
        let (webView, window) = await open(Self.playing("""
        <video id='main' data-click playsinline style='width:640px;height:360px'></video>
        <p id='text' style='height:200px'>About this video</p>
        <video id='other' playsinline style='width:640px;height:360px'></video>
        """))
        defer { close(webView, window) }
        // A real press, as the pointer makes it, on the first video: y runs up in the window.
        func press(at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                window.sendEvent(event)
            }
        }
        press(at: NSPoint(x: 320, y: 700 - 180))
        let videos = try await playingVideos(1, in: webView)
        #expect(videos.first?.isPlaying == true)
        #expect(videos.first?.isStartedByUser == true)
        #expect(followed(in: webView)?.index == 0)
        // A press on the text, then the page starts the second video itself: not one you started.
        try await script("document.getElementById('main').pause(); return true", in: webView)
        press(at: NSPoint(x: 320, y: 700 - 460))
        _ = try await webView.callAsyncJavaScript("window.start(document.getElementById('other')); return true", arguments: [:], in: nil, contentWorld: .page)
        var other: PageVideo?
        for _ in 0..<80 {
            other = PageVideos.shared.frames(in: webView).first(where: \.isMain)?.videos.first { $0.index == 1 && $0.isPlaying }
            if other != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(other?.isStartedByUser == false)
    }
}

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
        // Its own controls are off while it's in the card, so they don't show over the card's (#230).
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
}

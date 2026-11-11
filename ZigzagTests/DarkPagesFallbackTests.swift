import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Dark pages' invert fallback (#134): Pure black backgrounds, the style turning pictures back exactly, and pictures
/// the selectors can't see (background photos, ::before pictures, shadow roots, frames).
@MainActor
@Suite(.serialized)
struct DarkPagesFallbackTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DarkPagesFallbackTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
            DarkPages.refreshAll()
        }
        try body()
    }

    // MARK: Pure black

    @Test func pureBlackIsOffUntilChosenAndIsKept() {
        withDefaults {
            #expect(!DarkPages.pureBlack)
            DarkPages.pureBlack = true
            #expect(DarkPages.pureBlack)
            #expect(DarkPages.config(for: nil)["black"] as? Bool == true)
            #expect(DarkPages.config(for: nil)["strength"] as? Double == 1)
            DarkPages.pureBlack = false
            #expect(DarkPages.config(for: nil)["strength"] as? Double == 0.92)
        }
    }

    @Test func underThePageIsBlackOrTheDarkenedWhite() {
        let black = DarkPages.underPageColor(black: true).usingColorSpace(.sRGB)!
        #expect(black.redComponent == 0 && black.greenComponent == 0 && black.blueComponent == 0)
        let gray = DarkPages.underPageColor(black: false).usingColorSpace(.sRGB)!
        #expect(abs(gray.redComponent - 0.08) < 0.0001)
    }

    @Test func theRootFilterFollowsTheChoice() {
        #expect(DarkPages.rootCSS(black: true).contains("invert(1.0)"))
        #expect(DarkPages.rootCSS(black: false).contains("invert(0.92)"))
    }

    // MARK: Pictures turned back

    /// Inverting by s maps v to s + v(1 - 2s); the pictures' filter, after the page's, puts each tone back.
    @Test func picturesComeBackExactly() throws {
        for black in [false, true] {
            let s = DarkPages.strength(black: black)
            let filter = DarkPages.restoreFilter(black: black)
            #expect(filter.hasPrefix("invert(1) hue-rotate(180deg)"))
            let contrast = try filter.firstMatch(of: /contrast\(([0-9.]+)\)/).map { try #require(Double($0.1)) } ?? 1
            for step in 0...20 {
                let v = 1 - s + (2 * s - 1) * Double(step) / 20
                let restored = min(1, max(0, (1 - v - 0.5) * contrast + 0.5))
                let shown = s + restored * (1 - 2 * s)
                #expect(abs(shown - v) < 0.001, "black \(black) at \(v): \(shown)")
            }
        }
        #expect(!DarkPages.restoreFilter(black: true).contains("contrast"))
    }

    @Test func everyKindOfPictureIsTurnedBack() {
        let css = DarkPages.mediaCSS(black: false)
        for kind in ["img:not(", "picture", "video", "canvas", "embed", "object", "svg image", "input[type=image]",
                     "[\(DarkPages.imageMark)]", "iframe[\(DarkPages.frameMark)]",
                     "[\(DarkPages.beforeMark)]::before", "[\(DarkPages.afterMark)]::after"] {
            #expect(css.contains(kind), "\(kind)")
        }
        // Once: not again inside something turned back already.
        #expect(css.contains("filter: none"))
    }

    /// Frames get the script too, so a frame from elsewhere darkens itself instead of being darkened as a whole.
    @Test func theScriptRunsInEveryFrame() {
        #expect(!DarkPages.script(for: nil).isForMainFrameOnly)
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A web view with dark pages on Always (and Pure black if asked), its page loaded by `load`.
    private func page(black: Bool = false, _ load: (WKWebView) -> Void) async throws -> WKWebView {
        DarkPages.mode = .always
        DarkPages.pureBlack = black
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        DarkPages.attach(to: webView)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            load(webView)
        }
        return webView
    }

    /// What `js` returns in the page once it's true-ish, waiting for the idle pass; the last answer after 3 seconds.
    private func eventually(_ webView: WKWebView, _ js: String, world: WKContentWorld = .page) async throws -> Any? {
        var last: Any?
        for _ in 0..<30 {
            last = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: world)
            if let b = last as? Bool, b { return b }
            if let s = last as? String, !s.isEmpty, s != "none" { return s }
            try await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    private static let photo = "data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="

    @Test func pureBlackDrawsWhiteAsBlack() async throws {
        let name = "DarkPagesFallbackTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer { DarkPages.defaults.removePersistentDomain(forName: name); DarkPages.defaults = saved; DarkPages.refreshAll() }
        let webView = try await page(black: true) {
            $0.loadHTMLString("<html><body style='background:#fff'><p>Light</p></body></html>", baseURL: URL(string: "https://black.test/"))
        }
        let color = try await eventually(webView, "const s = window.__zigzagDark.state(); return s.darkened ? s.color : ''", world: DarkPages.world)
        #expect(color as? String == "#000000")
        #expect(webView.underPageBackgroundColor.usingColorSpace(.sRGB)?.redComponent == 0)
    }

    /// A photo shown as a background, in a box with plenty inside it or tiny beside it, is turned back unless it's an
    /// icon or a drawing; so is a ::before showing a picture.
    @Test func backgroundPhotosAndPseudoPicturesAreFound() async throws {
        let name = "DarkPagesFallbackTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer { DarkPages.defaults.removePersistentDomain(forName: name); DarkPages.defaults = saved; DarkPages.refreshAll() }
        let many = String(repeating: "<span>x</span>", count: 80)
        let html = """
        <html><head><style>
        .hero { background: url(\(Self.photo)) center / cover no-repeat; width: 600px; height: 30px; }
        .icon { background-image: url(\(Self.photo)); width: 16px; height: 16px; }
        .drawing { background-image: url("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg'/>"); width: 200px; height: 200px; }
        .before::before { content: url(\(Self.photo)); }
        </style></head><body style='background:#fff'>
        <div class="hero" id="hero">\(many)</div><div class="icon" id="icon"></div><div class="drawing" id="drawing"></div>
        <p class="before" id="before">Quote</p>
        </body></html>
        """
        let webView = try await page { $0.loadHTMLString(html, baseURL: URL(string: "https://photos.test/")) }
        let found = try await eventually(webView, "return document.getElementById('hero').hasAttribute('\(DarkPages.imageMark)')")
        #expect(found as? Bool == true)
        let marks = try await webView.callAsyncJavaScript("""
            return [document.getElementById('icon').hasAttribute('\(DarkPages.imageMark)'),
                    document.getElementById('drawing').hasAttribute('\(DarkPages.imageMark)'),
                    document.getElementById('before').hasAttribute('\(DarkPages.beforeMark)')]
            """, arguments: [:], in: nil, contentWorld: .page) as? [Bool]
        #expect(marks == [false, false, true])
    }

    /// A picture inside an open shadow root is turned back too: the page's style doesn't reach in there.
    @Test func picturesInShadowRootsAreTurnedBack() async throws {
        let name = "DarkPagesFallbackTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer { DarkPages.defaults.removePersistentDomain(forName: name); DarkPages.defaults = saved; DarkPages.refreshAll() }
        let html = """
        <html><body style='background:#fff'><div id="host"></div>
        <script>document.getElementById('host').attachShadow({ mode: 'open' }).innerHTML = '<img id="pic" src="\(Self.photo)" width="80" height="80">';</script>
        </body></html>
        """
        let webView = try await page { $0.loadHTMLString(html, baseURL: URL(string: "https://shadow.test/")) }
        let filter = try await eventually(webView, """
            const f = getComputedStyle(document.getElementById('host').shadowRoot.getElementById('pic')).filter;
            return f.includes('invert') ? f : ''
            """)
        #expect((filter as? String)?.contains("invert") == true)
    }

    /// A light frame darkens itself and the page around it turns the frame back, so it comes out dark once, not
    /// light again; a frame that's dark already is shown as it is.
    @Test func framesDarkenThemselves() async throws {
        let name = "DarkPagesFallbackTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer { DarkPages.defaults.removePersistentDomain(forName: name); DarkPages.defaults = saved; DarkPages.refreshAll() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DarkPagesFrames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Each frame says how it's drawn: the page around can't look inside a frame from another file.
        let report = { (id: String) in
            "<script>addEventListener('load', () => setTimeout(() => parent.postMessage({ report: '\(id)', "
                + "filter: getComputedStyle(document.documentElement).filter }, '*'), 400));</script>"
        }
        try "<html><body style='background:#fff;color:#222'><p>Light frame</p>\(report("light"))</body></html>"
            .write(to: folder.appendingPathComponent("light.html"), atomically: true, encoding: .utf8)
        try "<html><body style='background:#111;color:#eee'><p>Dark frame</p>\(report("dark"))</body></html>"
            .write(to: folder.appendingPathComponent("dark.html"), atomically: true, encoding: .utf8)
        try """
        <html><body style='background:#fff'><script>window.reports = {};
        addEventListener('message', (e) => { if (e.data && e.data.report) reports[e.data.report] = e.data.filter; });</script>
        <iframe id="light" src="light.html"></iframe><iframe id="dark" src="dark.html"></iframe></body></html>
        """.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let index = folder.appendingPathComponent("index.html")
        let webView = try await page { $0.loadFileURL(index, allowingReadAccessTo: folder) }
        let both = try await eventually(webView, """
            return ['light', 'dark'].every((id) => document.getElementById(id).hasAttribute('\(DarkPages.frameMark)'))
            """)
        #expect(both as? Bool == true)
        let frames = try await eventually(webView, "return String(window.__zigzagDark.state().frames)", world: DarkPages.world)
        #expect(frames as? String == "2")
        let reports = try await eventually(webView, """
            return 'light' in reports && 'dark' in reports ? String(reports.light.includes('invert')) + ' ' + String(reports.dark.includes('invert')) : ''
            """)
        #expect(reports as? String == "true false")
    }
}

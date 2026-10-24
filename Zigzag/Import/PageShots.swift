import AppKit
import WebKit

/// Real pages for onboarding's preview window, captured once in the background: Wikipedia, and an ad-heavy
/// page with and without Zigzag's blocker. Nothing is saved, no sound plays, and nothing shows on screen;
/// until a capture is ready (or if there's no connection), the preview draws its own stand-in.
@MainActor final class PageShots: NSObject, WKNavigationDelegate {
    static let shared = PageShots()
    enum Shot: Hashable { case wikipedia, adsShown, adsBlocked }
    private(set) var images: [Shot: NSImage] = [:]
    let changed = Signal<Void>()
    private var window: NSWindow?
    private var views: [Shot: WKWebView] = [:]
    private var started = false

    /// A laptop-ish column: wide enough for a real layout, narrow enough to read once shrunk into the preview.
    private static let size = NSSize(width: 720, height: 620)
    private static let urls: [Shot: URL] = [
        .wikipedia: URL(string: "https://en.wikipedia.org/wiki/Main_Page")!,

    ]

    func start() {
        guard !started else { return }
        started = true
        // Off screen, but in a window, so the pages really render.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: Self.size.width, height: Self.size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        self.window = window
        // The ads page ships with Zigzag: a real page, the same every time, with and without its ads.
        if let file = Bundle.main.url(forResource: "ads", withExtension: "html"), let html = try? String(contentsOf: file, encoding: .utf8) {
            for (shot, cls) in [(Shot.adsShown, ""), (.adsBlocked, "blocked")] {
                let view = makeView()
                views[shot] = view
                view.loadHTMLString(html.replacingOccurrences(of: "BODYCLASS", with: cls), baseURL: nil)
            }
        }
        for (shot, url) in Self.urls {
            let view = makeView()
            views[shot] = view
            view.load(URLRequest(url: url, timeoutInterval: 20))
            _ = shot
            // Heavy pages may never quite finish; take what's there after a while.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak view] in
                guard let self, let view, self.views[shot] === view else { return }
                self.capture(shot, view)
            }
        }
    }

    private func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: configuration)
        view.navigationDelegate = self
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if view.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(view.method(for: occlusion), to: SetBool.self)(view, occlusion, false)
        }
        window?.contentView?.addSubview(view)
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let shot = views.first(where: { $0.value === webView })?.key else { return }
        // A moment for late images and ads to arrive, then one capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + (shot == .wikipedia ? 1.2 : 0.4)) { [weak self, weak webView] in
            guard let self, let webView, self.views[shot] === webView else { return }
            self.capture(shot, webView)
        }
    }

    private func capture(_ shot: Shot, _ webView: WKWebView) {
        do {
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, _ in
                MainActor.assumeIsolated {
                    if let image { self.images[shot] = image }
                    self.views[shot] = nil
                    webView.removeFromSuperview()
                    if self.views.isEmpty { self.window?.close(); self.window = nil }
                    self.changed.send(())
                }
            }
        }
    }
}

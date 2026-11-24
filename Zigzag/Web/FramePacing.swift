import AppKit
import WebKit

/// Pages draw at the display's full rate (`FeatureFlags.ownDefaults`). One that can't keep up while it scrolls is held
/// near 60 fps, WebKit's and Safari's default, until its tab goes to another site (#394). On a 120 Hz display a heavy
/// page's rendering updates take longer than a frame, and WebKit's scrolling waits on them, so the page moves in an
/// uneven mix of 8, 17 and 25 ms steps; held near 60, scrolling keeps the display's rate on its own.
///
/// The page's pace is read from its animation frames, in Zigzag's own script world, only while it scrolls. WebKit reads
/// the setting when a page is made or shown, so a held page is hidden and shown again before the screen next updates.
@MainActor
enum FramePacing {
    static let messageName = "zigzagFramePacing"

    /// Frame gaps in, whether to hold the page near 60 fps out. Once held, a page stays held until another site.
    struct Judge: Equatable {
        /// Frames are judged in windows at least this long, in ms of scrolling.
        static let window = 1000.0
        /// A window is slow when the page missed more than this share of the display's frames.
        static let slowShare = 0.25
        /// Of this many recent windows, `slowNeeded` slow ones hold the page.
        static let recent = 3
        static let slowNeeded = 2
        /// A gap this long is a pause or one long task, not the page's pace.
        static let pause = 100.0

        private(set) var site: String?
        private(set) var held = false
        /// Missed shares of the last windows, oldest first.
        private(set) var windows: [Double] = []
        /// Windows judged on this site.
        private(set) var judged = 0
        private var pending: [Double] = []

        init(site: String? = nil) { self.site = site }

        /// A page of `site` started: another site starts over. True when it's another site.
        mutating func visit(_ site: String) -> Bool {
            guard site != self.site else { return false }
            self = Judge(site: site)
            return true
        }

        mutating func hold() {
            held = true
            pending = []
        }

        /// Adds the gaps between a page's frames, in ms, on a display drawing every `interval` ms. True when this
        /// holds the page.
        mutating func add(_ gaps: [Double], interval: Double) -> Bool {
            guard !held, interval > 0 else { return false }
            pending += gaps.filter { $0 > 0 && $0 < Self.pause }
            guard pending.reduce(0, +) >= Self.window else { return false }
            windows = Array((windows + [Self.missed(pending, interval: interval)]).suffix(Self.recent))
            judged += 1
            pending = []
            if windows.filter({ $0 > Self.slowShare }).count >= Self.slowNeeded { held = true }
            return held
        }

        /// The share of the display's frames that brought nothing new of the page.
        static func missed(_ gaps: [Double], interval: Double) -> Double {
            let spent = gaps.reduce(0, +)
            guard spent > 0, interval > 0 else { return 0 }
            return max(0, 1 - Double(gaps.count) * interval / spent)
        }
    }

    /// Main frame only. Asks once whether to measure; then, from a scroll until 200 ms after the last one, sends the
    /// gaps between animation frames about once a second. Stops when told to.
    static let script = WKUserScript(source: """
    (() => {
      if (window !== window.top || window.__zigzagPacing) return;
      window.__zigzagPacing = true;
      const post = (body) => window.webkit.messageHandlers.\(messageName).postMessage(body);
      post({}).then((measures) => {
        if (!measures) return;
        let gaps = [], spent = 0, last = 0, until = 0, running = false, done = false;
        const send = () => {
          if (!gaps.length) return;
          const sent = gaps;
          gaps = []; spent = 0;
          post({ gaps: sent }).then((more) => { if (!more) stop(); }, () => {});
        };
        const frame = (t) => {
          if (last) { const gap = Math.round((t - last) * 10) / 10; gaps.push(gap); spent += gap; }
          last = t;
          if (spent >= 1000) send();
          if (done || document.hidden || performance.now() > until) { running = false; last = 0; send(); return; }
          requestAnimationFrame(frame);
        };
        const scrolled = () => {
          if (done || document.readyState !== 'complete') return;
          until = performance.now() + 200;
          if (!running) { running = true; requestAnimationFrame(frame); }
        };
        const stop = () => { done = true; removeEventListener('scroll', scrolled, true); };
        addEventListener('scroll', scrolled, { capture: true, passive: true });
      }, () => {});
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    static func attach(to controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.addScriptMessageHandler(Messages.shared, contentWorld: .defaultClient, name: messageName)
    }

    private final class Page {
        var judge = Judge()
    }

    private static let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    /// Sites held this session, outside private windows: their next pages start held.
    private(set) static var heldSites: Set<String> = []

    /// Whether this web view is held near 60 fps for its site.
    static func holds(_ webView: WKWebView) -> Bool { pages.object(forKey: webView)?.judge.held == true }

    /// Low Power Mode or a hot Mac: WebKit slows pages itself, so their pace says nothing about them.
    private static var webKitThrottles: Bool {
        PowerSaving.lowPowerMode || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// What a page sent: `gaps`, or nothing as it starts. Answers whether it should keep measuring.
    static func received(_ body: [String: Any], site: String, from webView: WKWebView) -> Bool {
        // Held near 60 by choice (Settings › Developer › Feature Flags): nothing to measure, nothing to change.
        guard !site.isEmpty, !FeatureFlags.pagesStartNear60FPS else { return false }
        let page = pages.object(forKey: webView) ?? Page()
        pages.setObject(page, forKey: webView)
        let wasHeld = page.judge.held
        if page.judge.visit(site) {
            if heldSites.contains(site) {
                hold(webView, page, wasHeld: wasHeld)
                debugLog("framepacing \(site) held near 60 fps: held earlier this session")
                return false
            }
            if wasHeld {
                setNear60(false, webView)
                debugLog("framepacing \(site) back to full rate: another site")
            }
        }
        guard !page.judge.held else { return false }
        guard let gaps = (body["gaps"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }) else { return true }
        guard !webKitThrottles, let fps = webView.window?.screen?.maximumFramesPerSecond, fps > 60 else { return true }
        let before = page.judge.judged
        let held = page.judge.add(gaps, interval: 1000 / Double(fps))
        if page.judge.judged != before, let last = page.judge.windows.last {
            debugLog("framepacing \(site) missed \(Int((last * 100).rounded()))% of \(fps) Hz frames while scrolling")
        }
        guard held else { return true }
        if webView.configuration.websiteDataStore.isPersistent { heldSites.insert(site) }
        hold(webView, page, wasHeld: false)
        let shares = page.judge.windows.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: " ")
        debugLog("framepacing \(site) held near 60 fps: missed \(shares) of frames in the last windows")
        return false
    }

    private static func hold(_ webView: WKWebView, _ page: Page, wasHeld: Bool) {
        page.judge.hold()
        if !wasHeld { setNear60(true, webView) }
    }

    private static func setNear60(_ on: Bool, _ webView: WKWebView) {
        FeatureFlags.engine.set(on, key: FeatureFlags.sixtyFPSKey, in: webView.configuration.preferences)
        refresh(webView)
    }

    /// WebKit takes a page's new frame rate when it's next shown: hidden and shown again before the screen updates.
    /// A page out of sight takes it when it's shown.
    private static func refresh(_ webView: WKWebView) {
        let after = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard webView.window != nil, !webView.isHidden, webView.responds(to: after) else { return }
        typealias After = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let hidden = Hidden(webView, focus: webView.window?.firstResponder)
        webView.isHidden = true
        unsafeBitCast(webView.method(for: after), to: After.self)(webView, after, { hidden.show() })
        // Should WebKit not answer, shown again on the next turn.
        DispatchQueue.main.async { hidden.show() }
    }

    /// A web view hidden for a moment, shown again once.
    private final class Hidden: @unchecked Sendable {
        private weak var webView: WKWebView?
        /// What had the keyboard: hiding the page takes it away, so it gets it back.
        private weak var focus: NSResponder?
        private var shown = false

        init(_ webView: WKWebView, focus: NSResponder?) {
            self.webView = webView
            self.focus = focus
        }

        func show() {
            MainActor.assumeIsolated {
                guard !shown else { return }
                shown = true
                webView?.isHidden = false
                if let focus, let window = webView?.window, window.firstResponder !== focus { window.makeFirstResponder(focus) }
            }
        }
    }

    private final class Messages: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, let webView = message.webView else { return replyHandler(false, nil) }
            let host = message.frameInfo.securityOrigin.host
            let site = host.isEmpty ? "" : PublicSuffix.registrableDomain(host) ?? host
            replyHandler(FramePacing.received(message.body as? [String: Any] ?? [:], site: site, from: webView), nil)
        }
    }
}

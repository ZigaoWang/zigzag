import AppKit
import WebKit

/// Pages draw at the display's full rate (`FeatureFlags.ownDefaults`). One that can't keep up while it scrolls is held
/// near 60 fps, WebKit's and Safari's default, until its tab goes to another site (#394). On a 120 Hz display a heavy
/// page's rendering updates take longer than a frame, and WebKit's scrolling waits on them, so the page moves in an
/// uneven mix of 8, 17 and 25 ms steps; held near 60, scrolling keeps the display's rate on its own.
///
/// The page's pace is read from its animation frames, in Zigzag's own script world, only while it scrolls. WebKit reads
/// the setting when a page is made or shown, so a held page is hidden and shown again once scrolling stops, or at its
/// next page. Held sites are kept across launches; in Low Power Mode or on a hot Mac, pages start near 60 (#519).
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

    /// Sites held near 60, so their pages start held after a relaunch too: the latest `maxSites`, each for `keptFor`
    /// after it was last held. Never from a private window; cleared with History or the site's data.
    struct HeldSites: Equatable, Codable {
        static let maxSites = 200
        static let keptFor: TimeInterval = 30 * 24 * 60 * 60

        /// When each was last held.
        private(set) var sites: [String: Date] = [:]

        func contains(_ site: String, now: Date = Date()) -> Bool {
            guard let date = sites[site] else { return false }
            return now.timeIntervalSince(date) < Self.keptFor
        }

        mutating func insert(_ site: String, now: Date = Date()) {
            sites[site] = now
            sites = sites.filter { now.timeIntervalSince($0.value) < Self.keptFor }
            if sites.count > Self.maxSites {
                for old in sites.sorted(by: { $0.value < $1.value }).prefix(sites.count - Self.maxSites) { sites[old.key] = nil }
            }
        }

        /// Lets go of one site (covering its subdomains, and the site it's under), the ones held since a time, or all.
        mutating func forget(site: String? = nil, since: Date? = nil) {
            if let site {
                sites = sites.filter { key, _ in !(key == site || key.hasSuffix("." + site) || site.hasSuffix("." + key)) }
            } else if let since {
                sites = sites.filter { $0.value < since }
            } else {
                sites = [:]
            }
        }
    }

    static let heldFileName = "Held Near 60.plist"
    private static var file: URL { Paths.file(heldFileName) }
    private static var loadedHeld: HeldSites?
    private static let disk = DispatchQueue(label: "app.zigzag.frame-pacing", qos: .utility)

    /// The sites held, read from the data folder once.
    static var held: HeldSites {
        get {
            if let loadedHeld { return loadedHeld }
            let read = (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode(HeldSites.self, from: $0) } ?? HeldSites()
            loadedHeld = read
            return read
        }
        set {
            guard newValue != held else { return }
            loadedHeld = newValue
            let url = file
            let data = newValue.sites.isEmpty ? nil : try? PropertyListEncoder().encode(newValue)
            disk.async {
                guard let data else { try? FileManager.default.removeItem(at: url); return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// History or a site's data cleared: the sites held go with it.
    static func forget(site: String? = nil, since: Date? = nil) { held.forget(site: site, since: since) }

    /// Waits for the list to be written, and forgets what was read (tests).
    static func reloadHeld() {
        disk.sync {}
        loadedHeld = nil
    }

    /// Main frame only. Asks once whether to measure; then, from a scroll until 200 ms after the last one, sends the
    /// gaps between animation frames about once a second. Nothing runs between scrolls. Told to settle, it says when
    /// scrolling has been still for `stillFor` ms and stops; told to stop, it stops.
    static let stillFor = 300

    static let script = WKUserScript(source: """
    (() => {
      if (window !== window.top || window.__zigzagPacing) return;
      window.__zigzagPacing = true;
      const post = (body) => window.webkit.messageHandlers.\(messageName).postMessage(body);
      post({}).then((measures) => {
        if (!measures) return;
        let gaps = [], spent = 0, last = 0, until = 0, running = false, done = false, settling = false, still = 0;
        const send = () => {
          if (!gaps.length || settling) return;
          const sent = gaps;
          gaps = []; spent = 0;
          post({ gaps: sent }).then((more) => { if (more === 'settle') settle(); else if (!more) stop(); }, () => {});
        };
        const frame = (t) => {
          if (settling) { running = false; last = 0; return; }
          if (last) { const gap = Math.round((t - last) * 10) / 10; gaps.push(gap); spent += gap; }
          last = t;
          if (spent >= 1000) send();
          if (done || document.hidden || performance.now() > until) { running = false; last = 0; send(); return; }
          requestAnimationFrame(frame);
        };
        const stop = () => { done = true; clearTimeout(still); removeEventListener('scroll', scrolled, true); };
        const stilled = () => { stop(); post({ still: true }).catch(() => {}); };
        const settle = () => { settling = true; gaps = []; clearTimeout(still); still = setTimeout(stilled, \(stillFor)); };
        const scrolled = () => {
          if (done || document.readyState !== 'complete') return;
          if (settling) { clearTimeout(still); still = setTimeout(stilled, \(stillFor)); return; }
          until = performance.now() + 200;
          if (!running) { running = true; requestAnimationFrame(frame); }
        };
        addEventListener('scroll', scrolled, { capture: true, passive: true });
      }, () => {});
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    static func attach(to controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.addScriptMessageHandler(Messages.shared, contentWorld: .defaultClient, name: messageName)
        watchPower()
    }

    private final class Page {
        var judge = Judge()
        /// Whether the page's setting holds it near 60 now.
        var near60: Bool
        init(near60: Bool) { self.near60 = near60 }
    }

    private static let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    /// Pages made near 60 because WebKit was slowing them (`throttled`).
    private static let madeNear60 = NSHashTable<WKPreferences>.weakObjects()

    #if DEBUG
    /// perfsuite: pages are judged but never held, so every run scrolls at the same rate.
    static var keepsRate = false
    #endif

    /// Whether this web view is held near 60 fps, for its site or while WebKit slows pages.
    static func holds(_ webView: WKWebView) -> Bool { pages.object(forKey: webView)?.near60 == true }

    /// Low Power Mode or a hot Mac: WebKit slows pages itself, so they start near 60 and aren't lifted above it.
    static var throttled: () -> Bool = {
        PowerSaving.lowPowerMode || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// A page being made (`FeatureFlags.apply`): near 60 while WebKit slows pages, unless every page already is.
    static func starting(_ preferences: WKPreferences) {
        guard !FeatureFlags.pagesStartNear60FPS, throttled() else { return }
        FeatureFlags.engine.set(true, key: FeatureFlags.sixtyFPSKey, in: preferences)
        madeNear60.add(preferences)
    }

    /// What the page script hears back.
    enum Reply: Equatable {
        case measure, stop
        /// Held: say when scrolling has stopped, so the page's rate changes then.
        case settle

        var body: Any {
            switch self {
            case .measure: true
            case .stop: false
            case .settle: "settle"
            }
        }
    }

    private static func page(for webView: WKWebView) -> Page {
        if let page = pages.object(forKey: webView) { return page }
        let page = Page(near60: madeNear60.contains(webView.configuration.preferences))
        pages.setObject(page, forKey: webView)
        return page
    }

    /// What a page sent: nothing as it starts, `gaps`, or `still` once scrolling stopped after it was held.
    /// `rate` stands in for the display's (tests).
    static func received(_ body: [String: Any], site: String, from webView: WKWebView, rate: Int? = nil) -> Reply {
        // Held near 60 by choice (Settings › Developer › Feature Flags): nothing to measure, nothing to change.
        guard !site.isEmpty, !FeatureFlags.pagesStartNear60FPS else { return .stop }
        let page = page(for: webView)
        if body["still"] != nil {
            apply(webView, page)
            return .stop
        }
        guard let raw = body["gaps"] as? [Any] else {
            // A page starting: another site starts over, and one held before starts held, before any scroll.
            if page.judge.visit(site), held.contains(site) {
                page.judge.hold()
                debugLog("framepacing \(site) held near 60 fps: held before")
            }
            apply(webView, page)
            return page.judge.held ? .stop : .measure
        }
        guard !page.judge.held else { return .stop }
        let gaps = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard let fps = rate ?? webView.window?.screen?.maximumFramesPerSecond, fps > 60 else { return .measure }
        // Slowed by WebKit, the page is judged at the 60 it's held to.
        let interval = 1000 / Double(throttled() ? 60 : fps)
        let before = page.judge.judged
        let holds = page.judge.add(gaps, interval: interval)
        if page.judge.judged != before, let last = page.judge.windows.last {
            debugLog("framepacing \(site) missed \(Int((last * 100).rounded()))% of \(Int(1000 / interval)) Hz frames while scrolling")
        }
        guard holds else { return .measure }
        #if DEBUG
        if keepsRate { page.judge = Judge(site: site); return .measure }
        #endif
        if webView.configuration.websiteDataStore.isPersistent { held.insert(site) }
        debugLog("framepacing \(site) held near 60 fps once scrolling stops: missed \(page.judge.windows.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: " "))")
        return .settle
    }

    /// The page's setting brought in line: near 60 when held or while WebKit slows pages, the full rate otherwise.
    private static func apply(_ webView: WKWebView, _ page: Page) {
        let wanted = page.judge.held || throttled()
        guard wanted != page.near60 else { return }
        page.near60 = wanted
        setNear60(wanted, webView)
    }

    private static var watching = false

    /// Low Power Mode or the Mac's heat changed: pages out of sight take the new rate when next shown; pages in
    /// sight at their next page, never mid-scroll.
    private static func watchPower() {
        guard !watching else { return }
        watching = true
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { powerChanged() }
            }
        }
    }

    static func powerChanged() {
        guard !FeatureFlags.pagesStartNear60FPS else { return }
        for webView in pages.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            guard webView.window == nil || webView.isHidden, let page = pages.object(forKey: webView) else { continue }
            apply(webView, page)
        }
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
            replyHandler(FramePacing.received(message.body as? [String: Any] ?? [:], site: site, from: webView).body, nil)
        }
    }
}

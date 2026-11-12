import AppKit
import WebKit

/// Pop-ups a page opens on its own, without a click, are blocked, as in every browser. Rather than failing in silence
/// (a payment or a sign-in that just doesn't appear), Zigzag says so and offers to allow them.
@MainActor
enum PopupNotice {
    /// When each window last said a site's pop-up was blocked: once every few seconds is enough, so a page that
    /// opens window after window can't keep the toast coming up under the pointer.
    private static var lastNotice: [String: Date] = [:]
    static let noticeInterval: TimeInterval = 10

    /// Whether to say so now for `key` (a window and a site); if so, it's noted that it did.
    static func shouldNotice(_ key: String, now: Date = Date()) -> Bool {
        lastNotice = lastNotice.filter { now.timeIntervalSince($0.value) < noticeInterval }
        guard lastNotice[key] == nil else { return false }
        lastNotice[key] = now
        return true
    }

    /// Whether a blocked pop-up is one to say anything about, and the address to offer: a web page's, or none
    /// (pages often open an empty window, then send it where it goes). Anything else (javascript:, data:) stays
    /// quietly blocked.
    static func offered(_ url: URL?) -> (say: Bool, url: URL?) {
        guard let url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" else { return (true, nil) }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? (true, url) : (false, nil)
    }

    /// Only the page itself reports, not frames in it: blocked pop-ups from ads stay quietly blocked.
    private static func report(_ action: WKNavigationAction, from page: URL?) {
        let source: WKFrameInfo? = action.sourceFrame
        guard let source, source.isMainFrame, let webView = source.webView else { return }
        let (say, url) = offered(action.request.url)
        guard say else { return }
        let site = SiteOrigin.of(page) ?? ""
        // Said once WebKit has its answer, not while it waits for one.
        Task { @MainActor [weak webView] in
            guard let webView else { return }
            // From a sign-in popup's own page: said in the browser window behind it, the one that opened it.
            if let popup = PopupWindowController.all.first(where: { $0.webView === webView }) {
                guard let browser = popup.parentWindow?.windowController as? BrowserWindowController,
                      shouldNotice("\(ObjectIdentifier(browser))|\(site)") else { return }
                blocked(url, from: page, opener: nil, in: browser)
                return
            }
            guard let webView = webView as? BrowserWebView, let tab = webView.owner,
                  let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }),
                  shouldNotice("\(ObjectIdentifier(controller))|\(site)") else { return }
            blocked(url, from: page, opener: tab, in: controller)
        }
    }

    /// Whether a page may open the window it asks for. WebKit hands every request here (its own blocker is off, as
    /// it can only say yes or no for every site at once): one that comes from a click opens, and so does any from a
    /// site you've allowed pop-ups for, as a real pop-up the page can talk to. That's what sign-ins need, such as
    /// Teams asking for permission after a click inside one of its apps, a step WebKit no longer counts as the
    /// click. Anything else returns nothing, and is said to be blocked.
    static func allows(_ action: WKNavigationAction, from page: URL?, isPrivate: Bool) -> Bool {
        if isUserInitiated(action) { return true }
        if !isPrivate, let origin = SiteOrigin.of(page), SitePermissions.popups(origin: origin) { return true }
        report(action, from: page)
        return false
    }

    /// WebKit's own record of whether a click or a key started it (not public API, but long-standing); without
    /// it, whether the last thing you did was a click or a key a moment ago.
    static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        let selector = NSSelectorFromString("_isUserInitiated")
        if action.responds(to: selector), let initiated = action.value(forKey: "_isUserInitiated") as? Bool { return initiated }
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else { return false }
        return [.leftMouseUp, .leftMouseDown, .otherMouseUp, .keyDown].contains(event.type)
    }

    /// A pop-up the page opened on its own: on a site you've allowed, it opens; elsewhere a toast offers to allow
    /// the site's pop-ups from now on. A pop-up opened later than asked can't report back to the page (a sign-in or a
    /// payment would never finish), so allowing doesn't open this one: the page's own button, clicked again, opens a
    /// real one. A private window remembers nothing about a site, so there it offers to open this one in a tab.
    /// Site Controls takes it back.
    static func blocked(_ url: URL?, from page: URL?, opener: Tab?, in controller: BrowserWindowController) {
        // Kept per origin: allowing http://localhost:3000 doesn't allow http://localhost:3001.
        let origin = SiteOrigin.of(page)
        let isPrivate = controller.tabManager.isPrivate
        let allowed = !isPrivate && origin.map { SitePermissions.popups(origin: $0) } == true
        Diagnostics.note(allowed ? "Pop-up opened as a tab" : "Pop-up blocked", site: origin.map(SiteOrigin.label) ?? "", isPrivate: isPrivate)
        if allowed {
            if let url { controller.open(url, disposition: .foregroundTab, opener: opener, allowSwitch: false) }
            return
        }
        // Blocked in Site Controls: blocked without a word, as chosen.
        if let origin, !isPrivate, SitePermissions.choice(.popups, origin: origin) == .block { return }
        SitePermissions.noteAsked(.popups, origin: origin, isPrivate: isPrivate)
        if let origin, !isPrivate {
            Toast.show(String(localized: "Pop-up blocked", comment: "Toast when Zigzag blocks a page's pop-up window."), symbol: "macwindow.badge.plus", action: (String(localized: "Always Allow", comment: "Button in the toast when Zigzag blocks a page's pop-up: allows the site's pop-ups from now on."), { [weak controller] in
                SitePermissions.setPopups(true, origin: origin)
                guard let controller else { return }
                Toast.show(String(localized: "Pop-ups allowed. Click the button again.", comment: "Toast after allowing a site's pop-ups."), symbol: "macwindow.badge.plus", duration: 4, in: controller)
            }), duration: 6, in: controller)
        } else if let url {
            Toast.show(String(localized: "Pop-up blocked", comment: "Toast when Zigzag blocks a page's pop-up window."), symbol: "macwindow.badge.plus", action: (String(localized: "Open in New Tab", comment: "Button in the toast when Zigzag blocks a page's pop-up: opens it as a tab instead."), { [weak controller, weak opener] in
                controller?.open(url, disposition: .foregroundTab, opener: opener, allowSwitch: false)
            }), duration: 6, in: controller)
        }
    }
}

import AppKit
import WebKit

/// A kept permission changing has to reach the page that is open now, not only the next one (#545). One place decides
/// what can be taken away while a page is open and how, so every way of changing an answer behaves the same: the Site
/// Controls row, Reset Permissions, or a question answered on the page.
///
/// A change applies to the page that is open now, without a reload. Camera and microphone are held by the page, so a
/// Block ends the capture at once, and the page asks again on its next load, where the kept answer refuses it without
/// a question. Location is Zigzag's own source, so a Block stops the updates and fails the watch at once; WebKit's
/// per-page decision is what a reload refreshes. WebRTC's constructor is fixed for the life of the page, so a Block
/// replaces it and closes the calls that are up now, while allowing it again is what waits for the next load.
/// Notifications are the system's, and a Block takes them away now. Pop-ups, downloads and apps to open are kept for
/// the site and used at the moment of use, so there is nothing held open to take away, and the row says the answer
/// applies next time rather than pretending otherwise.
@MainActor
enum LivePermissions {
    /// Whether a change to this permission can take something away from a page that is already open.
    static func cutsLive(_ permission: SitePermission) -> Bool {
        switch permission {
        case .camera, .microphone, .location, .webRTC, .notifications: true
        case .popups, .downloads, .apps, .screen: false
        }
    }

    /// A page whose origin is the one the answer was kept for. Pages without an origin (file:, about:) keep nothing
    /// and are never cut: there is no answer of theirs to change.
    static func pages(of origin: String, in tabs: [Tab]) -> [Tab] {
        tabs.filter { tab in
            guard !tab.isClosed, let url = tab.url ?? tab.webView?.url else { return false }
            return SiteOrigin.of(url) == origin
        }
    }

    /// The tabs among `tabs` a change for `origin` has to reach.
    static func cutPages(for permission: SitePermission, origin: String, in tabs: [Tab]) -> [Tab] {
        guard cutsLive(permission) else { return [] }
        return pages(of: origin, in: tabs)
    }

    /// Applies a kept answer to the pages of `origin` that are open now. `allowed` is what the site is allowed now;
    /// false means the right is taken away at once.
    static func apply(_ permission: SitePermission, origin: String, allowed: Bool, to tabs: [Tab]) {
        guard cutsLive(permission) else { return }
        for tab in cutPages(for: permission, origin: origin, in: tabs) {
            apply(permission, to: tab, allowed: allowed)
        }
    }

    /// One page, one permission. Separated out so the panel, the capture menu and a question can all call it, and so
    /// a test can watch one page without a window.
    static func apply(_ permission: SitePermission, to tab: Tab, allowed: Bool) {
        let origin = SiteOrigin.of(tab.url) ?? ""
        switch permission {
        // Ending the capture is immediate either way, so a Block takes it away now and an Allow lets the page ask for
        // it again without a reload.
        case .camera: allowed ? () : tab.stopCamera()
        case .microphone: allowed ? () : tab.stopMicrophone()
        // Zigzag is the page's location source, so the guard goes on and off live: neither direction waits for a load.
        case .location: allowed ? PageLocation.shared.allow(origin: origin, in: tab)
                                : PageLocation.shared.revoke(origin: origin, in: tab)
        // The constructor is fixed for the life of the page: a Block closes the calls that are up, and allowing it
        // again is what waits for the next load.
        case .webRTC: allowed ? () : WebRTCProtection.revoke(in: tab)
        case .notifications: allowed ? () : WebNotifications.shared.removeAll(origin: origin)
        case .popups, .downloads, .apps, .screen: break
        }
    }

    /// Every open tab of the app, across its windows and Minis: a kept answer is the site's, wherever its page is.
    static var openTabs: [Tab] {
        var tabs: [Tab] = []
        for controller in WindowManager.shared.controllers { tabs += controller.tabManager.allTabs }
        tabs += MiniWindowController.all.map(\.tab)
        return tabs
    }

    /// Observes kept answers changing, for the life of the app: the one place that turns a stored change into a cut
    /// on the pages that are open. Called once at launch (`AppDelegate`), and by tests that need it.
    static func start() {
        guard token == nil else { return }
        token = SitePermissions.choiceChanged.observe { permission, origin in
            MainActor.assumeIsolated { keptAnswerChanged(permission, origin: origin) }
        }
    }

    private static var token: SignalToken?

    /// The stored answer changing: cut the open pages of that site, if the answer now takes something away.
    static func keptAnswerChanged(_ permission: SitePermission, origin: String) {
        guard cutsLive(permission) else { return }
        let allowed = isAllowedNow(permission, origin: origin)
        apply(permission, origin: origin, allowed: allowed, to: openTabs)
    }

    /// What the site is allowed now, as the page would see it on its next use.
    static func isAllowedNow(_ permission: SitePermission, origin: String) -> Bool {
        if permission == .webRTC { return WebRTCProtection.choice(origin: origin, in: nil) == .allow }
        switch SitePermissions.choice(permission, origin: origin) {
        case .allow: return true
        case .block: return false
        // Ask is not a grant: the page has to ask again, so nothing is held open for it.
        case .ask: return false
        }
    }
}

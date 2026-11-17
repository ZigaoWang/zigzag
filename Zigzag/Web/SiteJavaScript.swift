import Foundation
import WebKit

/// JavaScript for every site or one site (#282), like Chrome's: Settings › Privacy › JavaScript says Allowed (as it
/// starts) or Not Allowed, and Site Controls' JavaScript row gives one site its own choice, which then holds whatever
/// the setting says. A site covers its subdomains, as the other choices kept for a site do (`ContentBlocker.site`).
///
/// It's WebKit's own switch for a page's scripts (`WKWebpagePreferences.allowsContentJavaScript`), set as the tab
/// decides each navigation, so a page gets its scripts or not as it's made: a change for the page you're on takes a
/// reload. WebKit decides each frame on its own, so a frame follows the page it's in, whatever its own site, as in
/// Chrome. Only the page's own scripts stop. Zigzag's scripts (dark pages, passkeys,
/// notifications, cookie banners, the ad blocker's) and extensions' content scripts are the app's, and still run.
///
/// Only web pages (http, https) and files from the Mac follow it. Zigzag's own pages (History, Settings), its error
/// pages, extensions' pages and Reader always have their scripts.
///
/// A private window follows the setting and the choices made for sites elsewhere; what you choose in one is for that
/// tab only (`Tab.javaScriptHere`), never kept.
@MainActor
enum SiteJavaScript {
    /// Where the setting and the sites' choices are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    private static let settingKey = "JavaScriptAllowed"
    private static let onKey = "JavaScriptOnSites"
    private static let offKey = "JavaScriptOffSites"

    /// Settings › Privacy › JavaScript: Allowed unless you choose Not Allowed.
    static var isAllowed: Bool {
        get { defaults.object(forKey: settingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: settingKey) }
    }

    /// Sites (hosts without "www.") whose JavaScript is on, or off, whatever the setting says.
    static var sitesOn: Set<String> {
        get { Set(defaults.stringArray(forKey: onKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: onKey) }
    }

    static var sitesOff: Set<String> {
        get { Set(defaults.stringArray(forKey: offKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: offKey) }
    }

    /// The site a choice is kept under: a web page's host without "www.". Files and Zigzag's own pages have none.
    static func site(of url: URL?) -> String? {
        guard isWeb(url) else { return nil }
        return ContentBlocker.site(of: url)
    }

    private static func isWeb(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }

    /// Pages the setting is for: the web's and files from the Mac. Anything else is Zigzag's or an extension's.
    static func follows(_ url: URL?) -> Bool { isWeb(url) || url?.scheme?.lowercased() == "file" }

    /// Whether a page runs its scripts: a choice for this tab alone (a private window's) comes first, then the one
    /// kept for the site, then the setting.
    nonisolated static func allows(setting: Bool, kept: Bool?, here: Bool?) -> Bool {
        here ?? kept ?? setting
    }

    /// The choice kept for a site or a site it's part of: the nearest one, so news.example.com's own beats
    /// example.com's.
    static func kept(site: String) -> Bool? {
        let covering = { (sites: Set<String>) in sites.filter { site == $0 || site.hasSuffix("." + $0) }.map(\.count).max() }
        let on = covering(sitesOn), off = covering(sitesOff)
        guard on != nil || off != nil else { return nil }
        return (on ?? -1) > (off ?? -1)
    }

    /// The site's own choice, as Settings › Privacy › Sites lists it: only the one kept under that very name.
    static func choice(forSite site: String) -> Bool? {
        sitesOff.contains(site) ? false : sitesOn.contains(site) ? true : nil
    }

    /// Whether the page at `url` runs its scripts, with a private tab's own choices given (`Tab.javaScriptHere`).
    /// An error page Zigzag shows in its place always does, whatever the site's choice.
    static func allows(_ url: URL?, here choices: [String: Bool]?, errorPage: Bool = false) -> Bool {
        guard follows(url), !errorPage else { return true }
        let site = site(of: url)
        return allows(setting: isAllowed, kept: site.flatMap(kept(site:)), here: site.flatMap { choices?[$0] })
    }

    static func allows(_ url: URL?, in tab: Tab?) -> Bool { allows(url, here: tab?.javaScriptHere) }

    /// The site has a choice of its own, not just the setting: kept, or made in this private tab.
    static func isOwn(_ url: URL?, in tab: Tab?) -> Bool {
        guard let site = site(of: url) else { return false }
        return tab?.javaScriptHere[site] != nil || kept(site: site) != nil
    }

    /// Keeps a choice for the site of `url`; nil forgets it, so it follows the setting again. A site it's part of, or
    /// one of its own subdomains, keeps its choice: the nearest one counts (`kept(site:)`).
    static func setChoice(_ allowed: Bool?, for url: URL?) {
        guard let site = site(of: url) else { return }
        setChoice(allowed, forSite: site)
    }

    static func setChoice(_ allowed: Bool?, forSite site: String) {
        var on = sitesOn, off = sitesOff
        on.remove(site)
        off.remove(site)
        if let allowed { if allowed { on.insert(site) } else { off.insert(site) } }
        sitesOn = on
        sitesOff = off
    }

    /// Allowed or Not Allowed for the site of `url`, from Site Controls: kept for it, or in a private window for `tab`
    /// alone. The page in `tab` reloads into it at once when that changes it; any other tab, once it next loads.
    static func choose(_ allowed: Bool, for url: URL?, in tab: Tab?) {
        guard let site = site(of: url) else { return }
        let before = tab.map { allows(page(of: $0), in: $0) }
        if let tab, tab.isPrivate {
            tab.javaScriptHere[site] = allowed
        } else {
            setChoice(allowed, forSite: site)
        }
        guard let tab, let before, Self.site(of: page(of: tab)) == site, before != allows(page(of: tab), in: tab) else { return }
        Diagnostics.note("JavaScript", site: site, allowed ? "allowed, reloaded" : "not allowed, reloaded", isPrivate: tab.isPrivate)
        tab.reload()
    }

    /// One site's own choice forgotten (Forget in Settings › Privacy › Sites).
    static func forget(site: String) { setChoice(nil, forSite: site) }

    /// Every site's choice forgotten (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        sitesOn = []
        sitesOff = []
    }

    /// Sets the page's scripts on or off for a navigation's preferences: `url` is the page's (for a frame, the page
    /// it's in).
    static func apply(to preferences: WKWebpagePreferences, for url: URL?, here choices: [String: Bool]?, errorPage: Bool) {
        preferences.allowsContentJavaScript = allows(url, here: choices, errorPage: errorPage)
    }

    /// The page the tab shows, or the one it's going to before any.
    private static func page(of tab: Tab) -> URL? { tab.webView?.url ?? tab.url }
}

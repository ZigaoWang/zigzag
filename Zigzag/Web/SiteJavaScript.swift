import Foundation
import WebKit

/// JavaScript on or off globally or per site (#282), as in Chrome: Settings › Privacy › JavaScript (Allowed by
/// default), with per-site overrides from Site Controls. A site covers its subdomains (`ContentBlocker.site`). Uses
/// `WKWebpagePreferences.allowsContentJavaScript`, set per navigation, so a change takes a reload. Frames follow
/// their page, as in Chrome. Only page scripts stop; Zigzag's own scripts (dark pages, passkeys, notifications,
/// cookie banners, ad blocker) and extension content scripts still run. Applies to http(s) and file pages only;
/// Zigzag's pages, error pages, extension pages and Reader always run scripts. Private windows follow the setting and
/// kept choices; choices made there are per tab (`Tab.javaScriptHere`) and never kept.
@MainActor
enum SiteJavaScript {
    /// Tests use their own.
    static var defaults: UserDefaults = .standard
    private static let settingKey = "JavaScriptAllowed"
    private static let onKey = "JavaScriptOnSites"
    private static let offKey = "JavaScriptOffSites"

    static var isAllowed: Bool {
        get { defaults.object(forKey: settingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: settingKey) }
    }

    /// Hosts without "www." overriding the setting.
    static var sitesOn: Set<String> {
        get { Set(defaults.stringArray(forKey: onKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: onKey) }
    }

    static var sitesOff: Set<String> {
        get { Set(defaults.stringArray(forKey: offKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: offKey) }
    }

    /// Host without "www."; files and Zigzag's pages have none.
    static func site(of url: URL?) -> String? {
        guard isWeb(url) else { return nil }
        return ContentBlocker.site(of: url)
    }

    private static func isWeb(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }

    /// Web pages and local files; everything else is Zigzag's or an extension's.
    static func follows(_ url: URL?) -> Bool { isWeb(url) || url?.scheme?.lowercased() == "file" }

    /// A private tab's choice first, then the site's, then the setting.
    nonisolated static func allows(setting: Bool, kept: Bool?, here: Bool?) -> Bool {
        here ?? kept ?? setting
    }

    /// The most specific match wins, so news.example.com beats example.com.
    static func kept(site: String) -> Bool? {
        let covering = { (sites: Set<String>) in sites.filter { site == $0 || site.hasSuffix("." + $0) }.map(\.count).max() }
        let on = covering(sitesOn), off = covering(sitesOff)
        guard on != nil || off != nil else { return nil }
        return (on ?? -1) > (off ?? -1)
    }

    /// Only the choice under this exact name, for Settings › Privacy › Sites.
    static func choice(forSite site: String) -> Bool? {
        sitesOff.contains(site) ? false : sitesOn.contains(site) ? true : nil
    }

    /// With a private tab's choices (`Tab.javaScriptHere`). Error pages always run scripts.
    static func allows(_ url: URL?, here choices: [String: Bool]?, errorPage: Bool = false) -> Bool {
        guard follows(url), !errorPage else { return true }
        let site = site(of: url)
        return allows(setting: isAllowed, kept: site.flatMap(kept(site:)), here: site.flatMap { choices?[$0] })
    }

    static func allows(_ url: URL?, in tab: Tab?) -> Bool { allows(url, here: tab?.javaScriptHere) }

    /// Kept, or chosen in this private tab.
    static func isOwn(_ url: URL?, in tab: Tab?) -> Bool {
        guard let site = site(of: url) else { return false }
        return tab?.javaScriptHere[site] != nil || kept(site: site) != nil
    }

    /// Nil forgets it. Parent and subdomain choices are untouched; the most specific wins (`kept(site:)`).
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

    /// From Site Controls: kept, or for `tab` only in a private window. Reloads `tab`'s page if it changed; other
    /// tabs apply it on their next load.
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

    /// Forget in Settings › Privacy › Sites.
    static func forget(site: String) { setChoice(nil, forSite: site) }

    /// Settings › Privacy › Sites › Reset All.
    static func forgetAll() {
        sitesOn = []
        sitesOff = []
    }

    /// `url` is the page's (a frame's containing page).
    static func apply(to preferences: WKWebpagePreferences, for url: URL?, here choices: [String: Bool]?, errorPage: Bool) {
        preferences.allowsContentJavaScript = allows(url, here: choices, errorPage: errorPage)
    }

    /// The shown page, or the pending one.
    private static func page(of tab: Tab) -> URL? { tab.webView?.url ?? tab.url }
}

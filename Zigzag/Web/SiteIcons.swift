import AppKit
import WebKit

/// An icon for a whole site, set in Site Controls (#310): a symbol, an emoji or an image (`PageImageIcon`), kept as
/// an icon string under the site's host without "www.". It covers the site's subdomains, as a Dark page choice does,
/// and the nearest site with one wins. Every tab, pinned page, favorite and history row on the site shows it, unless
/// the tab or page has an icon of its own. A private window starts from what's kept and changes only its own copy.
enum SiteIcons {
    /// Where the icons are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    private static let key = "SiteIcons"

    /// Every site's icon, as kept.
    static var all: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { if newValue.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(newValue, forKey: key) } }
    }

    static var sites: Set<String> { Set(all.keys) }

    /// A private window's own changes, by its store: an empty string is an icon it took away.
    private final class Window {
        var icons: [String: String] = [:]
    }
    private static let windows = NSMapTable<WKWebsiteDataStore, Window>.weakToStrongObjects()

    /// The site an icon is kept under: a web page's host without "www.".
    static func site(of url: URL?) -> String? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else { return nil }
        return ContentBlocker.site(of: url)
    }

    /// The site and each site it's part of, nearest first: mail.example.com, example.com, com.
    static func covering(_ site: String) -> [String] {
        var out = [site], rest = Substring(site)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if !rest.isEmpty { out.append(String(rest)) }
        }
        return out
    }

    /// The icons a window sees: what's kept, with a private window's own changes over it.
    private static func icons(privateStore: WKWebsiteDataStore?) -> [String: String] {
        var icons = all
        if let privateStore, let own = windows.object(forKey: privateStore)?.icons {
            for (site, icon) in own { icons[site] = icon.isEmpty ? nil : icon }
        }
        return icons
    }

    /// The icon for a site, its own or the nearest one's it's part of.
    static func icon(forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> String? {
        let icons = icons(privateStore: privateStore)
        guard !icons.isEmpty else { return nil }
        return covering(site).lazy.compactMap { icons[$0] }.first
    }

    static func icon(for url: URL?, privateStore: WKWebsiteDataStore? = nil) -> String? {
        site(of: url).flatMap { icon(forSite: $0, privateStore: privateStore) }
    }

    /// The site's icon drawn, else the site's own favicon: for rows that stand for a page by its address alone
    /// (history, the command bar).
    static func shownIcon(for url: URL, privateStore: WKWebsiteDataStore? = nil) -> NSImage? {
        icon(for: url, privateStore: privateStore).map(IconChoice.pageIcon) ?? FaviconStore.shared.cachedIcon(for: url)
    }

    /// Gives a site its icon, or in a private window gives it for that window only. Nil goes back to the site's own,
    /// taking away any icon covering it, as a Dark page choice replaces what a site it's part of had.
    static func set(_ icon: String?, forSite site: String, privateStore: WKWebsiteDataStore? = nil) {
        let covered = Set(covering(site))
        if let privateStore {
            let window = windows.object(forKey: privateStore) ?? {
                let window = Window()
                windows.setObject(window, forKey: privateStore)
                return window
            }()
            if let icon {
                window.icons[site] = icon
            } else {
                for (kept, _) in icons(privateStore: privateStore) where covered.contains(kept) { window.icons[kept] = "" }
            }
        } else {
            var all = all
            if let icon { all[site] = icon } else { all = all.filter { !covered.contains($0.key) } }
            self.all = all
        }
        refreshTabs()
    }

    /// One site's icon forgotten (Forget in Settings › Privacy › Sites).
    static func forget(site: String) {
        var all = all
        guard all.removeValue(forKey: site) != nil else { return }
        self.all = all
        refreshTabs()
    }

    /// Every site's (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        guard !all.isEmpty else { return }
        all = [:]
        refreshTabs()
    }

    /// Open tabs show the change now, and the sidebar's pinned pages and favorites with no tab yet, as a library
    /// change shows them.
    private static func refreshTabs() {
        for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) { tab.refreshChosenIcon() }
        Library.shared.changed.send()
    }
}

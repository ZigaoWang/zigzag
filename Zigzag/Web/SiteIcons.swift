import AppKit
import WebKit

/// Per-site icons from Site Controls (#310): a symbol, emoji or image (`PageImageIcon`), stored as an icon string
/// under the host without "www.". Covers subdomains like Dark page choices, the nearest match wins. Shown for every
/// tab, pinned page, favorite and history row on the site unless it has its own icon. A private window works on its
/// own copy.
enum SiteIcons {
    /// Tests use their own.
    static var defaults: UserDefaults = .standard
    private static let key = "SiteIcons"

    static var all: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { if newValue.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(newValue, forKey: key) } }
    }

    static var sites: Set<String> { Set(all.keys) }

    /// A private window's changes, by store; an empty string means removed.
    private final class Window {
        var icons: [String: String] = [:]
    }
    private static let windows = NSMapTable<WKWebsiteDataStore, Window>.weakToStrongObjects()

    /// Host without "www.".
    static func site(of url: URL?) -> String? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else { return nil }
        return ContentBlocker.site(of: url)
    }

    /// Nearest first: mail.example.com, example.com, com.
    static func covering(_ site: String) -> [String] {
        var out = [site], rest = Substring(site)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if !rest.isEmpty { out.append(String(rest)) }
        }
        return out
    }

    /// Kept icons with a private window's changes on top.
    private static func icons(privateStore: WKWebsiteDataStore?) -> [String: String] {
        var icons = all
        if let privateStore, let own = windows.object(forKey: privateStore)?.icons {
            for (site, icon) in own { icons[site] = icon.isEmpty ? nil : icon }
        }
        return icons
    }

    /// Its own or the nearest parent's.
    static func icon(forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> String? {
        let icons = icons(privateStore: privateStore)
        guard !icons.isEmpty else { return nil }
        return covering(site).lazy.compactMap { icons[$0] }.first
    }

    static func icon(for url: URL?, privateStore: WKWebsiteDataStore? = nil) -> String? {
        site(of: url).flatMap { icon(forSite: $0, privateStore: privateStore) }
    }

    /// The site icon, else its favicon, for rows shown by address alone (history, command bar).
    static func shownIcon(for url: URL, privateStore: WKWebsiteDataStore? = nil) -> NSImage? {
        icon(for: url, privateStore: privateStore).map(IconChoice.pageIcon) ?? FaviconStore.shared.cachedIcon(for: url)
    }

    /// In a private window, for that window only. Nil reverts to the favicon and removes covering icons, as with Dark
    /// page choices.
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

    /// Forget in Settings › Privacy › Sites.
    static func forget(site: String) {
        var all = all
        guard all.removeValue(forKey: site) != nil else { return }
        self.all = all
        refreshTabs()
    }

    /// Settings › Privacy › Sites › Reset All.
    static func forgetAll() {
        guard !all.isEmpty else { return }
        all = [:]
        refreshTabs()
    }

    /// Updates open tabs and tabless pinned pages and favorites.
    private static func refreshTabs() {
        for tab in WindowManager.shared.everyOpenTab { tab.refreshChosenIcon() }
        Library.shared.changed.send()
    }
}

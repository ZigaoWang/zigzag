import Foundation

/// Developer tools (#141): tools for the people who build websites, on the sites they build. A tab showing a page on
/// the development list (`DevelopmentSites`) is a development tab (`Tab.isDevelopment`); everything the tools add
/// is there only for such a tab. Settings › Developer turns all of it off, and then nothing here does anything.
enum DeveloperTools {
    /// Where the choices are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// The switch or the list of sites changed.
    static let changed = Signal<Void>()

    private static let onKey = "DeveloperTools"

    /// Settings › Developer › Developer tools. On until you turn it off.
    static var isOn: Bool {
        get { defaults.object(forKey: onKey) as? Bool ?? true }
        set {
            guard newValue != isOn else { return }
            defaults.set(newValue, forKey: onKey)
            changed.send()
        }
    }

    /// Whether a page at `url` gets the tools: they're on, and it's on the list.
    static func applies(to url: URL?) -> Bool { isOn && DevelopmentSites.covers(url) }
}

/// The sites you develop on, listed in Settings › Developer: `localhost` and `127.0.0.1` to begin with, and any you
/// add (a name that points at this Mac, a staging site). A site is a host without "www.", whatever its port, and
/// covers its subdomains, as the other choices for a site do.
enum DevelopmentSites {
    private static let key = "DevelopmentSites"
    /// The list before you change it. Nothing is written until you do.
    static let seed = ["localhost", "127.0.0.1"]

    /// In the order Settings shows them.
    static var sites: [String] {
        get { (DeveloperTools.defaults.stringArray(forKey: key) ?? seed).sorted() }
        set {
            DeveloperTools.defaults.set(Array(Set(newValue)).sorted(), forKey: key)
            DeveloperTools.changed.send()
        }
    }

    private static func covers(_ entry: String, _ site: String) -> Bool { site == entry || site.hasSuffix("." + entry) }

    /// A page's site as the list has it: its host without "www.", and without the dot a full name may end in.
    private static func site(of url: URL?) -> String? {
        guard let site = ContentBlocker.site(of: url) else { return nil }
        let name = site.hasSuffix(".") ? String(site.dropLast()) : site
        return name.isEmpty ? nil : name
    }

    /// Whether a page at `url` is on a listed site: a web page only. Asked each time a tab's address changes, so the
    /// list is read as it's kept, not put in order.
    static func covers(_ url: URL?) -> Bool {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? ""), let site = site(of: url) else { return false }
        return (DeveloperTools.defaults.stringArray(forKey: key) ?? seed).contains { covers($0, site) }
    }

    /// Puts a site on the list. One already covered changes nothing, and one that covers others listed takes
    /// their place.
    static func add(_ site: String) {
        var list = sites
        guard !site.isEmpty, !list.contains(where: { covers($0, site) }) else { return }
        list.removeAll { covers(site, $0) }
        list.append(site)
        sites = list
    }

    /// Takes one entry off the list, as Settings › Developer's Remove does.
    static func remove(_ entry: String) {
        var list = sites
        guard list.contains(entry) else { return }
        list.removeAll { $0 == entry }
        sites = list
    }

    /// The site in what you typed into Add Site: a host ("app.localtest.me"), with or without a port, an address
    /// ("http://localhost:3000/admin") or a pattern ("*.test"). Nil when there's no host in it.
    static func entry(from text: String) -> String? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        if !typed.contains("://") {
            while typed.hasPrefix("*") || typed.hasPrefix(".") { typed.removeFirst() }
            typed = "http://" + typed
        }
        guard let url = URL(string: typed), let site = site(of: url) else { return nil }
        let name = site.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return name.isEmpty ? nil : name
    }
}

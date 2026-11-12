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

    private static let barKey = "DeveloperToolsInBar"

    /// Settings › Developer › Tools above the page: a development tab has the tools in the bar above its page
    /// (`DeveloperBarTools`). Off, they're in the site's controls.
    static var showsInBar: Bool {
        get { defaults.object(forKey: barKey) as? Bool ?? true }
        set {
            guard newValue != showsInBar else { return }
            defaults.set(newValue, forKey: barKey)
            changed.send()
        }
    }

    private static let trustKey = "DeveloperTrustsLocalServers"

    /// Settings › Developer › Trust certificates of servers on this Mac. Off until you turn it on.
    static var trustsLocalServers: Bool {
        get { defaults.bool(forKey: trustKey) }
        set {
            guard newValue != trustsLocalServers else { return }
            defaults.set(newValue, forKey: trustKey)
            changed.send()
        }
    }

    /// Whether a server's certificate is trusted without the warning (`CertificateExceptions.allowsLocalServer`):
    /// only with that setting on, for a development site, and only one on this Mac itself, where nothing between the page
    /// and its server could have swapped the certificate. A listed name that's looked up on the network
    /// (app.localtest.me) keeps the warning, however local it turns out to be.
    static func trustsServer(_ host: String) -> Bool {
        guard isOn, trustsLocalServers else { return false }
        var parts = URLComponents()
        parts.scheme = "https"
        // An address with colons goes in brackets, as it does in a page's address.
        parts.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = parts.url else { return false }
        return ErrorPage.isOnThisMac(url) && DevelopmentSites.covers(url)
    }

    /// Whether a page at `url` gets the tools: they're on, and it's on the list.
    static func applies(to url: URL?) -> Bool { isOn && DevelopmentSites.covers(url) }
}

/// The sites you develop on, listed in Settings › Developer: `localhost` and `127.0.0.1` to begin with, and any you
/// add (a name that points at this Mac, a staging site). A site is a host without "www.", whatever its port, and
/// covers its subdomains, as the other choices for a site do. Not changed from a page in a private window, so a
/// private visit never ends up in the list; a private window's tabs still follow it.
enum DevelopmentSites {
    private static let key = "DevelopmentSites"
    /// The list before you change it. Nothing is written until you do.
    static let seed = ["localhost", "127.0.0.1"]

    /// The list as it's kept.
    private static var stored: [String] { DeveloperTools.defaults.stringArray(forKey: key) ?? seed }

    /// In the order Settings shows them.
    static var sites: [String] {
        get { stored.sorted() }
        set {
            DeveloperTools.defaults.set(Array(Set(newValue)).sorted(), forKey: key)
            DeveloperTools.changed.send()
        }
    }

    private static func covers(_ entry: String, _ site: String) -> Bool { site == entry || site.hasSuffix("." + entry) }

    /// A page's site as the list has it: its host without "www.", and without the dot a full name may end in.
    private static func site(of url: URL?) -> String? {
        // A web page only: nothing else has a site to develop on.
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? ""), let site = ContentBlocker.site(of: url) else { return nil }
        let name = site.hasSuffix(".") ? String(site.dropLast()) : site
        return name.isEmpty ? nil : name
    }

    /// Whether a page at `url` is on a listed site: a web page only.
    static func covers(_ url: URL?) -> Bool { entry(covering: url) != nil }

    /// The listed site a page at `url` is on, which may be its parent domain's. Asked each time a tab's address
    /// changes, so the list is read as it's kept, not put in order.
    static func entry(covering url: URL?) -> String? {
        guard let site = site(of: url) else { return nil }
        return stored.first { covers($0, site) }
    }

    /// The name a page's site would be listed under.
    static func name(for url: URL?) -> String? { site(of: url) }

    /// Whether putting the page's site on the list is offered: for a web page, and not in a private window.
    static func isOffered(for url: URL?, isPrivate: Bool) -> Bool {
        !isPrivate && site(of: url) != nil
    }

    /// Puts the page's site on the list, or takes it off. Off takes away whatever covered it, its parent domain
    /// included, so it's off here at once.
    static func set(_ on: Bool, for url: URL?) {
        guard let site = site(of: url) else { return }
        if on { add(site); return }
        var list = sites
        guard list.contains(where: { covers($0, site) }) else { return }
        list.removeAll { covers($0, site) }
        sites = list
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

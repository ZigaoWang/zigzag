import Foundation

/// Settings › Spaces tests these rules in display order. The first match owns the link.
enum SiteRoutes {
    enum Match: String, Codable, CaseIterable, Sendable {
        case host, domain, path

        var title: String {
            switch self {
            case .host: String(localized: "Domain only", comment: "Space rule matching only the named host.")
            case .path: String(localized: "Path and subpaths", comment: "Space rule matching a path and its descendants on one host.")
            case .domain: String(localized: "Domain and subdomains", comment: "Space rule matching a domain and its subdomains.")
            }
        }
    }

    struct Route: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var match: Match = .domain
        var site: String
        var spaceID: UUID
        var isEnabled = true

        private var host: String { String(site.prefix { $0 != "/" }) }
        private var path: Substring { site.dropFirst(host.count) }

        func matches(_ urlHost: String, path urlPath: String) -> Bool {
            switch match {
            case .domain: SiteRoutes.covers(host, urlHost)
            case .host: host == urlHost
            case .path: host == urlHost && (urlPath == path || urlPath.hasPrefix(String(path) + "/"))
            }
        }

        /// True only when every URL covered by the later rule is also covered here.
        func includes(_ other: Route) -> Bool {
            if other.match == .domain { return match == .domain && SiteRoutes.covers(host, other.host) }
            return matches(other.host, path: String(other.path))
        }
    }

    /// How a page was asked for. Only what you did yourself is routed; what a page does on its own stays where it is,
    /// so a sign-in that redirects through a routed site never leaves its tab.
    enum Arrival: Equatable, Sendable {
        /// A link from another app: the default-browser path.
        case otherApp
        /// Typed or chosen in the command bar or the address.
        case typed
        /// A link you clicked in a page, opening where you are.
        case linkClick
        /// A link you opened in a new tab (⌘-click, a middle click, Open Link in New Tab, a target="_blank" link).
        case linkNewTab
        /// Open in Zigzag, from Zigzag Mini.
        case fromMini
        /// A redirect, a page's script, a frame, a form, a pop-up: never routed.
        case pageOnItsOwn
        case backForward
        case reload
    }

    /// Where the page would open.
    enum Place: Equatable, Sendable {
        case browser
        /// A private window: nothing is routed into or out of it.
        case privateWindow
        /// Zigzag Mini, a quick look: kept as it is.
        case mini
        /// A site installed as an app.
        case webApp
        /// A link peeked at (⇧-click).
        case peek
    }

    // MARK: Sites

    private static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") && !host.hasPrefix("[") { return "[\(host)]" }
        return host.isEmpty ? nil : host
    }

    static func site(of url: URL?) -> String? { host(of: url)?.withoutWWW }

    static func covers(_ entry: String, _ site: String) -> Bool { site == entry || site.hasSuffix("." + entry) }

    static func address(_ text: String) -> URL? {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        if !input.contains("://") { input = "https://" + input }
        guard let parts = URLComponents(string: input), let url = parts.url,
              let host = host(of: url), let schemeEnd = input.range(of: "://")?.upperBound,
              parts.user == nil, parts.password == nil else { return nil }
        // Validate the authority itself. URL accepts non-DNS characters, empty ports and escaped hostnames.
        let authority = input[schemeEnd...]
            .prefix { !"/?#".contains($0) }
        guard !authority.contains("%"), !authority.contains("@") else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            var bytes = in6_addr()
            guard authority.last == "]", inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &bytes) == 1 else { return nil }
        } else {
            guard !authority.contains(":"), host.utf8.count <= 253 else { return nil }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }) else { return nil }
            if labels.count > 1 && labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                var bytes = in_addr()
                guard inet_pton(AF_INET, host, &bytes) == 1 else { return nil }
            }
        }
        return url
    }

    private static func path(of url: URL) -> String {
        var path = url.standardized.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func suggestedMatch(for text: String) -> Match {
        guard let url = address(text), !path(of: url).isEmpty else { return .host }
        return .path
    }

    static func entry(from text: String, match: Match = .domain) -> String? {
        guard let url = address(text), let host = host(of: url) else { return nil }
        switch match {
        case .host, .domain:
            let path = url.path(percentEncoded: true)
            guard (path.isEmpty || path == "/"), url.query() == nil, url.fragment() == nil else { return nil }
            return host
        case .path:
            let path = path(of: url)
            return path.isEmpty ? nil : host + path
        }
    }

    /// Old libraries preferred the most specific domain. Preserve that result when assigning the initial order.
    static func migrated(from spaces: [SpaceInfo]) -> [Route] {
        spaces.flatMap { space in (space.routedSites ?? []).map { Route(site: $0, spaceID: space.id) } }
            .sorted { $0.site.count > $1.site.count }
    }

    static func route(for url: URL?, in routes: [Route]) -> Route? {
        guard let url, let host = host(of: url) else { return nil }
        let path = path(of: url)
        return routes.first { $0.isEnabled && $0.matches(host, path: path) }
    }

    static func blocker(for rule: Route, in rules: [Route]) -> Int? {
        guard rule.isEnabled, !rule.site.isEmpty else { return nil }
        return rules.prefix { $0.id != rule.id }.firstIndex { $0.isEnabled && !$0.site.isEmpty && $0.includes(rule) }
    }

    struct Coverage: Equatable {
        var blockedBy: Int?
        var blocks: [Int] = []
    }

    static func coverage(in rules: [Route]) -> [Coverage] {
        var result = Array(repeating: Coverage(), count: rules.count)
        for (index, rule) in rules.enumerated() {
            if let first = blocker(for: rule, in: rules) {
                result[index].blockedBy = first
                result[first].blocks.append(index)
            }
        }
        return result
    }

    static func move(_ id: UUID, before next: UUID?, in rules: inout [Route]) {
        guard id != next, let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = rules.remove(at: index)
        let target = rules.firstIndex { $0.id == next } ?? rules.endIndex
        rules.insert(rule, at: target)
    }

    // MARK: Deciding

    /// The space a page asked for this way should open in instead of `current`, or nil when it opens as it would
    /// anyway: nothing covers it, it's already in that space, it's in a private window, Zigzag Mini, a peek or an
    /// app, the page went there on its own, or it's a sign-in page a link sent you to (which has to stay with the site
    /// that sent you there to work).
    static func target(for url: URL, arrival: Arrival, from current: UUID?, place: Place, routes: [Route]) -> UUID? {
        switch arrival {
        case .pageOnItsOwn, .backForward, .reload: return nil
        case .otherApp, .typed, .linkClick, .linkNewTab, .fromMini: break
        }
        // Open in Zigzag is the one way out of Zigzag Mini that's routed: it's going to a browser window.
        guard place == .browser || (place == .mini && arrival == .fromMini) else { return nil }
        if arrival == .linkClick || arrival == .linkNewTab, isSignIn(url) { return nil }
        guard let route = route(for: url, in: routes), route.spaceID != current else { return nil }
        return route.spaceID
    }

    /// A page that signs you in for another site: a sign-in page by its address (`Tab.isSignIn`), or one that's
    /// handed where to come back to.
    static func isSignIn(_ url: URL) -> Bool {
        if Tab.isSignIn(url) { return true }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        return names.contains("redirect_uri") || names.contains("client_id")
    }
}

extension SiteRoutes.Route {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        match = try values.decode(SiteRoutes.Match.self, forKey: .match)
        site = try values.decode(String.self, forKey: .site)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

// MARK: - Opening a routed page

extension BrowserWindowController {
    /// The space a page asked for this way opens in instead, when a route sends it elsewhere. `tab`: the page the
    /// link was in, whose space it's leaving (else the space the window shows).
    func routedSpace(for url: URL, arrival: SiteRoutes.Arrival, from tab: Tab? = nil) -> UUID? {
        let place: SiteRoutes.Place = tabManager.isPrivate ? .privateWindow : tab?.isPeek == true ? .peek : .browser
        let target = SiteRoutes.target(for: url, arrival: arrival, from: tab?.spaceID ?? tabManager.currentSpaceID, place: place,
                                       routes: Library.shared.siteRoutes)
        return target.flatMap { Library.shared.space($0) != nil ? $0 : nil }
    }

    /// Opens the page in the space a route sends it to, as a new tab there, and shows that space (or, in the
    /// background, leaves you where you are); a tab already there on the page is gone to instead. A quiet toast says
    /// where it went. False when no route sends it anywhere else, so it opens as it would have.
    @discardableResult
    func openRouted(_ url: URL, arrival: SiteRoutes.Arrival, from tab: Tab? = nil, inBackground: Bool = false,
                    by sender: Tab.LoadSender, httpFallback: Bool = false) -> Bool {
        guard let space = routedSpace(for: url, arrival: arrival, from: tab) else { return false }
        if commandBar.isVisible { commandBar.dismiss(restoringFocus: false) }
        if !inBackground, let open = tabManager.tabs(in: space).first(where: { $0.url == url }) {
            tabManager.select(open)
        } else {
            if !inBackground { tabManager.switchToSpace(space) }
            tabManager.newTab(url: url, spaceID: space, select: !inBackground, by: sender, httpFallback: httpFallback)
        }
        toastRouted(to: space)
        return true
    }

    /// The quiet word that a page went to the space a route sends it to.
    func toastRouted(to space: UUID) {
        guard let name = Library.shared.space(space)?.name else { return }
        Toast.show(String(localized: "Opened in \(name)", comment: "Toast after a link to a site that always opens in a space (Settings › Spaces) opened there instead of where it was clicked or typed. The name is the space's."),
                   symbol: "square.stack", in: self)
    }
}

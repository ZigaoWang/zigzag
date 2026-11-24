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

        /// Both editors validate and normalize the address before keeping an edit to this rule.
        func edited(address: String, match: Match, spaceID: UUID, isEnabled: Bool) -> Self? {
            guard let site = SiteRoutes.entry(from: address, match: match) else { return nil }
            return Self(id: id, match: match, site: site, spaceID: spaceID, isEnabled: isEnabled)
        }

        private var host: String { String(site.prefix { $0 != "/" }) }
        private var path: Substring { site.dropFirst(host.count) }

        func matches(_ urlHost: String, path urlPath: String) -> Bool {
            switch match {
            case .domain: SiteRoutes.covers(host, urlHost)
            case .host: host == urlHost
            // A site's www. address is the same site, as for domain rules.
            case .path:
                host.withoutWWW == urlHost.withoutWWW && Self.matchesPath(path, in: urlPath)
            }
        }

        private static func matchesPath(_ prefix: Substring, in path: String) -> Bool {
            // Split before decoding so an escaped slash stays inside its original segment.
            let expected = prefix.split(separator: "/", omittingEmptySubsequences: false)
            let actual = path.split(separator: "/", omittingEmptySubsequences: false)
            guard actual.count >= expected.count else { return false }
            return zip(expected, actual).allSatisfy { lhs, rhs in
                let a = lhs.removingPercentEncoding ?? String(lhs)
                let b = rhs.removingPercentEncoding ?? String(rhs)
                return a.caseInsensitiveCompare(b) == .orderedSame
            }
        }

        /// True only when every URL covered by the later rule is also covered here.
        func includes(_ other: Route) -> Bool {
            if other.match == .domain { return match == .domain && SiteRoutes.covers(host, other.host) }
            return matches(other.host, path: String(other.path))
        }
    }

    /// On disk this is one ordered array. Keep future rules in their slots while this version edits the rules it knows.
    struct StoredRules: Codable {
        var rules: [Route]
        private var future: [(index: Int, value: StoredValue)] = []

        init(_ rules: [Route] = []) { self.rules = rules }

        init(from decoder: Decoder) throws {
            rules = []
            var entries = try decoder.unkeyedContainer()
            while !entries.isAtEnd {
                let index = entries.currentIndex
                let entry = try entries.superDecoder()
                // A rule this version can't read, from a newer Zigzag or edited by hand, is kept as it is and never
                // stops the library from opening.
                if let rule = try? Route(from: entry) { rules.append(rule) }
                else if let value = try? StoredValue(from: entry) { future.append((index, value)) }
            }
        }

        func encode(to encoder: Encoder) throws {
            var entries = encoder.unkeyedContainer()
            var known = rules.makeIterator()
            for item in future {
                while entries.count < item.index, let rule = known.next() { try entries.encode(rule) }
                try entries.encode(item.value)
            }
            while let rule = known.next() { try entries.encode(rule) }
        }

        // A future rule can have fields this version has never seen, including nested objects.
        private indirect enum StoredValue: Codable {
            case null, bool(Bool), string(String), number(Decimal), array([Self]), object([String: Self])

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if value.decodeNil() { self = .null }
                else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
                else if let string = try? value.decode(String.self) { self = .string(string) }
                else if let number = try? value.decode(Decimal.self) { self = .number(number) }
                else if let array = try? value.decode([Self].self) { self = .array(array) }
                else { self = .object(try value.decode([String: Self].self)) }
            }

            func encode(to encoder: Encoder) throws {
                var value = encoder.singleValueContainer()
                switch self {
                case .null: try value.encodeNil()
                case .bool(let v): try value.encode(v)
                case .string(let v): try value.encode(v)
                case .number(let v): try value.encode(v)
                case .array(let v): try value.encode(v)
                case .object(let v): try value.encode(v)
                }
            }
        }
    }

    /// How a page was opened. Only user actions are routed, so a sign-in redirect never leaves its tab.
    enum Arrival: Equatable, Sendable {
        /// A link from another app: the default-browser path.
        case otherApp
        /// Typed or chosen in the command bar or the address.
        case typed
        /// A clicked link opening in the same tab.
        case linkClick
        /// A link opened in a new tab (⌘-click, middle click, Open Link in New Tab, target="_blank").
        case linkNewTab
        /// Open in Zigzag, from Zigzag Mini.
        case fromMini
        /// Redirect, script, frame, form or pop-up: never routed.
        case pageOnItsOwn
        case backForward
        case reload
    }

    /// Where the page would open.
    enum Place: Equatable, Sendable {
        case browser
        /// A private window: nothing is routed into or out of it.
        case privateWindow
        /// A page whose profile isn't given your data (AI apps', `Profile.getsYourData`): your routes are yours, so
        /// none sends it out, as from a private window.
        case withoutYourData
        /// Zigzag Mini: left as is.
        case mini
        /// A site installed as an app.
        case webApp
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
        // Rules match the hostname across ports, just as the old site lists did.
        let portSuffix = authority.drop(while: { $0 != "]" }).dropFirst()
        let port = host.hasPrefix("[") ? portSuffix : authority.drop(while: { $0 != ":" })
        if !port.isEmpty {
            let digits = port.dropFirst()
            guard port.first == ":", !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  UInt16(digits) != nil else { return nil }
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            var bytes = in6_addr()
            guard authority.dropLast(port.count).last == "]", inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &bytes) == 1 else { return nil }
        } else {
            guard host.utf8.count <= 253 else { return nil }
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
            // www.github.com would leave github.com and its other subdomains out.
            return match == .domain ? host.withoutWWW : host
        case .path:
            let path = path(of: url)
            return path.isEmpty ? nil : host + path
        }
    }

    /// Each space's old sites in saved order, with a subdomain moved above its parent so it still wins as before.
    static func migrated(from spaces: [SpaceInfo]) -> [Route] {
        var rules: [Route] = []
        for space in spaces {
            for site in space.routedSites ?? [] where !rules.contains(where: { $0.site == site }) {
                let rule = Route(match: .domain, site: site, spaceID: space.id)
                rules.insert(rule, at: rules.firstIndex { covers($0.site, site) } ?? rules.endIndex)
            }
        }
        return rules
    }

    /// Spaces with their old site lists filled from the enabled domain rules, so going back to an older Zigzag keeps them.
    static func withLegacySites(_ spaces: [SpaceInfo], from rules: [Route]) -> [SpaceInfo] {
        spaces.map { space in
            var space = space
            let sites = Set(rules.filter { $0.spaceID == space.id && $0.match == .domain && $0.isEnabled }.map(\.site))
            space.routedSites = sites.isEmpty ? nil : sites.sorted()
            return space
        }
    }

    static func route(for url: URL?, in routes: [Route]) -> Route? {
        guard let url, let host = host(of: url) else { return nil }
        let path = path(of: url)
        return routes.first { $0.isEnabled && $0.matches(host, path: path) }
    }

    /// Site Controls changes the winning rule. If there is none, reuse the exact domain rule it would create.
    static func assigning(_ url: URL?, site: String, to space: UUID, in rules: [Route]) -> Route {
        let existing = route(for: url, in: rules) ?? rules.first { !$0.isEnabled && $0.match == .domain && $0.site == site }
        var rule = existing ?? Route(match: .domain, site: site, spaceID: space)
        rule.spaceID = space
        rule.isEnabled = true
        return rule
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

    /// The space to open `url` in instead of `current`, or nil to open normally: no route, already there, not a browser
    /// window, not a user action, or a sign-in page (it must stay with the site that sent it).
    static func target(for url: URL, arrival: Arrival, from current: UUID?, place: Place, routes: [Route]) -> UUID? {
        switch arrival {
        case .pageOnItsOwn, .backForward, .reload: return nil
        case .otherApp, .typed, .linkClick, .linkNewTab, .fromMini: break
        }
        // Open in Zigzag is the only routed way out of Mini.
        guard place == .browser || (place == .mini && arrival == .fromMini) else { return nil }
        if arrival == .linkClick || arrival == .linkNewTab, isSignIn(url) { return nil }
        guard let route = route(for: url, in: routes), route.spaceID != current else { return nil }
        return route.spaceID
    }

    /// Whether a page's request for a new window is a link you clicked, routed as one. A clicked `window.open` counts
    /// only from an embed, a frame from another site than its page (YouTube's Watch on YouTube): its opener is the
    /// embed, never the page, while the page's own pop-ups keep theirs.
    static func newWindowIsClickedLink(linkActivated: Bool, userInitiated: Bool, fromMainFrame: Bool,
                                       frameHost: String?, pageHost: String?) -> Bool {
        guard userInitiated else { return false }
        if linkActivated { return true }
        guard !fromMainFrame, let frame = frameHost?.lowercased(), !frame.isEmpty,
              let page = pageHost?.lowercased(), !page.isEmpty else { return false }
        return frame != page && (PublicSuffix.registrableDomain(frame) ?? frame) != (PublicSuffix.registrableDomain(page) ?? page)
    }

    /// Where a page from `tab` (else from the space `window` shows) would open; its profile decides over its window.
    static func place(from tab: Tab?, in window: TabManager) -> Place {
        if window.isPrivate { return .privateWindow }
        if !(tab?.profile ?? Profiles.shared.profile(forSpace: window.currentSpaceID)).getsYourData { return .withoutYourData }
        return tab?.isOutsideTabList == true ? .mini : .browser
    }

    /// A sign-in page by address (`Tab.isSignIn`), or one with a return URL.
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
    /// The space a route sends `url` to. `tab`: the tab the link came from (else the window's space).
    func routedSpace(for url: URL, arrival: SiteRoutes.Arrival, from tab: Tab? = nil) -> UUID? {
        let target = SiteRoutes.target(for: url, arrival: arrival, from: tab?.spaceID ?? tabManager.currentSpaceID,
                                       place: SiteRoutes.place(from: tab, in: tabManager),
                                       routes: Library.shared.siteRoutes)
        return target.flatMap { Library.shared.space($0) != nil ? $0 : nil }
    }

    /// Opens the page as a new tab in its routed space (or switches to an existing tab there) and shows a toast. False
    /// when no route applies.
    @discardableResult
    func openRouted(_ url: URL, arrival: SiteRoutes.Arrival, from tab: Tab? = nil, inBackground: Bool = false,
                    by sender: Tab.LoadSender, httpFallback: Bool = false) -> Bool {
        guard let space = routedSpace(for: url, arrival: arrival, from: tab) else { return false }
        if commandBar.isVisible { commandBar.dismiss(restoringFocus: false) }
        let key = TabManager.normalize(url)
        if !inBackground, let open = tabManager.tabs(in: space).first(where: { $0.url.map(TabManager.normalize) == key }) {
            tabManager.select(open)
        } else {
            if !inBackground { tabManager.switchToSpace(space) }
            tabManager.newTab(url: url, spaceID: space, select: !inBackground, by: sender, httpFallback: httpFallback)
        }
        toastRouted(to: space)
        return true
    }

    /// Toast saying the page opened in `space`.
    func toastRouted(to space: UUID) {
        guard let name = Library.shared.space(space)?.name else { return }
        Toast.show(String(localized: "Opened in \(name)", comment: "Toast after a link to a site that always opens in a space (Settings › Spaces) opened there instead of where it was clicked or typed. The name is the space's."),
                   symbol: "square.stack", in: self)
    }
}

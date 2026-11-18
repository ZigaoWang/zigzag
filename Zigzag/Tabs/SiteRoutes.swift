import Foundation

/// Sites that always open in a chosen space (#286), like Arc's Air Traffic Control. A site is a host without "www." and
/// covers its subdomains; the most specific entry wins.
///
/// Routes are stored on each space (`SpaceInfo.routedSites`), so removing a space removes its routes and ⌘Z restores
/// them.
enum SiteRoutes {
    struct Route: Equatable, Sendable {
        var site: String
        var spaceID: UUID
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
        /// Zigzag Mini: left as is.
        case mini
        /// A site installed as an app.
        case webApp
        /// A peeked link (⇧-click).
        case peek
    }

    // MARK: Sites

    /// Host without "www." or a trailing dot; nil for non-web URLs.
    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// True when `site` equals `entry` or is a subdomain of it.
    static func covers(_ entry: String, _ site: String) -> Bool { site == entry || site.hasSuffix("." + entry) }

    /// Parses Add Site input: a host, a URL or a "*." pattern. Nil when there's no host.
    static func entry(from text: String) -> String? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        if !typed.contains("://") {
            while typed.hasPrefix("*") || typed.hasPrefix(".") { typed.removeFirst() }
            typed = "https://" + typed
        }
        guard let site = site(of: URL(string: typed)) else { return nil }
        let name = site.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return name.isEmpty ? nil : name
    }

    // MARK: The list

    /// All routes, in space order.
    static func routes(in spaces: [SpaceInfo]) -> [Route] {
        spaces.flatMap { space in (space.routedSites ?? []).map { Route(site: $0, spaceID: space.id) } }
    }

    /// The most specific route covering `url`.
    static func route(for url: URL?, in routes: [Route]) -> Route? {
        guard let site = site(of: url) else { return nil }
        return routes.filter { covers($0.site, site) }.max { $0.site.count < $1.site.count }
    }

    /// Moves `site` to `space` (nil: any space). A site belongs to at most one space.
    static func setting(_ site: String, to space: UUID?, in spaces: [SpaceInfo]) -> [SpaceInfo] {
        spaces.map { info in
            var info = info
            var sites = (info.routedSites ?? []).filter { $0 != site }
            if info.id == space { sites.append(site) }
            info.routedSites = sites.isEmpty ? nil : sites.sorted()
            return info
        }
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

    /// A sign-in page by address (`Tab.isSignIn`), or one with a return URL.
    static func isSignIn(_ url: URL) -> Bool {
        if Tab.isSignIn(url) { return true }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        return names.contains("redirect_uri") || names.contains("client_id")
    }
}

// MARK: - Opening a routed page

extension BrowserWindowController {
    /// The space a route sends `url` to. `tab`: the tab the link came from (else the window's space).
    func routedSpace(for url: URL, arrival: SiteRoutes.Arrival, from tab: Tab? = nil) -> UUID? {
        let place: SiteRoutes.Place = tabManager.isPrivate ? .privateWindow : tab?.isPeek == true ? .peek : .browser
        let target = SiteRoutes.target(for: url, arrival: arrival, from: tab?.spaceID ?? tabManager.currentSpaceID, place: place,
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

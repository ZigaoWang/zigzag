import Foundation

/// Sites that always open in a space you chose (#286), as Arc's Air Traffic Control does: youtube.com in Media, so
/// however you get there (a link from Mail, ⌘T, a link in another space) it opens with Media's profile, cookies and
/// all. A site is a host without "www.", as the other choices for a site are, and covers its subdomains; the most
/// specific one listed wins, so music.youtube.com can go elsewhere than youtube.com.
///
/// Each site is kept with its space (`SpaceInfo.routedSites`), in the library, so a space that's removed takes its
/// sites with it (they open anywhere again) and ⌘Z that brings the space back brings them back too.
enum SiteRoutes {
    struct Route: Equatable, Sendable {
        var site: String
        var spaceID: UUID
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

    /// A page's site as routes have it: its host without "www." or a trailing dot, for a web page only.
    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Whether a listed site covers a page's: the same, or a subdomain of it.
    static func covers(_ entry: String, _ site: String) -> Bool { site == entry || site.hasSuffix("." + entry) }

    /// The site in what you typed into Add Site: a host ("youtube.com"), an address ("https://www.youtube.com/feed")
    /// or a pattern ("*.youtube.com"). Nil when there's no host in it.
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

    /// Every route, from the spaces that keep them, in the spaces' order.
    static func routes(in spaces: [SpaceInfo]) -> [Route] {
        spaces.flatMap { space in (space.routedSites ?? []).map { Route(site: $0, spaceID: space.id) } }
    }

    /// The route that covers a page: the most specific listed site that does.
    static func route(for url: URL?, in routes: [Route]) -> Route? {
        guard let site = site(of: url) else { return nil }
        return routes.filter { covers($0.site, site) }.max { $0.site.count < $1.site.count }
    }

    /// The spaces with `site` sent to `space`, or to no space (nil: Any space). A site is kept by one space at most,
    /// so choosing another takes it from the one it was in.
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

    /// The quiet word that a page went to the space a route sends it to.
    func toastRouted(to space: UUID) {
        guard let name = Library.shared.space(space)?.name else { return }
        Toast.show(String(localized: "Opened in \(name)", comment: "Toast after a link to a site that always opens in a space (Settings › Spaces) opened there instead of where it was clicked or typed. The name is the space's."),
                   symbol: "square.stack", in: self)
    }
}

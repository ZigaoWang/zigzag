import AppKit
import WebKit

/// What you chose with the developer tools for one tab (#141): how its page should look, and the rest as each tool
/// comes. The tab's alone: never saved, never another tab's, gone when the tab closes. In effect only while the tab
/// is a development tab (`Tab.developerInEffect`): on any other site its page is as it would be without them, and
/// they apply again when the tab comes back.
nonisolated struct DeveloperState: Equatable {
    /// The look the page is asked for: the Mac's, as any page, or one of the two whatever the Mac's is.
    enum Appearance: Int, CaseIterable {
        case followsMac, light, dark

        /// The web view's appearance for it; none to follow the window.
        var name: NSAppearance.Name? {
            switch self {
            case .followsMac: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    var appearance = Appearance.followsMac
    /// The page is laid out with its styles for print, as it would be on paper.
    var printStyles = false
    /// The page's own size, in points; nil fills the room it has, as any page.
    var size: CGSize?

    /// The size the other way up.
    var rotatedSize: CGSize? { size.map { CGSize(width: $0.height, height: $0.width) } }

    /// The browser the page is told it's in: Zigzag's own, as any page, or another's, for a site that serves each
    /// its own page.
    enum UserAgent: Int, CaseIterable {
        case zigzag, iPhone, iPad, chrome, firefox

        /// What the page is sent in its place; nil for Zigzag's own. Each as its browser sent it in November 2026
        /// (Safari 27, Chrome 157, Firefox 160): the one place to bring them up to date. Safari on an iPhone or iPad
        /// names iOS 18.7 whatever it runs on, and Chrome names macOS 10.15.7: both keep that part still on purpose.
        var string: String? {
            switch self {
            case .zigzag: nil
            case .iPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
            case .iPad: "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
            case .chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
            case .firefox: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:160.0) Gecko/20100101 Firefox/160.0"
            }
        }
    }

    var userAgent = UserAgent.zigzag
    /// The page's scripts don't run.
    var javaScriptOff = false
    /// Every element of the page is drawn with a line around it.
    var outlines = false
    /// The page loads none of its images (`PageImages`).
    var imagesOff = false
    /// The page is drawn without any of its styles, as bare HTML (`PageStyles`).
    var stylesOff = false

    /// Nothing is chosen: the page is as any page.
    var isUnchanged: Bool { self == DeveloperState() }

    /// Whether a change from `old` only shows once the page loads again: what a page is told, allowed and given as it
    /// loads (its user agent, its scripts, its images), not how one already here is drawn. Either way round: what
    /// differs, from or to `old`.
    func needsReload(from old: DeveloperState) -> Bool {
        userAgent != old.userAgent || javaScriptOff != old.javaScriptOff || imagesOff != old.imagesOff
    }
}

extension Tab {
    /// The choices in effect on the page the tab shows, for what shows them: the tab's own on a development site,
    /// none anywhere else.
    var developerInEffect: DeveloperState { isDevelopment ? developer : DeveloperState() }

    /// The choices in effect on a page at `url`. What puts them on the page asks by the address its web view is
    /// going to, which is ahead of the page the tab shows while another is on its way: a page off the list never
    /// starts with them, and one on it starts with them from its first frame.
    /// A tab with nothing chosen (nearly every tab) answers at once, without reading the list: dark pages ask this
    /// of every open page each time they look at one.
    func developerInEffect(at url: URL?) -> DeveloperState {
        guard !developer.isUnchanged, DeveloperTools.applies(to: url) else { return DeveloperState() }
        return developer
    }

    /// The look chosen for a page at `url` in this tab, light or dark whatever the Mac's is; none to follow it.
    func chosenLook(at url: URL?) -> NSAppearance.Name? {
        guard developer.appearance != .followsMac else { return nil }
        return developerInEffect(at: url).appearance.name
    }

    /// Puts the choices in effect on the page that loads: when one changes, when the web view's address does, when
    /// the tab becomes or stops being a development tab, and for a new web view. What it's told and given as it loads
    /// (its user agent, its images), and the look it's asked for. One path for all of them, so the page is never left
    /// with a choice nothing shows.
    func applyDeveloperState() {
        guard let webView else { return }
        let state = developerInEffect(at: webView.url ?? url)
        if (webView.customUserAgent ?? "") != (state.userAgent.string ?? "") { webView.customUserAgent = state.userAgent.string }
        PageImages.set(state.imagesOff, in: webView)
        DarkPages.lookChanged(for: webView)
    }

    /// Puts on the page that's here how the developer tools have it drawn (its styles, for print or none, and its
    /// outlines): once it has arrived (`didCommit`), and when a choice changes or the tab becomes or stops being a
    /// development tab. Never by the address a web view is going to: the page still showing would be drawn as the
    /// next one, without its styles while it waits.
    func applyDeveloperStateToPage() {
        guard let webView else { return }
        let state = developerInEffect
        let media: String? = state.printStyles ? "print" : nil
        if webView.mediaType != media { webView.mediaType = media }
        PageStyles.set(!state.stylesOff, in: webView.configuration.preferences)
        PageOutlines.set(state.outlines, in: webView)
    }

    /// Whether a page being gone to has to be asked for again: the web view asked for it as the browser the page
    /// it's leaving was told it's in, and this one is told another. So a site off the list is never asked for as an
    /// iPhone, and one on it never as Zigzag when you chose otherwise. Only a plain load you could make again: not
    /// Back or Forward, a reload, or a form's reply.
    static func asksAgain(sent: String?, wanted: String?, isGet: Bool, type: WKNavigationType) -> Bool {
        (sent ?? "") != (wanted ?? "") && isGet && type != .backForward && type != .reload && type != .formSubmitted && type != .formResubmitted
    }

    /// Whether a page at `url` in this tab is as its site made it: nothing chosen for it with the developer tools.
    /// What's learned from pages for later (a site's dark look, its colors) isn't learned from one that isn't.
    func pageIsUntouched(at url: URL?) -> Bool { developerInEffect(at: url).isUnchanged }
}

/// Disable Styles (#141): the page drawn with none of its styles, as bare HTML, through WebKit's own preference for it
/// (`authorAndUserStylesEnabled`, unpublished, so offered only where this WebKit has it). It takes every author style
/// with it, the ones Zigzag puts in a page included, and goes and comes back at once. WebKit lists it as the app's own
/// to set (an "embedder" feature), so Settings' Feature Flags never shows or sets it. It's the tab's web view's
/// (`Tab.applyDeveloperStateToPage`, as each page arrives); no other page shares them, not even one this page opened
/// (`WebKitSetup.separatePreferences`).
enum PageStyles {
    static let key = "authorAndUserStylesEnabled"
    static var isAvailable: Bool { WebKitSetup.hasPreference(key) }

    static func set(_ on: Bool, in preferences: WKPreferences) { WebKitSetup.setIfAvailable(on, key: key, in: preferences) }
}

/// Disable Images (#141): a content rule that blocks every image a page asks for, on a tab's web view while it's
/// chosen there. A rule rather than WebKit's preference to load images automatically: that one still shows any
/// image WebKit has in memory, so a page you come back to has them all, and a rule is checked before the cache.
/// It shows from the page's next load, either way.
///
/// The rule blocks only on a page whose site is on the development list (`if-top-url`), so it never touches any
/// other site's page, whatever shares it: a page and the tabs and pop-ups it opened share one set of scripts and
/// rules (as dark pages' scripts), so the choice is theirs together. A tab it opens starts with it, and turned on
/// or off in any of them it is in all (`Tab.shareImagesChoice`), so each one's menu says what its pages get. It's
/// compiled for the list as it is, the first time it's wanted and again when the list changes, then looked up.
enum PageImages {
    static let prefix = "zigzag-developer-images-off-"

    /// The rule for pages on `sites`, the development list's entries; nil with none, as WebKit compiles no
    /// condition that's empty.
    static func rules(for sites: [String]) -> String? {
        let pages = sites.compactMap(topURL(for:))
        guard !pages.isEmpty else { return nil }
        let rule: [String: Any] = [
            "trigger": ["url-filter": ".*", "resource-type": ["image"], "if-top-url": pages],
            "action": ["type": "block"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: [rule], options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The pages of a listed site, as `if-top-url` matches a page's address: the site or any of its subdomains,
    /// whatever its port, as the list covers them (`DevelopmentSites.covers`). By address rather than `if-domain`,
    /// which never matches an address in brackets (`[::1]`). The list keeps hosts as a page's address has them, so
    /// lowercase and ASCII; anything else couldn't be a page's host.
    static func topURL(for site: String) -> String? {
        guard !site.isEmpty, site.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:".contains($0)) && !$0.isUppercase }) else { return nil }
        let escaped = site.replacingOccurrences(of: ".", with: "\\.")
        // An address with colons is in brackets in a page's address, and has no subdomains.
        return site.contains(":") ? "^https?://\\[\(escaped)\\][:/]" : "^https?://([^/]*\\.)?\(escaped)[:/]"
    }

    /// The rules' version is in the name: compiled once for a list, and looked up after.
    static func identifier(for rules: String) -> String { prefix + String(Data(rules.utf8).hashValueStable, radix: 36) }

    /// The rule compiled last, put on every set of scripts and rules a page wants it in.
    private static var list: WKContentRuleList?
    /// The name of the rule for the list as it is now; nil with nothing listed. `list` is that rule once compiled.
    private static var wanted: String?
    /// The rule being compiled.
    private static var preparing: String?
    /// Per set of scripts and rules, the web views that want their images off: the rule is there while any does.
    private static let wanting = NSMapTable<WKUserContentController, NSHashTable<WKWebView>>.weakToStrongObjects()
    /// Per set of scripts and rules, the rule that's on it, as `PageFilters` keeps its own.
    private static let installed = NSMapTable<WKUserContentController, WKContentRuleList>.weakToStrongObjects()
    /// Pages waiting for the rule before they load again (`defersReload`).
    private static let waiting = NSHashTable<WKWebView>.weakObjects()
    /// Per set of scripts and rules, every tab's web view made with it: a page and the ones it opened.
    private static let members = NSMapTable<WKUserContentController, NSHashTable<WKWebView>>.weakToStrongObjects()

    /// A tab's new web view, among the others with its set of scripts and rules (`sharing`).
    static func join(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let webViews = members.object(forKey: controller) ?? NSHashTable<WKWebView>.weakObjects()
        webViews.add(webView)
        members.setObject(webViews, forKey: controller)
    }

    /// The other tabs' web views that share a web view's set of scripts and rules, and so its images rule: the page
    /// that opened it, and the ones it or they opened. WebKit makes a page's new window with its opener's set, and
    /// it can't be given its own: the opener's scripts, handlers and rules can't be read back to fill one.
    static func sharing(with webView: WKWebView) -> [WKWebView] {
        (members.object(forKey: webView.configuration.userContentController)?.allObjects ?? []).filter { $0 !== webView }
    }

    /// Images off or back on for a web view's pages: from its next load. A web view that goes (`Tab.tearDown`) is
    /// set back on, so the rule never stays for the pages it shared it with.
    static func set(_ off: Bool, in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let webViews = wanting.object(forKey: controller) ?? NSHashTable<WKWebView>.weakObjects()
        guard off != webViews.contains(webView) else { return }
        if off { webViews.add(webView) } else { webViews.remove(webView); waiting.remove(webView) }
        wanting.setObject(webViews, forKey: controller)
        if off { prepare() }
        sync(controller)
    }

    /// Whether a web view's pages are meant to be without their images.
    static func isOff(in webView: WKWebView) -> Bool { wanting.object(forKey: webView.configuration.userContentController)?.contains(webView) == true }

    /// Whether a web view's page waits for the rule before it loads again (`defersReload`).
    static func isWaiting(_ webView: WKWebView) -> Bool { waiting.contains(webView) }

    /// Whether the rule is on a web view's set of scripts and rules, the one for the list as it is.
    static func isOn(in webView: WKWebView) -> Bool {
        guard let wanted else { return false }
        return installed.object(forKey: webView.configuration.userContentController)?.identifier == wanted
    }

    /// Whether loading a page again for a change to its choices waits for the rule: its images are off and the rule
    /// for the list as it is isn't on yet. It's then loaded again once it is, with every change made meanwhile; the
    /// page loads once, never first with its images and again without.
    static func defersReload(of webView: WKWebView) -> Bool {
        guard isOff(in: webView), wanted != nil, !isOn(in: webView) else { return false }
        waiting.add(webView)
        return true
    }

    /// The development list changed: the rule follows it, while what's on stays until the new one is ready. Before
    /// the tabs take the change, so a page that just came onto the list waits for it (`defersReload`).
    static func sitesChanged() {
        let now = rules(for: DevelopmentSites.sites).map(identifier(for:))
        guard now != wanted else { return }
        wanted = now
        if now == nil { list = nil; waiting.removeAllObjects(); syncAll() } else if hasWanting { prepare() }
    }

    private static var controllers: [WKUserContentController] {
        Set(wanting.keyEnumerator().allObjects.compactMap { $0 as? WKUserContentController }
            + installed.keyEnumerator().allObjects.compactMap { $0 as? WKUserContentController }).map { $0 }
    }

    private static var hasWanting: Bool { wanting.objectEnumerator()?.allObjects.contains { ($0 as? NSHashTable<WKWebView>)?.allObjects.isEmpty == false } == true }

    /// Puts the rule on a set of scripts and rules while a page there wants it, and takes it off when none does, as
    /// `ContentBlocker.apply` swaps its lists: what's on is known, never counted.
    @discardableResult
    private static func sync(_ controller: WKUserContentController) -> Bool {
        let want = wanting.object(forKey: controller)?.allObjects.isEmpty == false ? list : nil
        let have = installed.object(forKey: controller)
        guard have !== want else { return false }
        if let have { controller.remove(have) }
        if let want { controller.add(want); installed.setObject(want, forKey: controller) } else { installed.removeObject(forKey: controller) }
        return true
    }

    private static func syncAll() { controllers.forEach { sync($0) } }

    /// Looks the rule for the list as it is up, or compiles it; then puts it where it's wanted, in place of the one
    /// before, and loads the pages that waited for it again. A list that changed meanwhile is worked toward next.
    private static func prepare() {
        // Nothing listed: no rule will come, so no page waits for one. Each tab, no longer a development tab, loads
        // again without its choices (`Tab.refreshDevelopment`).
        guard let rules = rules(for: DevelopmentSites.sites) else { wanted = nil; waiting.removeAllObjects(); return }
        let name = identifier(for: rules)
        wanted = name
        guard list?.identifier != name, preparing != name, let store = WKContentRuleListStore.default() else { return }
        preparing = name
        let ready: @MainActor (WKContentRuleList?) -> Void = { found in
            if preparing == name { preparing = nil }
            // The list changed while this was compiled: the one for it comes next, and the pages wait for that.
            guard name == wanted else { prepare(); return }
            if let found {
                list = found
                syncAll()
                ContentBlocker.removeOld(withPrefix: prefix, keeping: name)
            }
            // Loaded again, without the rule if it failed: the other changes made meanwhile are never lost.
            let pages = waiting.allObjects
            waiting.removeAllObjects()
            for page in pages { if let tab = (page as? BrowserWebView)?.owner { tab.reload() } else { page.reload() } }
        }
        store.lookUpContentRuleList(forIdentifier: name) { found, _ in
            MainActor.assumeIsolated {
                if let found { ready(found); return }
                store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: rules) { compiled, _ in
                    MainActor.assumeIsolated { ready(compiled) }
                }
            }
        }
    }
}

/// Outline Every Element (#141): a line around each element of the page, to see how it's laid out. One style in
/// the page, put in and taken out by name; it loads nothing and changes nothing else. A page that loads while it's
/// on gets it as it arrives (`Tab.applyDeveloperState` on each new address, and when the page has loaded).
enum PageOutlines {
    static let world = WKContentWorld.world(name: "zigzag-developer")
    static let styleID = "zigzag-developer-outlines"

    /// Run with `on` and the style's `id`: puts the style in, or takes it out.
    static let script = """
    const old = document.getElementById(id);
    if (!on) { if (old) old.remove(); return; }
    if (old || !document.documentElement) return;
    const style = document.createElement('style');
    style.id = id;
    style.textContent = '* { outline: 1px solid rgba(255, 45, 85, 0.55) !important; outline-offset: -1px !important; }';
    document.documentElement.appendChild(style);
    """

    /// Web views with the style in their page, so one that never had it is never run a script for it.
    private static let outlined = NSHashTable<WKWebView>.weakObjects()

    static func set(_ on: Bool, in webView: WKWebView) {
        guard on || outlined.contains(webView) else { return }
        if on { outlined.add(webView) } else { outlined.remove(webView) }
        webView.runOwnScript(script, asFunction: true, arguments: ["on": on, "id": styleID], world: world)
    }
}

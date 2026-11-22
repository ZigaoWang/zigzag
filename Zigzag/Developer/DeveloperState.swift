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
        /// Chrome's and Firefox's versions move on every four weeks, as their releases do (`major(_:on:)`).
        var string: String? {
            switch self {
            case .zigzag: nil
            case .iPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
            case .iPad: "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
            case .chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.major(157)).0.0.0 Safari/537.36"
            case .firefox: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(Self.major(160)).0) Gecko/20100101 Firefox/\(Self.major(160)).0"
            }
        }

        /// A major version as of 2026-11-21, one more for each four weeks since; never less.
        nonisolated static func major(_ base: Int, on date: Date = Date()) -> Int {
            let weeks = date.timeIntervalSince(Date(timeIntervalSince1970: 1_795_219_200)) / (7 * 86_400)
            return base + max(0, Int(weeks / 4))
        }
    }

    var userAgent = UserAgent.zigzag
    /// The page's scripts don't run.
    var javaScriptOff = false
    /// Every element of the page is drawn with a line around it.
    var outlines = false
    /// Blocks all images (`PageImages`).
    var imagesOff = false
    /// Renders as bare HTML with no styles (`PageStyles`).
    var stylesOff = false

    /// Nothing is chosen: the page is as any page.
    var isUnchanged: Bool { self == DeveloperState() }

    /// Whether a change needs a reload: anything applied at load time (user agent, scripts, images), not how the
    /// current page draws. Checked in both directions.
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

    /// Applies load-time choices (user agent, images) and the requested look: on change, on address change, on toggling
    /// development mode, and for new web views. One path so nothing is missed.
    func applyDeveloperState() {
        guard let webView else { return }
        let state = developerInEffect(at: webView.url ?? url)
        applyUserAgent()
        PageImages.set(state.imagesOff, in: webView)
        DarkPages.lookChanged(for: webView)
    }

    /// Applies draw-time choices (styles, outlines) to the current page: on `didCommit`, on change, and on toggling
    /// development mode. Never on the pending address, or the old page would draw unstyled while waiting.
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

/// Disable Styles (#141) via WebKit's private `authorAndUserStylesEnabled`, offered only where it exists. Drops all
/// author styles, Zigzag's included, and applies instantly. It's an embedder feature, so Feature Flags never shows it.
/// Per web view (`Tab.applyDeveloperStateToPage`); preferences aren't shared, even with opened pages
/// (`WebKitSetup.separatePreferences`).
enum PageStyles {
    static let key = "authorAndUserStylesEnabled"
    static var isAvailable: Bool { WebKitSetup.hasPreference(key) }

    static func set(_ on: Bool, in preferences: WKPreferences) { WebKitSetup.setIfAvailable(on, key: key, in: preferences) }
}

/// Disable Images (#141): a content rule blocking every image. Not WebKit's auto-load preference, which still shows
/// cached images; rules run before the cache. Applies from the next load. Scoped by `if-top-url` to development sites.
/// Opener and opened pages share rule sets, so the choice is shared (`Tab.shareImagesChoice`). Compiled per list
/// version on first use and on list change, then looked up.
enum PageImages {
    static let prefix = "zigzag-developer-images-off-"

    /// Nil for no sites; WebKit won't compile an empty condition.
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

    /// `if-top-url` pattern for a site and its subdomains, any port (`DevelopmentSites.covers`). Not `if-domain`, which
    /// never matches bracketed hosts (`[::1]`). Hosts are stored lowercase ASCII.
    static func topURL(for site: String) -> String? {
        guard !site.isEmpty, site.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:".contains($0)) && !$0.isUppercase }) else { return nil }
        let escaped = site.replacingOccurrences(of: ".", with: "\\.")
        // IPv6: bracketed, no subdomains.
        return site.contains(":") ? "^https?://\\[\(escaped)\\][:/]" : "^https?://([^/]*\\.)?\(escaped)[:/]"
    }

    /// Versioned by the rules' hash.
    static func identifier(for rules: String) -> String { prefix + String(Data(rules.utf8).hashValueStable, radix: 36) }

    /// Last compiled rule list, added to each content controller that needs it.
    private static var list: WKContentRuleList?
    /// Name of the rule for the current list; nil when empty. `list` holds it once compiled.
    private static var wanted: String?
    /// The rule being compiled.
    private static var preparing: String?
    /// Per content controller, the web views wanting images off; the rule stays while any does.
    private static let wanting = NSMapTable<WKUserContentController, NSHashTable<WKWebView>>.weakToStrongObjects()
    /// Per content controller, the installed rule, as `PageFilters` tracks its own.
    private static let installed = NSMapTable<WKUserContentController, WKContentRuleList>.weakToStrongObjects()
    /// Pages waiting for the rule before reloading (`defersReload`).
    private static let waiting = NSHashTable<WKWebView>.weakObjects()
    /// Per content controller, every tab web view using it: an opener and the pages it opened.
    private static let members = NSMapTable<WKUserContentController, NSHashTable<WKWebView>>.weakToStrongObjects()

    /// Registers a tab's new web view with its content controller (`sharing`).
    static func join(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let webViews = members.object(forKey: controller) ?? NSHashTable<WKWebView>.weakObjects()
        webViews.add(webView)
        members.setObject(webViews, forKey: controller)
    }

    /// Other tab web views sharing this one's content controller, and so its images rule. WebKit gives a new window its
    /// opener's controller, and a fresh one can't be filled since scripts, handlers and rules can't be read back.
    static func sharing(with webView: WKWebView) -> [WKWebView] {
        (members.object(forKey: webView.configuration.userContentController)?.allObjects ?? []).filter { $0 !== webView }
    }

    /// Turns images off or on from the next load. A torn-down web view (`Tab.tearDown`) is turned back on so the rule
    /// doesn't linger on shared pages.
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

    /// Whether the page waits for the rule before reloading (`defersReload`).
    static func isWaiting(_ webView: WKWebView) -> Bool { waiting.contains(webView) }

    /// Whether the current list's rule is installed on the web view's controller.
    static func isOn(in webView: WKWebView) -> Bool {
        guard let wanted else { return false }
        return installed.object(forKey: webView.configuration.userContentController)?.identifier == wanted
    }

    /// Whether a reload waits for the rule: images are off and the current rule isn't installed yet. Then it reloads
    /// once with all pending changes, never first with images and again without.
    static func defersReload(of webView: WKWebView) -> Bool {
        guard isOff(in: webView), wanted != nil, !isOn(in: webView) else { return false }
        waiting.add(webView)
        return true
    }

    /// The development list changed: recompile, keeping the old rule until the new one is ready. Runs before tabs
    /// update so a newly listed page waits (`defersReload`).
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

    /// Adds the rule to a controller while any page there wants it and removes it when none does, as
    /// `ContentBlocker.apply` swaps lists; tracked, not counted.
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

    /// Looks up or compiles the current rule, swaps it in where wanted, and reloads waiting pages. Recompiles if the
    /// list changed meanwhile.
    private static func prepare() {
        // Empty list: no rule coming, so nothing waits. Each tab reloads without its developer choices
        // (`Tab.refreshDevelopment`).
        guard let rules = rules(for: DevelopmentSites.sites) else { wanted = nil; waiting.removeAllObjects(); return }
        let name = identifier(for: rules)
        wanted = name
        guard list?.identifier != name, preparing != name, let store = WKContentRuleListStore.default() else { return }
        preparing = name
        let ready: @MainActor (WKContentRuleList?) -> Void = { found in
            if preparing == name { preparing = nil }
            // The list changed during compiling: compile again; pages keep waiting.
            guard name == wanted else { prepare(); return }
            if let found {
                list = found
                syncAll()
                ContentBlocker.removeOld(withPrefix: prefix, keeping: name)
            }
            // Reload even if compiling failed, so other pending changes aren't lost.
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

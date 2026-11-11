import AppKit
import WebKit

/// Dark pages: a page without a dark look of its own is drawn dark, one that has its own is left alone.
///
/// Settings › Appearance › Dark pages turns it on always, while the Mac is dark, or not at all, and the site panel
/// turns it on or off for one site. Where it's on, the page is first told dark is preferred (the web view's
/// appearance is dark, so `prefers-color-scheme: dark` matches and a site with its own dark theme uses it). Only a
/// page that still draws itself light is darkened, by dark-pages.js: one filter on the page's root, with pictures
/// and video turned back. That's drawn by WebKit on the GPU, with no script per element, so pages stay as fast as
/// they were. Reader has its own themes and its own web view, and isn't touched.
enum DarkPages {
    enum Mode: String, CaseIterable {
        case off, system, always
    }

    /// Where the choices are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// The setting or a site's choice changed.
    static let changed = Signal<Void>()
    /// Posted with the tab as its object when its page is darkened or stops being darkened (`Tab.darkPage`), for
    /// whatever colors itself after the page, like the bar above it.
    static let pageDarkenedNotification = Notification.Name("ZigzagPageDarkenedChanged")

    private static let modeKey = "DarkPages"
    private static let onKey = "DarkPagesOnSites"
    private static let offKey = "DarkPagesOffSites"

    static var mode: Mode {
        get { defaults.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: modeKey); refreshAll() }
    }

    /// Sites (hosts without "www.") turned on, or off, in the site panel. A site covers its subdomains.
    static var sitesOn: Set<String> {
        get { Set(defaults.stringArray(forKey: onKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: onKey) }
    }

    static var sitesOff: Set<String> {
        get { Set(defaults.stringArray(forKey: offKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: offKey) }
    }

    static func site(of url: URL?) -> String? { ContentBlocker.site(of: url) }

    private static func covers(_ sites: Set<String>, _ site: String) -> Bool {
        sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// The site's own choice: on, off, or nil to follow the setting.
    static func choice(for url: URL?) -> Bool? {
        guard let site = site(of: url) else { return nil }
        if covers(sitesOn, site) { return true }
        if covers(sitesOff, site) { return false }
        return nil
    }

    /// Turns dark pages on or off for a site, or back to following the setting (nil). A choice the same as the
    /// setting's (Always, or Off) isn't kept: the site simply follows it.
    static func setChoice(_ on: Bool?, for url: URL?) {
        guard let site = site(of: url) else { return }
        var yes = sitesOn.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        var no = sitesOff.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        let fixed: Bool? = mode == .always ? true : mode == .off ? false : nil
        if let on, on != fixed {
            if on { yes.insert(site) } else { no.insert(site) }
        }
        sitesOn = yes
        sitesOff = no
        refreshAll()
    }

    /// Every site's choice forgotten (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        sitesOn = []
        sitesOff = []
        refreshAll()
    }

    // MARK: Deciding

    /// Whether pages should be dark: the site's own choice first, then the setting.
    static func wants(mode: Mode, systemIsDark: Bool, site: Bool?) -> Bool {
        if let site { return site }
        switch mode {
        case .off: return false
        case .system: return systemIsDark
        case .always: return true
        }
    }

    /// Whether Zigzag draws the page dark: only when it's wanted and the page isn't dark already. A page not looked
    /// at yet (`pageIsDark` nil) is darkened from the start, so it never shows white first.
    static func darkens(wants: Bool, pageIsDark: Bool?) -> Bool { wants && pageIsDark != true }

    /// Whether the Mac is in Dark Mode (the app's own appearance, which follows it).
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Whether pages at this address should be dark now.
    static func wants(_ url: URL?) -> Bool {
        wants(mode: mode, systemIsDark: systemIsDark, site: choice(for: url))
    }

    /// Only web pages, files and Zigzag's own pages; an extension's own page is its own business.
    static func applies(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return ["http", "https", "file", "about", HistoryPage.scheme].contains(scheme)
    }

    // MARK: Pages

    static let world = WKContentWorld.world(name: "zigzag-dark")
    static let messageName = "zigzagDark"
    /// Behind a darkened page while it loads and where it ends: the darkened white.
    static let underPageColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)

    /// Sites seen already dark, this session only (never written down: it would be a list of where you've been),
    /// so their pages aren't darkened first and then let go. Kept for each profile: a page can see whether it was
    /// darkened from its first moment, so one profile's list would tell a site it had been visited in another.
    /// A private window learns nothing and is given nothing.
    private static var nativeSites: [String: Set<String>] = [:]

    /// Whose list of sites seen dark a page's store reads and adds to: its profile's; nil for a private one.
    static func nativeScope(of store: WKWebsiteDataStore?) -> String? {
        guard let store, store.isPersistent else { return nil }
        return store.identifier?.uuidString ?? "default"
    }

    /// Sites seen dark in a profile (`nativeScope`), as given to its pages.
    static func nativeSites(in scope: String?) -> Set<String> {
        scope.flatMap { nativeSites[$0] } ?? []
    }

    private static let source: String = {
        guard let url = Bundle.main.url(forResource: "dark-pages", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The choices as the page script reads them, for pages in this store.
    static func config(for store: WKWebsiteDataStore?) -> [String: Any] {
        ["on": wants(mode: mode, systemIsDark: systemIsDark, site: nil), "sitesOn": sitesOn.sorted(), "sitesOff": sitesOff.sorted(),
         "native": nativeSites(in: nativeScope(of: store)).sorted()]
    }

    private static func configJSON(for store: WKWebsiteDataStore?) -> String {
        (try? JSONSerialization.data(withJSONObject: config(for: store), options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The first line of the page script, so it can be told from a web view's other scripts at a glance.
    static let scriptMark = "/* zigzag dark pages */\n"

    static func script(for store: WKWebsiteDataStore?) -> WKUserScript {
        WKUserScript(source: scriptMark + source.replacingOccurrences(of: "__CONFIG__", with: configJSON(for: store)),
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// By its first line only. A web view's scripts come to hundreds of kilobytes (autofill, Reader, an extension's
    /// bridge); searching all of them for a word, as this once did, held up every new tab for a quarter of a second
    /// and every open tab at once when a page taught it a site (#89).
    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(scriptMark) }

    /// Puts the page script, with the choices as they are now, into a web view's set of scripts, in place of the
    /// one it had. Pages already open hear of a change from `refresh`; this is for the pages loaded after it.
    private static func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let scripts = controller.userScripts
        let others = scripts.filter { !isOurs($0) }
        if others.count != scripts.count {
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        let store = webView.configuration.websiteDataStore
        controller.addUserScript(script(for: store))
        installed[ObjectIdentifier(controller)] = Installed(generation: generation, native: nativeSites(in: nativeScope(of: store)))
    }

    /// Counts up each time the choices change (the setting, a site's own, the Mac's appearance): a web view whose
    /// script is older gets the new one as it next goes to a page, if `refreshAll` hasn't reached it yet.
    private static var generation = 0
    /// What each web view's script (by their set, shared by a page and the pop-ups it opened) was given.
    private struct Installed {
        var generation: Int
        /// The profile's sites seen dark, then.
        var native: Set<String>
    }
    private static var installed: [ObjectIdentifier: Installed] = [:]

    /// Whether a page going to `site` needs the script put in again for what was learned since: only when that site
    /// joined or left the list it was given. Any page teaching it a site moved every tab to new scripts, a few hundred
    /// kilobytes each, as each next changed its address (#89); the list is only read for the page's own site.
    static func siteChanged(_ site: String?, given: Set<String>, now: Set<String>) -> Bool {
        guard let site else { return false }
        return given.contains(site) != now.contains(site)
    }

    private static func installIfStale(in webView: WKWebView) {
        let key = ObjectIdentifier(webView.configuration.userContentController)
        guard let given = installed[key], given.generation == generation else { install(in: webView); return }
        let now = nativeSites(in: nativeScope(of: webView.configuration.websiteDataStore))
        if siteChanged(site(of: webView.url), given: given.native, now: now) { install(in: webView) }
    }

    private final class Entry {
        weak var webView: WKWebView?
        var observation: NSKeyValueObservation?
        /// The look again a moment after the address last changed: a single-page app changing its address as you
        /// scroll is looked at once it settles, not for every change.
        var recheck: DispatchWorkItem?
        init(_ webView: WKWebView) { self.webView = webView }
    }

    /// Open pages hearing of a change a few at a time, the ones on screen first (`refreshAll`).
    private static let refreshes = StagedQueue<ObjectIdentifier>(perStep: 4, interval: 0.05)

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var appearanceObservation: NSKeyValueObservation?

    /// A tab's new web view: it gets the page script and follows the choices from here on.
    static func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        install(in: webView)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: world)
        controller.add(Messages.shared, contentWorld: world, name: messageName)
        let entry = Entry(webView)
        // Going to another site, its own choice applies before its page starts.
        entry.observation = webView.observe(\.url, options: [.new]) { [weak entry] webView, _ in
            MainActor.assumeIsolated {
                // Sites learned since its script was put in: the page it's going to starts with them.
                installIfStale(in: webView)
                applyLook(to: webView)
                // A single-page app's new view, which loads nothing: looked at again once it's drawn.
                entry?.recheck?.cancel()
                let work = DispatchWorkItem { [weak webView] in
                    MainActor.assumeIsolated { if let webView { recheck(webView) } }
                }
                entry?.recheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
        entries = entries.filter { $0.value.webView != nil }
        let live = Set(entries.values.compactMap { $0.webView.map { ObjectIdentifier($0.configuration.userContentController) } })
        installed = installed.filter { live.contains($0.key) || $0.key == ObjectIdentifier(controller) }
        entries[ObjectIdentifier(webView)] = entry
        applyLook(to: webView)
        if appearanceObservation == nil {
            // The Mac going dark or light, for "When the Mac is dark".
            appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
                DispatchQueue.main.async { if mode == .system { refreshAll() } }
            }
        }
    }

    /// The web view's look for the page it's on: dark when dark pages are wanted there, so the page's own dark theme
    /// is the one used, and dark behind the page while it loads. Otherwise it follows the window, as always.
    private static func applyLook(to webView: WKWebView) {
        let url = webView.url
        let wanted = applies(to: url) && wants(url)
        let appearance = wanted ? NSAppearance(named: .darkAqua) : nil
        if webView.appearance?.name != appearance?.name { webView.appearance = appearance }
        let tab = (webView as? BrowserWebView)?.owner
        // A page that's dark on its own shows its own color past its edges, as without dark pages.
        let own = tab?.darkPage?.native == true && tab?.darkPage?.site == site(of: url)
        webView.underPageBackgroundColor = wanted && !own ? underPageColor : nil
    }

    /// The setting, a site's choice or the Mac's appearance changed: every open page follows at once, without
    /// reloading, and pages loaded later start the right way.
    static func refreshAll() {
        entries = entries.filter { $0.value.webView != nil }
        // Every script put in before now is out of date, so a page that goes somewhere before its turn below gets the
        // new one all the same.
        generation += 1
        // The look at once; the new script and the page's own change a few at a time, on screen first: all of them in
        // one go held Zigzag up with many tabs open.
        let webViews = entries.values.compactMap(\.webView).sorted { ($0.window != nil ? 0 : 1) < ($1.window != nil ? 0 : 1) }
        for webView in webViews {
            applyLook(to: webView)
            refreshes.add(ObjectIdentifier(webView)) { [weak webView] in
                guard let webView else { return }
                installIfStale(in: webView)
                webView.callAsyncJavaScript("if (window.__zigzagDark) window.__zigzagDark.set(config);",
                                            arguments: ["config": config(for: webView.configuration.websiteDataStore)],
                                            in: nil, in: world) { _ in }
            }
        }
        changed.send()
    }

    /// The page script's own look again, for a page that changed without loading (a single-page app's new view).
    static func recheck(_ webView: WKWebView) {
        webView.callAsyncJavaScript("if (window.__zigzagDark) window.__zigzagDark.check();", arguments: [:], in: nil, in: world) { _ in }
    }

    /// What the page script found on a page.
    struct State: Equatable {
        /// Zigzag is drawing the page dark.
        var darkened: Bool
        /// The page is dark on its own.
        var native: Bool
        /// The page's background as it's drawn now, darkened or not.
        var color: NSColor?
        var site: String
    }

    /// What a page in this store found: a site it saw dark, or saw light, joins or leaves its profile's list.
    /// True when the list changed.
    @discardableResult
    static func learn(_ state: State, in scope: String?) -> Bool {
        guard let scope, !state.site.isEmpty else { return false }
        let before = nativeSites[scope] ?? []
        var after = before
        if state.native { after.insert(state.site) } else if state.darkened { after.remove(state.site) }
        nativeSites[scope] = after
        return after != before
    }

    fileprivate static func received(_ state: State, from webView: WKWebView) {
        // Learned sites go into the scripts of pages loaded later in the same profile; not from a private window.
        // Each web view takes them as it next goes to a page (`installIfStale`): putting them into every open tab's
        // scripts at once held Zigzag up for seconds with many tabs open (#89).
        if learn(state, in: nativeScope(of: webView.configuration.websiteDataStore)) { generation += 1 }
        if let tab = (webView as? BrowserWebView)?.owner { tab.darkPageChanged(state) }
        applyLook(to: webView)
    }

    /// Hears the page script.
    private final class Messages: NSObject, WKScriptMessageHandler {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let webView = message.webView else { return }
            let state = State(darkened: body["darkened"] as? Bool ?? false, native: body["native"] as? Bool ?? false,
                              color: (body["color"] as? String).flatMap(DarkPages.color(hex:)), site: body["site"] as? String ?? "")
            DarkPages.received(state, from: webView)
        }
    }

    static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

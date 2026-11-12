import AppKit
import WebKit

/// Dark pages: a page without a dark look of its own is drawn dark, one that has its own is left alone.
///
/// Settings › Appearance › Dark pages turns it on always, while the Mac is dark, or not at all, and the site panel
/// turns it on or off for one site. Where it's on, the page is first told dark is preferred (the web view's
/// appearance is dark, so `prefers-color-scheme: dark` matches and a site with its own dark theme uses it). A page
/// that still draws itself light is darkened by Dark Reader's dynamic theme (`darkreader.js`, run by dark-pages.js in
/// Zigzag's own script world, with Dark Reader's site fixes from `DarkReaderFixes`), which rewrites the site's own
/// style, so pictures and video stay as they are. Every frame gets it and decides for itself, as a page would: a
/// light widget comes out dark and a dark video player as it is. Sites seen dark on their own are remembered
/// (`DarkSeen`) and start on their own dark. Force dark, in the site panel, darkens a site that looks dark as if it
/// didn't (#134). Pure black backgrounds draws white as black instead of a dark gray. Reader has its own themes and
/// its own web view, and isn't touched.
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
    private static let forcedKey = "DarkPagesForcedSites"
    private static let blackKey = "DarkPagesPureBlack"

    static var mode: Mode {
        get { defaults.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: modeKey); refreshAll() }
    }

    /// Settings › Appearance › Pure black backgrounds: a darkened page's white becomes black instead of a dark gray.
    static var pureBlack: Bool {
        get { defaults.bool(forKey: blackKey) }
        set { defaults.set(newValue, forKey: blackKey); refreshAll() }
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

    /// Sites darkened even when they look dark on their own (Force dark in the site panel, #134): for a site that
    /// says it's dark and isn't all the way, or draws parts of itself light.
    static var sitesForced: Set<String> {
        get { Set(defaults.stringArray(forKey: forcedKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: forcedKey) }
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
    /// setting's (Always, or Off) isn't kept: the site simply follows it. Anything but on lets go of Force dark.
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
        if on != true { sitesForced = sitesForced.filter { !(site == $0 || site.hasSuffix("." + $0)) } }
        refreshAll()
    }

    /// Whether a site is darkened even when it looks dark on its own.
    static func isForced(_ url: URL?) -> Bool {
        guard let site = site(of: url) else { return false }
        return covers(sitesForced, site)
    }

    /// Force dark for a site. On turns dark pages on there too, since forcing means drawing it dark.
    static func setForced(_ on: Bool, for url: URL?) {
        guard let site = site(of: url) else { return }
        var forced = sitesForced.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        if on { forced.insert(site) }
        sitesForced = forced
        if on, !wants(url) { setChoice(true, for: url) } else { refreshAll() }
    }

    /// Every site's choice forgotten (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        sitesOn = []
        sitesOff = []
        sitesForced = []
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
    static let fetchMessageName = "zigzagDarkFetch"
    static let imageMessageName = "zigzagDarkImage"

    /// The dark Dark Reader draws a page's white as: its own default, or black for Pure black.
    static func background(black: Bool) -> NSColor {
        black ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(srgbRed: 0x18 / 255, green: 0x1a / 255, blue: 0x1b / 255, alpha: 1)
    }

    /// Dark Reader's theme: its own, with black for Pure black.
    static func theme(black: Bool) -> [String: Any] {
        ["mode": 1, "brightness": 100, "contrast": 100, "sepia": 0, "grayscale": 0,
         "darkSchemeBackgroundColor": black ? "#000000" : "#181a1b", "darkSchemeTextColor": "#e8e6e3"]
    }

    /// What a page last seen dark on its own starts on until it's looked at (#134): a dark color-scheme, so WebKit's
    /// own ground under the page is dark rather than white, and the site's own dark on the root (as it was seen), with
    /// the body clear so it shows. It goes in the frame the page is first looked at, before that frame is drawn: one
    /// that's dark keeps its own colors, a light one is darkened.
    static func prepaintCSS(black: Bool, color: String? = nil) -> String {
        let own = color.flatMap { hex -> String? in
            guard let parsed = Self.color(hex: hex), isDark(parsed) else { return nil }
            return self.hex(parsed)
        }
        let hex = own ?? self.hex(background(black: black))
        return ":root { color-scheme: dark !important; background-color: \(hex) !important; }\nbody { background-color: transparent !important; }\n"
    }

    /// Dark enough to start a page on, as dark-pages.js tells a dark page from a light one.
    static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        func f(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent) < 0.2
    }

    /// "#0d1117".
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { min(255, max(0, Int(($0 * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2])
    }

    // Sites seen dark on their own are kept in `DarkSeen`, so their pages start on their own dark rather than being
    // darkened first and then let go. Kept for each profile: a page can see whether it was darkened from its first
    // moment, so one profile's list would tell a site it had been visited in another. A private window learns nothing
    // and is given nothing.

    /// Whose list of sites seen dark a page's store reads and adds to: its profile's; nil for a private one.
    static func nativeScope(of store: WKWebsiteDataStore?) -> String? {
        guard let store, store.isPersistent else { return nil }
        return store.identifier?.uuidString ?? "default"
    }

    /// Sites seen dark in a profile (`nativeScope`), as given to its pages.
    static func nativeSites(in scope: String?) -> Set<String> {
        Set(DarkSeen.sites(in: scope).keys)
    }

    /// What's kept for the site a page at `url` in this store is going to, if it was seen dark there.
    static func seen(for store: WKWebsiteDataStore?, url: URL?) -> DarkSeen.Site? {
        DarkSeen.site(site(of: url), in: nativeScope(of: store))
    }

    /// What a page's script is given from it: its dark and its mark, not when it was seen.
    static func seenKey(_ seen: DarkSeen.Site?) -> String? {
        seen.map { "\($0.color ?? "")|\($0.marker ?? "")" }
    }

    static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The page script with Dark Reader in it, cut where the choices go: what's before them, and what's after.
    private static let source: (head: String, tail: String) = {
        let page = resource("dark-pages").replacingOccurrences(of: "__DARKREADER__", with: resource("darkreader"))
        let parts = page.components(separatedBy: "__CONFIG__")
        return parts.count == 2 ? (parts[0], parts[1]) : (page, "")
    }()

    /// The choices as the page script reads them, for pages in this store, going to `url`.
    static func config(for store: WKWebsiteDataStore?, url: URL? = nil) -> [String: Any] {
        let black = pureBlack
        let seen = seen(for: store, url: url)
        let top = applies(to: url) && wants(url)
        return [
            "on": wants(mode: mode, systemIsDark: systemIsDark, site: nil), "sitesOn": sitesOn.sorted(), "sitesOff": sitesOff.sorted(),
            "sitesForced": sitesForced.sorted(), "topWanted": top, "topForced": top && isForced(url),
            "native": nativeSites(in: nativeScope(of: store)).sorted(), "prepaint": prepaintCSS(black: black, color: seen?.color),
            "marker": seen?.marker ?? NSNull(), "theme": theme(black: black),
            "fix": DarkReaderFixes.fix(for: url).json, "frameFix": DarkReaderFixes.fix(for: nil).json]
    }

    private static func configJSON(for store: WKWebsiteDataStore?, url: URL?) -> String {
        (try? JSONSerialization.data(withJSONObject: config(for: store, url: url), options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The first line of the page script, so it can be told from a web view's other scripts at a glance.
    static let scriptMark = "/* zigzag dark pages */\n"

    static func script(for store: WKWebsiteDataStore?, url: URL? = nil) -> WKUserScript {
        WKUserScript(source: scriptMark + source.head + configJSON(for: store, url: url) + source.tail,
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    /// Dark Reader's proxy, in the page's own world: it tells Dark Reader of style the page changes through the CSSOM
    /// (adopted sheets, inserted rules, custom elements), which it can't see from Zigzag's world. Dark Reader asks for it
    /// with an event (scripts/update-darkreader.sh), rather than as an inline script a page's Content-Security-Policy
    /// could block.
    static let proxyScript: WKUserScript = {
        let proxy = resource("darkreader-proxy")
        let source = scriptMark + """
        (() => {
        \(proxy)
          for (const a of [0, 1]) for (const b of [0, 1]) {
            document.addEventListener('__zigzag_darkreader_proxy_' + a + b, () => injectProxy(a === 1, b === 1));
          }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }()

    /// By its first line only. A web view's scripts come to hundreds of kilobytes (autofill, Reader, an extension's
    /// bridge); searching all of them for a word, as this once did, held up every new tab for a quarter of a second
    /// and every open tab at once when a page taught it a site (#89).
    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(scriptMark) }

    /// Puts the page scripts, with the choices as they are now, into a web view's set of scripts, in place of the
    /// ones it had: only where dark pages are wanted for the page it's going to, since Dark Reader is a few hundred
    /// kilobytes for every frame to read. Pages already open hear of a change from `refresh`; this is for the pages
    /// loaded after it.
    private static func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let scripts = controller.userScripts
        let others = scripts.filter { !isOurs($0) }
        if others.count != scripts.count {
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        let store = webView.configuration.websiteDataStore
        let wanted = applies(to: webView.url) && wants(webView.url)
        if wanted {
            controller.addUserScript(proxyScript)
            controller.addUserScript(script(for: store, url: webView.url))
        }
        installed[ObjectIdentifier(controller)] = Installed(generation: generation, wanted: wanted, native: nativeSites(in: nativeScope(of: store)),
                                                            seen: seenKey(seen(for: store, url: webView.url)), fix: fixKey(webView.url))
    }

    /// Counts up each time the choices change (the setting, a site's own, the Mac's appearance): a web view whose
    /// script is older gets the new one as it next goes to a page, if `refreshAll` hasn't reached it yet.
    private static var generation = 0
    /// What each web view's script (by their set, shared by a page and the pop-ups it opened) was given.
    private struct Installed {
        var generation: Int
        /// Whether it had the scripts at all.
        var wanted: Bool
        /// The profile's sites seen dark, then.
        var native: Set<String>
        /// The dark and mark of the site it was going to (`seenKey`).
        var seen: String?
        /// Which of Dark Reader's fixes it was given (`fixKey`).
        var fix: String
    }
    private static var installed: [ObjectIdentifier: Installed] = [:]

    /// Which fixes a page at `url` gets, to tell when the page a web view goes to needs others.
    static func fixKey(_ url: URL?) -> String {
        let fix = DarkReaderFixes.fix(for: url)
        return "\(fix.invert.count)|\(fix.css.count)|\(fix.css.hashValue)|\(fix.ignoreInlineStyle.count)|\(fix.ignoreImageAnalysis.count)|\(fix.ignoreCSSUrl.count)"
    }

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
        let url = webView.url
        // Going somewhere dark pages are wanted, or aren't, while the last place was the other way.
        if given.wanted != (applies(to: url) && wants(url)) { install(in: webView); return }
        guard given.wanted else { return }
        let store = webView.configuration.websiteDataStore
        let now = nativeSites(in: nativeScope(of: store))
        if siteChanged(site(of: url), given: given.native, now: now) { install(in: webView); return }
        // The site's own dark or mark, learned or changed since: the page starts on them.
        if let seen = seenKey(seen(for: store, url: url)), seen != given.seen { install(in: webView); return }
        // A site with fixes of its own, or going from one.
        if fixKey(url) != given.fix { install(in: webView) }
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
        controller.removeScriptMessageHandler(forName: fetchMessageName, contentWorld: world)
        controller.addScriptMessageHandler(Fetches.shared, contentWorld: world, name: fetchMessageName)
        controller.removeScriptMessageHandler(forName: imageMessageName, contentWorld: world)
        controller.addScriptMessageHandler(Images.shared, contentWorld: world, name: imageMessageName)
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

    /// The web view's look for the page it's on: dark when dark pages are wanted there (even with the Mac light), so
    /// the page's own dark theme is the one used, and dark behind the page while it loads. Otherwise it follows the
    /// window, as always.
    private static func applyLook(to webView: WKWebView) {
        let url = webView.url
        let wanted = applies(to: url) && wants(url)
        // Forced dark, the site is asked for its light look, which is darkened as a light site's is: its own dark
        // look, which drew parts of it light, is what Force dark is for.
        let appearance = wanted ? NSAppearance(named: isForced(url) ? .aqua : .darkAqua) : nil
        if webView.appearance?.name != appearance?.name { webView.appearance = appearance }
        let tab = (webView as? BrowserWebView)?.owner
        // Not wanted here, the page has no script to say so: what was heard of the page before doesn't hold, and the
        // bar above it shouldn't keep that page's dark.
        if !wanted, let tab, let state = tab.darkPage, state.darkened || state.native {
            tab.darkPageChanged(State(darkened: false, native: false, color: nil, site: site(of: url) ?? ""))
        }
        let store = webView.configuration.websiteDataStore
        // A site seen dark on its own starts on its own dark; any other on the dark its white will be. A page that's
        // dark on its own shows its own dark past its edges, the one the bar above it takes (#134): WebKit's own color
        // there is the page's root's, which can be white under a dark page.
        let ground = seen(for: store, url: url)?.color.flatMap(color(hex:)).flatMap { isDark($0) ? $0 : nil } ?? background(black: pureBlack)
        webView.underPageBackgroundColor = wanted ? underPage(tab?.darkPage, site: site(of: url), ground: ground) : nil
        // No white of WebKit's own under the page (#134): a new web view's first frame, or one bringing back a tab that
        // slept, was drawn on it before the page came, and stayed on screen until the page had drawn itself, since
        // WebKit holds what's shown while a page is on its way. Clear instead, the dark of the card shows there.
        let draws = !wanted
        if webView.value(forKey: "drawsBackground") as? Bool != draws { webView.setValue(draws, forKey: "drawsBackground") }
    }

    /// Behind a page where dark pages are wanted: a page dark on its own (and not darkened anyway), its own dark as the
    /// page script saw it; any other, the dark its white will be.
    static func underPage(_ state: State?, site: String?, ground: NSColor) -> NSColor? {
        guard let state, state.native, !state.darkened, state.site == site else { return ground }
        return state.color
    }

    /// For what turns a page's own background on or off for a while (Peek): back to how dark pages want it.
    static func restoreGround(of webView: WKWebView) { applyLook(to: webView) }

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
                refresh(webView)
            }
        }
        changed.send()
    }

    /// An open page, and each of its frames, told of the choices as they are now; one without the script yet (dark
    /// pages just turned on there) is given it.
    private static func refresh(_ webView: WKWebView) {
        let store = webView.configuration.websiteDataStore
        let wanted = applies(to: webView.url) && wants(webView.url)
        let config = config(for: store, url: webView.url)
        let frames: [WKFrameInfo?] = [nil] + PageFrames.shared.frames(in: webView)
        for frame in frames {
            webView.callAsyncJavaScript("if (window.__zigzagDark) { window.__zigzagDark.set(config); return true; } return false;",
                                        arguments: ["config": config], in: frame, in: world) { result in
                guard wanted, case .success(let had) = result, (had as? Bool) == false else { return }
                MainActor.assumeIsolated {
                    webView.evaluateJavaScript(proxyScript.source, in: frame, in: .page) { _ in }
                    webView.evaluateJavaScript(script(for: store, url: webView.url).source, in: frame, in: world) { _ in }
                }
            }
        }
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
        /// The mark the page's own dark look set on its root by script (`DarkSeen.Site.marker`): "" for none, nil when
        /// the page didn't say.
        var marker: String? = nil
    }

    /// What a page in this store found: a site it saw dark, or saw light, joins or leaves its profile's list, with
    /// its own dark and the mark it sets for it. True when the list changed (a site joined or left).
    @discardableResult
    static func learn(_ state: State, in scope: String?) -> Bool {
        guard let scope, !state.site.isEmpty else { return false }
        let before = DarkSeen.site(state.site, in: scope)
        var after: DarkSeen.Site?
        if state.native {
            var site = before ?? DarkSeen.Site(color: nil, marker: nil, date: Date())
            // Its own look only: a page forced dark is drawn in Zigzag's.
            if !state.darkened {
                if let color = state.color, isDark(color) { site.color = hex(color) }
                if let marker = state.marker { site.marker = marker.isEmpty ? nil : marker }
            }
            if let before, site != before { site.date = Date() }
            after = site
        } else if state.darkened {
            after = nil
        } else {
            after = before
        }
        if after != before { DarkSeen.set(state.site, after, in: scope) }
        return (before == nil) != (after == nil)
    }

    fileprivate static func received(_ state: State, from webView: WKWebView) {
        // Learned sites go into the scripts of pages loaded later in the same profile; not from a private window.
        // Each web view takes them as it next goes to a page (`installIfStale`): putting them into every open tab's
        // scripts at once held Zigzag up for seconds with many tabs open (#89).
        // This web view takes them at once, though: loading the same page again doesn't change its address, and it would
        // start darkened again, Dark Reader at work on a site that's dark on its own.
        if learn(state, in: nativeScope(of: webView.configuration.websiteDataStore)) {
            generation += 1
            install(in: webView)
        }
        if let tab = (webView as? BrowserWebView)?.owner { tab.darkPageChanged(state) }
        applyLook(to: webView)
    }

    /// Hears the page script.
    private final class Messages: NSObject, WKScriptMessageHandler {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let webView = message.webView else { return }
            let state = State(darkened: body["darkened"] as? Bool ?? false, native: body["native"] as? Bool ?? false,
                              color: (body["color"] as? String).flatMap(DarkPages.color(hex:)), site: body["site"] as? String ?? "",
                              marker: (body["marker"] as? String).flatMap(DarkPages.marker(_:)))
            DarkPages.received(state, from: webView)
        }
    }

    // MARK: Fetching for Dark Reader

    /// Whether something a page's Dark Reader can't fetch itself may be fetched for it: only from the web, never local
    /// or private addresses the page didn't reach the same way.
    static func fetchable(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }
        // A literal address on this Mac's networks.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1])) { return false }
        }
        if host.contains(":") { return false }
        return true
    }

    /// Only style sheets and pictures, which is all Dark Reader reads.
    nonisolated static func fetchableType(_ type: String) -> Bool {
        let type = type.lowercased()
        return type.isEmpty || type.contains("css") || type.hasPrefix("text/plain") || type.hasPrefix("image/")
    }

    nonisolated static let maxFetchBytes = 5 * 1024 * 1024

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// A style sheet or picture, as its type and its bytes in base64, or nil: neither, too big, or not there.
    nonisolated static func fetch(_ url: URL) async -> [String: String]? {
        var request = URLRequest(url: url)
        request.setValue("text/css,image/*,*/*;q=0.1", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), data.count <= maxFetchBytes else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard fetchableType(type) else { return nil }
        return ["type": type, "body": data.base64EncodedString()]
    }

    /// Fetches what a page's Dark Reader can't (from elsewhere, without CORS), without cookies. Never for a private
    /// window, whose pages ask nothing of the network they didn't ask themselves.
    private final class Fetches: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Fetches()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard let webView = message.webView, nativeScope(of: webView.configuration.websiteDataStore) != nil,
                  let href = message.body as? String, let url = URL(string: href), fetchable(url) else { replyHandler(nil, nil); return }
            Task {
                let got = await DarkPages.fetch(url)
                replyHandler(got, nil)
            }
        }
    }

    /// The largest SVG drawn for Dark Reader, and the largest side it's drawn at: it looks at a picture 32 pixels across.
    nonisolated static let maxImageBytes = 2 * 1024 * 1024
    nonisolated static let maxImageSide: CGFloat = 512

    /// An SVG picture, given as a data: URL, drawn as a PNG for Dark Reader to look at, with its own size in CSS
    /// pixels; nil if it isn't one. Where a page's policy won't let an image load a data: URL, its picture can't be
    /// looked at otherwise (#134).
    nonisolated static func rasterize(_ dataURL: String) -> (width: Double, height: Double, png: String)? {
        guard dataURL.utf8.count <= maxImageBytes, dataURL.lowercased().hasPrefix("data:image/svg+xml"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let head = dataURL[..<comma].lowercased(), body = String(dataURL[dataURL.index(after: comma)...])
        let data = head.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        guard let data, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxImageSide / max(image.size.width, image.size.height))
        let width = max(1, Int((image.size.width * scale).rounded())), height = max(1, Int((image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (Double(image.size.width), Double(image.size.height), png.base64EncodedString())
    }

    /// Draws SVG pictures for a page's Dark Reader (`rasterize`), off the main thread.
    private final class Images: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Images()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard let url = message.body as? String else { replyHandler(nil, nil); return }
            Task.detached(priority: .utility) {
                let drawn = DarkPages.rasterize(url)
                await MainActor.run { replyHandler(drawn.map { ["width": $0.width, "height": $0.height, "png": $0.png] }, nil) }
            }
        }
    }

    /// The marks a dark look is known by, as dark-pages.js reads them off the page's root.
    static let markerAttributes = ["data-color-mode", "data-theme", "data-bs-theme", "data-mode", "data-color-scheme", "data-mantine-color-scheme"]
    static let markerClasses = ["dark", "dark-mode", "theme-dark", "dark-theme"]

    /// A mark a page said its dark look set, if it's one of those (else nil: not kept); "" for none.
    static func marker(_ said: String) -> String? {
        if said.isEmpty { return "" }
        if said.hasPrefix("class:"), markerClasses.contains(String(said.dropFirst(6))) { return said }
        if said.hasPrefix("attr:") {
            let parts = said.dropFirst(5).split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, markerAttributes.contains(parts[0]), parts[1] == "dark" { return said }
        }
        return nil
    }

    static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

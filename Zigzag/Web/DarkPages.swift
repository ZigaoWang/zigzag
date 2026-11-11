import AppKit
import WebKit

/// Dark pages: a page without a dark look of its own is drawn dark, one that has its own is left alone.
///
/// Settings › Appearance › Dark pages turns it on always, while the Mac is dark, or not at all, and the site panel
/// turns it on or off for one site. Where it's on, the page is first told dark is preferred (the web view's
/// appearance is dark, so `prefers-color-scheme: dark` matches and a site with its own dark theme uses it). Only a
/// page that still draws itself light is darkened, by dark-pages.js. The first time a site is seen that's one filter on
/// the page's root, with pictures and video turned back, drawn by WebKit on the GPU with no script per element; once
/// the page is idle its colors are read and turned into a dark palette for the site (`DarkPalettes`), and from the
/// next visit on the page is drawn with that from its first frame: the site's own colors made dark, with pictures
/// untouched and nothing watching the page. Where a palette doesn't cover a page, the filter stays. Every frame gets the script: a frame from elsewhere (a player, a map, a widget) is turned back by the
/// page around it and darkens itself, or not, as a page would. Pure black backgrounds draws white as black instead of
/// a dark gray. Reader has its own themes and its own web view, and isn't touched.
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
    /// How far a darkened page's colors are turned over: white becomes `1 - strength` gray, black for Pure black.
    static func strength(black: Bool) -> Double { black ? 1 : 0.92 }

    /// Behind a darkened page while it loads and where it ends: the darkened white.
    static func underPageColor(black: Bool) -> NSColor {
        let gray = 1 - strength(black: black)
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }

    static var underPageColor: NSColor { underPageColor(black: pureBlack) }

    // MARK: The style

    /// On a picture's own element (a background photo), and on one whose ::before or ::after shows a picture.
    static let imageMark = "data-zigzag-dark-image"
    static let beforeMark = "data-zigzag-dark-before"
    static let afterMark = "data-zigzag-dark-after"
    /// On a frame whose page has Zigzag's script: it's turned back and looks after its own darkening.
    static let frameMark = "data-zigzag-dark-frame"

    /// What's turned back to how it looks: pictures, video, drawing, plugins, and frames that darken themselves.
    /// An SVG drawing (an img of an .svg, or inline svg) is usually a logo or icon drawn in the text's ink: it's left
    /// darkened with the page, so a black logo doesn't vanish into the dark; a photo inside one is turned back.
    static let replaced: [String] = [
        #"img:not([src$=".svg"]):not([src*=".svg?"])"#, "picture", "video", "canvas", "embed", "object", "svg image",
        "input[type=image]", "[\(imageMark)]", #"[style*="background-image"][style*="url("]"#, #"[style*="background:"][style*="url("]"#,
        "iframe[\(frameMark)]",
        // Video players and maps from elsewhere, framed in the page, for when their own frame can't run the script.
        #"iframe[src*="youtube.com/embed"]"#, #"iframe[src*="youtube-nocookie.com"]"#, #"iframe[src*="player.vimeo.com"]"#,
        #"iframe[src*="google.com/maps"]"#, #"iframe[src*="player.bilibili.com"]"#, #"iframe[src*="player.twitch.tv"]"#,
    ]

    /// The filter that undoes the page's: inverting by `strength` maps v to s + v(1 - 2s), so after inverting fully,
    /// contrast of 1 / (2s - 1) puts every tone back where it was (the darkest and lightest few clip, as the page's do).
    static func restoreFilter(black: Bool) -> String {
        let contrast = 1 / (2 * strength(black: black) - 1)
        let tail = abs(contrast - 1) < 0.0001 ? "" : " contrast(\(String(format: "%.4f", contrast)))"
        return "invert(1) hue-rotate(180deg)" + tail
    }

    /// The rule on a darkened page's root, and on a darkened frame's.
    static func rootCSS(black: Bool) -> String {
        "html { filter: invert(\(strength(black: black))) hue-rotate(180deg) !important; color-scheme: light !important; }\n"
    }

    /// A page painting no background of its own shows white, then darkened. Not in a frame: one painting nothing
    /// shows the page around it.
    static let canvasCSS = ":where(html) { background-color: #fff; }\n"

    /// Pictures and the rest turned back, once: not again inside something turned back already. Shadow roots get
    /// this alone, since the document's style doesn't reach inside them.
    static func mediaCSS(black: Bool) -> String {
        let all = replaced.joined(separator: ", ")
        let restore = restoreFilter(black: black)
        let before = "[\(beforeMark)]::before", after = "[\(afterMark)]::after"
        return """
        :is(\(all)) { filter: \(restore) !important; }
        :is(\(all)) :is(\(all)) { filter: none !important; }
        \(before), \(after) { filter: \(restore) !important; }
        :is(\(all)) \(before), :is(\(all)) \(after), :is(\(all))\(before), :is(\(all))\(after) { filter: none !important; }

        """
    }

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

    static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The palette's colors and the page script around them, as one script.
    private static let source: String = {
        let palette = resource("dark-palette").trimmingCharacters(in: .whitespacesAndNewlines)
        return resource("dark-pages").replacingOccurrences(of: "__PALETTE__", with: palette.isEmpty ? "null" : palette)
    }()

    /// How long after a page has loaded its colors are read (tests wait less).
    static var paletteDelay = 1200

    /// The site's palette a page at `url` in this store starts with: its own, for the backgrounds chosen now.
    static func palette(for store: WKWebsiteDataStore?, url: URL?) -> DarkPalettes.Entry? {
        DarkPalettes.entry(origin: DarkPalettes.origin(of: url), black: pureBlack, scope: nativeScope(of: store))
    }

    /// The choices as the page script reads them, for pages in this store, going to `url` (the site whose palette
    /// comes with them).
    static func config(for store: WKWebsiteDataStore?, url: URL? = nil) -> [String: Any] {
        let black = pureBlack
        var config: [String: Any] = [
            "on": wants(mode: mode, systemIsDark: systemIsDark, site: nil), "sitesOn": sitesOn.sorted(), "sitesOff": sitesOff.sorted(),
            "native": nativeSites(in: nativeScope(of: store)).sorted(), "black": black, "strength": strength(black: black),
            "root": rootCSS(black: black), "canvas": canvasCSS, "media": mediaCSS(black: black),
            "marks": ["image": imageMark, "before": beforeMark, "after": afterMark, "frame": frameMark],
            "learn": nativeScope(of: store) != nil, "paletteDelay": paletteDelay, "palette": NSNull()]
        if let entry = palette(for: store, url: url) {
            config["palette"] = ["origin": entry.origin, "black": entry.black, "css": entry.css, "invert": entry.invert,
                                 "fingerprints": entry.fingerprints, "verified": entry.verified]
        }
        return config
    }

    private static func configJSON(for store: WKWebsiteDataStore?, url: URL?) -> String {
        (try? JSONSerialization.data(withJSONObject: config(for: store, url: url), options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Which palette a web view's script was given, to tell when the page it's going to has another.
    static func paletteKey(_ entry: DarkPalettes.Entry?) -> String? {
        entry.map { "\($0.origin)|\($0.black)|\($0.revision)" }
    }

    /// Whether a page going to `origin` needs the script put in again for its palette: when its site has one other
    /// than the one given, or was given one that's gone. Going anywhere else, the one given is simply not used.
    static func paletteChanged(given: String?, now: String?, origin: String?) -> Bool {
        if let now { return now != given }
        guard let given, let origin else { return false }
        return given.hasPrefix(origin + "|")
    }

    /// The first line of the page script, so it can be told from a web view's other scripts at a glance.
    static let scriptMark = "/* zigzag dark pages */\n"

    static func script(for store: WKWebsiteDataStore?, url: URL? = nil) -> WKUserScript {
        WKUserScript(source: scriptMark + source.replacingOccurrences(of: "__CONFIG__", with: configJSON(for: store, url: url)),
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
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
        controller.addUserScript(script(for: store, url: webView.url))
        installed[ObjectIdentifier(controller)] = Installed(generation: generation, native: nativeSites(in: nativeScope(of: store)),
                                                            palette: paletteKey(palette(for: store, url: webView.url)))
    }

    /// Counts up each time the choices change (the setting, a site's own, the Mac's appearance): a web view whose
    /// script is older gets the new one as it next goes to a page, if `refreshAll` hasn't reached it yet.
    private static var generation = 0
    /// What each web view's script (by their set, shared by a page and the pop-ups it opened) was given.
    private struct Installed {
        var generation: Int
        /// The profile's sites seen dark, then.
        var native: Set<String>
        /// The palette that came with it (`paletteKey`).
        var palette: String?
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
        let store = webView.configuration.websiteDataStore
        let now = nativeSites(in: nativeScope(of: store))
        if siteChanged(site(of: webView.url), given: given.native, now: now) { install(in: webView); return }
        if paletteChanged(given: given.palette, now: paletteKey(palette(for: store, url: webView.url)), origin: DarkPalettes.origin(of: webView.url)) {
            install(in: webView)
        }
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
        controller.removeScriptMessageHandler(forName: sheetMessageName, contentWorld: world)
        controller.addScriptMessageHandler(Sheets.shared, contentWorld: world, name: sheetMessageName)
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
                                            arguments: ["config": config(for: webView.configuration.websiteDataStore, url: webView.url)],
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
        /// Drawn with the site's palette rather than the filter.
        var palette = false
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
            if body["kind"] as? String == "palette" {
                DarkPages.receivedPalette(body, origin: DarkPages.origin(of: message.frameInfo.securityOrigin), from: webView)
                return
            }
            let state = State(darkened: body["darkened"] as? Bool ?? false, native: body["native"] as? Bool ?? false,
                              color: (body["color"] as? String).flatMap(DarkPages.color(hex:)), site: body["site"] as? String ?? "",
                              palette: body["palette"] as? Bool ?? false)
            DarkPages.received(state, from: webView)
        }
    }

    // MARK: Palettes

    static let sheetMessageName = "zigzagDarkSheet"
    /// The last palette a page sent, and how long reading its site took (debug, tests).
    static private(set) var lastAnalysis: [String: Any] = [:]

    static func origin(of security: WKSecurityOrigin) -> String {
        let host = security.host.lowercased()
        let usual = security.protocol == "https" ? 443 : security.protocol == "http" ? 80 : 0
        return "\(security.protocol.lowercased())://\(host)" + (security.port == 0 || security.port == usual ? "" : ":\(security.port)")
    }

    /// A page read its site's colors (or drew them, and says whether they covered it): kept for the site in its
    /// profile, for the pages loaded there next. Never from a private window.
    fileprivate static func receivedPalette(_ body: [String: Any], origin: String, from webView: WKWebView) {
        guard let scope = nativeScope(of: webView.configuration.websiteDataStore), DarkPalettes.origin(of: webView.url) == origin,
              let fingerprint = body["fingerprint"] as? String, let black = body["black"] as? Bool else { return }
        let old = DarkPalettes.entry(origin: origin, black: black, scope: scope)
        let entry: DarkPalettes.Entry
        if let ok = body["verified"] as? Bool {
            guard let old else { return }
            entry = DarkPalettes.verified(old, fingerprint: fingerprint, ok: ok)
        } else {
            let rules = (body["rules"] as? [Any] ?? []).compactMap { $0 as? String }
            entry = DarkPalettes.merged(old, origin: origin, black: black, fingerprint: fingerprint, rules: rules,
                                        invert: body["invert"] as? Bool ?? rules.isEmpty)
            lastAnalysis = (body["stats"] as? [String: Any] ?? [:]).merging(["origin": origin, "kept": entry.rules.count, "bytes": entry.css.utf8.count]) { $1 }
        }
        guard entry != old else { return }
        DarkPalettes.store(entry, scope: scope)
    }

    /// Palettes were cleared: every web view's script is put in again as it next goes to a page.
    static func palettesForgotten() { generation += 1 }

    /// Fetches a sheet the page can't read (from elsewhere, without CORS) for a page reading its colors.
    private final class Sheets: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Sheets()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, let webView = message.webView, nativeScope(of: webView.configuration.websiteDataStore) != nil,
                  let href = message.body as? String, let url = URL(string: href), DarkPalettes.fetchable(url) else { replyHandler(nil, nil); return }
            Task {
                let text = await DarkPalettes.fetchSheet(url)
                replyHandler(text, nil)
            }
        }
    }

    static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

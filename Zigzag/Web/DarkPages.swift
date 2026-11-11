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
    /// so their pages aren't darkened first and then let go.
    private static var nativeSites: Set<String> = []

    private static let source: String = {
        guard let url = Bundle.main.url(forResource: "dark-pages", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The choices as the page script reads them.
    static func config() -> [String: Any] {
        ["on": wants(mode: mode, systemIsDark: systemIsDark, site: nil), "sitesOn": sitesOn.sorted(), "sitesOff": sitesOff.sorted(),
         "native": nativeSites.sorted()]
    }

    private static func configJSON() -> String {
        (try? JSONSerialization.data(withJSONObject: config(), options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func script() -> WKUserScript {
        WKUserScript(source: source.replacingOccurrences(of: "__CONFIG__", with: configJSON()),
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    private static func isOurs(_ script: WKUserScript) -> Bool { script.source.contains("window.__zigzagDark") }

    /// Puts the page script, with the choices as they are now, into a web view's set of scripts, in place of the
    /// one it had. Pages already open hear of a change from `refresh`; this is for the pages loaded after it.
    private static func install(in controller: WKUserContentController) {
        let others = controller.userScripts.filter { !isOurs($0) }
        if others.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        controller.addUserScript(script())
    }

    private final class Entry {
        weak var webView: WKWebView?
        var observation: NSKeyValueObservation?
        init(_ webView: WKWebView) { self.webView = webView }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var appearanceObservation: NSKeyValueObservation?

    /// A tab's new web view: it gets the page script and follows the choices from here on.
    static func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        install(in: controller)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: world)
        controller.add(Messages.shared, contentWorld: world, name: messageName)
        let entry = Entry(webView)
        // Going to another site, its own choice applies before its page starts.
        entry.observation = webView.observe(\.url, options: [.new]) { webView, _ in
            MainActor.assumeIsolated {
                applyLook(to: webView)
                // A single-page app's new view, which loads nothing: looked at again once it's drawn.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak webView] in
                    MainActor.assumeIsolated { if let webView { recheck(webView) } }
                }
            }
        }
        entries = entries.filter { $0.value.webView != nil }
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
        var controllers = Set<ObjectIdentifier>()
        let config = config()
        for entry in entries.values {
            guard let webView = entry.webView else { continue }
            let controller = webView.configuration.userContentController
            if controllers.insert(ObjectIdentifier(controller)).inserted { install(in: controller) }
            applyLook(to: webView)
            webView.callAsyncJavaScript("if (window.__zigzagDark) window.__zigzagDark.set(config);", arguments: ["config": config],
                                        in: nil, in: world) { _ in }
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

    private static var pendingInstall: DispatchWorkItem?

    fileprivate static func received(_ state: State, from webView: WKWebView, isPrivate: Bool) {
        // Learned sites go into the scripts of pages loaded later; not from a private window.
        if !isPrivate, !state.site.isEmpty {
            let before = nativeSites
            if state.native { nativeSites.insert(state.site) } else if state.darkened { nativeSites.remove(state.site) }
            if nativeSites != before {
                pendingInstall?.cancel()
                let work = DispatchWorkItem {
                    MainActor.assumeIsolated {
                        var done = Set<ObjectIdentifier>()
                        for entry in entries.values {
                            guard let controller = entry.webView?.configuration.userContentController,
                                  done.insert(ObjectIdentifier(controller)).inserted else { continue }
                            install(in: controller)
                        }
                    }
                }
                pendingInstall = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
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
                              color: (body["color"] as? String).flatMap(DarkPages.color(hex:)), site: body["site"] as? String ?? "")
            DarkPages.received(state, from: webView, isPrivate: !webView.configuration.websiteDataStore.isPersistent)
        }
    }

    static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

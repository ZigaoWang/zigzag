import AppKit
import WebKit

/// Where a page's full screen goes (#168): over the whole screen, as WebKit does it, or filling the page's own area
/// in the window (its pane in a split), the window around it as it was. Settings › Tabs › Full screen videos fill
/// decides for every site, and a site's controls for one site, so YouTube can always fill the page.
///
/// The page is filled by page-fullscreen.js, in the page's own world (where a player asks for full screen): it
/// answers requestFullscreen and the webkit names for it, and a video's webkitEnterFullscreen, by fixing the element
/// over the page's viewport, telling the page it's in full screen (fullscreenElement, fullscreenchange), matching
/// the page's own :fullscreen rules through a mark, and leaving on Esc or exitFullscreen. A frame (an embedded
/// player) has the page around it fill with the frame. WebKit's element full screen always opens a window of its
/// own, with nothing public or private to keep it in the page, so a full screen WebKit starts itself (a video's own
/// controls) is backed out of and the page filled instead.
enum PageFullScreen {
    enum Fill: String, CaseIterable {
        /// The whole screen: WebKit's own full screen.
        case screen
        /// The page's own area in the window.
        case page
    }

    /// Where the choices are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// The setting or a site's choice changed.
    static let changed = Signal<Void>()

    private static let fillKey = "FullScreenFills"
    private static let pageKey = "FullScreenPageSites"
    private static let screenKey = "FullScreenScreenSites"

    /// Settings › Tabs › Full screen videos fill. The whole screen until changed, as it always was.
    static var fill: Fill {
        get { defaults.string(forKey: fillKey).flatMap(Fill.init(rawValue:)) ?? .screen }
        set { defaults.set(newValue.rawValue, forKey: fillKey); refreshAll() }
    }

    /// Sites (hosts without "www.") whose full screen fills the page, or the whole screen, whatever the setting.
    /// A site covers its subdomains.
    static var pageSites: Set<String> {
        get { Set(defaults.stringArray(forKey: pageKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: pageKey) }
    }

    static var screenSites: Set<String> {
        get { Set(defaults.stringArray(forKey: screenKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: screenKey) }
    }

    private static func covers(_ sites: Set<String>, _ site: String) -> Bool {
        sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// The site's own choice, or nil to follow the setting.
    static func choice(for url: URL?) -> Fill? {
        guard let site = ContentBlocker.site(of: url) else { return nil }
        if covers(pageSites, site) { return .page }
        if covers(screenSites, site) { return .screen }
        return nil
    }

    /// The site's own choice first, then the setting.
    static func fills(setting: Fill, site: Fill?) -> Fill { site ?? setting }

    static func fills(for url: URL?) -> Fill { fills(setting: fill, site: choice(for: url)) }

    /// Sets a site's choice, or back to following the setting (nil). A choice the same as the setting's isn't kept:
    /// the site simply follows it. Whatever covered the site before (its parent domain's choice too) goes.
    static func setChoice(_ choice: Fill?, for url: URL?) {
        guard let site = ContentBlocker.site(of: url) else { return }
        var page = pageSites.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        var screen = screenSites.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        if let choice, choice != fill {
            if choice == .page { page.insert(site) } else { screen.insert(site) }
        }
        pageSites = page
        screenSites = screen
        refreshAll()
    }

    /// Every site's choice forgotten (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        pageSites = []
        screenSites = []
        refreshAll()
    }

    /// Whether the site controls offer the choice: for a web page, and not in a private window, whose site would be
    /// kept in Settings › Privacy › Sites. A private window's pages still follow the choices made elsewhere.
    static func isOffered(for url: URL?, isPrivate: Bool) -> Bool {
        !isPrivate && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
    }

    // MARK: Pages

    static let messageName = "zigzagFullScreen"
    /// The first line of the page script, to tell it from a web view's other scripts.
    static let scriptMark = "/* zigzag page full screen */\n"

    /// The choices as the page script reads them: the setting and the sites with a choice of their own. The page
    /// decides for the site it's on (a frame for the site of the page around it), so one script serves every page.
    static func config(fill: Fill, pageSites: Set<String>, screenSites: Set<String>) -> [String: Any] {
        ["fill": fill.rawValue, "page": pageSites.sorted(), "screen": screenSites.sorted()]
    }

    static var config: [String: Any] { config(fill: fill, pageSites: pageSites, screenSites: screenSites) }

    static func json(_ config: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "page-fullscreen", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The page script with these choices in it.
    static func source(config: [String: Any]) -> String {
        scriptMark + template.replacingOccurrences(of: "__CONFIG__", with: json(config))
    }

    /// In the page's own world, where a site's player asks for full screen, and in every frame, for embedded players.
    static func script(config: [String: Any] = config) -> WKUserScript {
        WKUserScript(source: source(config: config), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(scriptMark) }

    /// What the page runs to hear of changed choices, or to leave its full screen (Esc in Zigzag's window).
    static func applyCall(_ config: [String: Any]) -> String {
        "window[Symbol.for('zigzag.fullscreen')]?.apply(\(json(config)))"
    }

    static let exitCall = "window[Symbol.for('zigzag.fullscreen')]?.exit() ?? false"

    private static let webViews = NSHashTable<WKWebView>.weakObjects()

    /// A tab's new web view: the page script, and the page telling it when it fills itself.
    static func attach(to webView: WKWebView) {
        install(in: webView.configuration.userContentController)
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.add(Messages.shared, contentWorld: .page, name: messageName)
        webViews.add(webView)
        watchEsc()
    }

    private static var escMonitor: Any?

    /// Esc with the keyboard somewhere else in the window (the sidebar, a pane beside it) leaves a page's full
    /// screen too: the one you're on first, else one beside it in a split. In the page itself, the page hears it.
    /// What else is open over the page (a panel, Peek, the command bar) takes it first, and so does a field.
    private static func watchEsc() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, !event.isARepeat, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, let controller = window.windowController as? BrowserWindowController,
                  !controller.hasFloatingPanel, !controller.peek.isVisible, !controller.commandBar.isVisible,
                  !(window.firstResponder is NSText), let tab = pageInFullScreen(in: controller) else { return event }
            if let responder = window.firstResponder as? NSView, let webView = tab.webView, responder.isDescendant(of: webView) { return event }
            exit(tab)
            return nil
        }
    }

    /// The page on screen in this window that fills itself: the tab you're on, else another of its split.
    private static func pageInFullScreen(in controller: BrowserWindowController) -> Tab? {
        guard let selected = controller.tabManager.selectedTab else { return nil }
        if selected.isInPageFullScreen { return selected }
        let panes = controller.tabManager.split(for: selected)?.ids.compactMap { controller.tabManager.tab(with: $0) } ?? []
        return panes.first { $0.isInPageFullScreen && $0.webView != nil }
    }

    /// Puts the script with the choices as they are now in place of the one there, for pages loaded from now on.
    private static func install(in controller: WKUserContentController) {
        OwnScripts.remove(from: controller, where: isOurs)
        controller.addUserScript(script())
    }

    /// The choices changed: pages open now follow at once, pages loaded later start with them.
    static func refreshAll() {
        let config = config
        var controllers = Set<ObjectIdentifier>()
        for webView in webViews.allObjects {
            let controller = webView.configuration.userContentController
            if controllers.insert(ObjectIdentifier(controller)).inserted { install(in: controller) }
            webView.evaluateJavaScript(applyCall(config), in: nil, in: .page) { _ in }
        }
        changed.send()
    }

    /// Esc in Zigzag's window, while a page there fills itself: it leaves.
    static func exit(_ tab: Tab) {
        guard tab.isInPageFullScreen, let webView = tab.webView else { return }
        webView.evaluateJavaScript(exitCall, in: nil, in: .page) { _ in }
        tab.isInPageFullScreen = false
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let on = message.body as? Bool,
                  let tab = (message.webView as? BrowserWebView)?.owner else { return }
            tab.isInPageFullScreen = on
        }
    }
}

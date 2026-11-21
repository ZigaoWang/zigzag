import AppKit
import WebKit

/// Where a page's full screen goes (#168, #462): Settings › Tabs › Full screen videos fill decides for every site,
/// and a site's controls for one site. The Page fills the page's own area in the window, with the chrome around it,
/// through page-fullscreen.js in the page's own world: it answers requestFullscreen and the webkit names for it, and
/// a video's webkitEnterFullscreen, by fixing the element over the page's viewport, telling the page it's in full
/// screen, matching its :fullscreen rules through a mark, and leaving on Esc or exitFullscreen. A frame has the page
/// around it fill with the frame. The Whole Screen is WebKit's own native element full screen, as in Safari and
/// Chrome: the script steps aside and leaves the whole request to WebKit, which owns that full-screen window.
enum PageFullScreen {
    enum Fill: String, CaseIterable {
        /// The whole screen: the browser's own full-screen space.
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
        set { defaults.set(newValue.rawValue, forKey: fillKey); changed.send() }
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
        changed.send()
    }

    /// Every site's choice forgotten (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        pageSites = []
        screenSites = []
        changed.send()
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
    /// Where the script reads the fill it follows. Set for each page as it starts, and kept current while it's open.
    private static let fillName = "zigzag.fullscreen.fill"

    /// Isolated from the page.
    static let world = WKContentWorld.world(name: "zigzag-fullscreen")

    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "page-fullscreen", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The page script, with the fill its page starts with.
    static func source(fill: Fill = .screen) -> String {
        scriptMark + "window[Symbol.for('\(fillName)')] = '\(fill.rawValue)';\n" + template
    }

    /// In the page's own world, where a site's player asks for full screen, and in every frame, for embedded players.
    static func script(fill: Fill = .screen) -> WKUserScript {
        WKUserScript(source: source(fill: fill), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(scriptMark) }

    /// Run by the page to exit its full screen (Esc in Zigzag's window).
    static let exitCall = "window[Symbol.for('zigzag.fullscreen')]?.exit() ?? false"

    /// A tab's new web view: the page script, and the page telling it when it fills itself.
    static func attach(to webView: WKWebView, fill: Fill = .screen) {
        let controller = webView.configuration.userContentController
        install(in: controller, fill: fill)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.add(Messages.shared, contentWorld: .page, name: messageName)
        views.add(webView)
        if changedToken == nil { changedToken = changed.observe { _ in refreshAll() } }
        watchEsc()
    }

    /// The web views whose pages follow the choice, so a change to it reaches them while their pages are open.
    private static let views = NSHashTable<WKWebView>.weakObjects()
    private static var changedToken: SignalToken?

    /// A page has committed: its script follows the choice for the address it landed on, not the one before it.
    static func pageCommitted(_ webView: WKWebView) { refresh(webView) }

    /// Gives a loaded page's script its choice now: the next document the web view loads starts with it too.
    static func setFill(_ fill: Fill, in webView: WKWebView) {
        install(in: webView.configuration.userContentController, fill: fill)
        webView.runOwnScript(fillCall(fill), world: .page)
    }

    /// Tells a page's script which way its full screen goes now.
    static func fillCall(_ fill: Fill) -> String {
        "window[Symbol.for('zigzag.fullscreen')]?.fill('\(fill.rawValue)'); 0"
    }

    private static func refresh(_ webView: WKWebView) {
        let fill = fills(for: webView.url)
        install(in: webView.configuration.userContentController, fill: fill)
        guard webView.url != nil else { return }
        webView.runOwnScript(fillCall(fill), world: .page)
    }

    private static func refreshAll() {
        for webView in views.allObjects { refresh(webView) }
    }

    private static var escMonitor: Any?

    /// Esc with the keyboard somewhere else in the window (the sidebar, a pane beside it) leaves a page's full
    /// screen too: the one you're on first, else one beside it in a split. In the page itself, the page hears it.
    /// What else is open over the page (a panel, the command bar) takes it first, and so does a field.
    private static func watchEsc() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, !event.isARepeat, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, let controller = window.windowController as? BrowserWindowController,
                  !controller.hasFloatingPanel, !controller.commandBar.isVisible,
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

    /// Puts the script in place, for pages loaded from now on.
    private static func install(in controller: WKUserContentController, fill: Fill) {
        OwnScripts.remove(from: controller, where: isOurs)
        controller.addUserScript(script(fill: fill))
    }

    /// Esc in Zigzag's window, while a page there fills itself: it leaves.
    static func exit(_ tab: Tab) {
        guard tab.isInPageFullScreen, let webView = tab.webView else { return }
        webView.runOwnScript(exitCall, world: .page)
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

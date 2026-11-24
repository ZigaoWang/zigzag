import AppKit
import WebKit

/// Full screen for a page (#168, #462): Zigzag handles it, not the page. Settings › Tabs › Full screen videos fill
/// decides only where the browser puts it: The Page fills the page's own area in the window (its pane in a split),
/// with the chrome around it; The Whole Screen fills that and takes the browser into its own macOS full-screen space,
/// with the chrome out of the way. Either way the page itself is filled by page-fullscreen.js, in the page's own
/// world: it answers requestFullscreen and the webkit names for it, and a video's webkitEnterFullscreen, by fixing
/// the element over the page's viewport, telling the page it's in full screen (fullscreenElement, fullscreenchange),
/// matching the page's own :fullscreen rules through a mark, and leaving on Esc or exitFullscreen. A frame (an
/// embedded player) has the page around it fill with the frame. A page never takes the screen by itself: the expand
/// button is the one explicit hand-off to WebKit's own full screen.
enum PageFullScreen {
    enum Fill: String, CaseIterable {
        /// The whole screen: the browser's own full-screen space, with the chrome out of the way.
        case screen
        /// The page's own area in the window.
        case page
    }

    /// Where the choices are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// The setting or a site's choice changed: the window showing the page follows.
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

    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "page-fullscreen", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The page script.
    static func source() -> String {
        scriptMark + template
    }

    /// In the page's own world, where a site's player asks for full screen, and in every frame, for embedded players.
    static func script() -> WKUserScript {
        WKUserScript(source: source(), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(scriptMark) }

    static let exitCall = "window[Symbol.for('zigzag.fullscreen')]?.exit() ?? false"
    static let expandCall = "window[Symbol.for('zigzag.fullscreen')]?.expand() ?? false"

    /// A tab's new web view: the page script, and the page telling it when it fills itself.
    static func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        install(in: controller)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.add(Messages.shared, contentWorld: .page, name: messageName)
        watchEsc()
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
    private static func install(in controller: WKUserContentController) {
        OwnScripts.remove(from: controller, where: isOurs)
        controller.addUserScript(script())
    }

    /// Esc in Zigzag's window, while a page there fills itself: it leaves.
    static func exit(_ tab: Tab) {
        guard tab.isInPageFullScreen, let webView = tab.webView else { return }
        webView.runOwnScript(exitCall, world: .page)
        tab.isInPageFullScreen = false
    }

    /// The expand button over a page-filled element (#257) sends it to WebKit's own full screen. WebKit only allows
    /// full screen from a click or key and treats an app script as one, so the press counts as yours.
    static func expand(_ tab: Tab) {
        guard tab.isInPageFullScreen, let webView = tab.webView else { return }
        tab.isInPageFullScreen = false
        webView.evaluateJavaScript(expandCall, in: nil, in: .page) { _ in }
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

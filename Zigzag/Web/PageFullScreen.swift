import AppKit
import WebKit

/// Full screen in the page (#168, #462): a page asking for full screen (a player's button, Element.requestFullscreen
/// and its webkit names, video.webkitEnterFullscreen) gets its element filling the page's own area in the window, and
/// a tab on its own takes the window with the chrome out of the way. The page never takes the screen. The page is told
/// it's in full screen as it would be (fullscreenElement, fullscreenchange), its own :fullscreen styles are matched
/// through a mark, and Esc leaves. A frame asks the page around it to fill the page with the frame, all the way up.
/// Only a click or key of yours starts it; a frame only where it's allowed full screen.
enum PageFullScreen {
    static let messageName = "zigzagFullScreen"
    /// The first line of the page script, to tell it from a web view's other scripts.
    static let scriptMark = "/* zigzag page full screen */\n"

    /// Isolated from the page.
    static let world = WKContentWorld.world(name: "zigzag-fullscreen")

    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "page-fullscreen", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The page script.
    static func source() -> String { scriptMark + template }

    /// In the page's own world, where a site's player asks for full screen, and in every frame, for embedded players.
    static func script() -> WKUserScript {
        WKUserScript(source: source(), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(scriptMark) }

    /// Run by the page to exit its full screen (Esc in Zigzag's window).
    static let exitCall = "window[Symbol.for('zigzag.fullscreen')]?.exit() ?? false"

    /// A tab's new web view: the page script, and the page telling it when it fills itself.
    static func attach(to webView: WKWebView) {
        install(in: webView.configuration.userContentController)
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.add(Messages.shared, contentWorld: .page, name: messageName)
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

    private final class Messages: NSObject, WKScriptMessageHandler {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let on = message.body as? Bool,
                  let tab = (message.webView as? BrowserWebView)?.owner else { return }
            tab.isInPageFullScreen = on
        }
    }
}

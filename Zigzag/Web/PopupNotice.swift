import AppKit
import WebKit

/// Pop-ups a page opens on its own, without a click, are blocked, as in every browser. Rather than failing in silence
/// (a payment or a sign-in that just doesn't appear), Zigzag says so and offers to allow them.
@MainActor
final class PopupNotice: NSObject, WKScriptMessageHandler {
    static let shared = PopupNotice()
    private static let messageName = "zigzagPopupBlocked"
    private static let marker = "/* zigzag popups */"

    /// Only the page itself reports, not frames in it: blocked pop-ups from ads stay quietly blocked.
    static func attach(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: marker + "\n" + shim, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(shared, contentWorld: .page, name: messageName)
    }

    private static let shim = """
    (() => {
      const open = window.open;
      let last = 0;
      window.open = function (url, ...rest) {
        const opened = open.call(window, url, ...rest);
        // Reported with no address too: pages often open an empty window, then send it where it goes.
        if (!opened && Date.now() - last > 1500) {
          last = Date.now();
          try { window.webkit.messageHandlers.\(messageName).postMessage(url ? String(new URL(url, location.href)) : ''); } catch (_) {}
        }
        return opened;
      };
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        let url = URL(string: text).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        guard url != nil || text.isEmpty else { return }
        // From a sign-in popup's own page: said in the browser window behind it, the one that opened it.
        if let popup = PopupWindowController.all.first(where: { $0.webView === message.webView }) {
            guard let browser = popup.parentWindow?.windowController as? BrowserWindowController else { return }
            Self.blocked(url, from: popup.webView.url, opener: nil, in: browser)
            return
        }
        guard let webView = message.webView as? BrowserWebView, let tab = webView.owner,
              let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }) else { return }
        // It did open, the page just doesn't get it back (noopener).
        if let opened = tab.lastOpenedWindow, Date().timeIntervalSince(opened) < 2 { return }
        Self.blocked(url, from: tab.url, opener: tab, in: controller)
    }

    /// Whether a page may open the window it asks for. WebKit hands every request here (its own blocker is off, as
    /// it can only say yes or no for every site at once): one that comes from a click opens, and so does any from a
    /// site you've allowed pop-ups for, as a real pop-up the page can talk to. That's what sign-ins need, such as
    /// Teams asking for permission after a click inside one of its apps, a step WebKit no longer counts as the
    /// click. Anything else returns nothing, and the page's own script reports it blocked.
    static func allows(_ action: WKNavigationAction, from page: URL?, isPrivate: Bool) -> Bool {
        if isUserInitiated(action) { return true }
        guard !isPrivate, let host = page?.host()?.lowercased(), !host.isEmpty else { return false }
        return SitePermissions.popups(host: host)
    }

    /// WebKit's own record of whether a click or a key started it (not public API, but long-standing); without
    /// it, whether the last thing you did was a click or a key a moment ago.
    private static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        let selector = NSSelectorFromString("_isUserInitiated")
        if action.responds(to: selector), let initiated = action.value(forKey: "_isUserInitiated") as? Bool { return initiated }
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else { return false }
        return [.leftMouseUp, .leftMouseDown, .otherMouseUp, .keyDown].contains(event.type)
    }

    /// A pop-up the page opened on its own: on a site you've allowed, it opens; elsewhere a toast offers to allow
    /// the site's pop-ups from now on. A pop-up opened later than asked can't report back to the page (a sign-in or a
    /// payment would never finish), so allowing doesn't open this one: the page's own button, clicked again, opens a
    /// real one. A private window remembers nothing about a site, so there it offers to open this one in a tab.
    /// Site Controls takes it back.
    static func blocked(_ url: URL?, from page: URL?, opener: Tab?, in controller: BrowserWindowController) {
        let host = page?.host()?.lowercased() ?? ""
        let isPrivate = controller.tabManager.isPrivate
        let allowed = !host.isEmpty && !isPrivate && SitePermissions.popups(host: host)
        Diagnostics.note(allowed ? "Pop-up opened as a tab" : "Pop-up blocked", site: host, isPrivate: isPrivate)
        if !host.isEmpty, !isPrivate, SitePermissions.popups(host: host) {
            if let url { controller.open(url, disposition: .foregroundTab, opener: opener, allowSwitch: false) }
            return
        }
        if !host.isEmpty, !isPrivate {
            Toast.show("Pop-up blocked", symbol: "macwindow.badge.plus", action: ("Always Allow", { [weak controller] in
                SitePermissions.setPopups(true, host: host)
                guard let controller else { return }
                Toast.show("Pop-ups allowed. Click the button again.", symbol: "macwindow.badge.plus", duration: 4, in: controller)
            }), duration: 6, in: controller)
        } else if let url {
            Toast.show("Pop-up blocked", symbol: "macwindow.badge.plus", action: ("Open in New Tab", { [weak controller, weak opener] in
                controller?.open(url, disposition: .foregroundTab, opener: opener, allowSwitch: false)
            }), duration: 6, in: controller)
        }
    }
}

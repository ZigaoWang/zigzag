import WebKit

/// Pop-ups a page opens on its own, without a click, are blocked, as in every browser. Rather than failing in silence
/// (a payment or a sign-in that just doesn't appear), Zigzag says so and offers to open it.
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
        if (!opened && url && Date.now() - last > 1500) {
          last = Date.now();
          try { window.webkit.messageHandlers.\(messageName).postMessage(String(new URL(url, location.href))); } catch (_) {}
        }
        return opened;
      };
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
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

    /// A pop-up the page opened on its own: on a site you've allowed, it opens; elsewhere a toast offers to allow
    /// the site's pop-ups from now on, this one included. Site Controls takes it back.
    static func blocked(_ url: URL, from page: URL?, opener: Tab?, in controller: BrowserWindowController) {
        let host = page?.host()?.lowercased() ?? ""
        let isPrivate = controller.tabManager.isPrivate
        if !host.isEmpty, !isPrivate, SitePermissions.popups(host: host) {
            controller.open(url, disposition: .foregroundTab, opener: opener, allowSwitch: false)
            return
        }
        // A private window remembers nothing about a site, so it only offers to open this one.
        let allow = !host.isEmpty && !isPrivate
        Toast.show("Pop-up blocked", symbol: "macwindow.badge.plus", action: (allow ? "Always Allow" : "Open", { [weak controller, weak opener] in
            if allow { SitePermissions.setPopups(true, host: host) }
            controller?.open(url, disposition: .foregroundTab, opener: opener, allowSwitch: false)
        }), duration: 6, in: controller)
    }
}

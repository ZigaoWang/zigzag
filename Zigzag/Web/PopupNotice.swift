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
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let webView = message.webView as? BrowserWebView, let tab = webView.owner,
              let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }) else { return }
        Toast.show("Pop-up blocked", symbol: "macwindow.badge.plus", action: ("Open", { [weak controller, weak tab] in
            controller?.open(url, disposition: .foregroundTab, opener: tab, allowSwitch: false)
        }), duration: 6, in: controller)
    }
}

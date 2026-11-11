import AppKit
import WebKit

/// The Chrome Web Store's own "Add to Chrome" button, working in Zigzag and reading "Add to Zigzag": the store turns it
/// on where its page has Chrome's install API, so on that one site a page script gives it one
/// (Resources/Extensions/web-store.js) that asks here. Adding goes through Zigzag's own download, review sheet and
/// install, as the bar over the page does; removing asks first, as Settings does. Only the store's own page, in the
/// tab itself (never a frame), is heard; any other page that posts here gets nothing.
enum WebStoreButton {
    static let messageName = "zigzagWebStore"
    static let host = "chromewebstore.google.com"
    /// How long a listing's page has to ask before the bar over it shows instead.
    static let grace: TimeInterval = 2

    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    /// What only Zigzag knows, for web-store.js: its own words for the store's button, and the Chrome version it
    /// answers with.
    static let config = [
        "add": String(localized: "Add to Zigzag", comment: "The Chrome Web Store's own button, and the bar over its page: installs the extension."),
        "remove": String(localized: "Remove from Zigzag", comment: "The Chrome Web Store's own button once an extension is in, and the tooltip of the trash button on an extension's row in Settings › Extensions."),
        "version": ExtensionStore.chromeVersion + ".0.0",
    ]

    /// web-store.js with `config` filled in.
    static let source: String = {
        let file = Bundle.main.url(forResource: "web-store", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else { return file }
        return file.replacingOccurrences(of: "const config = {};", with: "const config = \(json);")
    }()

    static func attach(to configuration: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.addScriptMessageHandler(Answer.shared, contentWorld: .page, name: messageName)
    }

    /// What the store asked, once it's known to be a well-formed question about a real extension ID.
    enum Request: Equatable {
        /// Every extension installed in the tab's profile (chrome.management.getAll).
        case list
        /// "installable", "enabled" or "disabled" (chrome.webstorePrivate.getExtensionStatus).
        case status(String)
        /// The store's own button was clicked (chrome.webstorePrivate.beginInstallWithManifest3).
        case install(String)
        /// "Remove from Zigzag" (chrome.management.uninstall).
        case remove(String)

        init?(_ body: Any) {
            guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
            if kind == "list" { self = .list; return }
            guard let id = body["id"] as? String, ExtensionStore.isExtensionID(id) else { return nil }
            switch kind {
            case "status": self = .status(id)
            case "install": self = .install(id)
            case "remove": self = .remove(id)
            default: return nil
            }
        }
    }

    /// The store's page itself: secure, its own host on the standard port, and the tab's page rather than a frame in it.
    static func isStore(scheme: String, host: String, port: Int, isMainFrame: Bool) -> Bool {
        isMainFrame && scheme == "https" && host.lowercased() == Self.host && (port == 0 || port == 443)
    }

    static func isStore(_ url: URL?) -> Bool {
        guard let url, let host = url.host() else { return false }
        return isStore(scheme: url.scheme ?? "", host: host, port: url.port ?? 0, isMainFrame: true)
    }

    /// Chrome's word for an extension's state in a profile.
    static func status(installed: Bool, enabled: Bool) -> String {
        installed ? (enabled ? "enabled" : "disabled") : "installable"
    }

    // MARK: Whether the store's button took over

    /// Each web view's listing whose button the store has turned on: there the bar over the page isn't needed. One
    /// the store never asks about (a page it has changed so this no longer works) keeps the bar.
    private static let engaged = NSMapTable<WKWebView, NSString>.weakToStrongObjects()

    static func isEngaged(_ webView: WKWebView?, for id: String) -> Bool {
        guard let webView else { return false }
        return engaged.object(forKey: webView) as String? == id
    }

    private final class Answer: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Answer()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            let security = message.frameInfo.securityOrigin
            guard message.name == WebStoreButton.messageName,
                  WebStoreButton.isStore(scheme: security.protocol, host: security.host, port: security.port, isMainFrame: message.frameInfo.isMainFrame),
                  let webView = message.webView as? BrowserWebView, WebStoreButton.isStore(webView.url),
                  let tab = webView.owner, let request = Request(message.body) else { return (nil, nil) }
            guard #available(macOS 15.4, *) else { return (nil, nil) }
            let profile = tab.profile
            let installs = profile.installs
            switch request {
            case .list:
                let items: [[String: Any]] = installs.installedIDs.filter(installs.isInstalled).map { id in
                    let ext = profile.extensions.installed[id]
                    return ["id": id, "name": ext?.displayName ?? "", "version": ext?.version ?? "", "enabled": installs.isEnabled(id)]
                }
                return (items, nil)
            case .status(let id):
                WebStoreButton.engaged.setObject(id as NSString, forKey: webView)
                (tab.host as? BrowserWindowController)?.webStoreButtonTookOver(id)
                return (WebStoreButton.status(installed: installs.isInstalled(id), enabled: installs.isEnabled(id)), nil)
            case .install(let id):
                guard let window = tab.host as? BrowserWindowController else { return (false, nil) }
                return (await window.installExtensionFromStore(id), nil)
            case .remove(let id):
                guard installs.isInstalled(id), let window = tab.host as? BrowserWindowController else { return (false, nil) }
                let name = profile.extensions.installed[id]?.displayName
                return (await withCheckedContinuation { done in
                    ConfirmSheet.removeExtension(id: id, name: name, from: profile, in: window.root.overlay, done: { done.resume(returning: $0) })
                }, nil)
            }
        }
    }
}

import AppKit
import WebKit

/// Links for other apps (zoommtg:, wemeet:, steam:, mailto:). A page doesn't get to open an app on your Mac by
/// itself: everyday links you click (mail, phone, FaceTime) open at once, anything else asks first, naming the app,
/// and a site you've said Open to opens that app straight away from then on, as in Chrome.
@MainActor
enum ExternalLinks {
    /// What the web view handles itself; everything else is for another app.
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension"]
    private static let everyday: Set<String> = ["mailto", "tel", "facetime", "facetime-audio", "sms"]
    /// One question at a time: meeting pages fire the same link a few times while they wait.
    private static var asking: Set<String> = []
    /// Asked and turned down this session: the page doesn't get to ask again until Zigzag restarts.
    private static var declined: Set<String> = []

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// Frames count too: meeting pages often open their app from a hidden frame, and the question keeps that honest.
    /// Only a page you can see asks; one in a background tab never puts a question over another site.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, from webView: WKWebView) {
        let scheme = url.scheme?.lowercased() ?? ""
        // A background tab has no window, and a popup's isn't a browser window: ask in the tab's own window, or the
        // front one, so the link never just does nothing.
        let controller = WindowManager.shared.controllers.first { $0.window === webView.window }
            ?? ((webView as? BrowserWebView)?.owner?.host as? BrowserWindowController)
            ?? WindowManager.shared.keyController
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if isMainFrame, webView.window != nil, let controller {
                Toast.show("No app on this Mac opens “\(scheme):” links", symbol: "questionmark.app", duration: 3, in: controller)
            }
            return
        }
        let host = webView.url?.host()?.lowercased() ?? ""
        let key = "\(host)|\(scheme)"
        if isClick && everyday.contains(scheme) || !host.isEmpty && SitePermissions.opensApp(host: host, scheme: scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let controller, webView.window != nil, !asking.contains(key), !declined.contains(key) else { return }
        let name = appName(app)
        // Private windows, popups included, never remember the answer.
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        let tab = (webView as? BrowserWebView)?.owner
        asking.insert(key)
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(host: host.isEmpty ? name : host, what: name, symbol: "arrow.up.forward.app",
                                                    isPrivate: false, in: controller, tab: tab, title: "Open \(name)",
                                                    allowTitle: "Always Open",
                                                    onceTitle: "Open This Time", denyTitle: "Don’t Open",
                                                    answered: { !host.isEmpty && SitePermissions.opensApp(host: host, scheme: scheme) ? .allow : nil })
            asking.remove(key)
            switch answer {
            case .allow:
                if !isPrivate, !host.isEmpty { SitePermissions.allowOpeningApp(host: host, scheme: scheme) }
                NSWorkspace.shared.open(url)
            case .allowOnce:
                NSWorkspace.shared.open(url)
            case .deny:
                declined.insert(key)
            case .notNow:
                break
            }
        }
    }

    /// "Tencent Meeting" for the app that opens a scheme, as Finder names it.
    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The app a site may open without asking, by its link scheme, for Settings.
    static func appName(forScheme scheme: String) -> String {
        URL(string: "\(scheme):").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.map(appName) ?? scheme
    }
}

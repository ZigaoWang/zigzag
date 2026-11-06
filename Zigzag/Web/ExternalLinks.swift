import AppKit
import WebKit

/// Links for other apps (zoommtg:, wemeet:, steam:, mailto:). A page doesn't get to open an app on your Mac by
/// itself: everyday links you click (mail, phone, FaceTime) open at once, anything else asks first, naming the app,
/// and a site you've said Open to opens that app straight away from then on, as in Chrome.
@MainActor
enum ExternalLinks {
    /// What the web view handles itself; everything else is for another app.
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension", "zigzag"]
    private static let everyday: Set<String> = ["mailto", "tel", "facetime", "facetime-audio", "sms"]
    /// One question at a time: meeting pages fire the same link a few times while they wait.
    private static var asking: Set<String> = []
    /// Asked and turned down this session: the page doesn't get to ask again until Zigzag restarts.
    private static var declined: Set<String> = []
    /// Asked and put off (closed, or the tab moved on): not again from that site for a minute, so a page can't
    /// keep putting the question back up.
    private static var putOff: [String: Date] = [:]

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// Frames count too: meeting pages often open their app from a hidden frame, and the question keeps that honest.
    /// Only a page you can see asks; one in a background tab never puts a question over another site.
    /// `isClick`: a real click or key started it (not a script's click()).
    /// `asker`: the frame that asked, when it's from another site than the page (an ad on a meeting page): it's named,
    /// and it never gets the page's saved answer.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, from webView: WKWebView, asker: WKSecurityOrigin? = nil) {
        let scheme = url.scheme?.lowercased() ?? ""
        // A background tab has no window, and a popup's isn't a browser window: ask in the tab's own window, or the
        // front one, so the link never just does nothing.
        let popup = PopupWindowController.all.first { $0.webView === webView }
        let controller = WindowManager.shared.controllers.first { $0.window === webView.window }
            ?? ((webView as? BrowserWebView)?.owner?.host as? BrowserWindowController)
            ?? popup.flatMap { p in WindowManager.shared.controllers.first { $0.window === p.parentWindow } }
            ?? WindowManager.shared.keyController
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            Diagnostics.note("No app for a link", site: webView.url?.host(), "\(scheme):", isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            if isMainFrame, webView.window != nil, let controller {
                Toast.show("No app on this Mac opens “\(scheme):” links", symbol: "questionmark.app", duration: 3, in: controller)
            }
            return
        }
        let pageHost = webView.url?.host()?.lowercased() ?? ""
        let askerHost = asker?.host.lowercased() ?? ""
        let foreign = !askerHost.isEmpty && (PublicSuffix.registrableDomain(askerHost) ?? askerHost) != (PublicSuffix.registrableDomain(pageHost) ?? pageHost)
        // Answers are kept for secure pages only: one given to https://zoom.us never opens Zoom for http://zoom.us.
        let canRemember = !foreign && webView.url?.scheme?.lowercased() == "https"
        let host = foreign ? askerHost : pageHost
        let key = "\(host)|\(scheme)"
        // Mail, phone and FaceTime open at once for a link you clicked in the page in front; from anywhere else
        // (a hidden frame, a background tab, a script) they ask like any other app.
        let clickedHere = isClick && isMainFrame && webView.window != nil
        if clickedHere && everyday.contains(scheme) || canRemember && !host.isEmpty && SitePermissions.opensApp(host: host, scheme: scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let controller, webView.window != nil, !asking.contains(key), !declined.contains(key),
              putOff[key].map({ Date() > $0 }) ?? true else { return }
        let name = appName(app)
        // Private windows, popups included, never remember the answer.
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        // Nothing to keep the answer under (a private window, or a page with no host): Open is for this time only.
        let saves = !isPrivate && !host.isEmpty && canRemember
        let tab = (webView as? BrowserWebView)?.owner
        asking.insert(key)
        // Asked from a popup: its browser window comes forward, so the question isn't hidden behind the popup.
        if popup != nil { controller.window?.makeKeyAndOrderFront(nil) }
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(host: host.isEmpty ? "This page" : host, what: name, symbol: "arrow.up.forward.app",
                                                    icon: NSWorkspace.shared.icon(forFile: app.path), in: controller,
                                                    tab: tab, title: "Open \(name)", allowTitle: "Open",
                                                    denyTitle: "Don’t Open",
                                                    answered: { canRemember && !host.isEmpty && SitePermissions.opensApp(host: host, scheme: scheme) ? .allow : nil })
            asking.remove(key)
            switch answer {
            case .allow:
                if saves { SitePermissions.allowOpeningApp(host: host, scheme: scheme) }
                NSWorkspace.shared.open(url)
            case .deny:
                declined.insert(key)
            case .notNow:
                putOff[key] = Date().addingTimeInterval(60)
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

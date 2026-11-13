import AppKit
import WebKit

/// Links for other apps (zoommtg:, itms-apps:, steam:, mailto:). A page doesn't get to open an app on your Mac by
/// itself: everyday links you click (mail, phone, FaceTime) open at once, anything else asks first, naming the app.
/// Open is for this time; Always Open lets the site open that app straight away from then on, as in Chrome. Open
/// apps is a permission like the camera's (#192): Allow or Block for the whole site is chosen in Site Controls or
/// Settings › Privacy, and Block means nothing on the site opens an app, not even a link you click.
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
    /// and it never gets the page's saved answer, though the page's Block holds for it too.
    /// `byYou`: Zigzag itself sent the tab there (typed in the address bar, a bookmark), never the page: it opens.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, from webView: WKWebView, asker: WKSecurityOrigin? = nil, byYou: Bool = false) {
        let scheme = url.scheme?.lowercased() ?? ""
        // Only a site installed as an app sends these, from its own small app: never a page.
        if scheme == WebAppLink.scheme { return }
        // A background tab has no window, and a popup's isn't a browser window: ask in the tab's own window, or the
        // front one, so the link never just does nothing.
        let popup = PopupWindowController.all.first { $0.webView === webView }
        let controller = WindowManager.shared.controller(for: webView.window)
            ?? ((webView as? BrowserWebView)?.owner?.host as? BrowserWindowController)
            ?? popup.flatMap { p in WindowManager.shared.controller(for: p.parentWindow) }
            ?? WindowManager.shared.keyController
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            Diagnostics.note("No app for a link", site: webView.url?.host(), "\(scheme):", isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            if isMainFrame, webView.window != nil, let controller {
                Toast.show(String(localized: "No app on this Mac opens “\(scheme):” links", comment: "Toast when a page opens a link no app handles. The placeholder is the link's scheme, like “zoommtg”."), symbol: "questionmark.app", duration: 3, in: controller)
            }
            return
        }
        if byYou {
            NSWorkspace.shared.open(url)
            return
        }
        let pageHost = webView.url?.host()?.lowercased() ?? ""
        let askerHost = asker?.host.lowercased() ?? ""
        let foreign = !askerHost.isEmpty && (PublicSuffix.registrableDomain(askerHost) ?? askerHost) != (PublicSuffix.registrableDomain(pageHost) ?? pageHost)
        // Always Open is kept for secure pages only. Choices are kept per origin, so one for https://zoom.us is not
        // one for http://zoom.us or https://zoom.us:8443.
        let pageOrigin = SiteOrigin.of(webView.url)
        let canRemember = !foreign && webView.url?.scheme?.lowercased() == "https"
        let host = foreign ? askerHost : pageHost
        let origin = foreign ? asker.flatMap { SiteOrigin.of($0) } : pageOrigin
        let key = "\(origin ?? host)|\(scheme)"
        // The page's Allow or Block, or the app it was told Always Open to. A frame from elsewhere gets only Block.
        let decision: () -> Bool? = { Self.decision(page: pageOrigin, scheme: scheme, foreign: foreign) }
        if decision() == false {
            Diagnostics.note("Blocked opening an app", site: host, "\(scheme):", isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            return
        }
        // Mail, phone and FaceTime open at once for a link you clicked in the page in front; from anywhere else
        // (a hidden frame, a background tab, a script) they ask like any other app.
        let clickedHere = isClick && isMainFrame && webView.window != nil
        if clickedHere && everyday.contains(scheme) || decision() == true {
            NSWorkspace.shared.open(url)
            return
        }
        guard let controller, webView.window != nil, !asking.contains(key), !declined.contains(key),
              putOff[key].map({ Date() > $0 }) ?? true else { return }
        let name = appName(app)
        // Private windows, popups included, never remember the answer.
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        // Nothing to keep the answer under (a private window, or a page with no host): Open is for this time only.
        let saves = !isPrivate && origin != nil && canRemember
        let tab = (webView as? BrowserWebView)?.owner
        if !foreign { SitePermissions.noteAsked(.apps, origin: pageOrigin, isPrivate: isPrivate) }
        asking.insert(key)
        // Asked from a popup: its browser window comes forward, so the question isn't hidden behind the popup.
        if popup != nil { controller.window?.makeKeyAndOrderFront(nil) }
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(host: SitePermissions.askerName(origin), origin: origin, what: name, symbol: "arrow.up.forward.app",
                                                    icon: NSWorkspace.shared.icon(forFile: app.path), in: controller,
                                                    tab: tab, title: String(localized: "Open \(name)", comment: "A page's question to open an app, without its question mark. The placeholder is the app's name, like “zoom.us”."),
                                                    allowTitle: String(localized: "Open", comment: "Button on a page's question to open an app: opens it this time."),
                                                    alwaysTitle: saves ? String(localized: "Always Open", comment: "Button on a page's question to open an app: opens it, and the site may open this app without asking from now on.") : nil,
                                                    denyTitle: String(localized: "Don’t Open", comment: "Button on a page's question to open an app."),
                                                    answered: { decision().map { $0 ? .allow : .deny } })
            asking.remove(key)
            switch answer {
            case .allow:
                NSWorkspace.shared.open(url)
            case .always:
                if saves, let origin { SitePermissions.allowOpeningApp(origin: origin, scheme: scheme) }
                NSWorkspace.shared.open(url)
            case .deny:
                declined.insert(key)
            case .notNow:
                putOff[key] = Date().addingTimeInterval(60)
            }
        }
    }

    /// What's kept for the page at `page` opening `scheme`'s app: its Allow or Block, or the app it was told Always
    /// Open to; nil asks. A frame from another site on the page (`foreign`) is held by Block only, never let in.
    static func decision(page: String?, scheme: String, foreign: Bool) -> Bool? {
        guard let page, let found = SitePermissions.appDecision(origin: page, scheme: scheme) else { return nil }
        return foreign ? (found ? nil : false) : found
    }

    /// A site's choice changed in Site Controls or Settings (or was reset): its Don't Open and Not Now for this
    /// session go too, so Ask asks again.
    static func forgetAnswers(origin: String) {
        declined = declined.filter { !$0.hasPrefix(origin + "|") }
        putOff = putOff.filter { !$0.key.hasPrefix(origin + "|") }
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

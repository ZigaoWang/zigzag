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
    /// What's been asked this session, by site and scheme.
    struct Asked {
        /// One question at a time: meeting pages fire the same link a few times while they wait, and two quick
        /// clicks don't stack two questions.
        var asking: Set<String> = []
        /// Asked and turned down this session: the page doesn't get to ask again until Zigzag restarts, unless you
        /// click a link or button for it.
        var declined: Set<String> = []
        /// Asked and put off (closed, or the tab moved on): not again from that site for a minute, so a page can't
        /// keep putting the question back up.
        var putOff: [String: Date] = [:]

        /// Whether `key` may ask now. A page asking again on its own, after you put it off or said Don't Open, is let
        /// be for now. A click of yours in the page asks even right after a question was put off: the click that
        /// dismissed the last question (claude.ai asks on load, and its Open Claude button asks again) must not be
        /// what silences this one. Only a click on a link (`linkClick`) undoes Don't Open: a click is also what a
        /// page's own script rides on while you press anything.
        /// `page`: the site of the page it's on, whose frames share its few seconds' gap (by default, the key's site).
        mutating func mayAsk(_ key: String, page: String? = nil, clickedHere: Bool, linkClick: Bool, now: Date = Date()) -> Bool {
            guard !asking.contains(key) else { return false }
            if clickedHere {
                if linkClick { declined.remove(key) } else if declined.contains(key) { return false }
                putOff[key] = nil
                return true
            }
            guard !declined.contains(key), putOff[key].map({ now > $0 }) ?? true else { return false }
            // Asking on its own, from any site or frame: never while another question is up, and not again from the
            // same page's site for a few seconds, so frames from many sites on it can't line up question after
            // question. Another site (another tab's meeting page) isn't held up by this one.
            let site = page ?? String(key.prefix { $0 != "|" })
            guard asking.isEmpty, lastOnItsOwn[site].map({ now.timeIntervalSince($0) >= Self.unaskedGap }) ?? true else { return false }
            if lastOnItsOwn.count > 200 { lastOnItsOwn = lastOnItsOwn.filter { now.timeIntervalSince($0.value) < Self.unaskedGap } }
            lastOnItsOwn[site] = now
            return true
        }

        /// When a question last went up without a click of yours, by the site of the page it was on.
        var lastOnItsOwn: [String: Date] = [:]
        static let unaskedGap: TimeInterval = 10
    }
    private static var asked = Asked()

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// Frames count too: meeting pages often open their app from a hidden frame, and the question keeps that honest.
    /// Only a page you can see asks; one in a background tab never puts a question over another site.
    /// `isClick`: a real click or key started it (not a script's click()).
    /// `linkClick`: it's a link you clicked (`.linkActivated`), not a page's script running on your click; nil when
    /// that's what `isClick` already means (a link in Reader or a PDF).
    /// `asker`: the frame that asked, when it's from another site than the page (an ad on a meeting page): it's named,
    /// and it never gets the page's saved answer, though the page's Block holds for it too.
    /// `byYou`: you typed it in the address bar or chose it in the command bar, never a page or Zigzag on its own: it
    /// opens without asking, unless the site is set to Block.
    /// `sourceIsMainFrame`: the link or script that asked is the page's own document, not a frame in it.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, linkClick: Bool? = nil, sourceIsMainFrame: Bool = true, from webView: WKWebView,
                     asker: WKSecurityOrigin? = nil, byYou: Bool = false, fromPDF: Bool = false) {
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
        let pageURL = page(showing: webView.url, asker: asker.flatMap { SiteOrigin.of($0) })
        let pageHost = pageURL?.host()?.lowercased() ?? ""
        let askerHost = asker?.host.lowercased() ?? ""
        let foreign = isForeign(askerHost: asker == nil ? nil : askerHost, pageHost: pageHost)
        // Always Open is kept for secure pages only. Choices are kept per origin, so one for https://zoom.us is not
        // one for http://zoom.us or https://zoom.us:8443.
        let pageOrigin = SiteOrigin.of(pageURL)
        let canRemember = !foreign && pageURL?.scheme?.lowercased() == "https"
        let host = foreign ? askerHost : pageHost
        let origin = foreign ? asker.flatMap { SiteOrigin.of($0) } : pageOrigin
        let key = "\(origin ?? host)|\(scheme)"
        // The page's Allow or Block, or the app it was told Always Open to. A frame from elsewhere gets only Block, and
        // so does a link in a PDF (`fromPDF`), whose links are the PDF's, not the site's: it always asks.
        // A page with no site of its own (about:blank its opener wrote) is held to the Block of the site that made
        // it: the frame that asked, which has its origin, or the tab that opened it.
        let openerOrigin = (webView as? BrowserWebView)?.owner?.opener.flatMap { SiteOrigin.of($0.url) }
        let standIns = pageOrigin == nil ? [asker.flatMap { SiteOrigin.of($0) }, openerOrigin].compactMap { $0 } : []
        let decision: () -> Bool? = {
            let found = Self.decision(page: pageOrigin, standIns: standIns, scheme: scheme, foreign: foreign)
            return fromPDF && found == true ? nil : found
        }
        let clickedHere = isClick && isMainFrame && webView.window != nil
        let everydayClick = isEverydayClick(clickedHere: clickedHere, linkClick: linkClick ?? isClick, sourceIsMainFrame: sourceIsMainFrame, fromPDF: fromPDF)
        switch verdict(byYou: byYou, decision: decision(), clickedHere: everydayClick, scheme: scheme) {
        case .block:
            Diagnostics.note("Blocked opening an app", site: host, "\(scheme):", isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            return
        case .open:
            NSWorkspace.shared.open(url)
            return
        case .ask:
            break
        }
        guard let controller, webView.window != nil,
              asked.mayAsk(key, page: pageOrigin ?? pageHost, clickedHere: clickedHere, linkClick: linkClick ?? isClick) else { return }
        let name = appName(app)
        // Private windows, popups included, never remember the answer.
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        // Nothing to keep the answer under (a private window, or a page with no host): Open is for this time only.
        // Nor is it from a PDF: Always Open there would let any PDF on the site open the app.
        let saves = !isPrivate && origin != nil && canRemember && !fromPDF
        let tab = (webView as? BrowserWebView)?.owner
        if !foreign { SitePermissions.noteAsked(.apps, origin: pageOrigin, isPrivate: isPrivate) }
        asked.asking.insert(key)
        // Asked where the page is: in Zigzag Mini or an installed app's window, over its own page, not in a browser
        // window behind it, where it couldn't be seen (a report: claude.ai's Open Claude did nothing in Mini).
        let promptHost: PromptHost = (webView.window?.windowController as? PromptHost).flatMap { $0 is BrowserWindowController ? nil : $0 } ?? controller
        // Asked from a popup: its browser window comes forward, so the question isn't hidden behind the popup.
        if popup != nil { controller.window?.makeKeyAndOrderFront(nil) }
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(host: SitePermissions.askerName(origin), origin: origin, what: name, symbol: "arrow.up.forward.app",
                                                    icon: NSWorkspace.shared.icon(forFile: app.path), in: promptHost,
                                                    tab: tab, title: String(localized: "Open \(name)", comment: "A page's question to open an app, without its question mark. The placeholder is the app's name, like “zoom.us”."),
                                                    allowTitle: String(localized: "Open", comment: "Button on a page's question to open an app: opens it this time."),
                                                    alwaysTitle: saves ? String(localized: "Always Open", comment: "Button on a page's question to open an app: opens it, and the site may open this app without asking from now on.") : nil,
                                                    denyTitle: String(localized: "Don’t Open", comment: "Button on a page's question to open an app."),
                                                    answered: { decision().map { $0 ? .allow : .deny } })
            asked.asking.remove(key)
            switch answer {
            case .allow, .alternate:
                NSWorkspace.shared.open(url)
            case .always:
                if saves, let origin { SitePermissions.allowOpeningApp(origin: origin, scheme: scheme) }
                NSWorkspace.shared.open(url)
            case .deny:
                asked.declined.insert(key)
            case .notNow:
                asked.putOff[key] = Date().addingTimeInterval(60)
            }
        }
    }

    /// The address of the page a link for an app is from: the web view's. A tab Zigzag itself sends to an app's link
    /// (an extension's tabs.update: Downie's button) already shows that link as its address while it's decided, so
    /// the page is the one it's still on, the frame that asked (`asker`, its origin). Taking the link for the page
    /// made every such question come from a site of its own ("downie://xuopenlink"), never the site you're on (#239).
    static func page(showing address: URL?, asker: String?) -> URL? {
        guard let address, isExternal(address) else { return address }
        return asker.flatMap { URL(string: $0) }
    }

    enum Verdict: Equatable { case block, open, ask }

    /// Whether a link for another app opens, asks first or goes nowhere. The site's Block always holds, even for an
    /// address you typed: `byYou` only spares you the question. Mail, phone and FaceTime open at once for a link you
    /// clicked in the page in front (`clickedHere`); from anywhere else (a hidden frame, a background tab, a script)
    /// they ask like any other app.
    static func verdict(byYou: Bool, decision: Bool?, clickedHere: Bool, scheme: String) -> Verdict {
        if decision == false { return .block }
        if byYou || decision == true || (clickedHere && everyday.contains(scheme)) { return .open }
        return .ask
    }

    /// What's kept for the page at `page` opening `scheme`'s app: its Allow or Block, or the app it was told Always
    /// Open to; nil asks. A frame from another site on the page (`foreign`) is held by Block only, never let in.
    static func decision(page: String?, scheme: String, foreign: Bool) -> Bool? {
        guard let page, let found = SitePermissions.appDecision(origin: page, scheme: scheme) else { return nil }
        return foreign ? (found ? nil : false) : found
    }

    /// Whether mail, phone and FaceTime may open at once: only for a link you clicked in the page in front itself,
    /// never from a frame in it, a script riding on your click, or a PDF.
    static func isEverydayClick(clickedHere: Bool, linkClick: Bool, sourceIsMainFrame: Bool, fromPDF: Bool) -> Bool {
        clickedHere && linkClick && sourceIsMainFrame && !fromPDF
    }

    /// The same, where a page with no site (`page` nil) answers to the Block of the sites standing in for it.
    static func decision(page: String?, standIns: [String], scheme: String, foreign: Bool) -> Bool? {
        if let page { return decision(page: page, scheme: scheme, foreign: foreign) }
        return standIns.contains { decision(page: $0, scheme: scheme, foreign: true) == false } ? false : nil
    }

    /// Whether the frame that asked is someone other than the page: another site, or a frame with no host of its own
    /// (sandboxed, data:) on a page that has one, which never gets the page's Always Open. `askerHost` nil: no
    /// frame was named, the page asked.
    static func isForeign(askerHost: String?, pageHost: String) -> Bool {
        guard let askerHost else { return false }
        if askerHost.isEmpty { return !pageHost.isEmpty }
        return (PublicSuffix.registrableDomain(askerHost) ?? askerHost) != (PublicSuffix.registrableDomain(pageHost) ?? pageHost)
    }

    /// A site's choice changed in Site Controls or Settings (or was reset): its Don't Open and Not Now for this
    /// session go too, so Ask asks again.
    static func forgetAnswers(origin: String) {
        asked.declined = asked.declined.filter { !$0.hasPrefix(origin + "|") }
        asked.putOff = asked.putOff.filter { !$0.key.hasPrefix(origin + "|") }
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

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
        /// When the page's own "this time" answer last opened an app, by site and scheme: that answer covers one
        /// launch, not a page that fires the same link over and over.
        var lastOpened: [String: Date] = [:]
        /// How long a page's own answer is held to one launch, the same gap a question keeps.
        static let repeatGap: TimeInterval = 10

        /// Whether the page's own "this time" answer may open the app again now, and notes that it did. A click of
        /// yours never comes here: a click is you asking, and opens each time.
        mutating func mayOpenAgain(_ key: String, now: Date = Date()) -> Bool {
            if let last = lastOpened[key], now.timeIntervalSince(last) < Self.repeatGap { return false }
            lastOpened[key] = now
            if lastOpened.count > 200 { lastOpened = lastOpened.filter { now.timeIntervalSince($0.value) < 60 } }
            return true
        }

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
    /// `fromPDF`: the link is in a PDF, so it's the PDF's, not the site's: it always asks, and never opens an app at
    /// once.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, linkClick: Bool? = nil, sourceIsMainFrame: Bool = true, from webView: WKWebView,
                     asker: WKSecurityOrigin? = nil, byYou: Bool = false, fromPDF: Bool = false) {
        let scheme = url.scheme?.lowercased() ?? ""
        // Only a site installed as an app sends these, from its own small app: never a page.
        if scheme == WebAppLink.scheme { return }
        // A background tab has no window, and a popup's isn't a browser window: ask in the tab's own window, or the
        // front one, so the link never just does nothing.
        let popup = PopupWindowController.all.first { $0.webView === webView }
        let owner = (webView as? BrowserWebView)?.owner
        let controller = WindowManager.shared.controller(for: webView.window)
            ?? (owner?.host as? BrowserWindowController)
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
        let tab = (webView as? BrowserWebView)?.owner
        // The page's Allow or Block, or the app it was told Always Open to. The site-wide row comes first, as it
        // always did: Allow means every app on the site, Block means none. A frame from elsewhere gets only Block, and
        // so does a link in a PDF (`fromPDF`), whose links are the PDF's, not the site's: it always asks.
        // A page with no site of its own (about:blank its opener wrote) is held to the Block of the site that made
        // it: the frame that asked, which has its origin, or the tab that opened it.
        // What this page already answered "this time" is a kept answer too, from the tab's page store, so a page that
        // asks again on its own (a redirect on load, the same link fired twice) is not asked twice for the same app.
        let openerOrigin = (webView as? BrowserWebView)?.owner?.opener.flatMap { SiteOrigin.of($0.url) }
        let standIns = pageOrigin == nil ? [asker.flatMap { SiteOrigin.of($0) }, openerOrigin].compactMap { $0 } : []
        let stored: () -> KeptAppAnswer? = {
            let found = Self.storedAppAnswer(pageOrigin: pageOrigin, standIns: standIns, origin: origin, scheme: scheme,
                                             foreign: foreign, tab: tab)
            return fromPDF && found?.action == "allow" ? nil : found
        }
        let clickedHere = isClick && isMainFrame && webView.window != nil
        let everydayClick = isEverydayClick(clickedHere: clickedHere, linkClick: linkClick ?? isClick, sourceIsMainFrame: sourceIsMainFrame, fromPDF: fromPDF)
        func openApp() {
            NSWorkspace.shared.open(url)
            // A sign-in page in Zigzag Mini sending you back to the app that asked: that window's done (#246).
            MiniWindowController.pageOpenedApp(webView, isMainFrame: isMainFrame, linkClick: linkClick ?? isClick)
        }
        let kept = stored()
        // The page's own "this time" answer covers one launch, not a page that fires the same link over and over: a
        // script's repeat is held to the same few seconds a question is. A click of yours is you asking, and opens.
        if kept?.remember == false, !clickedHere, !asked.mayOpenAgain(key) { return }
        switch verdict(byYou: byYou, clickedHere: everydayClick, scheme: scheme, stored: kept?.action) {
        case .block:
            Diagnostics.note("Blocked opening an app", site: host, "\(scheme):", isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            return
        case .open:
            openApp()
            return
        case .ask:
            break
        }
        // A page asking again on its own, after you put it off, is let be for now. A click of yours in the page is
        // asked every time: it's you asking, and the click that dismissed the last question (claude.ai asks on load,
        // and its Open Claude button asks again) must not be what silences this one. A Deny holds on the page that
        // gave it (its `stored` above), so a page cannot ask again for an answer you already refused.
        // A background tab's page has no window attached, but its question still belongs to it: ask in the tab's own
        // host, where `PermissionPrompt` holds it and marks the tab until it can be shown. A web view with neither a
        // window nor a tab (an orphaned pop-up) must not put a question up in whatever window happens to be in front.
        // Mini and an installed app's window are hosts in their own right, with no browser window to fall back on.
        let pagePromptHost: PromptHost? = (webView.window?.windowController as? PromptHost)
            .flatMap { $0 is BrowserWindowController ? nil : $0 }
            ?? (owner?.host as? PromptHost).flatMap { $0 is BrowserWindowController ? nil : $0 }
        guard let promptHost = pagePromptHost ?? controller, webView.window != nil || owner?.host != nil,
              asked.mayAsk(key, page: pageOrigin ?? pageHost, clickedHere: clickedHere, linkClick: linkClick ?? isClick) else { return }
        let name = appName(app)
        // Private windows, popups included, never remember the answer.
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        // Nothing to keep the answer under (a private window, or a page with no host): Open is for this time only.
        // Nor is it from a PDF: Always Open there would let any PDF on the site open the app.
        let saves = Self.saves(isPrivate: isPrivate, origin: origin, canRemember: canRemember) && !fromPDF
        if !foreign { SitePermissions.noteAsked(.apps, origin: pageOrigin, isPrivate: isPrivate) }
        asked.asking.insert(key)
        // Asked where the page is: in Zigzag Mini or an installed app's window, over its own page, not in a browser
        // window behind it, where it couldn't be seen (a report: claude.ai's Open Claude did nothing in Mini).
        // Asked from a popup: its window comes forward, so the question isn't hidden behind the pop-up.
        if popup != nil { promptHost.window?.makeKeyAndOrderFront(nil) }
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(host: SitePermissions.askerName(origin), origin: origin, answerKey: key, what: name, symbol: "arrow.up.forward.app",
                                                    icon: NSWorkspace.shared.icon(forFile: app.path), in: promptHost,
                                                    tab: tab, title: String(localized: "Open \(name)", comment: "A page's question to open an app, without its question mark. The placeholder is the app's name, like “zoom.us”."),
                                                    actions: [.deny, .allow], canRemember: saves,
                                                    answered: {
                                                        stored().map { PermissionAnswer(action: $0.action, remember: $0.remember) }
                                                    })
            asked.asking.remove(key)
            guard let answer else {
                asked.putOff[key] = Date().addingTimeInterval(60)
                return
            }
            // This time holds on the page that asked, until it navigates; Always is kept for the site, and only
            // where it could be kept (https, no foreign frame, not a private window). Both answers stay that one
            // app's, a Don't Allow included: refusing one link must not block every other app on the site.
            if let origin {
                SitePermissions.rememberAnswer(answer, subject: Self.storageSubject(for: answer, scheme: scheme),
                                               origin: origin, tab: tab, isPrivate: isPrivate)
            }
            if answer.action == "deny" {
                asked.declined.insert(key)
            } else {
                openApp()
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
    /// `stored` is the site's kept answer: Allow or Block chosen in Site Controls or Settings, an app told Always
    /// Allow, or the page's own answer this time. Both are honored as they stand. Writing an allow is already closed
    /// to anywhere it shouldn't be kept (`saves`), and a frame from another site can only carry a Block this far
    /// (`decision`), so an allow found here was given deliberately and is not second-guessed.
    static func verdict(byYou: Bool, clickedHere: Bool, scheme: String, stored: String?) -> Verdict {
        if stored == "deny" { return .block }
        if stored == "allow" { return .open }
        if byYou || (clickedHere && everyday.contains(scheme)) { return .open }
        return .ask
    }

    /// Whether mail, phone and FaceTime may open at once: only for a link you clicked in the page in front itself,
    /// never from a frame in it, a script riding on your click, or a PDF.
    static func isEverydayClick(clickedHere: Bool, linkClick: Bool, sourceIsMainFrame: Bool, fromPDF: Bool) -> Bool {
        clickedHere && linkClick && sourceIsMainFrame && !fromPDF
    }

    /// Whether a question's answer may be kept for the site: not a private window, a site we can name, and a place an
    /// answer can live (a secure page, and never a frame from another site). This is the whole gate on *storing*; what
    /// may be *honored* is everything already in the store, which `verdict` trusts.
    static func saves(isPrivate: Bool, origin: String?, canRemember: Bool) -> Bool {
        !isPrivate && origin != nil && canRemember
    }

    /// Whether an app answer can be kept for the page at `url`: only a secure page, and never a frame from another
    /// site (its answer would be the page's to give, not the frame's).
    static func canRemember(url: URL?, foreign: Bool) -> Bool {
        !foreign && url?.scheme?.lowercased() == "https"
    }

    /// The subject an answered app question is kept under: always that one app. "Always / Don't Allow" refuses this
    /// app on this site, and the next app the page opens asks on its own; the site-wide "apps" row stays Site
    /// Controls' to write, so refusing the App Store link on a site doesn't block its Zoom link too.
    static func storageSubject(for answer: PermissionAnswer, scheme: String) -> String {
        PermissionSubject.app(scheme)
    }

    /// What's kept for the page at `page` opening an app: its Allow or Block, or the app it was told Always Open to;
    /// nil asks. A frame from another site on the page (`foreign`) is held by Block only, never let in.
    static func decision(page: String?, foreign: Bool, stored: String?) -> String? {
        guard let page, let stored else { return nil }
        if stored == "deny" { return "deny" }
        return foreign ? nil : stored
    }

    /// What a page opening an app is held to, and whether that answer was kept for the site rather than given on this
    /// page. The page's own This-time answer must never be returned as something to keep (`PermissionAnswer.remember`),
    /// or the question machinery would write it down as the site's Always.
    struct KeptAppAnswer: Equatable {
        let action: String
        /// True only for an answer kept for the site; false for the page's own answer this time.
        let remember: Bool
    }

    /// What a page opening an app is held to, in one place: the site's own Allow or Block (the one "Open apps" row,
    /// which means every app), then the app told Always Allow, then the page's own answer this time. The site-wide
    /// row is read before the app's own key — a site-wide Allow covers every app, exactly as it always did. A page
    /// with no site of its own (`pageOrigin` nil) is held to the Block of the sites standing in for it. Nil asks.
    static func storedAppAnswer(pageOrigin: String?, standIns: [String] = [], origin: String?, scheme: String, foreign: Bool, tab: Tab?) -> KeptAppAnswer? {
        let siteWide = pageOrigin.flatMap { SitePermissions.action(PermissionSubject.apps, origin: $0) }
        let perApp = pageOrigin.flatMap { SitePermissions.action(PermissionSubject.app(scheme), origin: $0) }
        if let kept = decision(page: pageOrigin, foreign: foreign, stored: siteWide ?? perApp) {
            return KeptAppAnswer(action: kept, remember: true)
        }
        if pageOrigin == nil {
            let blocked = standIns.contains { standIn in
                let wide = SitePermissions.action(PermissionSubject.apps, origin: standIn)
                let app = SitePermissions.action(PermissionSubject.app(scheme), origin: standIn)
                return decision(page: standIn, foreign: true, stored: wide ?? app) == "deny"
            }
            if blocked { return KeptAppAnswer(action: "deny", remember: true) }
        }
        guard let origin, let page = tab?.permissionAnswers.action(key: origin, kind: PermissionSubject.app(scheme)) else { return nil }
        return KeptAppAnswer(action: page, remember: false)
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
        asked.lastOpened = asked.lastOpened.filter { !$0.key.hasPrefix(origin + "|") }
        // The ask-on-its-own gap too, so a site forgotten is asked at once rather than after its few seconds.
        asked.lastOnItsOwn[origin] = nil
        if let host = URL(string: origin)?.host() { asked.lastOnItsOwn[host] = nil }
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

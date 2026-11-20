import AppKit
import WebKit

/// Links for other apps (zoommtg:, itms-apps:, steam:, mailto:). A page doesn't get to open an app on your Mac by
/// itself: everyday links you click (mail, phone, FaceTime) open at once, anything else asks first, naming the app.
/// Open is for this time; with Always allow checked the site opens that app straight away from then on, as in Chrome;
/// Cancel puts it off. Open apps is a permission like the camera's (#192): Allow or Block for the whole site is chosen in
/// Site Controls or Settings › Privacy, and Block means nothing on the site opens an app, not even a link you click.
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
        /// When a page's "this time" answer last opened an app, by site and scheme, so it covers one launch rather
        /// than a repeating link.
        var lastOpened: [String: Date] = [:]
        /// Same gap as for questions.
        static let repeatGap: TimeInterval = 10

        /// Whether a "this time" answer may open the app again now; records the open. Clicks don't come here, they
        /// open every time.
        mutating func mayOpenAgain(_ key: String, now: Date = Date()) -> Bool {
            if let last = lastOpened[key], now.timeIntervalSince(last) < Self.repeatGap { return false }
            lastOpened[key] = now
            if lastOpened.count > 200 { lastOpened = lastOpened.filter { now.timeIntervalSince($0.value) < 60 } }
            return true
        }

        /// Whether `key` may ask now. A page re-asking on its own after you put it off or chose Don't Open waits. A
        /// click asks even right after a put-off, since the click that dismissed one question (claude.ai asks on
        /// load, then its Open Claude button asks again) mustn't silence the next. Only a link click (`linkClick`)
        /// undoes Don't Open, because page scripts can ride on any click. `page` is the page's site, whose frames
        /// share the gap (defaults to the key's site).
        mutating func mayAsk(_ key: String, page: String? = nil, clickedHere: Bool, linkClick: Bool, now: Date = Date()) -> Bool {
            guard !asking.contains(key) else { return false }
            if clickedHere {
                if linkClick { declined.remove(key) } else if declined.contains(key) { return false }
                putOff[key] = nil
                return true
            }
            guard !declined.contains(key), putOff[key].map({ now > $0 }) ?? true else { return false }
            // Unclicked asks: never while another question is up, and not again from the same page's site for a few
            // seconds, so frames from many sites can't queue questions. Other sites aren't held up.
            let site = page ?? String(key.prefix { $0 != "|" })
            guard asking.isEmpty, lastOnItsOwn[site].map({ now.timeIntervalSince($0) >= Self.unaskedGap }) ?? true else { return false }
            if lastOnItsOwn.count > 200 { lastOnItsOwn = lastOnItsOwn.filter { now.timeIntervalSince($0.value) < Self.unaskedGap } }
            lastOnItsOwn[site] = now
            return true
        }

        /// Last unclicked question time, by page site.
        var lastOnItsOwn: [String: Date] = [:]
        static let unaskedGap: TimeInterval = 10
    }
    private static var asked = Asked()

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// Frames count too: meeting pages often open their app from a hidden frame. Only a visible page asks. `isClick`:
    /// a real click or key, not a script's click(). `linkClick`: a clicked link (`.linkActivated`) rather than a
    /// script on your click; nil means same as `isClick` (Reader, PDF). `asker`: a cross-site frame that asked (an ad
    /// on a meeting page); named in the question, never gets the page's saved answer, but the page's Block applies.
    /// `byYou`: typed in the address or command bar; opens without asking unless the site is Blocked.
    /// `sourceIsMainFrame`: asked by the page's own document. `fromPDF`: a PDF's link always asks and never opens at
    /// once.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, linkClick: Bool? = nil, sourceIsMainFrame: Bool = true, from webView: WKWebView,
                     asker: WKSecurityOrigin? = nil, byYou: Bool = false, fromPDF: Bool = false) {
        let scheme = url.scheme?.lowercased() ?? ""
        // Only a site installed as an app sends these, from its own small app: never a page.
        if scheme == WebAppLink.scheme { return }
        // A page with no one there (AI apps in the background) never opens another app: no one can be asked, and an
        // Always Open for the site was chosen for you, not for them.
        if let tab = (webView as? BrowserWebView)?.owner, tab.isUnattended {
            Diagnostics.note("Blocked opening an app", site: webView.url?.host(), "\(scheme):", isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            tab.noteUnanswered(.app, "\(scheme):")
            return
        }
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
        // Site-wide Allow or Block first (Allow means every app), then the app's Always Open. Cross-site frames and
        // PDF links (`fromPDF`) get only Block. A page with no site (an about:blank its opener wrote) uses the Block
        // of the asking frame's or opener tab's site. The page's "this time" answer counts too, so a redirect or
        // repeated link doesn't ask twice.
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
            // A sign-in in Zigzag Mini returning to the app that asked closes that window (#246).
            MiniWindowController.pageOpenedApp(webView, isMainFrame: isMainFrame, linkClick: linkClick ?? isClick)
        }
        let kept = stored()
        // A "this time" answer covers one launch: script repeats are throttled like questions. Clicks always open.
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
        // A page re-asking after you put it off waits; clicks always ask (see `mayAsk`). A Deny holds for the page
        // (`stored` above). A background tab asks in its own host, where `PermissionPrompt` holds the question and
        // marks the tab. A web view with no window or tab (an orphaned pop-up) must not ask in whichever window is in
        // front. Mini and installed app windows are their own hosts.
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
        // Ask over the page itself, in Mini or an app window, not a browser window behind it (claude.ai's Open Claude
        // did nothing in Mini). A pop-up's window comes forward so the question isn't hidden.
        if popup != nil { promptHost.window?.makeKeyAndOrderFront(nil) }
        Task { @MainActor in
            let answer = await ask(app: name, icon: NSWorkspace.shared.icon(forFile: app.path), origin: origin, answerKey: key,
                                   in: promptHost, tab: tab, canRemember: saves,
                                   answered: { stored().map { PermissionAnswer(action: $0.action, remember: $0.remember) } })
            asked.asking.remove(key)
            guard let answer else {
                asked.putOff[key] = Date().addingTimeInterval(60)
                return
            }
            // This time holds for the page until it navigates; Always is kept for the site where allowed (https, no
            // foreign frame, not private). Both are per app, so a no kept for one link (an older answer) doesn't block
            // every app on the site.
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

    /// The words of "Open Slack?": who asks and what happens, Remember naming the site and the app, and Cancel
    /// then Open Slack.
    struct Question: Equatable {
        let title: String
        let detail: String
        let rememberTitle: String
        let actions: [String]
    }

    static func question(app name: String, site: String) -> (question: Question, actions: [PermissionAction]) {
        let open = PermissionAction(id: PermissionAction.allow.id,
                                    title: String(localized: "Open \(name)", comment: "A page's question to open an app, without its question mark. The placeholder is the app's name, like “zoom.us”."),
                                    isDeny: false, isProminent: true)
        let actions = [PermissionAction.cancel, open]
        let question = Question(
            title: open.title,
            detail: String(localized: "\(site) wants to open the \(name) app.", comment: "Under a page's question to open an app: the site, then the app's name, like “app.slack.com wants to open the Slack app.”."),
            rememberTitle: String(localized: "Always allow \(site) to open \(name)", comment: "Checkbox on a page's question to open an app: the site may open this app without asking from now on. The placeholders are the site and the app's name."),
            actions: actions.map(\.id))
        return (question, actions)
    }

    /// Asks to open `name`. Nil is Cancel, Esc or a click away; an allow with `remember` is Always.
    static func ask(app name: String, icon: NSImage?, origin: String?, answerKey: String?, in host: PromptHost, tab: Tab?,
                    canRemember: Bool, answered: @escaping () -> PermissionAnswer? = { nil }) async -> PermissionAnswer? {
        let site = SitePermissions.askerName(origin)
        let (question, actions) = question(app: name, site: site.withoutWWW)
        return await PermissionPrompt.ask(host: site, origin: origin, answerKey: answerKey, what: name, symbol: "arrow.up.forward.app",
                                          icon: icon, in: host, tab: tab, title: question.title, actions: actions,
                                          canRemember: canRemember, rememberTitle: question.rememberTitle, detail: question.detail,
                                          answered: answered)
    }

    /// The page's address for an app link. A tab Zigzag sends to an app link (an extension's tabs.update, e.g.
    /// Downie) already shows that link while it's decided, so the asking frame's origin (`asker`) is used instead.
    /// Otherwise every question came from "downie://xuopenlink" (#239).
    static func page(showing address: URL?, asker: String?) -> URL? {
        guard let address, isExternal(address) else { return address }
        return asker.flatMap { URL(string: $0) }
    }

    enum Verdict: Equatable { case block, open, ask }

    /// Whether an app link opens, asks or goes nowhere. A site Block always holds, even for typed addresses (`byYou`
    /// only skips the question). Mail, phone and FaceTime open at once only for a click in the front page
    /// (`clickedHere`); otherwise they ask. `stored` is honored as is: storing is already gated by `saves`, and
    /// cross-site frames only carry a Block this far (`decision`).
    static func verdict(byYou: Bool, clickedHere: Bool, scheme: String, stored: String?) -> Verdict {
        if stored == "deny" { return .block }
        if stored == "allow" { return .open }
        if byYou || (clickedHere && everyday.contains(scheme)) { return .open }
        return .ask
    }

    /// Only a clicked link in the front page's own document, never a frame, a script on your click, or a PDF.
    static func isEverydayClick(clickedHere: Bool, linkClick: Bool, sourceIsMainFrame: Bool, fromPDF: Bool) -> Bool {
        clickedHere && linkClick && sourceIsMainFrame && !fromPDF
    }

    /// Whether an answer may be kept for the site: not private, a nameable site, and a secure page with no foreign
    /// frame. This gates storing only; `verdict` trusts what's stored.
    static func saves(isPrivate: Bool, origin: String?, canRemember: Bool) -> Bool {
        !isPrivate && origin != nil && canRemember
    }

    /// Only secure pages, and never a cross-site frame, whose answer isn't the page's to give.
    static func canRemember(url: URL?, foreign: Bool) -> Bool {
        !foreign && url?.scheme?.lowercased() == "https"
    }

    /// Always the one app, so refusing the App Store link on a site doesn't block its Zoom link. The site-wide "apps"
    /// row is only written by Site Controls.
    static func storageSubject(for answer: PermissionAnswer, scheme: String) -> String {
        PermissionSubject.app(scheme)
    }

    /// The kept Allow, Block, or Always Open app; nil asks. A foreign frame (`foreign`) only gets Block.
    static func decision(page: String?, foreign: Bool, stored: String?) -> String? {
        guard page != nil, let stored else { return nil }
        if stored == "deny" { return "deny" }
        return foreign ? nil : stored
    }

    /// A kept app answer, and whether it's the site's rather than this page's. A page answer must never come back as
    /// `remember`, or it would be saved as the site's Always.
    struct KeptAppAnswer: Equatable {
        let action: String
        let remember: Bool
    }

    /// Site-wide "Open apps" Allow or Block first (covers every app), then the app's Always Allow, then the page's
    /// "this time" answer. A page with no site (`pageOrigin` nil) uses its stand-ins' Block. Nil asks.
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

    /// Whether the asking frame isn't the page: another site, or a hostless frame (sandboxed, data:) on a page with a
    /// host. Such frames never get the page's Always Open. `askerHost` nil means the page itself asked.
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
        // Clears the throttle too, so a forgotten site asks at once.
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

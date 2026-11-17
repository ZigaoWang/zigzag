import AppKit
import WebKit

/// Pop-ups a page opens on its own, without a click, are not opened silently: a page's own `window.open` asks where it
/// should go — this tab, a new tab, or the pop-up viewer (Mini) — and the answer can be kept for the site. A click
/// opens at once, as it always did, and so does a window Zigzag itself asked for (Open in New Tab, New Window, Peek).
@MainActor
enum PopupNotice {
    /// The destination a site's pop-ups were remembered to open in, if any: `"automatic"` (as it always did: a real
    /// tab for a plain `window.open`, a real pop-up for a sized one), `"mini"`, `"thisTab"`, `"newTab"` or `"deny"`.
    /// Nothing here reads for a private window: a private window asks every time.
    static func storedAction(origin: String?) -> String? {
        guard let origin else { return nil }
        return SitePermissions.action(PermissionSubject.popups, origin: origin)
    }

    /// The kind a page's "this time" answer is kept under: the one request it answered, not every `window.open` the
    /// page makes until it navigates. Two pop-ups to two addresses are two questions.
    static func requestKind(_ url: URL) -> String { "\(PermissionSubject.popups):\(url.absoluteString)" }

    /// Where the page at `origin` already said this one pop-up should go "this time", if it said so: a page that asks
    /// again on its own (a retry, the same link fired twice) is not asked twice for the same address. Nil when it
    /// hasn't, in a private window, or with no site to key the answer to — none of which keeps one.
    static func pageAction(tab: Tab?, origin: String?, url: URL, isPrivate: Bool) -> String? {
        guard !isPrivate, let origin else { return nil }
        return tab?.permissionAnswers.action(key: origin, kind: requestKind(url))
    }

    /// Writes what a pop-up's question was answered: This time is kept under the one request it answered, which is
    /// the key `pageAction` reads before asking again. `ask` and the test use this one path, so the two keys cannot
    /// drift apart again.
    static func remember(_ answer: PermissionAnswer, url: URL, key: String, tab: Tab?, isPrivate: Bool) {
        SitePermissions.rememberAnswer(answer, subject: PermissionSubject.popups, origin: key,
                                       pageSubject: requestKind(url), tab: tab, isPrivate: isPrivate)
    }

    /// Whether a page's own pop-up may be put to you as a question: only the page itself, never a frame in it, and
    /// only a web address or the blank page `window.open()` starts with. A frame's pop-up is blocked quietly, as it
    /// was before the card, and so is a data: page, a script, a file or one of Zigzag's own.
    static func mayAsk(url: URL?, fromMainFrame: Bool) -> Bool {
        guard fromMainFrame, let url else { return false }
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https": return true
        case "about": return url.absoluteString.lowercased() == "about:blank"
        default: return false
        }
    }

    /// What a page's own pop-up asked for, as a page link. `window.open('')` arrives as an address with no scheme,
    /// not nil, so an empty one is the blank page rather than something to refuse. `isBlank` covers about:blank too,
    /// which is just as nameless: a stored answer must not use it to take a whole tab.
    static func popupTarget(_ url: URL?) -> (url: URL, isBlank: Bool) {
        guard let url, !url.absoluteString.isEmpty, let scheme = url.scheme, !scheme.isEmpty else {
            return (URL(string: "about:blank")!, true)
        }
        return (url, url.absoluteString.lowercased() == "about:blank")
    }

    /// Whether a stored answer may open a pop-up that is a frame's or that names no address. Allow and Zigzag Mini
    /// may; This Tab and New Tab may not, since either would move the page wholesale, and a frame or a blank window
    /// can ask without a click.
    static func storedDestinationMayOpen(_ destination: Destination, forBlankOrFrame: Bool) -> Bool {
        !forBlankOrFrame || destination == .automatic || destination == .viewer
    }

    /// Where a page's pop-up address may be opened: the same routing a page link takes, so a kept destination can
    /// never be used to open a data: page, a script or one of Zigzag's own at the top level.
    enum Route: Equatable { case open, app, refuse }

    static func route(_ url: URL, from page: URL?) -> Route {
        switch Tab.route(forPageLink: url, from: page) {
        case .load: .open
        case .app: .app
        case .refuse: .refuse
        }
    }

    /// WebKit's own record of whether a click or a key started it (not public API, but long-standing); without
    /// it, whether the last thing you did was a click or a key a moment ago.
    static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        let selector = NSSelectorFromString("_isUserInitiated")
        if action.responds(to: selector), let initiated = action.value(forKey: "_isUserInitiated") as? Bool { return initiated }
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else { return false }
        return [.leftMouseUp, .leftMouseDown, .otherMouseUp, .keyDown].contains(event.type)
    }

    /// A page that asks again on its own is held to one question per site every few seconds, and a question that was
    /// put off is not put straight back up: the same guard the app question uses, for the same reason. A page's own
    /// "this time" answer keeps this too: it covers one request, not an endless run of windows.
    private static var lastAsked: [String: Date] = [:]
    private static var setAside: [String: Date] = [:]
    static let unaskedGap: TimeInterval = 10
    static let putOffGap: TimeInterval = 60

    static func mayAsk(origin: String?, now: Date = Date()) -> Bool {
        guard let origin else { return true }
        if let until = setAside[origin], now < until { return false }
        guard let last = lastAsked[origin] else { return true }
        return now.timeIntervalSince(last) >= unaskedGap
    }

    /// The question went up: another page asking on its own doesn't put it up again for a few seconds.
    static func noteAsked(origin: String?, now: Date = Date()) {
        guard let origin else { return }
        lastAsked[origin] = now
        if lastAsked.count > 200 { lastAsked = lastAsked.filter { now.timeIntervalSince($0.value) < 600 } }
    }

    /// The site's answers were forgotten: its throttle goes too, so the next pop-up asks as if it had never asked.
    static func forgetAnswers(origin: String) {
        lastAsked[origin] = nil
        setAside[origin] = nil
    }

    /// The question was put off (Esc, or its window closed): not straight back up.
    static func noteSetAside(origin: String?, now: Date = Date()) {
        guard let origin else { return }
        setAside[origin] = now.addingTimeInterval(putOffGap)
        if setAside.count > 200 { setAside = setAside.filter { now < $0.value } }
    }

    /// What a page's answer means for the pop-up WebKit is holding: show the window WebKit offered, close it and open
    /// the address the answer names, or close it and open nothing. Mini is the answer that needs the offered window:
    /// only it has `window.opener`, so a sign-in can hand its result back.
    enum HeldOutcome: Equatable { case reveal, discardAndOpen, discard }

    static func heldOutcome(for action: String, sized: Bool) -> HeldOutcome {
        switch destination(for: action) {
        case .viewer: .reveal
        case .automatic: sized ? .reveal : .discardAndOpen
        case .thisTab, .newTab: .discardAndOpen
        case .deny: .discard
        }
    }

    /// Asks, in the page's own window, where a pop-up should go, and opens it there. WebKit has already been told no,
    /// so nothing appears while the question waits; putting the question off (or Esc) opens nothing, and the page's
    /// next attempt asks again once the site's few seconds are up.
    /// The window WebKit offered is made before the answer, held off screen with its address unfetched: a Mini answer
    /// shows that very window, so `window.opener` works and a sign-in can finish, while any other answer closes it
    /// without the address ever being asked for. A page's own "this time" answer is known before the question, so it
    /// opens the same way.
    /// `configuration` and `features` are the pop-up WebKit offered: the viewer must use its data store (a private
    /// pop-up's child must not open a lasting window), and the real pop-up its size.
    @discardableResult
    static func ask(_ action: WKNavigationAction, from page: URL?, isPrivate: Bool, tab: Tab?, in host: PromptHost?,
                    configuration: WKWebViewConfiguration? = nil, features: WKWindowFeatures? = nil) -> WKWebView? {
        let origin = SiteOrigin.of(page)
        let frameOrigin = SiteOrigin.of(action.sourceFrame.securityOrigin)
        // Only the page itself asks. A pop-up from a frame — an ad in an iframe, say — is blocked without a word,
        // as it was before the card; a frame never gets to put a question up over the page it sits in.
        guard action.sourceFrame.isMainFrame else { return nil }
        // Answers are kept for sites only where the page itself is secure: an allow on an http page would be a
        // standing answer anyone on the network could have written.
        let secure = page?.scheme?.lowercased() == "https"
        let sameFrame = frameOrigin != nil && frameOrigin == origin
        let key = SitePermissions.answerKey(frame: frameOrigin, page: origin)
        guard let host, let url = action.request.url else { return nil }
        // A page's pop-up is a page link like any other: an app's address goes through the app's own question, and
        // anything the web may not open top-level (data:, a script, a file) goes nowhere.
        switch route(url, from: page) {
        case .refuse:
            Diagnostics.note("Refused a page's pop-up", site: origin.map(SiteOrigin.label) ?? "",
                             "\(url.scheme ?? "no scheme"):", isPrivate: isPrivate)
            return nil
        case .app:
            tab?.openFromPage(url, isClick: isUserInitiated(action), asker: action.sourceFrame.securityOrigin)
            return nil
        case .open:
            break
        }
        // Only a web address, or the blank page window.open() starts with, is put to you as a question.
        guard mayAsk(url: url, fromMainFrame: true) else { return nil }
        // What this frame already answered "this time" for this very request holds, so a page that asks again on its
        // own is not asked twice. It is held to the same few seconds as a question: the answer covers the request,
        // not every pop-up the page opens afterwards.
        if let kept = pageAction(tab: tab, origin: key, url: url, isPrivate: isPrivate) {
            guard mayAsk(origin: origin) else { return nil }
            noteAsked(origin: origin)
            return open(url, action: kept, from: tab, in: host, configuration: configuration, features: features)
        }
        guard mayAsk(origin: origin) else { return nil }
        noteAsked(origin: origin)
        SitePermissions.noteAsked(.popups, origin: origin, isPrivate: isPrivate)
        // The window WebKit offered, made now so a Mini answer can use it, but kept off screen with its address
        // unfetched: `revealHeldPage` shows it once the answer is known, and any other answer closes it.
        let cancellation = QuestionCancellation()
        let held = configuration.flatMap { configuration in
            features.map { PopupWindowController.asking(configuration: configuration, features: $0,
                                                        parent: host.window, opener: tab) }
        }
        // A pop-up the page closes while the card is up ends the question: there is nothing left to reveal.
        held?.onClose = { cancellation.cancel() }
        let target = SiteOrigin.of(url).map(SiteOrigin.label) ?? url.absoluteString
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(
                host: SitePermissions.askerName(frame: frameOrigin ?? origin, page: origin), origin: origin, answerKey: key,
                what: target, symbol: "macwindow.badge.plus", in: host, tab: tab,
                title: String(localized: "Open \(target) in a new window", comment: "A page's question before Zigzag opens the pop-up window it asked for. The placeholder is the address it wants to open, like meet.example.com."),
                actions: [.deny],
                menu: [.alternate("thisTab", String(localized: "This Tab", comment: "Choice in the pop-up question's menu: loads the pop-up's page in the tab you are in.")),
                       .alternate("newTab", String(localized: "New Tab", comment: "Choice in the pop-up question's menu: opens the pop-up's page in a new tab.")),
                       .alternate("mini", String(localized: "Zigzag Mini", comment: "Choice in the pop-up question's menu: opens the pop-up's page in Zigzag's small window for one page, which the app calls Zigzag Mini everywhere else."))],
                canRemember: !isPrivate && origin != nil && secure && sameFrame,
                cancellation: cancellation,
                answered: {
                    // A queued question may have been answered meanwhile: a destination the page kept for the site,
                    // or the same frame's This-time choice. The site's answer wins, as it does before asking.
                    if !isPrivate, let kept = storedAction(origin: origin) {
                        return PermissionAnswer(action: kept, remember: true)
                    }
                    if let key, let kept = pageAction(tab: tab, origin: key, url: url, isPrivate: isPrivate) {
                        return PermissionAnswer(action: kept, remember: false)
                    }
                    return nil
                })
            guard let answer else {
                // A closed pop-up is not a question put off: no site-wide pause comes from it.
                held?.discardHeldPage()
                if cancellation.isCancelled { return }
                noteSetAside(origin: origin)
                return
            }
            // The page closed the window while the card was up: answering opens nothing.
            guard held?.isClosed != true else { return }
            if let key {
                remember(answer, url: url, key: key, tab: tab, isPrivate: isPrivate)
            }
            switch heldOutcome(for: answer.action, sized: features.map(PopupNotice.isSized) ?? false) {
            case .reveal:
                // The window WebKit offered, which the page can script: a sign-in hands its result back through it.
                if let held {
                    // The address is checked once more at the moment it is revealed: the first request only, and
                    // never a data: page the opener sent the held window to after the card was put up.
                    if held.isClosed { return }
                    if let heldURL = held.heldURL, case .refuse = route(heldURL, from: page) {
                        held.discardHeldPage()
                        return
                    }
                    if held.revealHeldPage() { return }
                    return
                }
            case .discardAndOpen:
                held?.discardHeldPage()
            case .discard:
                held?.discardHeldPage()
                return
            }
            open(url, action: answer.action, from: tab, in: host, configuration: configuration, features: features)
        }
        return held?.webView
    }

    /// Where a pop-up goes, as one value: one of the two places a window can be told to open it, the viewer, the
    /// routing it had before the card, or nowhere. An action we don't know reads as the viewer — the ordinary yes for
    /// a pop-up — so a value an older build stored there ("allow", from when Always Allow meant an everyday pop-up)
    /// still opens rather than being dropped unseen.
    enum Destination: Equatable { case deny, automatic, thisTab, newTab, viewer }

    static func destination(for action: String) -> Destination {
        switch action {
        case "deny": .deny
        case "thisTab": .thisTab
        case "newTab": .newTab
        case "automatic", "allow": .automatic
        case "mini": .viewer
        default: .viewer
        }
    }

    /// Whether WebKit asked for a real pop-up window rather than a plain new tab, as Site Controls' automatic answer
    /// decides it: a size, or no toolbars, is a sign-in or a payment and gets its own window.
    static func isSized(_ features: WKWindowFeatures) -> Bool {
        features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false
    }

    /// Opens a pop-up where it was answered. A page link's routing holds here too: an app's address asks its own
    /// question, and anything not on the web opens nowhere.
    /// Returns the real pop-up where one is made from WebKit's own request (`features` given, while it is still
    /// waiting), so the page can script it; everything else opens later or elsewhere and returns nil.
    @discardableResult
    static func open(_ url: URL, action: String, from tab: Tab?, in host: PromptHost,
                     configuration: WKWebViewConfiguration? = nil, features: WKWindowFeatures? = nil) -> WKWebView? {
        switch route(url, from: tab?.url) {
        case .refuse:
            Diagnostics.note("Refused a page's pop-up", site: tab?.url?.host(), "\(url.scheme ?? "no scheme"):", isPrivate: tab?.isPrivate ?? false)
            return nil
        case .app:
            tab?.openFromPage(url, isClick: false, asker: nil)
            return nil
        case .open:
            break
        }
        switch destination(for: action) {
        case .deny:
            return nil
        case .automatic:
            // The ordinary yes, as it was before the card: a sized pop-up gets its own window, and a plain
            // window.open opens a tab.
            if let features, let tab, isSized(features) {
                guard let configuration = configuration ?? tab.webView?.configuration else { return nil }
                return PopupWindowController.open(configuration: configuration, features: features, parent: host.window, opener: tab)
            }
            openInWindow(url, disposition: .foregroundTab, from: tab, in: host)
            return nil
        case .thisTab:
            // The tab that asked, never the selected one: in a split they are different panes.
            if let tab, !tab.isClosed {
                tab.load(url, by: .page)
            } else {
                openInWindow(url, disposition: .currentTab, from: tab, in: host)
            }
            return nil
        case .newTab:
            openInWindow(url, disposition: .foregroundTab, from: tab, in: host)
            return nil
        case .viewer:
            guard let configuration = configuration ?? tab?.webView?.configuration else { return nil }
            if let features, let tab {
                // WebKit is still offering the window, so it is made the real thing: `window.opener` and everything
                // the page does with the new window keep working.
                return PopupWindowController.open(configuration: configuration, features: features, parent: host.window, opener: tab)
            }
            // The small window that shows the pop-up's page: the pop-up viewer. The page's own configuration, so the
            // viewer is on the same data store — a private pop-up's child must not outlive it in a persistent one.
            PopupWindowController.viewer(url: url, configuration: configuration, parent: host.window)
            return nil
        }
    }

    /// A page's pop-up opened somewhere in a window: in this tab, or a new one. It goes through the asking tab's own
    /// host, so a browser window, Zigzag Mini and an installed app's window are all served — the hosts of the last two
    /// are not `BrowserWindowController`s. Where no tab asked (a pop-up window's own child), the window it was asked
    /// from opens it: a browser window at once, or, for a window with one page of its own and no tabs to name, that
    /// page's own host — which is what settles what "this tab" and "a new tab" mean inside it.
    private static func openInWindow(_ url: URL, disposition: OpenDisposition, from tab: Tab?, in host: PromptHost) {
        if let tab, let opener = tab.host {
            opener.tab(tab, openURL: url, disposition: disposition)
        } else if let browser = host as? BrowserWindowController {
            browser.open(url, disposition: disposition, opener: nil, allowSwitch: false, by: .page)
        } else if let page = host.promptFrontTab, let opener = page.host {
            opener.tab(page, openURL: url, disposition: disposition)
        }
    }
}

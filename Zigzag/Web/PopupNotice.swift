import AppKit
import WebKit

/// Unclicked `window.open` asks where to go (this tab, a new tab, or Mini), and the answer can be kept for the site.
/// Clicked pop-ups and Zigzag's own windows (Open in New Tab, New Window, Zigzag Mini) open at once.
@MainActor
enum PopupNotice {
    /// The site's kept pop-up destination: `"automatic"` (tab for a plain `window.open`, window for a sized one),
    /// `"mini"`, `"thisTab"`, `"newTab"` or `"deny"`. Private windows always ask.
    static func storedAction(origin: String?) -> String? {
        guard let origin else { return nil }
        return SitePermissions.action(PermissionSubject.popups, origin: origin)
    }

    /// Keyed per request, so two pop-ups to two addresses are two questions.
    static func requestKind(_ url: URL) -> String { "\(PermissionSubject.popups):\(url.absoluteString)" }

    /// The page's "this time" answer for this address, so a retry isn't asked again. Nil if none, in a private
    /// window, or with no site.
    static func pageAction(tab: Tab?, origin: String?, url: URL, isPrivate: Bool) -> String? {
        guard !isPrivate, let origin else { return nil }
        return tab?.permissionAnswers.action(key: origin, kind: requestKind(url))
    }

    /// Records an answer. This time is keyed by request, matching `pageAction`; shared with tests so the keys can't
    /// drift.
    static func remember(_ answer: PermissionAnswer, url: URL, key: String, tab: Tab?, isPrivate: Bool) {
        SitePermissions.rememberAnswer(answer, subject: PermissionSubject.popups, origin: key,
                                       pageSubject: requestKind(url), tab: tab, isPrivate: isPrivate)
    }

    /// Only the main frame asks, and only for a web address or `window.open()`'s blank page. Frames, data:, scripts,
    /// files and Zigzag's own pages are blocked quietly.
    static func mayAsk(url: URL?, fromMainFrame: Bool) -> Bool {
        guard fromMainFrame, let url else { return false }
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https": return true
        case "about": return url.absoluteString.lowercased() == "about:blank"
        default: return false
        }
    }

    /// `window.open('')` arrives as a scheme-less address, not nil, so empty means blank. about:blank counts as blank
    /// too, so a kept answer can't use it to take a whole tab.
    static func popupTarget(_ url: URL?) -> (url: URL, isBlank: Bool) {
        guard let url, !url.absoluteString.isEmpty, let scheme = url.scheme, !scheme.isEmpty else {
            return (URL(string: "about:blank")!, true)
        }
        return (url, url.absoluteString.lowercased() == "about:blank")
    }

    /// Allow and Mini may open frame or blank pop-ups from a kept answer; This Tab and New Tab may not, since they'd
    /// move the page without a click.
    static func storedDestinationMayOpen(_ destination: Destination, forBlankOrFrame: Bool) -> Bool {
        !forBlankOrFrame || destination == .automatic || destination == .viewer
    }

    /// Same routing as page links, so a kept destination can't open data:, scripts or Zigzag pages top-level.
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

    /// Each page's last click or key from you, by its web view, so a pop-up can only count its own page's input.
    private static let lastInput = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    /// How long after your click or key a page's pop-up still counts as clicked when WebKit didn't see it so.
    nonisolated static let inputGrace: TimeInterval = 1

    /// A real event on its way in (`ZigzagApplication.sendEvent`): a click or key that lands in a page is noted for it.
    /// AI apps' keys don't count.
    static func noteInput(_ event: NSEvent) {
        guard [.leftMouseDown, .leftMouseUp, .keyDown].contains(event.type), !MCPKeyDelivery.isAgentEvent(event),
              let window = event.window else { return }
        var view: NSView?
        if event.type == .keyDown {
            view = window.firstResponder as? NSView
        } else if let frame = window.contentView?.superview ?? window.contentView {
            view = frame.hitTest(event.locationInWindow)
        }
        while let current = view, !(current is WKWebView) { view = current.superview }
        if let webView = view as? WKWebView { noteInput(in: webView) }
    }

    static func noteInput(in webView: WKWebView, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastInput.setObject(NSNumber(value: time), forKey: webView)
    }

    /// Seconds since your last click or key in this page; nil if none.
    static func sinceInput(in webView: WKWebView, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        lastInput.object(forKey: webView).map { now - $0.doubleValue }
    }

    /// A main-frame pop-up counts as clicked within `inputGrace` of your own click or key in its page while its
    /// window is key, as with Chrome's transient activation. Frames never do.
    nonisolated static func countsAsClicked(sinceInput: TimeInterval?, windowIsKey: Bool, fromMainFrame: Bool) -> Bool {
        guard fromMainFrame, windowIsKey, let sinceInput else { return false }
        return sinceInput >= 0 && sinceInput <= inputGrace
    }

    /// Clicked as WebKit saw it, or right after your own click or key in this page (`countsAsClicked`), which is noted
    /// for Report a Problem.
    static func isClicked(_ action: WKNavigationAction, in webView: WKWebView, isPrivate: Bool) -> Bool {
        if isUserInitiated(action) { return true }
        let since = sinceInput(in: webView)
        guard countsAsClicked(sinceInput: since, windowIsKey: webView.window != nil && webView.window === NSApp.keyWindow,
                              fromMainFrame: action.sourceFrame.isMainFrame), let since else { return false }
        Diagnostics.note("Pop-up without a click", site: webView.url?.host(), countedNote(sinceInput: since), isPrivate: isPrivate)
        return true
    }

    nonisolated static func countedNote(sinceInput: TimeInterval) -> String {
        "counted as clicked: input \(String(format: "%.1f", sinceInput)) s before"
    }

    /// The diagnostics line for a pop-up WebKit saw no click for: where it was, and how long since your last click or
    /// key in a page, if that was in the last 5 seconds.
    nonisolated static func unclickedNote(inMini: Bool, sinceInput: TimeInterval) -> String {
        let place = inMini ? "in Zigzag Mini" : "in a window"
        guard sinceInput >= 0, sinceInput < 5 else { return "\(place), no click or key in a page for 5 s" }
        return "\(place), a click or key in a page \(String(format: "%.1f", sinceInput)) s before"
    }

    /// One question per site every few seconds, and a put-off question doesn't come straight back, as with the app
    /// question. Also applies after a "this time" answer.
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

    static func noteAsked(origin: String?, now: Date = Date()) {
        guard let origin else { return }
        lastAsked[origin] = now
        if lastAsked.count > 200 { lastAsked = lastAsked.filter { now.timeIntervalSince($0.value) < 600 } }
    }

    /// Clears the throttle with the site's answers.
    static func forgetAnswers(origin: String) {
        lastAsked[origin] = nil
        setAside[origin] = nil
    }

    /// Put off (Esc, or window closed).
    static func noteSetAside(origin: String?, now: Date = Date()) {
        guard let origin else { return }
        setAside[origin] = now.addingTimeInterval(putOffGap)
        if setAside.count > 200 { setAside = setAside.filter { now < $0.value } }
    }

    /// What happens to the pop-up WebKit is holding. Only Mini reveals it, since only that keeps `window.opener` for
    /// sign-ins.
    enum HeldOutcome: Equatable { case reveal, discardAndOpen, discard }

    static func heldOutcome(for action: String, sized: Bool) -> HeldOutcome {
        switch destination(for: action) {
        case .viewer: .reveal
        case .automatic: sized ? .reveal : .discardAndOpen
        case .thisTab, .newTab: .discardAndOpen
        case .deny: .discard
        }
    }

    /// Asks in the page's window where a pop-up goes, then opens it. WebKit's window is made now but held off screen
    /// and unfetched: Mini reveals it (so `window.opener` works), any other answer closes it without a request.
    /// Putting it off opens nothing; the next attempt asks again after the throttle. A page's "this time" answer
    /// skips the question. `configuration` and `features` are WebKit's: the viewer must use its data store (so a
    /// private pop-up doesn't open a persistent window) and the real pop-up its size.
    @discardableResult
    static func ask(_ action: WKNavigationAction, from page: URL?, isPrivate: Bool, tab: Tab?, in host: PromptHost?,
                    configuration: WKWebViewConfiguration? = nil, features: WKWindowFeatures? = nil) -> WKWebView? {
        let origin = SiteOrigin.of(page)
        let frameOrigin = SiteOrigin.of(action.sourceFrame.securityOrigin)
        // Frame pop-ups (e.g. iframe ads) are blocked silently.
        guard action.sourceFrame.isMainFrame else { return nil }
        // Only https pages keep site answers; an allow on http could be written by anyone on the network.
        let secure = page?.scheme?.lowercased() == "https"
        let sameFrame = frameOrigin != nil && frameOrigin == origin
        let key = SitePermissions.answerKey(frame: frameOrigin, page: origin)
        guard let host, let url = action.request.url else { return nil }
        // Same routing as page links: app addresses get the app question; data:, scripts and files go nowhere.
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
        guard mayAsk(url: url, fromMainFrame: true) else { return nil }
        // This frame's "this time" answer for this request holds, under the same throttle.
        if let kept = pageAction(tab: tab, origin: key, url: url, isPrivate: isPrivate) {
            guard mayAsk(origin: origin) else { return nil }
            noteAsked(origin: origin)
            return open(url, action: kept, from: tab, in: host, configuration: configuration, features: features)
        }
        guard mayAsk(origin: origin) else { return nil }
        noteAsked(origin: origin)
        SitePermissions.noteAsked(.popups, origin: origin, isPrivate: isPrivate)
        // Made now so Mini can use it, kept off screen and unfetched until `revealHeldPage`.
        let cancellation = QuestionCancellation()
        let held = configuration.flatMap { configuration in
            features.map { PopupWindowController.asking(configuration: configuration, features: $0,
                                                        parent: host.window, opener: tab) }
        }
        // The page closing the pop-up ends the question.
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
                    // May have been answered while queued; the site's answer wins.
                    if !isPrivate, let kept = storedAction(origin: origin) {
                        return PermissionAnswer(action: kept, remember: true)
                    }
                    if let key, let kept = pageAction(tab: tab, origin: key, url: url, isPrivate: isPrivate) {
                        return PermissionAnswer(action: kept, remember: false)
                    }
                    return nil
                })
            guard let answer else {
                // A closed pop-up doesn't trigger the put-off pause.
                held?.discardHeldPage()
                if cancellation.isCancelled { return }
                noteSetAside(origin: origin)
                return
            }
            guard held?.isClosed != true else { return }
            if let key {
                remember(answer, url: url, key: key, tab: tab, isPrivate: isPrivate)
            }
            switch heldOutcome(for: answer.action, sized: features.map(PopupNotice.isSized) ?? false) {
            case .reveal:
                // Mini shows WebKit's own window, which the page can script for sign-ins.
                if let held {
                    // Check again at reveal: only the first request, never a data: page sent later.
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

    /// Unknown actions read as the viewer, so an old "allow" (from when Always Allow meant a normal pop-up) still
    /// opens.
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

    /// A size or hidden toolbars means a sign-in or payment window, which gets its own window instead of a tab.
    static func isSized(_ features: WKWindowFeatures) -> Bool {
        features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false
    }

    /// Opens via `OpenInZigzag`, which handles the same three places as Open URL rules. The page's configuration is
    /// passed on so a private pop-up stays on its data store. Returns the real pop-up when made from WebKit's pending
    /// request (`features` given), so the page can script it; nil otherwise.
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
            // Pre-card behavior: sized pop-ups get a window, plain window.open a tab.
            if let features, let tab, isSized(features) {
                guard let configuration = configuration ?? tab.webView?.configuration else { return nil }
                return PopupWindowController.open(configuration: configuration, features: features, parent: host.window, opener: tab)
            }
            openInWindow(url, disposition: .foregroundTab, from: tab, in: host)
            return nil
        case .thisTab:
            OpenInZigzag.open(url, at: .thisTab, from: tab, in: host, configuration: configuration, by: .page)
            return nil
        case .newTab:
            OpenInZigzag.open(url, at: .newTab, from: tab, in: host, configuration: configuration, by: .page)
            return nil
        case .viewer:
            guard let configuration = configuration ?? tab?.webView?.configuration else { return nil }
            if let features, let tab {
                // WebKit is still offering the window, so the page keeps `window.opener`.
                return PopupWindowController.open(configuration: configuration, features: features, parent: host.window, opener: tab)
            }
            OpenInZigzag.open(url, at: .mini, from: tab, in: host, configuration: configuration, by: .page)
            return nil
        }
    }

    /// Opens via the asking tab's host, so browser windows, Zigzag Mini and installed app windows all work. With no
    /// tab (a pop-up's child), uses the window it came from, or that window's single page's host.
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

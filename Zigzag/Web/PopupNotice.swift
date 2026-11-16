import AppKit
import WebKit

/// Pop-ups a page opens on its own, without a click, are not opened silently: a page's own `window.open` asks where it
/// should go — this tab, a new tab, or the pop-up viewer (Mini) — and the answer can be kept for the site. A click
/// opens at once, as it always did, and so does a window Zigzag itself asked for (Open in New Tab, New Window, Peek).
@MainActor
enum PopupNotice {
    /// The destination a site's pop-ups were remembered to open in, if any: `"mini"`, `"thisTab"`, `"newTab"` or
    /// `"deny"`. Nothing here reads for a private window: a private window asks every time.
    static func storedAction(origin: String?) -> String? {
        guard let origin else { return nil }
        return SitePermissions.action(PermissionSubject.popups, origin: origin)
    }

    /// Where the page at `origin` already said its pop-ups should go "this time", if it said so: a page that asks
    /// again on its own (a second `window.open` while the first is still loading, a retry) is not asked twice. Nil
    /// when it hasn't, in a private window, or with no site to key the answer to — none of which keeps one.
    static func pageAction(tab: Tab?, origin: String?, isPrivate: Bool) -> String? {
        guard !isPrivate, let origin else { return nil }
        return tab?.permissionAnswers.action(key: origin, kind: PermissionSubject.popups)
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
    /// put off is not put straight back up: the same guard the app question uses, for the same reason.
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

    /// Asks, in the page's own window, where a pop-up should go, and opens it there. WebKit has already been told no,
    /// so nothing appears while the question waits; putting the question off (or Esc) opens nothing, and the page's
    /// next attempt asks again once the site's few seconds are up.
    /// `configuration` is the pop-up's own configuration where the page is inside a pop-up window: the viewer must
    /// use the same data store as the page that asked, or a private pop-up's child would open a lasting window.
    static func ask(_ action: WKNavigationAction, from page: URL?, isPrivate: Bool, tab: Tab?, in host: PromptHost?,
                    configuration: WKWebViewConfiguration? = nil) {
        let origin = SiteOrigin.of(page)
        let frameOrigin = SiteOrigin.of(action.sourceFrame.securityOrigin)
        // Only the page's own frame may choose where the page's pop-ups go for good. A frame from another origin —
        // and an opaque frame, whose origin cannot be named — may ask this time, and its answer stays that frame's.
        let sameFrame = frameOrigin != nil && frameOrigin == origin
        let key = SitePermissions.answerKey(frame: frameOrigin, page: origin)
        // Answers are kept for sites only where the page itself is secure: an allow on an http page would be a
        // standing answer anyone on the network could have written.
        let secure = page?.scheme?.lowercased() == "https"
        let url = action.request.url
        guard let host, let url else { return }
        // What this frame already answered "this time" holds, so a page that asks again on its own (a second
        // `window.open` while the first is still loading, a retry) is not asked twice.
        if let kept = pageAction(tab: tab, origin: key, isPrivate: isPrivate) {
            open(url, action: kept, from: tab, in: host, configuration: configuration)
            return
        }
        guard mayAsk(origin: origin) else { return }
        noteAsked(origin: origin)
        SitePermissions.noteAsked(.popups, origin: origin, isPrivate: isPrivate)
        let target = SiteOrigin.of(url).map(SiteOrigin.label) ?? url.absoluteString
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(
                host: SitePermissions.askerName(frame: frameOrigin ?? origin, page: origin), origin: origin, what: target, symbol: "macwindow.badge.plus",
                in: host, tab: tab,
                title: String(localized: "Open \(target) in a new window", comment: "A page's question before Zigzag opens the pop-up window it asked for. The placeholder is the address it wants to open, like meet.example.com."),
                actions: [.deny],
                menu: [.alternate("thisTab", String(localized: "This Tab", comment: "Choice in the pop-up question's menu: loads the pop-up's page in the tab you are in.")),
                       .alternate("newTab", String(localized: "New Tab", comment: "Choice in the pop-up question's menu: opens the pop-up's page in a new tab.")),
                       .alternate("mini", String(localized: "Mini", comment: "Choice in the pop-up question's menu: opens the pop-up's page in the small pop-up viewer window."))],
                canRemember: !isPrivate && origin != nil && secure && sameFrame,
                answered: {
                    // A queued question may have been answered meanwhile: a destination the page kept for the site,
                    // or the same frame's This-time choice. The site's answer wins, as it does before asking.
                    if !isPrivate, let kept = storedAction(origin: origin) {
                        return PermissionAnswer(action: kept, remember: true)
                    }
                    if let key, let kept = pageAction(tab: tab, origin: key, isPrivate: isPrivate) {
                        return PermissionAnswer(action: kept, remember: false)
                    }
                    return nil
                })
            guard let answer else { noteSetAside(origin: origin); return }
            if let key {
                SitePermissions.rememberAnswer(answer, subject: PermissionSubject.popups, origin: key, tab: tab, isPrivate: isPrivate)
            }
            open(url, action: answer.action, from: tab, in: host, configuration: configuration)
        }
    }

    /// Where a pop-up goes, as one value: one of the two places a window can be told to open it, the viewer, or
    /// nowhere. An action we don't know reads as the viewer — the ordinary yes for a pop-up — so a value an older
    /// build stored there ("allow", from when Always Allow meant an everyday pop-up) still opens rather than being
    /// dropped unseen.
    enum Destination: Equatable { case deny, thisTab, newTab, viewer }

    static func destination(for action: String) -> Destination {
        switch action {
        case "deny": .deny
        case "thisTab": .thisTab
        case "newTab": .newTab
        default: .viewer
        }
    }

    /// Opens a pop-up where it was answered. The three places are the same three an Open URL rule can name, so they
    /// are opened by the one thing that knows what they mean (`OpenInZigzag`). The page's own configuration is passed
    /// on, so a private pop-up's viewer is on the same data store and does not outlive it in a persistent one.
    static func open(_ url: URL, action: String, from tab: Tab?, in host: PromptHost,
                     configuration: WKWebViewConfiguration? = nil) {
        switch destination(for: action) {
        case .deny:
            return
        case .thisTab:
            OpenInZigzag.open(url, at: .thisTab, from: tab, in: host, configuration: configuration, by: .page)
        case .newTab:
            OpenInZigzag.open(url, at: .newTab, from: tab, in: host, configuration: configuration, by: .page)
        case .viewer:
            OpenInZigzag.open(url, at: .mini, from: tab, in: host, configuration: configuration, by: .page)
        }
    }
}

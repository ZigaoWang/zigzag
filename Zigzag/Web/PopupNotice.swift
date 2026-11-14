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

    /// Asks, in the page's own window, where a pop-up should go, and opens it there. WebKit has already been told no,
    /// so nothing appears while the question waits; putting the question off (or Esc) opens nothing, and the page's
    /// next attempt asks again.
    static func ask(_ action: WKNavigationAction, from page: URL?, isPrivate: Bool, tab: Tab?, in host: PromptHost?) {
        let origin = SiteOrigin.of(page)
        let url = action.request.url
        guard let host, let url else { return }
        // What this page already answered "this time" holds, so a page that asks again on its own (a second
        // `window.open` while the first is still loading, a retry) is not asked twice.
        if let kept = pageAction(tab: tab, origin: origin, isPrivate: isPrivate) {
            open(url, action: kept, from: tab, in: host)
            return
        }
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(
                host: SitePermissions.askerName(origin), origin: origin, what: SiteOrigin.of(url).map(SiteOrigin.label) ?? "", symbol: "macwindow.badge.plus",
                in: host, tab: tab,
                title: String(localized: "A page wants to open a new window", comment: "A page's question before Zigzag opens the pop-up window it asked for."),
                actions: [.deny,
                          .alternate("thisTab", String(localized: "This Tab", comment: "Button in the pop-up question: loads the pop-up's page in the tab you are in.")),
                          .alternate("newTab", String(localized: "New Tab", comment: "Button in the pop-up question: opens the pop-up's page in a new tab.")),
                          .alternate("mini", String(localized: "Mini", comment: "Button in the pop-up question: opens the pop-up's page in the small pop-up viewer window."))],
                canRemember: !isPrivate && origin != nil)
            guard let answer else { return }
            if let origin {
                SitePermissions.rememberAnswer(answer, subject: PermissionSubject.popups, origin: origin, tab: tab, isPrivate: isPrivate)
            }
            open(url, action: answer.action, from: tab, in: host)
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

    /// Opens a pop-up where it was answered.
    static func open(_ url: URL, action: String, from tab: Tab?, in host: PromptHost) {
        switch destination(for: action) {
        case .deny:
            return
        case .thisTab:
            openInWindow(url, disposition: .currentTab, from: tab, in: host)
        case .newTab:
            openInWindow(url, disposition: .foregroundTab, from: tab, in: host)
        case .viewer:
            // The small window that shows the pop-up's page: the pop-up viewer.
            PopupWindowController.viewer(url: url, configuration: tab?.webView?.configuration, parent: host.window)
        }
    }

    /// A page's pop-up opened somewhere in a window: in this tab, or a new one. It goes through the asking tab's own
    /// host, so a browser window, Zigzag Mini and an installed app's window are all served — the hosts of the last two
    /// are not `BrowserWindowController`s. Where no tab asked (a pop-up window's own child), the window it was asked
    /// from opens it.
    private static func openInWindow(_ url: URL, disposition: OpenDisposition, from tab: Tab?, in host: PromptHost) {
        if let tab, let opener = tab.host {
            opener.tab(tab, openURL: url, disposition: disposition)
        } else if let browser = host as? BrowserWindowController {
            browser.open(url, disposition: disposition, opener: nil, allowSwitch: false, by: .page)
        }
    }
}

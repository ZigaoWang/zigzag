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

    /// Opens a pop-up where it was answered: the tab you are in, a new tab, or the pop-up viewer (Mini).
    static func open(_ url: URL, action: String, from tab: Tab?, in host: PromptHost) {
        guard let controller = host as? BrowserWindowController else { return }
        switch action {
        case "thisTab": controller.open(url, disposition: .currentTab, opener: tab, allowSwitch: false)
        case "newTab": controller.open(url, disposition: .foregroundTab, opener: tab, allowSwitch: false)
        case "mini": PopupWindowController.viewer(url: url, configuration: tab?.webView?.configuration, parent: controller.window)
        default: break
        }
    }
}

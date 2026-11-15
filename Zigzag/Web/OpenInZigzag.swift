import AppKit

/// Opens a web address in Zigzag itself, at the place it was asked for: the tab you're in, a new tab, or the small
/// window that shows one page (the pop-up viewer). One place, so a page's pop-up question and a download rule's Open
/// URL action mean exactly the same thing by "This Tab", "New Tab" and "Mini" — and so a rule can write the answer
/// down and mean the same thing later.
nonisolated enum OpenInZigzag {
    /// One of the three places Zigzag can show a web address, all of them inside Zigzag. The raw value is what a rule
    /// saves and what a question's answer comes back as, so it is also the id the pop-up question's menu has always
    /// used: the two can never drift apart.
    enum Place: String, Codable, CaseIterable, Sendable {
        case thisTab
        case newTab
        case mini

        /// The words the rule editor and the question both use, the same ones the pop-up question has always offered.
        var title: String {
            switch self {
            case .thisTab: String(localized: "This Tab", comment: "Choice in the pop-up question's menu, and in a download rule's Open in choice: loads the address in the tab you are in.")
            case .newTab: String(localized: "New Tab", comment: "Choice in the pop-up question's menu, and in a download rule's Open in choice: opens the address in a new tab.")
            case .mini: String(localized: "Mini", comment: "Choice in the pop-up question's menu, and in a download rule's Open in choice: opens the address in the small pop-up viewer window.")
            }
        }
    }

    /// Whether Zigzag is what shows an address: the web's own, and only the web's. Anything else — mpv://, a magnet, a
    /// mail link — belongs to the app that handles it, and is handed on as it always was.
    static func handles(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Opens `url` where it was asked for.
    @MainActor
    static func open(_ url: URL, at place: Place, from tab: Tab?, in host: PromptHost) {
        switch place {
        case .thisTab:
            inWindow(url, disposition: .currentTab, from: tab, in: host)
        case .newTab:
            inWindow(url, disposition: .foregroundTab, from: tab, in: host)
        case .mini:
            // The small window that shows one page of its own, on the same data store where there is one to share.
            PopupWindowController.viewer(url: url, configuration: tab?.webView?.configuration, parent: host.window)
        }
    }

    /// A page opened somewhere in a window: in this tab, or a new one. It goes through the asking tab's own host, so a
    /// browser window, Zigzag Mini and an installed app's window are all served — the hosts of the last two are not
    /// `BrowserWindowController`s. Where no tab asked (a pop-up window's own child), the window it was asked from
    /// opens it: a browser window at once, or, for a window with one page of its own and no tabs to name, that page's
    /// own host — which is what settles what "this tab" and "a new tab" mean inside it.
    ///
    /// Sent as `.rule`, so the page it lands on is never caught by a rule again: a rule that took the address it had
    /// just opened would ask, or open, for ever.
    @MainActor
    private static func inWindow(_ url: URL, disposition: OpenDisposition, from tab: Tab?, in host: PromptHost) {
        if let tab, let opener = tab.host {
            opener.tab(tab, openURL: url, disposition: disposition, by: .rule)
        } else if let browser = host as? BrowserWindowController {
            browser.open(url, disposition: disposition, opener: nil, allowSwitch: false, by: .rule)
        } else if let page = host.promptFrontTab, let opener = page.host {
            opener.tab(page, openURL: url, disposition: disposition, by: .rule)
        }
    }
}

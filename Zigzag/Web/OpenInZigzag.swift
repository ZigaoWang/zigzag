import AppKit
import WebKit

/// Opens a web address in Zigzag: this tab, a new tab, or the pop-up viewer (Mini). Shared by the pop-up question and
/// Open URL rules so "This Tab", "New Tab" and "Mini" mean the same in both, including when saved.
nonisolated enum OpenInZigzag {
    /// The raw value is what rules save and questions return, and matches the pop-up question's menu ids.
    enum Place: String, Codable, CaseIterable, Sendable {
        case thisTab
        case newTab
        case mini

        /// Shared by the rule editor and the questions.
        var title: String {
            switch self {
            case .thisTab: String(localized: "This Tab", comment: "Choice in the pop-up question's menu, and in a download rule's Open in choice: loads the address in the tab you are in.")
            case .newTab: String(localized: "New Tab", comment: "Choice in the pop-up question's menu, and in a download rule's Open in choice: opens the address in a new tab.")
            case .mini: String(localized: "Zigzag Mini", comment: "Choice in the pop-up question's menu, and in a download rule's Open in choice: opens the address in Zigzag's small window for one page, which the app calls Zigzag Mini everywhere else.")
            }
        }
    }

    /// Where an Open URL rule opens a web address: a Zigzag place, the default browser, or Ask (not decided yet). The
    /// sheet offers all five; the question omits Ask, since its buttons already decide whether the rule runs.
    enum Choice: String, Codable, CaseIterable, Sendable {
        case ask
        case defaultBrowser
        case thisTab
        case newTab
        case mini

        /// Order in the question's dropdown. The hand-off card puts This Tab first (`DownloadHandoff.cardPlaces`).
        static var destinations: [Choice] { [.defaultBrowser, .thisTab, .newTab, .mini] }

        /// Nil for Ask and the default browser.
        var place: Place? {
            switch self {
            case .thisTab: .thisTab
            case .newTab: .newTab
            case .mini: .mini
            case .ask, .defaultBrowser: nil
            }
        }

        var title: String {
            switch self {
            case .ask: String(localized: "Ask", comment: "Choice in an Open URL download rule's Open in dropdown: the rule asks where to open the first time it fires, and keeps the answer. Also a choice in Site Controls' permission dropdown: the site asks each time.")
            case .defaultBrowser: String(localized: "Default Browser", comment: "Choice in an Open URL download rule's Open in dropdown: opens the web address in the Mac's default browser, as these rules did before Zigzag had its own places.")
            case .thisTab, .newTab, .mini: place?.title ?? ""
            }
        }
    }

    /// Only web addresses. Others (mpv://, magnet, mailto) go to their handler.
    static func handles(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// `configuration` is a pop-up's own when it has one, so Mini uses the page's data store. `sender` is `.rule`
    /// when a rule opens an address it just took, so the landing page doesn't trigger it again.
    @MainActor
    static func open(_ url: URL, at place: Place, from tab: Tab?, in host: PromptHost,
                     configuration: WKWebViewConfiguration? = nil, by sender: Tab.LoadSender = .rule) {
        switch place {
        case .thisTab:
            inWindow(url, disposition: .currentTab, from: tab, in: host, configuration: configuration, by: sender)
        case .newTab:
            inWindow(url, disposition: .foregroundTab, from: tab, in: host, configuration: configuration, by: sender)
        case .mini:
            // Mini, on the same data store when there is one.
            guard let configuration = configuration ?? tab?.webView?.configuration else { return }
            _ = PopupWindowController.viewer(url: url, configuration: configuration, parent: host.window, by: sender)
        }
    }

    /// Opens via the asking tab's host, so browser windows, Zigzag Mini and installed app windows all work. With no
    /// tab (a pop-up's child), uses the window it came from, or that window's single page's host. Sent as `.rule` so
    /// the landing page isn't caught by a rule again, which would loop.
    @MainActor
    private static func inWindow(_ url: URL, disposition: OpenDisposition, from tab: Tab?, in host: PromptHost,
                                 configuration: WKWebViewConfiguration?, by sender: Tab.LoadSender) {
        if let tab, let opener = tab.host {
            opener.tab(tab, openURL: url, disposition: disposition, by: sender)
        } else if let browser = host as? BrowserWindowController {
            browser.open(url, disposition: disposition, opener: nil, allowSwitch: false, by: sender)
        } else if let page = host.promptFrontTab, let opener = page.host {
            opener.tab(page, openURL: url, disposition: disposition, by: sender)
        }
    }
}

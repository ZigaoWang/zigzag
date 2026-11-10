import AppKit

/// Settings as a page in a tab, as other browsers have it: zigzag://settings, or zigzag://settings/privacy for one
/// section. The tab is an ordinary one (it sits in the sidebar, closes, splits and comes back with the session); its
/// page is only a placeholder that Zigzag's own SettingsView covers, the way the PDF viewer covers WebKit's.
@MainActor
enum SettingsPage {
    static let host = "settings"
    static let url = URL(string: "\(HistoryPage.scheme)://\(host)")!

    static func url(for pane: SettingsPane) -> URL {
        pane == .general ? url : url.appendingPathComponent(pane.path)
    }

    static func isSettings(_ url: URL?) -> Bool { url?.scheme == HistoryPage.scheme && url?.host() == host }

    static func pane(for url: URL?) -> SettingsPane {
        guard let name = url?.pathComponents.first(where: { $0 != "/" }) else { return .general }
        return SettingsPane(rawValue: name) ?? .general
    }

    /// ⌘,: the Settings tab this window already has (in this space first, then any other), or a new one; at `pane`
    /// when one is asked for. What it shows of one profile is the profile of the space it was asked for in, also
    /// when the tab it finds is in a space on another.
    static func open(_ pane: SettingsPane? = nil, in controller: BrowserWindowController) {
        // Settings belong to your everyday windows, never a private one: the frontmost normal window, or a new one.
        if controller.tabManager.isPrivate {
            let normal = NSApp.orderedWindows.lazy.compactMap { window in
                WindowManager.shared.controllers.first { $0.window === window && !$0.tabManager.isPrivate }
            }.first
            // With none open, your saved windows come back first, so a new empty one never stands in for (and saves over)
            // the session you left.
            open(pane, in: normal ?? WindowManager.shared.restoreIfNoWindows() ?? WindowManager.shared.newWindow(showCommandBar: false))
            return
        }
        let manager = controller.tabManager
        let asked = manager.profile.id
        if let existing = (manager.currentTabs + manager.allTabs).first(where: { isSettings($0.url) }) {
            // Already in front, Settings keeps the profile chosen there.
            let wasInFront = manager.selectedTab === existing
            manager.select(existing)
            if !wasInFront { existing.showSettings(of: asked) }
            if let pane { existing.showSettings(pane) }
        } else {
            controller.open(url(for: pane ?? .general), disposition: .foregroundTab, allowSwitch: false)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// What the tab's web view shows under Settings: just its name, and the page's surface so nothing flashes.
    static var html: String {
        let title = String(localized: "Settings", comment: "Title of the Settings page, also its tab's name.")
        return #"<!doctype html><meta charset="utf-8"><title>"# + title + "</title><style>" + PageStyle.css(theme: .brand) + "</style>"
    }
}

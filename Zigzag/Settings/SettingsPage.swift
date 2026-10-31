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
        return SettingsPane.allCases.first { $0.path == name } ?? .general
    }

    /// ⌘,: the Settings tab this window already has (in this space first, then any other), or a new one; at `pane`
    /// when one is asked for.
    static func open(_ pane: SettingsPane? = nil, in controller: BrowserWindowController) {
        // Settings belong to your everyday windows, never a private one: the frontmost normal window, or a new one.
        if controller.tabManager.isPrivate {
            let normal = NSApp.orderedWindows.lazy.compactMap { window in
                WindowManager.shared.controllers.first { $0.window === window && !$0.tabManager.isPrivate }
            }.first
            open(pane, in: normal ?? WindowManager.shared.newWindow(showCommandBar: false))
            return
        }
        let manager = controller.tabManager
        if let existing = (manager.currentTabs + manager.allTabs).first(where: { isSettings($0.url) }) {
            manager.select(existing)
            if let pane { existing.showSettings(pane) }
        } else {
            controller.open(url(for: pane ?? .general), disposition: .foregroundTab, allowSwitch: false)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// What the tab's web view shows under Settings: just its name, and the page's color so nothing flashes.
    static let html = """
    <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Settings</title>
    <style>html { background: #F2F2F4 } @media (prefers-color-scheme: dark) { html { background: #1E1E20 } }</style>
    """
}

import AppKit
import Foundation
import WebKit

/// Settings for showing a shift-clicked link in the page instead of a separate Mini window.
enum InPageMiniSettings {
    static let key = "InPageMini"
    static var defaults: UserDefaults = .standard

    static var isEnabled: Bool {
        get { isEnabled(in: defaults) }
        set { setEnabled(newValue, in: defaults) }
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults) {
        defaults.set(on, forKey: key)
    }
}

/// Where the in-page Mini may appear: only in the frontmost, visible browser window on the active Space.
enum InPageMiniPolicy {
    static func shouldDock(enabled: Bool, windowIsKey: Bool, windowIsVisible: Bool,
                           windowIsMiniaturized: Bool, windowIsOnActiveSpace: Bool) -> Bool {
        enabled && windowIsKey && windowIsVisible && !windowIsMiniaturized && windowIsOnActiveSpace
    }
}

/// One docked Mini per browser window. The Mini is the existing Zigzag Mini, shown over the page it came from.
@MainActor
final class InPageMiniHost {
    struct Record {
        let hostTabID: UUID
        weak var hostTab: Tab?
        let tab: Tab
        let controller: MiniWindowController
    }

    weak var browser: BrowserWindowController?
    private(set) var record: Record?

    /// Opens `url` in the page if the setting is on and this window can hold it. Returns false to fall back to the
    /// standalone Mini.
    func openURL(url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?, by sender: Tab.LoadSender) -> Bool {
        guard InPageMiniSettings.isEnabled, let browser, let window = browser.window,
              let host = opener ?? browser.tabManager.selectedTab else { return false }
        guard InPageMiniPolicy.shouldDock(enabled: true, windowIsKey: window.isKeyWindow,
                                          windowIsVisible: window.isVisible,
                                          windowIsMiniaturized: window.isMiniaturized,
                                          windowIsOnActiveSpace: window.isOnActiveSpace) else { return false }
        closeShown(animated: false)
        let controller = MiniWindowController.open(fromPage: url, configuration: configuration, opener: host,
                                                   in: browser, by: sender, dockedIn: browser)
        guard controller.isDockedInPage else { return false }
        record = Record(hostTabID: host.id, hostTab: host, tab: controller.tab, controller: controller)
        controller.onInPageMiniClosed = { [weak self] in
            if self?.record?.controller === controller { self?.record = nil }
        }
        controller.onInPageMiniDetached = { [weak self] in
            if self?.record?.controller === controller { self?.record = nil }
        }
        return true
    }

    /// Closes the docked Mini, if one is up. Returns false when there was none.
    @discardableResult
    func closeShown(animated: Bool = true) -> Bool {
        guard let record else { return false }
        self.record = nil
        record.controller.onInPageMiniClosed = nil
        record.controller.onInPageMiniDetached = nil
        if record.controller.isDockedInPage { record.controller.closeInPage(animated: animated) }
        return true
    }

    /// Esc over the docked Mini: the page keeps typed text or a dialog, otherwise the Mini closes.
    func escapePressed(_ event: NSEvent) -> Bool {
        guard let record else { return false }
        if record.controller.noteEscape(event) { return true }
        if record.controller.isDockedInPage {
            closeShown()
            return true
        }
        return false
    }

    func willSelect(_ tab: Tab?) {
        guard let record, tab?.id != record.hostTabID else { return }
        closeShown()
    }

    func tabsChanged() {
        guard let record, record.hostTab?.isClosed != false || record.tab.isClosed else { return }
        closeShown(animated: false)
    }

    func windowClosing() { closeShown(animated: false) }

    func browserLayoutChanged() {
        guard let record, let browser else { return }
        record.controller.layoutInDock(pane: browser.root.cardFrame)
    }

    /// The edge sidebar starts to slide over the page, or back: the docked Mini gets out of its way for the whole
    /// slide, rather than sitting over it while it moves.
    func sidebarSlid(show: Bool, duration: TimeInterval) {
        record?.controller.sidebarSlid(show: show, duration: duration)
    }
}

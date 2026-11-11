import AppKit

/// Which tabs an AI app is using, and the bar that says so over each one with Stop. A tab is in use from the app's
/// first tool on it until the app goes quiet for a while, its connection ends, or you press Stop. Stopped, the
/// tab stays out of reach until Zigzag quits or the setting is turned off.
@MainActor
final class AgentControl {
    static let shared = AgentControl()

    struct Use: Equatable {
        var client: MCPClient
        var last: Date
    }

    /// How long a tab counts as in use after the app last did something with it.
    static let quietAfter: TimeInterval = 5 * 60

    private(set) var inUse: [UUID: Use] = [:]
    private(set) var stopped: Set<UUID> = []
    /// Told when you press Stop: the app's connection ends.
    var onStop: ((MCPClient) -> Void)?
    private var banners: [ObjectIdentifier: ToastView] = [:]
    private var quietTimer: Timer?

    /// The app just used this tab.
    func touch(_ tab: Tab, by client: MCPClient, now: Date = Date()) {
        inUse[tab.id] = Use(client: client, last: now)
        refresh()
        scheduleQuiet()
    }

    func isStopped(_ id: UUID) -> Bool { stopped.contains(id) }

    /// Stop on the bar: the tab is let go, kept out of reach, and the app that had it is disconnected.
    func stop(_ id: UUID) {
        let client = inUse.removeValue(forKey: id)?.client
        stopped.insert(id)
        if let client {
            // Everything else that app had is let go too: it was disconnected.
            inUse = inUse.filter { $0.value.client != client }
            onStop?(client)
        }
        refresh()
    }

    /// The app's connection ended: its tabs aren't in use any more.
    func release(_ client: MCPClient) {
        let before = inUse.count
        inUse = inUse.filter { $0.value.client != client }
        if inUse.count != before { refresh() }
    }

    /// The setting was turned off: nothing is in use, and nothing stays stopped.
    func reset() {
        inUse = [:]
        stopped = []
        refresh()
    }

    /// Tabs an app hasn't touched for a while go back to being only yours.
    func forgetQuiet(now: Date = Date()) {
        let before = inUse.count
        inUse = inUse.filter { now.timeIntervalSince($0.value.last) < Self.quietAfter }
        if inUse.count != before { refresh() }
    }

    private func scheduleQuiet() {
        quietTimer?.invalidate()
        guard let next = inUse.values.map(\.last).min() else { return }
        let wait = max(1, next.addingTimeInterval(Self.quietAfter).timeIntervalSinceNow + 0.5)
        quietTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated {
                AgentControl.shared.forgetQuiet()
                AgentControl.shared.scheduleQuiet()
            }
        }
    }

    // MARK: The bar

    /// What the bar says: the app's own name, as it gave it, or a plain stand-in.
    static func line(for name: String?) -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return String(localized: "An AI app is using this tab", comment: "On the bar over a tab an AI app is using through MCP, when the app gave no name.")
        }
        let shown = name.count > 40 ? String(name.prefix(40)) + "…" : name
        return String(localized: "\(shown) is using this tab", comment: "On the bar over a tab an AI app is using through MCP. The placeholder is the app's name, as it gives it.")
    }

    /// Of the window's tabs on screen (one, or two side by side), the one an app is using.
    private func usedTab(in controller: BrowserWindowController) -> Tab? {
        guard let selected = controller.tabManager.selectedTab else { return nil }
        let shown = [selected] + [controller.tabManager.partner(of: selected)].compactMap { $0 }
        return shown.first { inUse[$0.id] != nil }
    }

    /// Its pane: the page, or its half of a split.
    private func area(of tab: Tab, in controller: BrowserWindowController) -> NSRect {
        let panes = controller.root.paneFrames
        if let right = panes.right, let pair = controller.tabManager.split(for: tab) { return pair.left == tab.id ? panes.left : right }
        return controller.root.cardFrame
    }

    /// The room the bar takes at the top of the page, so a toast sits under it rather than over it.
    func reservedHeight(in controller: BrowserWindowController) -> CGFloat {
        guard let banner = banners[ObjectIdentifier(controller)], banner.superview != nil, !banner.dismissing else { return 0 }
        return banner.frame.height + Tokens.Space.x2
    }

    func refresh() {
        let controllers = WindowManager.shared.controllers
        let live = Set(controllers.map(ObjectIdentifier.init))
        for (key, banner) in banners where !live.contains(key) {
            banner.removeFromSuperview()
            banners[key] = nil
        }
        for controller in controllers { refresh(controller) }
    }

    func refresh(_ controller: BrowserWindowController) {
        let key = ObjectIdentifier(controller)
        guard let tab = usedTab(in: controller), let use = inUse[tab.id] else {
            if let banner = banners.removeValue(forKey: key) { banner.dismiss() }
            return
        }
        let banner: ToastView
        if let existing = banners[key], existing.superview === controller.root.overlay, !existing.dismissing {
            banner = existing
        } else {
            banners[key]?.removeFromSuperview()
            banner = ToastView()
            banner.actionButton.isHidden = false
            banner.actionButton.title = String(localized: "Stop", comment: "Button on the bar over a tab an AI app is using: stops it and disconnects the app.")
            banners[key] = banner
            controller.root.overlay.addSubview(banner)
            banner.slidesFromTop = true
            place(banner, for: tab, in: controller)
            banner.present()
        }
        let tabID = tab.id
        banner.actionButton.onClick = { _ in AgentControl.shared.stop(tabID) }
        let line = Self.line(for: use.client.name)
        if banner.label.stringValue != line {
            banner.label.stringValue = line
            Announcement.post(line, priority: .medium)
        }
        banner.setAccessibilityLabel(line)
        place(banner, for: tab, in: controller)
    }

    /// Keeps the bar over its page when the page moves: the sidebar shown or hidden, a split, a resize.
    func reposition(in controller: BrowserWindowController) {
        guard let banner = banners[ObjectIdentifier(controller)], banner.superview != nil, let tab = usedTab(in: controller) else { return }
        place(banner, for: tab, in: controller)
    }

    private func place(_ banner: ToastView, for tab: Tab, in controller: BrowserWindowController) {
        let area = area(of: tab, in: controller)
        let size = banner.size(maxWidth: max(160, area.width - Tokens.Space.x12))
        banner.frame = NSRect(x: round(area.midX - size.width / 2), y: area.minY + Tokens.Space.x3, width: size.width, height: size.height)
        banner.needsLayout = true
    }

    #if DEBUG
    var debugBannerLines: [String] { banners.values.filter { $0.superview != nil && !$0.dismissing }.map(\.label.stringValue) }
    #endif
}

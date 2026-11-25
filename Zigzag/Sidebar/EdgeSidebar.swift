import AppKit

/// What the page pill shows for a row: the running page itself, or the card that stands in while it isn't running.
enum EdgePreviewKind: Equatable {
    case live
    case card
}

/// What the edge panel can take from a row. Zigzag's own pages (Settings, History) belong to the window: the panel
/// does not preview them, and a click opens them there as it always has.
enum EdgeLensPolicy {
    static func takesPage(url: URL?) -> Bool { !HistoryPage.isInternal(url) }
    /// A running page is lent to the preview. One that is not — asleep, or not loaded since Zigzag reopened — shows
    /// the card instead: resting on its row must not wake it. Only a click does.
    static func previewKind(isLoaded: Bool, isAsleep: Bool) -> EdgePreviewKind {
        isLoaded && !isAsleep ? .live : .card
    }
}

/// Where a space switch takes the page already beside the list: the new space's selected tab, folded from the side
/// its list slid in on.
enum EdgePreviewRouting {
    static func keepsPreviewOnSpaceChange(previewOpen: Bool) -> Bool { previewOpen }

    /// 1 for a space later in the list (its list slides in from the right), -1 for one before it, 0 when the order
    /// can't say (the same space, or one not listed).
    static func spaceSlide(from before: UUID?, to after: UUID?, order: [UUID]) -> Int {
        guard let before, let after, before != after,
              let from = order.firstIndex(of: before), let to = order.firstIndex(of: after) else { return 0 }
        return to > from ? 1 : -1
    }
}

/// Where and when the screen's edge brings the sidebar out over other apps (#363).
enum EdgeSidebarLayout {
    /// How close to the screen's side the pointer has to be: pushed against it.
    static let edgeWidth: CGFloat = 2
    /// Kept clear at the screen's top and bottom corners, which are the system's hot corners.
    static let cornerReserve: CGFloat = Tokens.Space.x6
    /// How long the pointer rests against the edge before the panel comes out.
    static let dwell: TimeInterval = 0.25
    /// How long the pointer can be off the panel before it goes back.
    static let leaveDelay: TimeInterval = 0.15
    /// Room beside the card for a menu from it and its submenu.
    static let menuRoom: CGFloat = 480

    /// The panel: the visible frame's height, `width` wide against the screen's edge, never wider than the screen.
    static func frame(in visible: NSRect, width: CGFloat, onRight: Bool) -> NSRect {
        let width = min(max(width, 0), visible.width)
        return NSRect(x: onRight ? visible.maxX - width : visible.minX, y: visible.minY, width: width, height: visible.height)
    }

    /// The page's share of the screen when the preview is beside the sidebar: a portrait third.
    static let pageShare: CGFloat = 1.0 / 3.0
    static func pageWidth(in visible: NSRect) -> CGFloat { floor(visible.width * pageShare) }

    /// The panel's width: the sidebar and its gutter, and the page's third and its gutters when one is open.
    static func width(sidebar: CGFloat, page: Bool, inset: CGFloat, in visible: NSRect) -> CGFloat {
        sidebar + inset + (page ? pageWidth(in: visible) + inset * 2 : 0)
    }

    /// The sidebar card inside the panel. With the page open it keeps its own width at the screen's edge; without it,
    /// it is the panel's whole inner width.
    static func cardFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, page: Bool, onRight: Bool) -> NSRect {
        let width = page ? sidebar : max(0, bounds.width - inset)
        return NSRect(x: onRight ? bounds.width - inset - width : inset, y: inset,
                      width: width, height: max(0, bounds.height - inset * 2))
    }

    /// The page's place inside the panel: beside the card, the same inset away from the card and the panel's inner
    /// edge, and the card's height.
    static func pageFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, page: Bool, onRight: Bool) -> NSRect {
        guard page else { return .zero }
        let card = cardFrame(in: bounds, sidebar: sidebar, inset: inset, page: true, onRight: onRight)
        let x = onRight ? inset : card.maxX + inset
        let width = onRight ? card.minX - 2 * inset : bounds.width - card.maxX - 2 * inset
        return NSRect(x: x, y: inset, width: max(0, width), height: max(0, bounds.height - inset * 2))
    }

    /// Against the screen's outer side edge, clear of the menu bar, a bottom Dock, the corners and other displays.
    static func opens(at point: NSPoint, screen: NSRect, visible: NSRect, onRight: Bool, screens: [NSRect]) -> Bool {
        let atEdge = onRight ? point.x >= screen.maxX - edgeWidth : point.x < screen.minX + edgeWidth
        let low = max(visible.minY, screen.minY + cornerReserve)
        let high = min(visible.maxY, screen.maxY - cornerReserve)
        guard atEdge, point.y >= low, point.y <= high else { return false }
        let beyond = NSPoint(x: onRight ? screen.maxX + 1 : screen.minX - 1, y: point.y)
        return !screens.contains { $0 != screen && $0.contains(beyond) }
    }

    /// The pointer is on the panel or just around it.
    static func keeps(at point: NSPoint, panel: NSRect) -> Bool {
        panel.insetBy(dx: -Tokens.Space.x2, dy: -Tokens.Space.x2).contains(point)
    }

    /// The Dock and Stage Manager's strip own their side of the screen: the edge never opens there.
    static func sideIsFree(onRight: Bool, dockSide: String, stageManager: Bool) -> Bool {
        let side = onRight ? "right" : "left"
        if dockSide == side { return false }
        // Stage Manager's strip is on the left, or on the right when the Dock is on the left.
        return !(stageManager && (dockSide == "left" ? "right" : "left") == side)
    }

    /// Only while another app is in front, with no mouse button down.
    static func canShow(appIsActive: Bool, buttonsPressed: Bool) -> Bool {
        !appIsActive && !buttonsPressed
    }
}

/// The edge preview rests like the page-in-panel preview did: long enough that crossing rows previews nothing, short
/// enough that stopping on one still feels immediate. A pointer that moves within the row starts the wait again.
enum EdgePreviewHoverPolicy {
    static let dwell: TimeInterval = 0.2
    static let check: TimeInterval = 0.05
    static let movement: CGFloat = 2

    static func rests(now: TimeInterval, since: TimeInterval, moved: Bool) -> Bool {
        !moved && now - since >= dwell
    }
}

/// The sidebar at the screen's edge (#363): the last browser window's sidebar, over other apps.
@MainActor
final class EdgeSidebar {
    static let shared = EdgeSidebar()

    static let defaultsKey = "EdgeSidebar"

    /// Off until turned on in Settings › Appearance.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The last non-private browser window that was in front: its sidebar is the one that comes out.
    private weak var target: BrowserWindowController?
    private var panel: EdgeSidebarPanel?
    private var host: EdgeSidebarHost?
    private(set) var isShowing = false
    private var shownOnRight = false
    /// The visible frame the panel is on, and the panel's frame without a menu's room.
    private var shownVisible: NSRect = .zero
    private var cardPanelFrame: NSRect = .zero
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dwellTimer: Timer?
    private var followTimer: Timer?
    /// When the pointer left the panel, while it's on its way back.
    private var leftAt: TimeInterval?
    /// Counts shows, so a slide back only orders out the panel it hid.
    private var generation = 0
    /// The page shown beside the sidebar while a row is rested on: the same docked Mini as the in-page peek.
    private var preview: MiniWindowController?
    private var previewTab: Tab?
    /// A row's page that isn't running: a plain card stands in the page pill, so a hover answers without waking
    /// it. Only a click on the row loads the page.
    private var sleepingTab: Tab?
    /// The tab picked in the panel: its page fills the page's room, and leaving another row's hover comes back to it.
    /// Weak, so a tab closed elsewhere cannot be kept alive by the panel; `show` and `hide` clear it too.
    private weak var activeTab: Tab?
    /// A clicked tab that still has to load: its card is out until the page arrives.
    private var activeLoadToken: SignalToken?
    private var previewWork: DispatchWorkItem?
    /// Counts hovers, so a rest check left over from the previous row cannot preview it.
    private var hoverCheck = 0
    private var closeWork: DispatchWorkItem?
    /// Listens to the window's list while the panel is out: a page closed or left under it puts the preview away
    /// rather than showing a page with no row to come from.
    private var managerToken: SignalToken?
    /// The panel's wide frame: the sidebar's own width plus the page's third.
    private var previewPanelFrame: NSRect = .zero
    /// The space the panel last showed: a switch moves the page in from the side the list came from.
    private var lastSpaceID: UUID?
    /// When the page's last move lands. A space switch waits for it, so two folds never run over each other.
    private var previewMoveUntil: TimeInterval = 0

    private init() {}

    // MARK: The switch

    /// Turns the edge on or off; off, nothing watches the pointer and the mirror goes.
    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        on ? start() : stop()
    }

    /// At launch: listens only if the switch is on.
    func startIfOn() {
        if Self.isOn { start() }
    }

    private func start() {
        guard monitor == nil else { return }
        // Mouse moves need no permission; key events would.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        // Zigzag came forward on its own, or another app did: the panel has done its job. Clicking into the preview
        // is the preview working, so that keeps the panel.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideUnlessPreviewIsKey() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideUnlessPreviewIsKey() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        if let key = WindowManager.shared.keyController, !key.tabManager.isPrivate { target = key }
    }

    /// Zigzag came forward. A click into the preview brings it forward too, and that is the preview working; any
    /// other way back to the app is the panel's errand done. Another app coming forward (⌘Tab) always puts the panel
    /// away, even while the pointer rests on the preview.
    private func hideUnlessPreviewIsKey() {
        guard NSApp.isActive else {
            hide(animated: false)
            return
        }
        if let window = preview?.window {
            if window.isKeyWindow { return }
            if window.frame.contains(NSEvent.mouseLocation) { return }
        }
        hide(animated: false)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        cancelDwell()
        hide(animated: false)
        target?.discardEdgeSidebar()
        target = nil
    }

    /// The last browser window to become key; a private window's sidebar never comes out at the edge.
    func noteFocused(_ controller: BrowserWindowController) {
        guard monitor != nil, !controller.tabManager.isPrivate, target !== controller else { return }
        hide(animated: false)
        target?.discardEdgeSidebar()
        target = controller
    }

    func windowClosed(_ controller: BrowserWindowController) {
        guard target === controller else { return }
        hide(animated: false)
        target = nil
    }

    /// The panel's window, so a menu in it can tell where it is.
    func isPanel(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    // MARK: The pointer

    private func moved() {
        guard !isShowing, !NSApp.isActive else { return }
        if target == nil, let key = WindowManager.shared.keyController, !key.tabManager.isPrivate { target = key }
        guard let target, atEdge(target: target) else { return cancelDwell() }
        guard dwellTimer == nil else { return }
        let timer = Timer(timeInterval: EdgeSidebarLayout.dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dwelled() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    /// The pointer against the edge now, on a side no part of macOS uses.
    private func atEdge(target: BrowserWindowController) -> Bool {
        let point = NSEvent.mouseLocation
        let onRight = target.edgeSidebarOnRight
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              EdgeSidebarLayout.opens(at: point, screen: screen.frame, visible: screen.visibleFrame, onRight: onRight,
                                      screens: NSScreen.screens.map(\.frame)) else { return false }
        // Read only at the edge: the Dock's side and Stage Manager change rarely.
        let dock = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        let stage = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
        return EdgeSidebarLayout.sideIsFree(onRight: onRight, dockSide: dock, stageManager: stage)
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    private func dwelled() {
        dwellTimer = nil
        guard !isShowing, let target, atEdge(target: target),
              EdgeSidebarLayout.canShow(appIsActive: NSApp.isActive, buttonsPressed: NSEvent.pressedMouseButtons != 0),
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
        else { return }
        show(on: screen.visibleFrame, for: target)
    }

    private func follow() {
        guard isShowing, let panel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A pressed button, a menu from the panel or a sheet keeps it out.
        let held = NSEvent.pressedMouseButtons != 0 || MenuPanel.current != nil
            || RunLoop.current.currentMode == .eventTracking || NSApp.modalWindow != nil
        // The menu's room goes with the menu; the wide frame while a page or its card is beside the sidebar stays.
        let intended = preview == nil && sleepingTab == nil ? cardPanelFrame : previewPanelFrame
        if MenuPanel.current == nil, panel.frame != intended { panel.setFrame(intended, display: true) }
        let keeps = EdgeSidebarLayout.keeps(at: NSEvent.mouseLocation, panel: intended)
        if held || keeps {
            leftAt = nil
        } else if let leftAt {
            if now - leftAt > EdgeSidebarLayout.leaveDelay { hide() }
        } else {
            leftAt = now
        }
        // The panel is over another app and has no key window to bring mouse moves in, so the strip follows the
        // pointer from here.
        if preview != nil { preview?.pointerMoved(toScreen: NSEvent.mouseLocation) }
        restoreActiveIfNeeded()
    }

    // MARK: The preview

    /// A row rested on in the panel: its page comes in beside the sidebar after the same pause the window's row
    /// previews use. Leaving the rows closes it unless the pointer has moved onto the page or the panel.
    func hover(_ tab: Tab?, in controller: BrowserWindowController) {
        guard isShowing, target === controller else {
            previewWork?.cancel()
            previewWork = nil
            closePreview(animated: false)
            return
        }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        hoverCheck += 1
        guard let tab else {
            // Off the rows: a picked page is the one to come back to; otherwise the hover is only a glance. While the
            // pointer rests on the hovered page itself, that page stays until it leaves.
            if let activeTab, !pointerIsOverPreview() {
                showActive(activeTab, in: controller)
            } else if activeTab == nil {
                schedulePreviewClose()
            }
            return
        }
        guard tab !== previewTab, tab !== sleepingTab, let url = tab.url, !tab.isPrivate,
              EdgeLensPolicy.takesPage(url: url),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            schedulePreviewClose()
            return
        }
        scheduleHoverCheck(tab: tab, in: controller, pointer: NSEvent.mouseLocation,
                           stillSince: ProcessInfo.processInfo.systemUptime, token: hoverCheck)
    }

    /// A row clicked in the panel: the browser's tab is selected there, but Zigzag doesn't come forward and the
    /// panel stays out. The page fills the page's room, and it is the page a later hover comes back to.
    func markActive(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, target === controller, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url) else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        hoverCheck += 1
        activeTab = tab
        showActive(tab, in: controller)
    }

    /// Esc in the panel closes the page first, as #365 did, leaving the sidebar where it is.
    @discardableResult
    func dismissPreview() -> Bool {
        activeTab = nil
        activeLoadToken?.cancel()
        activeLoadToken = nil
        if sleepingTab != nil {
            closeSleeping(animated: true)
            return true
        }
        guard preview != nil else { return false }
        closePreview()
        return true
    }

    /// Follows the pointer while it rests on a row: a crossing pointer never previews, a stopped one does after the
    /// same short beat the old page-in-panel preview used.
    private func scheduleHoverCheck(tab: Tab, in controller: BrowserWindowController, pointer: NSPoint,
                                    stillSince: TimeInterval, token: Int) {
        let work = DispatchWorkItem { [weak self, weak tab, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let tab, let controller, self.isShowing, self.target === controller,
                      self.hoverCheck == token else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let point = NSEvent.mouseLocation
                let moved = abs(point.x - pointer.x) > EdgePreviewHoverPolicy.movement
                    || abs(point.y - pointer.y) > EdgePreviewHoverPolicy.movement
                if EdgePreviewHoverPolicy.rests(now: now, since: stillSince, moved: moved) {
                    self.previewWork = nil
                    switch EdgeLensPolicy.previewKind(isLoaded: tab.isLoaded, isAsleep: tab.isAsleep) {
                    case .live: self.showPreview(tab, in: controller)
                    case .card: self.showSleepingPreview(tab, in: controller)
                    }
                } else {
                    self.scheduleHoverCheck(tab: tab, in: controller, pointer: point,
                                            stillSince: moved ? now : stillSince, token: token)
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgePreviewHoverPolicy.check, execute: work)
    }

    /// The page is the same docked Mini as the in-page peek: its own floor-to-ceiling pill beside the sidebar.
    private func showPreview(_ tab: Tab, in controller: BrowserWindowController, foldFromRight: Bool? = nil) {
        guard isShowing, let panel, let host, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url) else { return }
        // A page that isn't running shows the card: a hover never wakes a tab on its own.
        guard EdgeLensPolicy.previewKind(isLoaded: tab.isLoaded, isAsleep: tab.isAsleep) == .live else {
            showSleepingPreview(tab, in: controller, foldFromRight: foldFromRight)
            return
        }
        // A page in the same space takes the Mini already out: the window, its size and its place stay, and only
        // the borrowed page changes. Opening a new Mini here made a tile group's parts jitter as each came in.
        if let preview, preview.tab !== tab, preview.loadPreview(tab, fromRight: foldFromRight) {
            if sleepingTab != nil {
                sleepingTab = nil
                host.sleepingShowing = false
            }
            previewTab = tab
            host.pageShowing = true
            host.placeCard()
            notePreviewMove()
            return
        }
        // The page already out stays under the next one until its fold has covered it. Giving it back first made
        // the next fold start over an empty Mini.
        let previous = preview
        guard previous?.tab !== tab else { return }
        // The panel takes its full width at once, before the page is opened: the page is laid out at its final size
        // and the fold is the only thing moving, so its content never reflows through a widening animation.
        if sleepingTab != nil {
            sleepingTab = nil
            host.sleepingShowing = false
        }
        let sidebar = controller.edgeSidebarWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.cardWidth = sidebar
        host.pageShowing = true
        panel.setFrame(previewPanelFrame, display: true)
        host.placeCard()
        host.layoutSubtreeIfNeeded()
        guard let mini = MiniWindowController.openPreview(of: tab, from: controller, dockedIn: self, reveal: false) else {
            if previous == nil, sleepingTab == nil { narrowPanel() }
            return
        }
        mini.onInPageMiniClosed = { [weak self, weak mini] in self?.previewClosed(mini) }
        mini.onInPageMiniDetached = { [weak self, weak mini] in self?.previewDetached(mini) }
        preview = mini
        previewTab = tab
        mini.layoutInDock(force: true)
        // The page is at its final place already; the fold uncovers it as the panel edge reaches it, or over the page
        // it replaces.
        mini.revealDockedPage(fromRight: foldFromRight ?? shownOnRight)
        notePreviewMove()
        if let previous {
            // Off the bookkeeping first: the old Mini is closing under the new one, not taking the panel with it.
            previous.onInPageMiniClosed = nil
            previous.onInPageMiniDetached = nil
            let duration = Tokens.Motion.reduceMotion ? 0 : Tokens.Motion.Role.drawer.duration(entering: true) + 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                MainActor.assumeIsolated { previous.closeInPage(focusBack: false, animated: false) }
            }
        }
    }

    /// A row whose page isn't running: the card stands in the page pill, with the moon, the reason and the way to
    /// wake it. Nothing here touches the tab's page, so resting on its row never wakes it.
    private func showSleepingPreview(_ tab: Tab, in controller: BrowserWindowController, foldFromRight: Bool? = nil) {
        guard isShowing, let panel, let host, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url) else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        guard sleepingTab !== tab else { return }
        // A page or card already out has the room; the panel is set to its full width before the card is placed, so
        // the card is laid out once and never stretches with a widening animation.
        if let mini = preview {
            preview = nil
            previewTab = nil
            mini.onInPageMiniClosed = nil
            mini.onInPageMiniDetached = nil
            mini.closeInPage(focusBack: false, animated: false)
        }
        sleepingTab = tab
        let sidebar = controller.edgeSidebarWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.cardWidth = sidebar
        host.pageShowing = true
        host.sleeping.show(tab: tab)
        host.sleepingShowing = true
        panel.setFrame(previewPanelFrame, display: true)
        host.placeCard()
        host.layoutSubtreeIfNeeded()
        if let foldFromRight {
            let offset = (foldFromRight ? 1 : -1) * host.pageFrame.width
            Tokens.Motion.slide(host.sleeping, fromOffsetX: offset, curve: Tokens.Motion.edgeSlide)
            notePreviewMove()
        }
    }

    /// The picked page comes back in the page's full room, from a hover or another row.
    private func showActive(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, target === controller, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url) else { return }
        activeLoadToken?.cancel()
        activeLoadToken = nil
        guard previewTab !== tab else { return }
        if sleepingTab === tab {
            // The click already woke its page: the card gives way to the live page.
            if tab.isLoaded {
                sleepingTab = nil
                host?.sleepingShowing = false
                showPreview(tab, in: controller)
            }
            return
        }
        switch EdgeLensPolicy.previewKind(isLoaded: tab.isLoaded, isAsleep: tab.isAsleep) {
        case .live:
            showPreview(tab, in: controller)
        case .card:
            showSleepingPreview(tab, in: controller)
            // The click woke it: its page replaces the card when it arrives.
            watchActiveLoad(tab, in: controller)
        }
    }

    /// A picked tab whose page is still loading shows its card until the page is there, then the live page.
    private func watchActiveLoad(_ tab: Tab, in controller: BrowserWindowController) {
        guard !tab.isLoaded else { return }
        activeLoadToken = tab.changed.observe { [weak self, weak tab, weak controller] change in
            MainActor.assumeIsolated {
                guard let self, let tab, let controller, change == .webView,
                      self.activeTab === tab, self.isShowing, self.target === controller else { return }
                self.showActive(tab, in: controller)
            }
        }
    }

    /// Whether the pointer is on the page or card itself, rather than the rows or the panel around it.
    private func pointerIsOverPreview() -> Bool {
        let mouse = NSEvent.mouseLocation
        if preview?.window?.frame.contains(mouse) == true { return true }
        guard let panel, let host, panel.frame.contains(mouse) else { return false }
        let inHost = host.convert(panel.convertPoint(fromScreen: mouse), from: nil)
        return host.pageFrame.contains(inHost)
    }

    /// Off the rows and off a hovered page, the picked page comes back. The pointer over the panel's blank page area
    /// has no row to report a hover change, so the follow timer checks for it.
    private func restoreActiveIfNeeded() {
        guard isShowing, let panel, let host, let target, let activeTab else { return }
        guard previewTab !== activeTab, sleepingTab !== activeTab else { return }
        guard panel.frame.contains(NSEvent.mouseLocation) else { return }
        guard !pointerIsOverPreview() else { return }
        let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard !host.cardFrame.contains(host.convert(inWindow, from: nil)) else { return }
        guard EdgeLensPolicy.takesPage(url: activeTab.url), !activeTab.isPrivate else { return }
        showActive(activeTab, in: target)
    }

    /// The card has gone: the panel narrows unless a live page is taking the area.
    private func closeSleeping(animated: Bool = false) {
        guard let sleeping = sleepingTab else { return }
        if activeTab === sleeping {
            activeTab = nil
            activeLoadToken?.cancel()
            activeLoadToken = nil
        }
        sleepingTab = nil
        host?.sleepingShowing = false
        if preview == nil { narrowPanel(animated: animated) }
    }

    private func schedulePreviewClose() {
        closeWork?.cancel()
        closeWork = nil
        guard preview != nil || sleepingTab != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if let frame = self.preview?.window?.frame, frame.contains(mouse) { return }
            if self.isShowing, let frame = self.panel?.frame, frame.contains(mouse) { return }
            self.closeSleeping()
            self.closePreview()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Puts the page away and brings the panel back to the sidebar's own width. The panel stays out. `animated`: the
    /// page slides back behind the sidebar first, and `previewClosed` narrows the panel after it; a panel that is
    /// going away itself closes the page at once.
    private func closePreview(animated: Bool = true) {
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        guard let mini = preview else { return }
        // Already on its way out: the first close brings the panel back.
        if mini.isLeavingDock { return }
        activeTab = nil
        activeLoadToken?.cancel()
        activeLoadToken = nil
        preview = nil
        previewTab = nil
        if animated {
            // The page folds out while the panel is still its full width; only once it has gone does the panel
            // narrow, so the page is never resized through the close.
            notePreviewMove()
            mini.closeInPage(focusBack: false, animated: true)
        } else {
            mini.onInPageMiniClosed = nil
            mini.onInPageMiniDetached = nil
            mini.closeInPage(focusBack: false, animated: false)
            narrowPanel()
        }
    }

    /// The Mini closed itself (Esc, its close button, or Open in Zigzag): the sidebar is alone again, and goes when
    /// the page went to Zigzag rather than just closing. A page that closed after another preview took the panel
    /// leaves the new one alone.
    private func previewClosed(_ closing: MiniWindowController?) {
        if let closing, let preview, preview !== closing { return }
        let moved = preview?.pageMovedOut == true
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        preview = nil
        previewTab = nil
        activeTab = nil
        activeLoadToken?.cancel()
        activeLoadToken = nil
        // A close that began with closePreview narrowed the panel with the page's fold; don't snap it again.
        if panel?.frame != cardPanelFrame { narrowPanel(animated: true) }
        if moved {
            hide(animated: false)
        } else {
            panel?.makeKey()
        }
    }

    /// Expand took the page out into a window of its own: the panel has done its job and goes. A page that left after
    /// another preview took the panel leaves the new one alone.
    private func previewDetached(_ closing: MiniWindowController?) {
        if let closing, let preview, preview !== closing { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        preview = nil
        previewTab = nil
        activeTab = nil
        activeLoadToken?.cancel()
        activeLoadToken = nil
        narrowPanel()
        hide(animated: false)
    }

    private func narrowPanel(animated: Bool = false) {
        previewPanelFrame = .zero
        guard isShowing, let host, let panel else { return }
        host.pageShowing = false
        host.sleepingShowing = false
        if let target { host.cardWidth = target.edgeSidebarWidth }
        host.placeCard()
        guard animated, !Tokens.Motion.reduceMotion else {
            panel.setFrame(cardPanelFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.Role.drawer.duration(entering: false)
            context.timingFunction = Tokens.Motion.Role.drawer.timing
            panel.animator().setFrame(cardPanelFrame, display: true)
        }
    }

    /// Widens the panel to the page's room in place: the page already sits at its final frame, so the panel's edge
    /// moving out uncovers it rather than the page sliding over the sidebar.
    /// The panel shows the window's list, so a change to that list is a change to the panel. A space switch puts the
    /// hover preview away, as the row it came from is no longer the one under the pointer; a page closed under it
    /// puts the preview away too.
    private func installManagerObserver(for controller: BrowserWindowController) {
        managerToken?.cancel()
        managerToken = controller.tabManager.changed.observe { [weak self, weak controller] change in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.managerChanged(change, in: controller)
            }
        }
    }

    private func managerChanged(_ change: TabManager.Change, in controller: BrowserWindowController) {
        guard isShowing, target === controller else { return }
        if case .space = change {
            let before = lastSpaceID
            let after = controller.tabManager.currentSpaceID
            lastSpaceID = after
            // Only a page or card already beside the list follows the switch. Its tab is prepared later in
            // `switchToSpace`, so wait a turn: the new space's selected page is then ready to lend.
            let hadPreview = preview != nil || sleepingTab != nil
            guard hadPreview, EdgePreviewRouting.keepsPreviewOnSpaceChange(previewOpen: hadPreview) else { return }
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, self.isShowing, self.target === controller,
                      controller.tabManager.currentSpaceID == after else { return }
                self.followSpace(from: before, to: after, in: controller)
            }
            return
        }
        guard preview != nil || sleepingTab != nil || activeTab != nil else { return }
        switch change {
        case .space:
            break
        case .structure:
            if previewTab?.isClosed == true { closePreview() }
            if sleepingTab?.isClosed == true { closeSleeping() }
            if activeTab?.isClosed == true {
                activeTab = nil
                activeLoadToken?.cancel()
                activeLoadToken = nil
            }
        case .selection:
            // The picked page is no longer the window's: the old lens put itself away a turn later, so a page chosen
            // for the panel or opened from it has the pass it needs to arrive first.
            if let activeTab, let selected = controller.tabManager.selectedTab, selected !== activeTab {
                self.activeTab = nil
                activeLoadToken?.cancel()
                activeLoadToken = nil
            }
            guard let shown = previewTab, let selected = controller.tabManager.selectedTab,
                  selected !== shown else { return }
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, self.isShowing, self.target === controller,
                      let shown = self.previewTab, let selected = controller.tabManager.selectedTab,
                      selected !== shown else { return }
                self.closePreview()
            }
        case .content:
            break
        }
    }

    private var isPreviewMoving: Bool { ProcessInfo.processInfo.systemUptime < previewMoveUntil }

    /// A page move started: the panel's widen or the page's fold. The next space switch waits out the same beat.
    private func notePreviewMove() {
        let settle = max(Tokens.Motion.Role.drawer.duration(entering: true), Tokens.Motion.spaceSwitch.duration)
        previewMoveUntil = ProcessInfo.processInfo.systemUptime + settle + 0.02
    }

    /// A space was picked in the panel while a page or card was out: the new space's selected tab takes its place,
    /// folding from the side the list came from, as the old lens did.
    private func followSpace(from before: UUID?, to after: UUID, in controller: BrowserWindowController) {
        // The list and the page move together; starting the next pick's fold before this one lands makes the two
        // fight. Wait for the page it is replacing to finish, then take the new space.
        guard !isPreviewMoving else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak controller] in
                guard let self, let controller, self.isShowing, self.target === controller,
                      controller.tabManager.currentSpaceID == after else { return }
                self.followSpace(from: before, to: after, in: controller)
            }
            return
        }
        let slide = EdgePreviewRouting.spaceSlide(from: before, to: after, order: controller.tabManager.listedSpaces.map(\.id))
        let fold: Bool? = slide == 0 ? nil : slide > 0
        guard let shown = controller.tabManager.selectedTab, !shown.isPrivate,
              EdgeLensPolicy.takesPage(url: shown.url) else {
            activeTab = nil
            activeLoadToken?.cancel()
            activeLoadToken = nil
            closeSleeping()
            closePreview(animated: false)
            return
        }
        activeTab = shown
        activeLoadToken?.cancel()
        activeLoadToken = nil
        switch EdgeLensPolicy.previewKind(isLoaded: shown.isLoaded, isAsleep: shown.isAsleep) {
        case .live:
            showPreview(shown, in: controller, foldFromRight: fold)
        case .card:
            showSleepingPreview(shown, in: controller, foldFromRight: fold)
            // The switch is already preparing the page; it replaces the card when it arrives.
            watchActiveLoad(shown, in: controller)
        }
    }

    // MARK: The panel

    private func show(on visible: NSRect, for target: BrowserWindowController) {
        let container = target.prepareEdgeSidebar()
        let onRight = target.edgeSidebarOnRight
        let panel = panel ?? makePanel()
        guard let host else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        preview = nil
        previewTab = nil
        sleepingTab = nil
        activeTab = nil
        activeLoadToken?.cancel()
        activeLoadToken = nil
        host.pageShowing = false
        host.sleepingShowing = false
        installManagerObserver(for: target)
        host.onRight = onRight
        host.cardWidth = target.edgeSidebarWidth
        lastSpaceID = target.tabManager.currentSpaceID
        previewMoveUntil = 0
        host.set(container)
        generation += 1
        cardPanelFrame = EdgeSidebarLayout.frame(in: visible, width: host.cardWidth + host.inset, onRight: onRight)
        shownVisible = visible
        panel.setFrame(cardPanelFrame, display: true)
        host.placeCard()
        isShowing = true
        shownOnRight = onRight
        leftAt = nil
        // The keyboard stays with the app in front until the panel is clicked.
        panel.orderFrontRegardless()
        let card = host.cardFrame
        Tokens.Motion.withoutAnimation { container.frame = card }
        Tokens.Motion.slide(container, fromOffsetX: (onRight ? 1 : -1) * (card.width + host.inset), curve: Tokens.Motion.edgeSlide)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    /// Puts the panel away; without the slide when Zigzag is coming forward.
    func hide(animated: Bool = true) {
        followTimer?.invalidate()
        followTimer = nil
        managerToken?.cancel()
        managerToken = nil
        lastSpaceID = nil
        previewMoveUntil = 0
        activeTab = nil
        activeLoadToken?.cancel()
        activeLoadToken = nil
        guard isShowing, let panel else { return }
        if sleepingTab != nil { closeSleeping(animated: animated) }
        if preview != nil { closePreview(animated: false) }
        isShowing = false
        generation += 1
        if MenuPanel.current?.window === panel { MenuPanel.current?.close(animated: false) }
        guard animated, let host, let container = host.container else { panel.orderOut(nil); return }
        let card = host.cardFrame
        let out = card.offsetBy(dx: (shownOnRight ? 1 : -1) * (card.width + host.inset), dy: 0)
        Tokens.Motion.withoutAnimation { container.frame = out }
        let duration = Tokens.Motion.slide(container, fromOffsetX: card.minX - out.minX, curve: Tokens.Motion.edgeTuck)
        guard duration > 0 else { panel.orderOut(nil); return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// A menu is opening in the panel: it widens on the inner side, the card staying put, so the menu isn't cut off.
    func makeRoomForMenu() {
        guard isShowing, let panel else { return }
        if sleepingTab != nil { closeSleeping(animated: false) }
        if preview != nil { closePreview(animated: false) }
        let width = cardPanelFrame.width + EdgeSidebarLayout.menuRoom
        panel.setFrame(EdgeSidebarLayout.frame(in: shownVisible, width: width, onRight: shownOnRight), display: true)
    }

    /// ⌘T with the panel clicked into: a new tab in the window, which comes forward.
    func newTab() { target?.newTabFromEdge() }

    /// A menu item picked in the panel: the window comes forward with its sidebar out, where the item acts.
    func chose() {
        guard let target else { return }
        target.bringForwardForEdge()
        target.revealSidebarForEdge()
    }

    /// A sideways scroll over the panel's sidebar changes space, as in the window.
    private func intercept(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, isShowing, let host, let container = host.container else { return false }
        let point = host.convert(event.locationInWindow, from: nil)
        guard host.cardFrame.contains(point), host.hitTest(point)?.isDescendant(of: container) == true else { return false }
        return container.sidebar.handleSwipe(event)
    }

    private func makePanel() -> EdgeSidebarPanel {
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Over other apps and full-screen apps, on every Space, out of Stage Manager and ⌘`.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // ⌘H hides Zigzag's windows, not the way back to them.
        panel.canHide = false
        panel.eventInterceptor = { [weak self] event in self?.intercept(event) ?? false }
        let host = EdgeSidebarHost()
        panel.contentView = host
        self.host = host
        self.panel = panel
        return panel
    }
}

/// The edge sidebar's panel: over another app without taking the front or the keyboard; a click in it takes the keyboard.
final class EdgeSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var eventInterceptor: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow, event.type == .leftMouseDown || event.type == .rightMouseDown { makeKey() }
        if eventInterceptor?(event) == true { return }
        // Esc puts the page away first, then the panel, unless a field is being edited.
        if event.type == .keyDown, event.keyCode == 53, !(firstResponder is NSTextView), MenuPanel.current == nil {
            if EdgeSidebar.shared.dismissPreview() { return }
            EdgeSidebar.shared.hide()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
            EdgeSidebar.shared.newTab()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The panel's content: the floating sidebar card, set off the screen's edge as it is from a window's.
final class EdgeSidebarHost: NSView {
    private(set) weak var container: SidebarContainer?
    let inset = Tokens.Metric.cardInset
    var onRight = false { didSet { placeCard() } }
    var cardWidth: CGFloat = 0 { didSet { placeCard() } }
    /// The preview's page sits beside the sidebar as its own floor-to-ceiling pill; the sidebar keeps its width and
    /// place, and the panel's background stays clear between them.
    var pageShowing = false { didSet { placeCard() } }
    /// A row whose page isn't running, in the page pill's place: the plain card and why it is asleep.
    let sleeping = EdgeAsleepPageView()
    var sleepingShowing = false { didSet { placeCard() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sleeping.isHidden = true
        addSubview(sleeping)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Against the screen's edge, whatever room beside it a menu has.
    var cardFrame: NSRect {
        EdgeSidebarLayout.cardFrame(in: bounds, sidebar: cardWidth, inset: inset, page: pageShowing, onRight: onRight)
    }

    /// Beside the card: the page's own pill, the same inset from the card and the panel's inner edge.
    var pageFrame: NSRect {
        EdgeSidebarLayout.pageFrame(in: bounds, sidebar: cardWidth, inset: inset, page: pageShowing, onRight: onRight)
    }

    func set(_ container: SidebarContainer) {
        if self.container !== container {
            self.container?.removeFromSuperview()
            self.container = container
            container.autoresizingMask = []
        }
        if container.superview !== self { addSubview(container) }
        placeCard()
    }

    func placeCard() {
        // The sidebar is its own card, not a surface widened behind the page: the page is a separate pill.
        container?.frame = cardFrame
        sleeping.frame = pageFrame
        sleeping.isHidden = !sleepingShowing
    }

    override func layout() {
        super.layout()
        placeCard()
    }

    /// A click beside the cards puts the panel away; while the page pill is out, the gutter between it and the
    /// sidebar is part of the panel, not a dismissal.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if container?.frame.contains(point) != true, !pageFrame.contains(point) {
            if pageShowing { return }
            EdgeSidebar.shared.hide()
            return
        }
        super.mouseDown(with: event)
    }
}

extension EdgeSidebar: MiniDockHosting {
    var dockParentWindow: NSWindow? { panel }
    var dockPageView: NSView { host ?? panel?.contentView ?? NSView() }
    var dockPageFrame: NSRect { host?.pageFrame ?? .zero }
    /// The preview is the page pill itself: floor to ceiling, the old page card's large corners, ground and shadow.
    func dockCardFrame(in page: NSRect) -> NSRect { page }
    var dockCardRadius: CGFloat { Tokens.Radius.large }
    var dockCardColor: NSColor? { Tokens.Color.cardBackground }
    var dockHasShadow: Bool { true }
    /// The preview's page comes in and goes out from the sidebar's side; a page card's peek just fades.
    var dockSlidesPage: Bool { true }
    var dockPageOnRight: Bool { shownOnRight }
    var dockIsCovered: Bool { !isShowing || !(host?.pageShowing ?? false) }
    var dockIsFullScreen: Bool { false }

    /// No page behind it to dim: the page is its own card beside the sidebar.
    func dockShowDim(owner: AnyObject, onClick: @escaping () -> Void) -> MiniPeekDimView? { nil }
    func dockHideDim(owner: AnyObject) {}
    func dockFocusPage() {}
}

/// A row whose page isn't running: its name, why it isn't running, and how to wake it. A plain card with no page
/// picture, so a hover never shows a stale snapshot. It never touches the tab's page, so resting on the row cannot
/// wake it; a click on the row loads it in the browser.
final class EdgeAsleepPageView: NSView {
    private let clip = NSView()
    private let scrim = ColorView(color: NSColor.black.withAlphaComponent(0.42))
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.heading(), color: .white)
    private let note = Label("", font: Tokens.Font.detail(), color: NSColor.white.withAlphaComponent(0.82))
    private let hint = Label("", font: Tokens.Font.small(), color: NSColor.white.withAlphaComponent(0.7))
    /// What the card says, for tests: the row's name and why its page isn't running.
    private(set) var shownTitle = ""
    private(set) var shownNote = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        clip.wantsLayer = true
        clip.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
        clip.layer?.cornerRadius = Tokens.Radius.large
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        addSubview(clip)

        clip.addSubview(scrim)

        icon.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.alignment = .center
        note.alignment = .center
        note.usesSingleLineMode = false
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        hint.alignment = .center
        [icon, title, note, hint].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The row's tab: its name and note, nothing that would make its page run.
    func show(tab: Tab) {
        shownTitle = tab.displayTitle
        title.stringValue = shownTitle
        title.toolTip = shownTitle
        shownNote = tab.notLoadedNote ?? String(localized: "This page is asleep.",
                                               comment: "In the edge sidebar's card for a tab whose page isn't running, when the app has no more specific reason to give.")
        note.stringValue = shownNote
        note.isHidden = shownNote.isEmpty
        hint.stringValue = tab.isAsleep
            ? String(localized: "Click the tab to wake it.",
                     comment: "At the foot of the edge sidebar's card for a sleeping tab: hovering only shows this card, and a click loads the page.")
            : String(localized: "Click the tab to load it.",
                     comment: "At the foot of the edge sidebar's card for a tab whose page hasn't loaded since Zigzag reopened: hovering only shows this card, and a click loads the page.")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        scrim.frame = clip.bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Tokens.Radius.large,
                                   cornerHeight: Tokens.Radius.large, transform: nil)

        let width = min(320, max(0, bounds.width - Tokens.Space.x6 * 2))
        let iconSide: CGFloat = 34
        let gap = Tokens.Space.x2
        let titleHeight = title.lineHeight
        let noteHeight = note.isHidden ? 0 : ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 200)).height ?? note.lineHeight)
        let hintHeight = hint.lineHeight
        let total = iconSide + gap * 2 + titleHeight + gap + noteHeight + gap * 2 + hintHeight
        var y = max(Tokens.Space.x6, (bounds.height - total) / 2)
        icon.frame = NSRect(x: bounds.midX - iconSide / 2, y: y, width: iconSide, height: iconSide)
        y = icon.frame.maxY + gap * 2
        title.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: titleHeight)
        y = title.frame.maxY + gap
        note.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: noteHeight)
        y = note.frame.maxY + gap * 2
        hint.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: hintHeight)
    }
}

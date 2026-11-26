import AppKit

/// What the page pill shows for a row: the running page itself, or the card that stands in while it isn't running.
enum EdgePreviewKind: Equatable {
    case live
    case card
}

/// What the edge panel can take from a row. Zigzag's own pages (Settings, History) belong to the window: the panel
/// shows the card over their pill rather than the page, and a click is refused in the panel as it always has.
enum EdgeLensPolicy {
    static func takesPage(url: URL?) -> Bool { !HistoryPage.isInternal(url) }
    static func isSystemPage(_ url: URL?) -> Bool { HistoryPage.isInternal(url) }
    /// A running page is lent to the preview. One that is not — asleep, or not loaded since Zigzag reopened — shows
    /// the card instead: resting on its row must not wake it. Only a click does.
    static func previewKind(isLoaded: Bool, isAsleep: Bool) -> EdgePreviewKind {
        isLoaded && !isAsleep ? .live : .card
    }
    /// Zigzag's own page, in the pill's card: it is the window's, so the panel can't show it live.
    static let systemPageNote = String(localized: "Zigzag's own page.",
                                       comment: "In the edge sidebar's card over a row of Zigzag's own pages, like Settings or History.")
    static let systemPageHint = String(localized: "Open it from the sidebar in Zigzag's window.",
                                       comment: "At the foot of the edge sidebar's card over a row of Zigzag's own pages, like Settings or History.")
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

    /// How long an activation change is given to settle before it may put the panel away.
    static let focusGrace: TimeInterval = 0.12

    /// Whether the panel survives an activation change once it has settled. Clicking into the preview activates
    /// Zigzag before the page's Mini takes the keyboard, and a system focus change can hand the app back within a
    /// moment: the pointer resting on the panel is the user still using it. A real switch of app leaves it inactive.
    static func keepsAfterActivation(appIsActive: Bool, panelIsKey: Bool, previewIsKey: Bool, pointerOnPanel: Bool) -> Bool {
        appIsActive && (panelIsKey || previewIsKey || pointerOnPanel)
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

    #if DEBUG
    /// A debug harness keeps the panel out with the pointer elsewhere.
    static var debugHoldsOpen = false
    #endif

    /// Off until turned on in Settings › Appearance.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The last non-private browser window that was in front: its sidebar is the one that comes out.
    private weak var target: BrowserWindowController?
    private var panel: EdgeSidebarPanel?
    private var host: EdgeSidebarHost?
    /// The browser's command bar over the screen while the panel is in use: the user types in it over another app.
    private var commandBarPopup: EdgeCommandBarPopup?
    private(set) var isCommandBarOpen = false
    /// A result was chosen in the bar: its page becomes the panel's when the bar goes, unlike a bar dismissed with Esc.
    private var choseResult = false
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
    /// A pending activation verdict: the panel goes away only once focus has settled.
    private var activationWork: DispatchWorkItem?
    /// When the pointer left the panel, while it's on its way back.
    private var leftAt: TimeInterval?
    /// Counts shows, so a slide back only orders out the panel it hid.
    private var generation = 0
    /// The page shown beside the sidebar while a row is rested on: the same docked Mini as the in-page peek.
    private var preview: MiniWindowController?
    private var previewTab: Tab?
    /// The page the panel is showing: the row's previewed page (live, or its card while it isn't running), or the
    /// browser's selection. The address row's buttons act on this page, so they work on what the panel shows rather
    /// than on a tab behind it.
    var displayedTab: Tab? { preview?.tab ?? target?.tabManager.selectedTab }
    /// The page beside the panel, if one is out: its pill, with the page in it or the card over it.
    var pagePreview: MiniWindowController? { preview }
    /// The tab picked in the panel: its page fills the page's room, and leaving another row's hover comes back to it.
    /// Weak, so a tab closed elsewhere cannot be kept alive by the panel; `show` and `hide` clear it too.
    private weak var activeTab: Tab?
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
    /// A space switch is taking the page with it: its selection change is the switch's, not a row's page leaving.
    private var followsSpace = false
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

    /// Zigzag came forward, or another app did. A click into the preview brings Zigzag forward before the Mini is
    /// key, and a focus change can hand it back within a moment, so the verdict waits a grace: the panel stays if
    /// Zigzag holds the keyboard there or the pointer still rests on it, and a real app switch still puts it away.
    private func hideUnlessPreviewIsKey() {
        guard isShowing else { return }
        activationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleActivation() }
        }
        activationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeSidebarLayout.focusGrace, execute: work)
    }

    /// The activation change, a grace later: keep the panel only while Zigzag is in front and the panel, its preview,
    /// or the pointer is holding it.
    private func settleActivation() {
        activationWork = nil
        guard isShowing, let panel else { return }
        let keeps = EdgeSidebarLayout.keepsAfterActivation(
            appIsActive: NSApp.isActive,
            panelIsKey: panel.isKeyWindow,
            previewIsKey: preview?.window?.isKeyWindow == true,
            pointerOnPanel: panel.frame.contains(NSEvent.mouseLocation))
        guard !keeps else { return }
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
        var held = NSEvent.pressedMouseButtons != 0 || MenuPanel.current != nil || isCommandBarOpen
            || SpaceEditorPanel.current?.window === panel
            || RunLoop.current.currentMode == .eventTracking || NSApp.modalWindow != nil
        #if DEBUG
        // A debug harness drives the panel with the pointer elsewhere.
        if Self.debugHoldsOpen { held = true }
        #endif
        // The menu's room goes with the menu; the wide frame while a page or its card is beside the sidebar stays.
        let intended = preview == nil ? cardPanelFrame : previewPanelFrame
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
        // On the sidebar card the panel takes the keyboard, without bringing Zigzag forward: the menu bar's keys and
        // ⌘T then act on it as they do in the window. Over the page pill the page stays the one taking keys.
        if let host, !isCommandBarOpen, MenuPanel.current == nil, !panel.isKeyWindow {
            let inHost = host.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if host.cardFrame.contains(inHost) { panel.makeKey() }
        }
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
        guard tab !== previewTab, let url = tab.url, !tab.isPrivate,
              EdgeLensPolicy.isSystemPage(url)
                || ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
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
        guard preview != nil else { return false }
        closePreview()
        return true
    }

    #if DEBUG
    /// A row's preview without the hover's wait or the pointer, for the tests and the debug harness.
    func previewNow(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, target === controller, !tab.isPrivate, tab.url != nil else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        hoverCheck += 1
        showPreview(tab, in: controller)
    }
    #endif

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
                    self.showPreview(tab, in: controller)
                } else {
                    self.scheduleHoverCheck(tab: tab, in: controller, pointer: point,
                                            stillSince: moved ? now : stillSince, token: token)
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgePreviewHoverPolicy.check, execute: work)
    }

    /// The page is the same docked Mini as the in-page peek: its own floor-to-ceiling pill beside the sidebar. A row
    /// whose page isn't running — asleep, not loaded since Zigzag reopened, or Zigzag's own — is the same pill with
    /// a card laid over its room: waking it takes the card away, never the window.
    private func showPreview(_ tab: Tab, in controller: BrowserWindowController, foldFromRight: Bool? = nil) {
        guard isShowing, let panel, let host, !tab.isPrivate, tab.url != nil else { return }
        let system = !EdgeLensPolicy.takesPage(url: tab.url)
        let live = !system && EdgeLensPolicy.previewKind(isLoaded: tab.isLoaded, isAsleep: tab.isAsleep) == .live
        // The tab already out keeps the one pill: waking it takes its card away in place, and a tab whose page went
        // to sleep puts the card over the page it already has. Nothing closes and nothing is opened again.
        if let current = preview, current.tab === tab {
            previewTab = tab
            host.pageShowing = true
            host.placeCard()
            current.onAsleepCardClicked = system ? nil : { [weak self] in self?.wakePreviewedCard() }
            if !live {
                current.showAsleepCard(note: system ? EdgeLensPolicy.systemPageNote : nil,
                                       hint: system ? EdgeLensPolicy.systemPageHint : nil)
            }
            refreshAddress()
            return
        }
        // The pill already out keeps its room; the page or card it replaces stays under the next one's fold, so a
        // swap is a transition from what was there rather than a fresh fold over an empty page area.
        let previous = preview
        // The panel takes its full width at once, before the page is opened: the page is laid out at its final size
        // and the fold is the only thing moving, so its content never reflows through a widening animation.
        let sidebar = controller.edgeSidebarWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.cardWidth = sidebar
        host.pageShowing = true
        panel.setFrame(previewPanelFrame, display: true)
        host.placeCard()
        host.layoutSubtreeIfNeeded()
        guard let mini = MiniWindowController.openPreview(of: tab, from: controller, dockedIn: self,
                                                           reveal: false, deferPage: !live) else {
            if previous == nil { narrowPanel() }
            return
        }
        if !live {
            mini.showAsleepCard(note: system ? EdgeLensPolicy.systemPageNote : nil,
                                hint: system ? EdgeLensPolicy.systemPageHint : nil)
        }
        mini.onAsleepCardClicked = system ? nil : { [weak self] in self?.wakePreviewedCard() }
        mini.onInPageMiniClosed = { [weak self, weak mini] in self?.previewClosed(mini) }
        mini.onInPageMiniDetached = { [weak self, weak mini] in self?.previewDetached(mini) }
        preview = mini
        previewTab = tab
        refreshAddress()
        mini.layoutInDock(force: true)
        // The page is at its final place already; the fold uncovers it as the panel edge reaches it, or over the page
        // it replaces.
        mini.revealDockedPage(fromRight: foldFromRight ?? shownOnRight) { [weak self, weak previous] in
            guard let previous else { return }
            // Off the bookkeeping first: the old Mini is closing under the new one, not taking the panel with it.
            previous.onInPageMiniClosed = nil
            previous.onInPageMiniDetached = nil
            self?.target?.closeReaderForEdgePreview(previous)
            previous.closeInPage(focusBack: false, animated: false)
        }
        notePreviewMove()
    }

    /// The picked page comes back in the page's full room, from a hover or another row.
    private func showActive(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, target === controller, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url) else { return }
        // Already the pill's tab: its page and its card trade places there by themselves.
        guard preview?.tab !== tab else { return }
        showPreview(tab, in: controller)
    }

    /// A click on the card standing in for the previewed page wakes it where it is, as a click on its row does: the
    /// tab is selected in the browser, the panel stays out, and the page takes the card's place in the one Mini.
    private func wakePreviewedCard() {
        guard isShowing, let target, let tab = preview?.tab, !tab.isPrivate,
              EdgeLensPolicy.takesPage(url: tab.url) else { return }
        activeTab = tab
        target.listSelect(tab)
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
        guard previewTab !== activeTab else { return }
        guard panel.frame.contains(NSEvent.mouseLocation) else { return }
        guard !pointerIsOverPreview() else { return }
        let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard !host.cardFrame.contains(host.convert(inWindow, from: nil)) else { return }
        guard EdgeLensPolicy.takesPage(url: activeTab.url), !activeTab.isPrivate else { return }
        showActive(activeTab, in: target)
    }

    private func schedulePreviewClose() {
        closeWork?.cancel()
        closeWork = nil
        guard preview != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if let frame = self.preview?.window?.frame, frame.contains(mouse) { return }
            if self.isShowing, let frame = self.panel?.frame, frame.contains(mouse) { return }
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
        target?.closeReaderForEdgePreview(mini)
        activeTab = nil
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
            refreshAddress()
        }
    }

    /// The address row follows the page the panel is showing, so its back, forward, reload, site controls and star
    /// answer for the previewed page while it is out, not for the selection behind it.
    private func refreshAddress() {
        host?.container?.sidebar.update(tab: displayedTab)
        // Reader and Translate follow the previewed page, which may be a tab other than the one selected behind.
        target?.updateEdgeAddressButtons(for: displayedTab)
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
        refreshAddress()
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
        refreshAddress()
        narrowPanel()
        hide(animated: false)
    }

    private func narrowPanel(animated: Bool = false) {
        previewPanelFrame = .zero
        guard isShowing, let host, let panel else { return }
        host.pageShowing = false
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
            // Only a page beside the list follows the switch. Its tab is prepared later in `switchToSpace`, so wait a
            // turn: the new space's selected page is then ready to lend.
            let hadPreview = preview != nil
            guard hadPreview, EdgePreviewRouting.keepsPreviewOnSpaceChange(previewOpen: hadPreview) else { return }
            followsSpace = true
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, self.isShowing, self.target === controller,
                      controller.tabManager.currentSpaceID == after else { return }
                self.followSpace(from: before, to: after, in: controller)
            }
            return
        }
        guard preview != nil || activeTab != nil else { return }
        switch change {
        case .space:
            break
        case .structure:
            if previewTab?.isClosed == true { closePreview() }
            if activeTab?.isClosed == true {
                activeTab = nil
            }
        case .selection:
            // The picked page is no longer the window's: the old lens put itself away a turn later, so a page chosen
            // for the panel or opened from it has the pass it needs to arrive first.
            if let activeTab, let selected = controller.tabManager.selectedTab, selected !== activeTab {
                self.activeTab = nil
            }
            // The panel's own bar is opening a page: the new selection is the page to show, not a reason to close.
            guard !isCommandBarOpen else { return }
            // A space switch is taking the page with it; its selection is not the shown page leaving.
            guard !followsSpace else { return }
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
        followsSpace = false
        let slide = EdgePreviewRouting.spaceSlide(from: before, to: after, order: controller.tabManager.listedSpaces.map(\.id))
        let fold: Bool? = slide == 0 ? nil : slide > 0
        guard let shown = controller.tabManager.selectedTab, !shown.isPrivate,
              EdgeLensPolicy.takesPage(url: shown.url) else {
            activeTab = nil
            closePreview(animated: false)
            return
        }
        activeTab = shown
        // A page the space switch is still preparing is the same pill with its card: it replaces the card in place
        // when the page arrives, as it would on a click.
        showPreview(shown, in: controller, foldFromRight: fold)
    }

    // MARK: The panel

    func show(on visible: NSRect, for target: BrowserWindowController) {
        self.target = target
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
        activeTab = nil
        host.pageShowing = false
        installManagerObserver(for: target)
        host.onRight = onRight
        host.cardWidth = target.edgeSidebarWidth
        lastSpaceID = target.tabManager.currentSpaceID
        previewMoveUntil = 0
        followsSpace = false
        host.set(container)
        generation += 1
        cardPanelFrame = EdgeSidebarLayout.frame(in: visible, width: host.cardWidth + host.inset, onRight: onRight)
        shownVisible = visible
        panel.setFrame(cardPanelFrame, display: true)
        host.placeCard()
        isShowing = true
        shownOnRight = onRight
        leftAt = nil
        refreshAddress()
        // The keyboard stays with the app in front until the panel is clicked.
        panel.nextResponder = target
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
        activationWork?.cancel()
        activationWork = nil
        // The bar open over the screen goes with the panel.
        if isCommandBarOpen, let target { target.commandBar.dismiss(restoringFocus: false) }
        commandBarPopup?.orderOut(nil)
        isCommandBarOpen = false
        choseResult = false
        // A space being named in the panel goes with it; its close is the panel's, not the window's behind.
        if let editor = SpaceEditorPanel.current, editor.window === panel { editor.close() }
        if let host, DownloadsPanel.isOpen(in: host.window) { DownloadsPanel.closeCurrent() }
        if let panel, SitePanel.isOpen(in: panel) { SitePanel.closeCurrent() }
        managerToken?.cancel()
        managerToken = nil
        lastSpaceID = nil
        previewMoveUntil = 0
        followsSpace = false
        activeTab = nil
        // The panel goes out from under the pointer, so its row never gets the exit that would put its hover away.
        target?.edgeSidebar?.list.clearHover()
        guard isShowing, let panel else { return }
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

    /// Where a sheet belongs while the panel is in use: over the panel, above its cards, not in the window behind.
    var sheetHost: NSView? { isShowing ? host?.overlay : nil }

    /// The panel's space name, where an editor opens when a menu bar command started it.
    var headerView: NSView? { isShowing ? target?.edgeSidebar?.list.headerView : nil }

    /// Downloads from the panel: the list in the panel's window, over the mirror's lane, not in the window behind.
    func showDownloads(from anchor: NSView, in controller: BrowserWindowController) {
        guard isShowing, let host, let target else { return }
        DownloadsPanel.show(from: anchor, in: controller, host: host, lane: host.cardFrame,
                            receding: target.edgeSidebar.map { [$0.list] } ?? [])
    }

    /// Site Controls for the page the address names: in the preview's own Mini when it shows that page, otherwise
    /// over the panel's card, never in the browser window behind.
    func showSiteControls(for tab: Tab, from button: IconButton, in controller: BrowserWindowController) {
        if let preview, preview.tab === tab {
            preview.showSiteControls()
            return
        }
        guard isShowing, let host, let panel else { return }
        SitePanel.toggle(in: EdgeSitePanelHost(tab: tab, overlay: host.overlay, window: panel), from: button)
    }

    /// ⌘T with the panel clicked into: the browser's own bar, over the screen, not in the window behind it.
    func newTab() { newTabInPlace() }

    // MARK: The command bar

    /// The surface the browser's command bar draws in while the panel is in use: the screen the panel is on.
    var commandBarOverlay: NSView? { isCommandBarOpen ? commandBarPopup?.overlay : nil }
    var commandBarPageFrame: NSRect? {
        guard isCommandBarOpen, let popup = commandBarPopup else { return nil }
        guard let host, let panel, host.pageShowing else { return popup.overlay.bounds }
        // A new tab or history, with a page beside the sidebar, centers over that page's pill. With no page out there
        // is no pill to center over: the bar is the spotlight it is everywhere else, in the middle of the screen.
        let screen = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        return popup.overlay.convert(popup.convertFromScreen(screen), from: nil)
    }

    /// The panel's address row, in the popup's terms: editing the address opens the bar over it, at its size, as
    /// clicking the window's sidebar address does — not in the middle of the screen.
    var commandBarAnchorView: NSView? {
        guard isCommandBarOpen, let popup = commandBarPopup, let panel, let host,
              let address = host.container?.sidebar.address, address.window === panel, !address.isHidden else { return nil }
        let screen = panel.convertToScreen(address.convert(address.bounds, to: nil))
        popup.anchor.frame = popup.overlay.convert(popup.convertFromScreen(screen), from: nil)
        return popup.anchor
    }

    func newTabInPlace() { openCommandBarInPlace(.newTab) }

    /// The address clicked in the panel: the same bar, editing the page the panel shows.
    func editAddressInPlace() {
        // Editing "the page the panel shows": a previewed row is made the window's tab first, so the bar edits it,
        // not whichever tab was selected behind the panel.
        if let target, let displayed = displayedTab, target.tabManager.selectedTab !== displayed {
            target.tabManager.select(displayed)
        }
        openCommandBarInPlace(.editCurrent)
    }

    private func openCommandBarInPlace(_ mode: CommandBarController.Mode) {
        guard isShowing, !isCommandBarOpen, let target, shownVisible.width > 0 else { return }
        if target.commandBar.isVisible { target.commandBar.dismiss(restoringFocus: false) }
        let popup = commandBarPopup ?? makeCommandBarPopup()
        popup.setFrame(shownVisible, display: true)
        popup.overlay.frame = NSRect(origin: .zero, size: shownVisible.size)
        // The menu bar's tab and sidebar keys reach the browser controller from the bar's window too.
        popup.nextResponder = target
        isCommandBarOpen = true
        choseResult = false
        popup.orderFrontRegardless()
        target.showEdgeCommandBar(mode: mode)
    }

    /// A result was chosen in the bar: the page it opens is the panel's page when the bar goes.
    func commandBarChoseResult() {
        choseResult = true
    }

    /// The bar's field is in the popup, and the popup takes the keyboard for it.
    func focusCommandBar(_ field: NSTextField) {
        guard isCommandBarOpen, let popup = commandBarPopup else { return }
        popup.makeKeyAndOrderFront(nil)
        popup.makeFirstResponder(field)
    }

    /// The bar has finished leaving: the popup goes, and the panel takes the keyboard back.
    /// The bar has finished leaving: the popup goes, and the panel takes the keyboard back. A page it opened or
    /// changed becomes the panel's page: opening a tab or typing an address stays in the panel.
    func commandBarDidHide() {
        guard isCommandBarOpen else { return }
        isCommandBarOpen = false
        let chose = choseResult
        choseResult = false
        commandBarPopup?.orderOut(nil)
        guard isShowing else { return }
        panel?.makeKey()
        guard chose, let target, let selected = target.tabManager.selectedTab, !selected.isPrivate,
              EdgeLensPolicy.takesPage(url: selected.url) else { return }
        activeTab = selected
        showActive(selected, in: target)
    }

    private func makeCommandBarPopup() -> EdgeCommandBarPopup {
        let popup = EdgeCommandBarPopup(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.level = .statusBar
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = false
        popup.hidesOnDeactivate = false
        popup.isMovable = false
        popup.isReleasedWhenClosed = false
        popup.animationBehavior = .none
        popup.contentView = popup.overlay
        popup.anchor.isHidden = true
        popup.overlay.addSubview(popup.anchor)
        commandBarPopup = popup
        return popup
    }

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
        panel.setSeeThrough(shadow: false)
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
            EdgeSidebar.shared.newTabInPlace()
            return true
        }
        // The panel's next responder is its browser window's controller, so the menu's tab and sidebar commands
        // reach the same actions as they do in the window.
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The edge panel as a place for Site Controls: the page the address names, and the panel opens over the card instead
/// of bringing the browser window forward.
@MainActor final class EdgeSitePanelHost: SitePanelPageHost {
    let tab: Tab
    let overlay: PassthroughView
    private let hostWindow: NSWindow?

    init(tab: Tab, overlay: PassthroughView, window: NSWindow?) {
        self.tab = tab
        self.overlay = overlay
        self.hostWindow = window
    }

    var window: NSWindow? { hostWindow }
    var listsExtensions: Bool { false }

    func copyPageURL(_ sender: Any?) {
        guard let url = tab.url else { return }
        CleanLink.write(url, title: tab.displayTitle)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."),
                   symbol: "link", over: overlay, area: overlay.bounds)
    }

    func confirmClear(_ kind: WebsiteData.Kind, of tab: Tab) {
        BrowserWindowController.confirmClear(kind, of: tab, over: overlay) { [weak self] text in
            guard let self else { return }
            Toast.show(text, symbol: "checkmark.circle", over: self.overlay, area: self.overlay.bounds)
        }
    }
}

/// The browser's command bar over the screen while the edge sidebar is in use: it takes the keyboard without bringing
/// Zigzag forward, so the bar can be typed in over another app.
final class EdgeCommandBarPopup: NSPanel {
    /// Flipped, as the window's command-bar overlay is: the bar's frames count down from the screen's top.
    let overlay = PassthroughView()
    /// Where the sidebar's address is, in this window's terms: the bar opens over it, as it does in the window. Hidden,
    /// so it never takes a click.
    let anchor = NSView()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    /// The panel as a place for Site Controls: their panel opens here, over the card, not in the browser behind.
    let overlay = PassthroughView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(overlay)
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
        if container.superview !== self { addSubview(container, positioned: .below, relativeTo: overlay) }
        placeCard()
    }

    func placeCard() {
        // The sidebar is its own card, not a surface widened behind the page: the page is a separate pill.
        container?.frame = cardFrame
        overlay.frame = bounds
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
/// wake it; a click on the row, or on this card in the pill, loads it in the browser.
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
    /// A click on the card does what a click on its row does: the panel's page wakes in place. Nil for Zigzag's own
    /// pages, which the panel never runs.
    var onClick: (() -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// The card is the click's target, not the labels on it: a label would take the click and never pass it on.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// The panel is over another app and needn't be key: the first click still wakes the tab.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

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

    /// The row's tab: its name and note, nothing that would make its page run. `note`/`hint` for a tab the panel
    /// will never show live (one of Zigzag's own pages): what it is, and where it opens.
    func show(tab: Tab, note: String? = nil, hint: String? = nil) {
        shownTitle = tab.displayTitle
        title.stringValue = shownTitle
        title.toolTip = shownTitle
        shownNote = note ?? tab.notLoadedNote ?? String(localized: "This page is asleep.",
                                                       comment: "In the edge sidebar's card for a tab whose page isn't running, when the app has no more specific reason to give.")
        self.note.stringValue = shownNote
        self.note.isHidden = shownNote.isEmpty
        self.hint.stringValue = hint ?? (tab.isAsleep
            ? String(localized: "Click the tab to wake it.",
                     comment: "At the foot of the edge sidebar's card for a sleeping tab: hovering only shows this card, and a click loads the page.")
            : String(localized: "Click the tab to load it.",
                     comment: "At the foot of the edge sidebar's card for a tab whose page hasn't loaded since Zigzag reopened: hovering only shows this card, and a click loads the page."))
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

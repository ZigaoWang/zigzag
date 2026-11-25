import AppKit

/// What a row picked while the panel is already showing a page does.
enum EdgeLensPick: Equatable {
    /// Nothing was out: the page comes in.
    case open
    /// Another page was out: this one takes its place.
    case replace
    /// This page was already out: the pick keeps it and the keyboard goes into it.
    case lock
}

/// What the edge panel can take from a row, and what a pick does with the page already there. Zigzag's own pages
/// (Settings, History) belong to the window: the panel greys their rows and says where they work instead of lending.
enum EdgeLensPolicy {
    static func takesPage(url: URL?) -> Bool { !HistoryPage.isInternal(url) }

    static func pickAction(isVisible: Bool, sameTab: Bool) -> EdgeLensPick {
        guard isVisible else { return .open }
        return sameTab ? .lock : .replace
    }
}

/// Which page the panel takes when the list's space changes under it, and which way the spaces moved.
enum EdgePreviewRouting {
    static func keepsPreviewOnSpaceChange(previewOpen: Bool) -> Bool { previewOpen }

    /// +1 to the next space, -1 to the one before, 0 when either is unknown. The list slides the new space in from
    /// the right on +1 and the left on -1; the page's fold follows it.
    static func spaceSlide(from old: UUID?, to new: UUID, order: [UUID]) -> Int {
        guard let old, let before = order.firstIndex(of: old), let after = order.firstIndex(of: new) else { return 0 }
        return after == before ? 0 : (after > before ? 1 : -1)
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
    /// One of Zigzag's own pages under the pointer: the panel can't lend its page, so the page area says where it
    /// works and offers the window. Setting it does not change `previewTab`: the notice has no page of its own.
    private var noticeTab: Tab?
    /// The row picked while the preview is out: leaving the rows comes back to it. Nil until a pick.
    private var lockedTab: Tab?
    private var previewWork: DispatchWorkItem?
    /// Counts hovers, so a rest check left over from the previous row cannot preview it.
    private var hoverCheck = 0
    private var closeWork: DispatchWorkItem?
    /// Listens to the window's list while the panel is out: a space change moves the preview with it, and a page
    /// closed or left under it puts the preview away rather than showing a page with no row to come from.
    private var managerToken: SignalToken?
    /// The space the panel was in when it last showed a page: a switch's direction is this and the spaces' order.
    private var lastSpaceID: UUID?
    /// The panel's wide frame: the sidebar's own width plus the page's third.
    private var previewPanelFrame: NSRect = .zero

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
        // A pick brings Zigzag forward, and so does anything else: the panel has done its job. Clicking into the
        // preview does too, but that is the preview working, so it keeps the panel.
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

    /// Zigzag came forward. A click into the preview brings it forward too, and that is the preview working; a pick
    /// in the rows or any other way back to the app is the panel's errand done.
    private func hideUnlessPreviewIsKey() {
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
        // The menu's room goes with the menu; the wide frame while a page or a note is beside the sidebar stays.
        let intended = preview == nil && noticeTab == nil ? cardPanelFrame : previewPanelFrame
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
            // Leaving the rows after a pick goes back to the picked page; before one, the preview stays for a glance.
            if let lockedTab, previewTab !== lockedTab {
                showPreview(lockedTab, in: controller)
            } else {
                schedulePreviewClose()
            }
            return
        }
        guard tab !== previewTab, tab !== noticeTab, let url = tab.url, !tab.isPrivate,
              HistoryPage.isInternal(url) || ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            schedulePreviewClose()
            return
        }
        scheduleHoverCheck(tab: tab, in: controller, pointer: NSEvent.mouseLocation,
                           stillSince: ProcessInfo.processInfo.systemUptime, token: hoverCheck)
    }

    /// The row under the pointer is clicked: its page stays in the panel from then on, and the keyboard goes into it.
    /// A pick that the panel cannot show returns false, so the click keeps today's way into the window.
    @discardableResult
    func pick(_ tab: Tab, in controller: BrowserWindowController) -> Bool {
        guard isShowing, target === controller, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url),
              let url = tab.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        hoverCheck += 1
        let action = EdgeLensPolicy.pickAction(isVisible: previewTab != nil || noticeTab != nil,
                                               sameTab: previewTab === tab)
        if action != .lock { showPreview(tab, in: controller) }
        guard previewTab === tab, let preview else { return false }
        lockedTab = tab
        preview.focusPage()
        return true
    }

    /// Esc in the panel closes the page first, as #365 did, leaving the sidebar where it is.
    @discardableResult
    func dismissPreview() -> Bool {
        if noticeTab != nil {
            closeNotice()
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
                    if EdgeLensPolicy.takesPage(url: tab.url) {
                        self.showPreview(tab, in: controller)
                    } else {
                        self.showNotice(tab, in: controller)
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
    private func showPreview(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, let panel, let host, !tab.isPrivate, EdgeLensPolicy.takesPage(url: tab.url) else { return }
        if noticeTab != nil {
            noticeTab = nil
            host.noticeShowing = false
            host.notice.onReturn = nil
        }
        // A page from another space is another Mini: the strip and the space it wears belong to the page.
        if let old = preview, old.tab.spaceID != tab.spaceID {
            preview = nil
            old.onInPageMiniClosed = nil
            old.onInPageMiniDetached = nil
            old.closeInPage(focusBack: false, animated: false)
        }
        let sidebar = controller.edgeSidebarWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.cardWidth = sidebar
        host.pageShowing = true
        panel.setFrame(previewPanelFrame, display: true)
        host.placeCard()
        host.layoutSubtreeIfNeeded()
        if let preview {
            preview.loadPreview(tab)
        } else if let mini = MiniWindowController.openPreview(of: tab, from: controller, dockedIn: self) {
            mini.onInPageMiniClosed = { [weak self, weak mini] in self?.previewClosed(mini) }
            mini.onInPageMiniDetached = { [weak self, weak mini] in self?.previewDetached(mini) }
            preview = mini
        } else {
            narrowPanel()
            return
        }
        previewTab = tab
        preview?.layoutInDock(force: true)
    }

    /// One of Zigzag's own pages under the pointer: the panel can't lend its page, so the page area says where it
    /// works and offers the window. The panel widens exactly as for a page, so the row keeps the same shape.
    private func showNotice(_ tab: Tab, in controller: BrowserWindowController) {
        guard isShowing, let panel, let host, !tab.isPrivate, !EdgeLensPolicy.takesPage(url: tab.url) else { return }
        previewWork?.cancel()
        previewWork = nil
        closeWork?.cancel()
        closeWork = nil
        // A page already out slides back to its tab while the note unfolds in its place, but the picked page stays
        // picked: the notice is only a glance.
        if let mini = preview {
            preview = nil
            previewTab = nil
            mini.onInPageMiniClosed = nil
            mini.onInPageMiniDetached = nil
            mini.closeInPage(focusBack: false, animated: true)
        }
        noticeTab = tab
        let sidebar = controller.edgeSidebarWidth
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: host.inset, in: shownVisible)
        previewPanelFrame = EdgeSidebarLayout.frame(in: shownVisible, width: wide, onRight: shownOnRight)
        host.cardWidth = sidebar
        host.pageShowing = true
        host.notice.show(tab: tab)
        host.noticeShowing = true
        host.notice.onReturn = { [weak self, weak controller, weak tab] in
            guard let self, let controller, let tab else { return }
            self.returnToBrowser(tab, in: controller)
        }
        panel.setFrame(previewPanelFrame, display: true)
        host.placeCard()
        host.layoutSubtreeIfNeeded()
        // The note comes in from behind the card, as the page does, rather than appearing in one frame.
        host.foldInSide()
    }

    /// The note's button: the page is the window's, so the window comes forward on it and the panel puts itself away.
    private func returnToBrowser(_ tab: Tab, in controller: BrowserWindowController) {
        controller.tabManager.select(tab)
        controller.bringForwardForEdge()
    }

    /// The note has gone: the panel narrows to the card unless a page is taking the area.
    private func closeNotice() {
        guard noticeTab != nil else { return }
        noticeTab = nil
        host?.noticeShowing = false
        host?.notice.onReturn = nil
        if preview == nil { narrowPanel() }
    }

    private func schedulePreviewClose() {
        closeWork?.cancel()
        closeWork = nil
        guard preview != nil || noticeTab != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if let frame = self.preview?.window?.frame, frame.contains(mouse) { return }
            if self.isShowing, let frame = self.panel?.frame, frame.contains(mouse) { return }
            self.closeNotice()
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
        preview = nil
        previewTab = nil
        lockedTab = nil
        if animated {
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
        lockedTab = nil
        narrowPanel()
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
        lockedTab = nil
        narrowPanel()
        hide(animated: false)
    }

    private func narrowPanel() {
        previewPanelFrame = .zero
        guard isShowing, let host, let panel else { return }
        host.pageShowing = false
        host.noticeShowing = false
        if let target { host.cardWidth = target.edgeSidebarWidth }
        host.placeCard()
        panel.setFrame(cardPanelFrame, display: true)
    }

    /// The panel shows the window's list, so a change to that list is a change to the panel. A space switch moves the
    /// preview to the new space's page; a page closed under it puts the preview away.
    private func installManagerObserver(for controller: BrowserWindowController) {
        managerToken?.cancel()
        lastSpaceID = controller.tabManager.currentSpaceID
        managerToken = controller.tabManager.changed.observe { [weak self, weak controller] change in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.managerChanged(change, in: controller)
            }
        }
    }

    private func managerChanged(_ change: TabManager.Change, in controller: BrowserWindowController) {
        guard isShowing, target === controller else { return }
        // Before a page is out, only the space's place is kept current: nothing else has a preview to move.
        guard preview != nil || noticeTab != nil else {
            lastSpaceID = controller.tabManager.currentSpaceID
            return
        }
        switch change {
        case .space:
            lastSpaceID = controller.tabManager.currentSpaceID
            guard EdgePreviewRouting.keepsPreviewOnSpaceChange(previewOpen: preview != nil || noticeTab != nil) else {
                closeNotice()
                closePreview()
                return
            }
            let keepsPick = lockedTab != nil
            guard let shown = controller.tabManager.selectedTab, !shown.isPrivate else {
                closeNotice()
                closePreview()
                return
            }
            if EdgeLensPolicy.takesPage(url: shown.url) {
                showPreview(shown, in: controller)
                if keepsPick, previewTab === shown { lockedTab = shown }
            } else {
                showNotice(shown, in: controller)
                lockedTab = nil
            }
        case .structure:
            if previewTab?.isClosed == true { closePreview() }
            if noticeTab?.isClosed == true { closeNotice() }
        case .selection:
            // The page out of the panel is no longer the window's: the old lens put itself away a turn later, so a
            // page chosen for the panel or opened from it has the pass it needs to arrive first.
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
        noticeTab = nil
        host.pageShowing = false
        host.noticeShowing = false
        installManagerObserver(for: target)
        host.onRight = onRight
        host.cardWidth = target.edgeSidebarWidth
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
        guard isShowing, let panel else { return }
        if noticeTab != nil { closeNotice() }
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
    /// One of Zigzag's own pages, in the page pill's place: the panel can't lend it, so it says where it works.
    let notice = EdgeSystemPageNotice()
    var noticeShowing = false { didSet { placeCard() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        notice.isHidden = true
        addSubview(notice)
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
        notice.frame = pageFrame
        notice.isHidden = !noticeShowing
    }

    /// Unfolds the note from the card's side as it takes the page's place, the same way the page itself comes in:
    /// its layout is final under a layer mask, so nothing moves or reflows as it is revealed.
    func foldInSide(fromRight: Bool? = nil) {
        guard noticeShowing, !Tokens.Motion.reduceMotion, let layer = notice.layer else { return }
        let size = notice.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let right = fromRight ?? onRight
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: right ? 1 : 0, y: 0.5)
        mask.position = CGPoint(x: right ? size.width : 0, y: size.height / 2)
        mask.bounds = CGRect(origin: .zero, size: size)
        layer.mask = mask
        let fold = CABasicAnimation(keyPath: "bounds.size.width")
        fold.fromValue = 0
        fold.toValue = size.width
        fold.duration = 0.16
        fold.timingFunction = Tokens.Motion.easeOut
        mask.add(fold, forKey: "fold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeShowing else { return }
                self.notice.layer?.mask = nil
            }
        }
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

/// One of Zigzag's own pages under the pointer in the edge panel: the panel can't lend its page, so the page area
/// says where it works and offers the window. It stands in the page pill's place, at the same size.
final class EdgeSystemPageNotice: NSView {
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.heading(), color: Tokens.Color.textPrimary)
    private let detail = Label(String(localized: "Zigzag's own pages only work in the browser window.",
                                      comment: "Under the page's name in the edge sidebar's note for one of Zigzag's own pages, which the panel can't show."),
                               font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    let returnButton = PillButton(title: String(localized: "Return to Zigzag",
                                                comment: "Button in the edge sidebar's note for one of Zigzag's own pages: brings the browser forward on that page."),
                                  style: .prominent)
    var onReturn: (() -> Void)? {
        didSet {
            returnButton.onClick = { [weak self] _ in self?.onReturn?() }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
        layer?.cornerRadius = Tokens.Radius.large
        layer?.cornerCurve = .continuous
        layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        icon.image = NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.alignment = .center
        detail.alignment = .center
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
        addSubview(returnButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(tab: Tab) {
        title.stringValue = tab.title.isEmpty
            ? String(localized: "This page opens in Zigzag", comment: "The edge sidebar's note for one of Zigzag's own pages when the page's name is not known yet.")
            : tab.title
        title.toolTip = tab.title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(320, max(0, bounds.width - Tokens.Space.x6 * 2))
        let iconSide: CGFloat = 34
        let gap = Tokens.Space.x2
        let button = returnButton.intrinsicContentSize
        let buttonWidth = max(button.width, 132)
        let titleHeight = title.lineHeight
        let detailHeight = detail.lineHeight
        let total = iconSide + gap * 2 + titleHeight + gap + detailHeight + gap * 2 + button.height
        // From the bottom up: the button, the explanation, the page's name, the symbol.
        var y = max(Tokens.Space.x6, (bounds.height - total) / 2)
        returnButton.frame = NSRect(x: bounds.midX - buttonWidth / 2, y: y, width: buttonWidth, height: button.height)
        y = returnButton.frame.maxY + gap * 2
        detail.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: detailHeight)
        y = detail.frame.maxY + gap
        title.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: titleHeight)
        y = title.frame.maxY + gap * 2
        icon.frame = NSRect(x: bounds.midX - iconSide / 2, y: y, width: iconSide, height: iconSide)
    }
}

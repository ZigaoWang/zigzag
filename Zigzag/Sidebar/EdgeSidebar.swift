import AppKit

/// The sidebar's hot screen edge (#363): where the sidebar comes out on a screen, and the edge the pointer meets to
/// bring it. The screen's visible frame stands in for a window's bounds, so the same `SidebarEdgeZone` that decides
/// the window's hidden edge decides the screen's: where the pointer opens the sidebar, keeps it, and has gone past it.
enum EdgeSidebarLayout {
    /// The panel: the visible frame's full height, `width` wide against the screen's edge. Never wider than the screen.
    static func frame(in visible: NSRect, width: CGFloat, onRight: Bool) -> NSRect {
        let width = min(max(width, 0), visible.width)
        return NSRect(x: onRight ? visible.maxX - width : visible.minX, y: visible.minY, width: width, height: visible.height)
    }

    /// The pointer's place among the screen's, top-down from the visible frame's top edge, as `SidebarEdgeZone`
    /// reads it. Over the menu bar it's above the top, and so outside.
    static func point(_ point: NSPoint, in visible: NSRect) -> NSPoint {
        NSPoint(x: point.x - visible.minX, y: visible.maxY - point.y)
    }

    /// The screen-sized edge for a pointer at `point`: the panel where it comes out, and the strip along the
    /// screen's edge that opens it.
    static func zone(in visible: NSRect, width: CGFloat, onRight: Bool) -> SidebarEdgeZone {
        let out = frame(in: visible, width: width, onRight: onRight)
        return SidebarEdgeZone(
            bounds: NSRect(origin: .zero, size: visible.size),
            sidebar: NSRect(x: out.minX - visible.minX, y: 0, width: out.width, height: visible.height),
            onRight: onRight
        )
    }

    /// Which screen a pointer is on: the one whose visible frame holds it, in the order given. None where no visible
    /// frame reaches, as over a menu bar.
    static func screen(containing point: NSPoint, in screens: [NSRect]) -> Int? {
        screens.firstIndex { $0.contains(point) }
    }

    /// Whether the panel may come out: whenever Zigzag is not the app in front. A window behind another app is not
    /// on screen, so whether its own sidebar is docked or floating there changes nothing the person can see.
    static func canShow(appIsActive: Bool) -> Bool {
        !appIsActive
    }

    /// The panel stays while the page is attached beside it: the popout taking the keyboard is the panel working,
    /// not the browser coming forward.
    static func keepsPanelOnActivation(holdsForPeek: Bool) -> Bool { holdsForPeek }
}

/// What ends the panel's popout, and how a non-activating panel joins another app's Space rather than bringing
/// Zigzag's own Space forward (#363).
enum EdgePopoutPolicy {
    /// A click outside the popout and the panel that opened it puts it away.
    static func closesOnOutsideClick(eventWindow: NSWindow?, mini: NSWindow?, panel: NSWindow?) -> Bool {
        eventWindow !== mini && eventWindow !== panel
    }

    /// Zigzag's own pages (Settings, History, Archive) are not a web site with a field or a dialog to back out of
    /// first: Esc closes the popout at once, as it closes a page in the browser.
    static func closesOnFirstEscape(isInternalPage: Bool, isLeaving: Bool, commandBarVisible: Bool) -> Bool {
        isInternalPage && !isLeaving && !commandBarVisible
    }

    /// ⌘O is the Return button's shortcut. A status-bar panel over another app does not get the main menu's key
    /// equivalents, so the panel reads this one itself.
    static func isReturnKey(command: Bool, key: String?) -> Bool {
        command && key?.lowercased() == "o"
    }

    /// A floating popout is ordered front regardless and made key without activating Zigzag: the way the edge panel
    /// and the Peek join another app's Space, full-screen included. `showWindow`/`makeKeyAndOrderFront` asks the app
    /// to come forward, and its own Space with it.
    static func ordersFrontRegardless(floating: Bool) -> Bool { floating }
}

/// The sidebar's hot screen edge (#363): one switch, and the one panel that comes out of it.
///
/// While the switch is on, every pointer move is read against the screen edge on the sidebar's side. The window's own
/// `SidebarEdgeReveal` decides whether the pointer meant to bring the sidebar out, and the panel shows a live second
/// `SidebarView` belonging to the last browser window in front. Nothing in that window is moved, hidden or frozen.
final class EdgeSidebar {
    static let shared = EdgeSidebar()

    static let defaultsKey = "EdgeSidebar"
    static let changed = Notification.Name("EdgeSidebarChanged")

    /// Off until turned on in Settings › Appearance.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Zigzag is active with a window of its own in front, so the pointer is in the browser, not at the screen's
    /// edge. The panel and its command bar are not that window: showing them can make Zigzag active, and they must
    /// not read their own act of taking the keyboard as the browser being in front.
    private var isBrowserInFront: Bool {
        NSApp.isActive && NSApp.keyWindow !== panel && NSApp.keyWindow !== commandBarPopup
    }
    /// The last browser window that was in front: its sidebar is the one that comes out.
    private weak var target: BrowserWindowController?
    private var panel: EdgeSidebarPanel?
    private var host: EdgeSidebarHost?
    /// The browser's command bar, over the screen while the panel is in use (#363).
    private var commandBarPopup: EdgeCommandBarPopup?
    /// The bar is open in that popup, not in the window.
    private(set) var isCommandBarOpen = false
    private var reveal = SidebarEdgeReveal()
    /// Whether the panel is out now (or on its way back in).
    private(set) var isShowing = false
    /// The Peek's page is attached beside it: the pointer being over the page is not the pointer leaving.
    private var holdsForPeek = false
    /// The visible frame of the screen the panel is on, while it's out.
    private var shownScreen: NSRect?
    /// The side the panel last came out on, so it slides back the same way after its window has gone.
    private var lastPanelWasOnRight = false
    private var decideTimer: Timer?
    private var followTimer: Timer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isActivated = false
    /// The last moved event's time and speed toward the edge; once the pointer stops, none comes.
    private var lastMoveTime: TimeInterval = 0
    private var lastMoveSpeed: CGFloat = 0
    /// Counts shows, so a hide under way only orders out the panel it hid.
    private var generation = 0

    private init() {}

    // MARK: The switch

    /// Called at launch: with the switch on, the edge listens from now on, and follows it as it's turned on and off.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        observers.append(NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.isOn ? self.start() : self.stop()
            }
        })
        // A screen coming or going changes the edge under the panel: it goes until it's asked for again.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        // Zigzag coming forward with one of its windows puts it back: the panel is for reaching a tab from another
        // app. The panel making itself key is not that: it can make Zigzag active while it is the window in front.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async {
                    guard let self, self.isBrowserInFront else { return }
                    // The popout taking key is the panel working, not the browser coming forward.
                    guard !EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: self.holdsForPeek) else { return }
                    self.hide(animated: false)
                }
            }
        })
        // Another app or another space is a change of context: the panel goes, and the peek closes with it.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        if Self.isOn { start() }
    }

    private func start() {
        guard monitors.isEmpty else { return }
        // The pointer over any app: the global one hears the others', the local one Zigzag's own.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }
            return event
        }) { monitors.append(local) }
        // Esc puts the panel away. The lens consumes its own Esc first; once it has collapsed, the next Esc is the
        // sidebar's. A field being edited keeps its Esc to cancel the edit.
        if let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, self.panel?.isKeyWindow == true,
                      !self.isCommandBarOpen else { return false }
                if self.panel?.firstResponder is NSTextView { return false }
                self.hide()
                return true
            }
            return handled ? nil : event
        }) { monitors.append(esc) }
        target = WindowManager.shared.keyController ?? target
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide(animated: false, force: true)
        target = nil
    }

    /// A tab, favorite or other action picked in the panel: it goes at once, and its window comes forward.
    func picked() { hide(animated: false) }

    /// The Peek keeps the panel out while its page is attached, whatever the pointer does.
    func holdForPeek(_ hold: Bool) { holdsForPeek = hold }

    /// Whether the pointer is still in the strip that keeps the panel out.
    var pointerInEdgeZone: Bool {
        guard isShowing, let visible = shownScreen, let zone = zone(in: visible) else { return false }
        return zone.keeps(at: EdgeSidebarLayout.point(NSEvent.mouseLocation, in: visible))
    }

    /// Whether the panel could stay out at all: the browser coming forward takes that away.
    var canStayOut: Bool { !isBrowserInFront }

    /// The edge panel takes the keyboard back after the lens closes without hiding it.
    func makeKey() {
        guard isShowing else { return }
        panel?.makeKey()
    }

    /// A preview or a row was clicked: the lens opens for that tab.
    func openLens(for tab: Tab) {
        target?.openEdgeLens(for: tab)
    }

    /// Whether a click in the panel is one of the list's own actions (a row, New Tab, blank space), which closes the
    /// lens, rather than one of the sidebar's controls (back, reload, the address) that act on the lens instead.
    func clickClosesLens(at point: NSPoint) -> Bool {
        guard let target else { return true }
        let (sidebar, _) = target.edgeSidebarForDisplay()
        let list = sidebar.list
        return list.convert(list.bounds, to: nil).contains(point)
    }

    /// The panel's window, so the Peek can tell a click on the sidebar from a click outside.
    var panelWindow: NSWindow? { panel }

    /// Where Site Controls and other floating pieces sit over the panel's card.
    var panelOverlay: PassthroughView? { host?.overlay }

    /// The panel is along the screen's right edge; the page attaches on the other side of it.
    var panelOnRight: Bool { sideIsRight }

    /// The sidebar card's frame on screen: the page sits beside its inner edge.
    var sidebarCardScreenFrame: NSRect? {
        guard let panel, let host else { return nil }
        return panel.convertToScreen(host.convert(host.cardFrame, to: nil))
    }

    /// The last browser window to become key: what the edge brings out from now on.
    func noteFocused(_ controller: BrowserWindowController) {
        guard controller.window?.isVisible == true else { return }
        guard target !== controller else { return }
        target = controller
        if isShowing { hide() }
    }

    func windowClosed(_ controller: BrowserWindowController) {
        guard target === controller else { return }
        hide(animated: false, force: true)
        target = nil
    }

    // MARK: The pointer

    private var sideIsRight: Bool { target?.edgeSidebarOnRight ?? false }

    private func moved(_ event: NSEvent) {
        let elapsed = event.timestamp - lastMoveTime
        lastMoveSpeed = elapsed > 0 && elapsed < 0.1 ? (sideIsRight ? event.deltaX : -event.deltaX) / max(elapsed, 1.0 / 240) : 0
        lastMoveTime = event.timestamp
        guard !isShowing, case .hidden = reveal.phase else { return }
        // The window whose sidebar comes out: the last one in front, or, after that one closed, the one Zigzag would
        // have brought forward.
        if target == nil { target = WindowManager.shared.keyController }
        guard let target, EdgeSidebarLayout.canShow(appIsActive: isBrowserInFront) else { return }
        let point = NSEvent.mouseLocation
        guard let (zone, local, _) = zone(at: point), zone.opens(at: local) else { return }
        met(at: event.timestamp)
    }

    /// The screen-sized edge under the pointer: the screen's visible frame stands in for a window's bounds.
    private func zone(at point: NSPoint) -> (SidebarEdgeZone, NSPoint, NSRect)? {
        guard let target else { return nil }
        let frames = NSScreen.screens.map(\.visibleFrame)
        guard let index = EdgeSidebarLayout.screen(containing: point, in: frames) else { return nil }
        let visible = frames[index]
        return (zone(in: visible)!, EdgeSidebarLayout.point(point, in: visible), visible)
    }

    private func zone(in visible: NSRect) -> SidebarEdgeZone? {
        guard let target else { return nil }
        // The panel is the card and the gutter it stands off the screen's edge by: the card's inner edge is the panel's.
        return EdgeSidebarLayout.zone(in: visible, width: target.edgeSidebarWidth + Tokens.Metric.cardInset, onRight: target.edgeSidebarOnRight)
    }

    private func met(at time: TimeInterval) {
        guard target != nil else { return }
        reveal.met(at: time, speed: lastMoveSpeed)
        guard decideTimer == nil else { return }
        // A breath after meeting it, as at the window's edge: brushing past leaves it be.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.decide() }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        decideTimer = timer
    }

    private func decide() {
        let point = NSEvent.mouseLocation
        guard let (zone, local, visible) = zone(at: point) else { return stopDeciding(dismiss: true) }
        switch reveal.decide(at: local, time: ProcessInfo.processInfo.systemUptime, in: zone) {
        case .some(true):
            stopDeciding(dismiss: false)
            show(on: visible)
        case .some(false):
            stopDeciding(dismiss: true)
        case .none:
            break
        }
    }

    private func stopDeciding(dismiss: Bool) {
        decideTimer?.invalidate()
        decideTimer = nil
        if dismiss { reveal.dismiss() }
    }

    private func startFollowing() {
        followTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.follow() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func follow() {
        guard isShowing, let visible = shownScreen, let zone = zone(in: visible) else { return }
        // The page is attached beside the panel, or the preview card is out: the pointer is over them, not the panel,
        // and the panel stays.
        guard !holdsForPeek, !EdgePeekPreview.shared.isVisible else { return }
        // Zigzag came forward, or the window's sidebar came out: the panel has nothing left to show.
        guard let target, EdgeSidebarLayout.canShow(appIsActive: isBrowserInFront) else {
            hide()
            return
        }
        let point = EdgeSidebarLayout.point(NSEvent.mouseLocation, in: visible)
        // A pressed button holds it out, as a drag from the panel does. So does a menu opened from it, whose tracking
        // (system menus) or open panel (MenuPanel) runs while the pointer is over it.
        let held = NSEvent.pressedMouseButtons != 0
            || RunLoop.current.currentMode == .eventTracking
            || MenuPanel.current != nil
            || isCommandBarOpen
        if reveal.follow(at: point, time: ProcessInfo.processInfo.systemUptime, in: zone, held: held) {
            hide()
        }
    }

    // MARK: The panel

    // MARK: The command bar

    /// The surface the browser's command bar draws in while the panel is in use: the screen the panel is on.
    var commandBarOverlay: NSView? { isCommandBarOpen ? commandBarPopup?.overlay : nil }
    var commandBarPageFrame: NSRect? {
        guard isCommandBarOpen, let popup = commandBarPopup else { return nil }
        return NSRect(origin: .zero, size: popup.frame.size)
    }

    /// New Tab from the panel — ⌘T or its row: the browser's own bar, over the screen, not in the window behind it.
    func newTabInPlace() {
        guard isShowing, !isCommandBarOpen, let target, let visible = shownScreen else { return }
        let popup = commandBarPopup ?? makeCommandBarPopup()
        popup.setFrame(visible, display: true)
        popup.overlay.frame = NSRect(origin: .zero, size: visible.size)
        isCommandBarOpen = true
        popup.orderFrontRegardless()
        target.showEdgeCommandBar()
    }

    /// The bar's field is in the popup, and the popup takes the keyboard for it.
    func focusCommandBar(_ field: NSTextField) {
        guard isCommandBarOpen, let popup = commandBarPopup else { return }
        popup.makeKeyAndOrderFront(nil)
        popup.makeFirstResponder(field)
    }

    /// The bar has finished leaving: the popup goes, and the panel (still out) takes the keyboard back.
    func commandBarDidHide() {
        guard isCommandBarOpen else { return }
        isCommandBarOpen = false
        commandBarPopup?.orderOut(nil)
        if EdgePeek.shared.isVisible { EdgePeek.shared.makeKey() } else if isShowing { panel?.makeKey() }
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
        commandBarPopup = popup
        return popup
    }

    private func show(on visible: NSRect) {
        guard let target, EdgeSidebarLayout.canShow(appIsActive: isBrowserInFront) else { return }
        let (sidebar, container) = target.edgeSidebarForDisplay()
        target.prepareEdgeSidebar()
        let onRight = target.edgeSidebarOnRight
        lastPanelWasOnRight = onRight
        // The card keeps the window's sidebar's width; the panel is that and the gutter it stands off the edge by.
        let width = target.edgeSidebarWidth + Tokens.Metric.cardInset
        let panel = panel ?? makePanel()
        guard let host else { return }
        sidebar.isOnRight = onRight
        let look = target.edgeSidebarLook
        container.isFloating = true
        container.tint = look.tint
        container.gradient = look.gradient
        container.grain = look.grain
        container.windowGlass = look.glass
        host.onRight = onRight
        host.set(container)

        generation += 1
        panel.setFrame(EdgeSidebarLayout.frame(in: visible, width: width, onRight: onRight), display: true)
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.placeCard()
        shownScreen = visible
        isShowing = true
        panel.orderFrontRegardless()
        // The panel has the keyboard while it's out: ⌘T and typing work there, over the app in front.
        panel.makeKey()

        // The card slides in from beyond the screen's edge, as the window's hidden sidebar does.
        let card = host.cardFrame
        let start = card.offsetBy(dx: onRight ? card.width + host.inset : -(card.width + host.inset), dy: 0)
        Tokens.Motion.withoutAnimation { container.frame = card }
        let duration = Tokens.Motion.slide(container, fromOffsetX: start.minX - card.minX, curve: Tokens.Motion.edgeSlide)
        reveal.shown(true, at: ProcessInfo.processInfo.systemUptime, settling: duration)
        startFollowing()
    }

    /// Downloads from the panel: the list in the panel's window, over the mirror's lane, not in the window behind.
    func showDownloads(from anchor: NSView, in controller: BrowserWindowController) {
        guard isShowing, let host, let target else { return }
        let (sidebar, _) = target.edgeSidebarForDisplay()
        DownloadsPanel.show(from: anchor, in: controller, host: host, lane: host.cardFrame, receding: [sidebar.list])
    }

    /// Puts the panel away. Without the slide for a pick, so its window can come forward at once.
    func hide(animated: Bool = true, force: Bool = false) {
        // The preview is the closed lens: it goes whenever the panel goes.
        EdgePeekPreview.shared.hide()
        // The lens and the sidebar are one session: the lens collapses first, and only then does the sidebar follow.
        // A stop or a closed window is the exception: there is nothing left to follow.
        guard force || !EdgeLensPolicy.blocksSidebarHide(lensOpen: EdgePeek.shared.isVisible) else { return }
        // The panel's popout is its page: it goes with the panel, however the panel goes.
        target?.edgePopoutDidDismiss()
        stopDeciding(dismiss: true)
        holdsForPeek = false
        // The bar and the downloads list open over the screen go with the panel.
        if isCommandBarOpen, let target { target.commandBar.dismiss(restoringFocus: false) }
        if let host, DownloadsPanel.isOpen(in: host.window) { DownloadsPanel.closeCurrent() }
        followTimer?.invalidate()
        followTimer = nil
        guard isShowing else { return }
        isShowing = false
        shownScreen = nil
        reveal.shown(false, at: ProcessInfo.processInfo.systemUptime, settling: 0)
        generation += 1
        let current = generation
        guard let panel = panel, let host, let container = host.container else {
            self.panel?.orderOut(nil)
            return
        }
        guard animated else { panel.orderOut(nil); return }
        let card = host.cardFrame
        let onRight = target?.edgeSidebarOnRight ?? lastPanelWasOnRight
        let out = card.offsetBy(dx: onRight ? card.width + host.inset : -(card.width + host.inset), dy: 0)
        Tokens.Motion.withoutAnimation { container.frame = out }
        let duration = Tokens.Motion.slide(container, fromOffsetX: card.minX - out.minX, curve: Tokens.Motion.edgeTuck)
        guard duration > 0 else { panel.orderOut(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> EdgeSidebarPanel {
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above other apps' windows, on every space and over full-screen apps; never the key window, never in ⌘`.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = EdgeSidebarHost()
        panel.contentView = host
        host.overlay.frame = host.bounds
        host.overlay.autoresizingMask = [.width, .height]
        host.addSubview(host.overlay)
        self.host = host
        self.panel = panel
        return panel
    }
}

/// The edge sidebar's panel: it comes out over another app without taking the front; it takes the keyboard while it's
/// out, so ⌘T and typing in it work there, and gives it back when it goes.
final class EdgeSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: the floating sidebar card, set off the screen's edge as it is from a window's, and flush at
/// the panel's other edge, which is the page's side. The panel is the card and that gutter, so the card is what shows.
final class EdgeSidebarHost: NSView {
    private(set) weak var container: SidebarContainer?
    /// Where the site panel and other floating pieces sit, above the card.
    let overlay = PassthroughView()
    let inset = Tokens.Metric.cardInset
    /// The panel is along the screen's right edge: its gutter is on the right.
    var onRight = false { didSet { placeCard() } }
    var cardFrame: NSRect {
        NSRect(x: onRight ? 0 : inset, y: inset, width: max(0, bounds.width - inset), height: max(0, bounds.height - inset * 2))
    }

    override var isFlipped: Bool { true }

    func set(_ container: SidebarContainer) {
        self.container?.removeFromSuperview()
        self.container = container
        container.autoresizingMask = []
        addSubview(container)
        addSubview(overlay, positioned: .above, relativeTo: container)
        placeCard()
    }

    func placeCard() {
        container?.frame = cardFrame
        overlay.frame = bounds
    }

    /// File › New Tab (⌘T) with the panel key: the browser's own bar, in place over the screen.
    @objc func newTab(_ sender: Any?) { EdgeSidebar.shared.newTabInPlace() }

    /// Esc while the panel has the keyboard puts it away, as it closes anything else opened to use for a moment. A
    /// menu or the command bar is the first responder while either is up, so it closes itself first instead.
    override func cancelOperation(_ sender: Any?) { EdgeSidebar.shared.hide() }

    /// A click outside the card, in the panel's gutter, puts it away; clicks on the card belong to the sidebar in it
    /// (its own blank space does the same).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if container?.frame.contains(point) != true { EdgeSidebar.shared.hide(); return }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
            EdgeSidebar.shared.newTabInPlace()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The edge panel as a place for Site Controls: the page is the one the popout is showing, and the panel opens over
/// the sidebar card instead of bringing the browser window forward.
@MainActor final class EdgeSitePanelHost: SitePanelPageHost {
    let tab: Tab
    let overlay: PassthroughView
    private let hostWindow: NSWindow?

    init(tab: Tab, overlay: PassthroughView, window: NSWindow? = nil) {
        self.tab = tab
        self.overlay = overlay
        self.hostWindow = window
    }

    var window: NSWindow? { hostWindow ?? EdgeSidebar.shared.panelWindow }
    var listsExtensions: Bool { false }

    func copyPageURL(_ sender: Any?) {
        guard let url = tab.url else { return }
        CleanLink.write(url, title: tab.displayTitle)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", over: overlay, area: overlay.bounds)
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
    let overlay = NSView()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

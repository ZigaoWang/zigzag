import AppKit

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
        // A pick brings Zigzag forward, and so does anything else: the panel has done its job.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(animated: false) }
            })
        }
        if let key = WindowManager.shared.keyController, !key.tabManager.isPrivate { target = key }
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
        // The menu's room goes with the menu.
        if MenuPanel.current == nil, panel.frame != cardPanelFrame { panel.setFrame(cardPanelFrame, display: true) }
        if held || EdgeSidebarLayout.keeps(at: NSEvent.mouseLocation, panel: cardPanelFrame) {
            leftAt = nil
            return
        }
        guard let leftAt else { leftAt = now; return }
        if now - leftAt > EdgeSidebarLayout.leaveDelay { hide() }
    }

    // MARK: The panel

    private func show(on visible: NSRect, for target: BrowserWindowController) {
        let container = target.prepareEdgeSidebar()
        let onRight = target.edgeSidebarOnRight
        let panel = panel ?? makePanel()
        guard let host else { return }
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
        guard isShowing, let panel else { return }
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
        // Esc puts it away, unless a field is being edited.
        if event.type == .keyDown, event.keyCode == 53, !(firstResponder is NSTextView), MenuPanel.current == nil {
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

    override var isFlipped: Bool { true }

    /// Against the screen's edge, whatever room beside it a menu has.
    var cardFrame: NSRect {
        NSRect(x: onRight ? bounds.width - inset - cardWidth : inset, y: inset, width: cardWidth,
               height: max(0, bounds.height - inset * 2))
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
        container?.frame = cardFrame
    }

    override func layout() {
        super.layout()
        placeCard()
    }

    /// A click beside the card puts the panel away.
    override func mouseDown(with event: NSEvent) {
        if container?.frame.contains(convert(event.locationInWindow, from: nil)) != true {
            EdgeSidebar.shared.hide()
            return
        }
        super.mouseDown(with: event)
    }
}

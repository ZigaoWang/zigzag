import AppKit
import WebKit

/// A window controller whose Back and Forward list their pages for a held side button (#515).
@MainActor protocol SideButtonHistory: AnyObject {
    func sideButtonHistory(back: Bool) -> NSMenu?
}

/// A window with no title bar and no toolbar. The traffic lights live in the sidebar's top row.
final class BrowserWindow: NSWindow {
    /// Where the traffic lights should sit, in window coordinates (top-left of the close button), or nil to hide them.
    var trafficLightOrigin: NSPoint? { didSet { layoutTrafficLights() } }
    /// Intercepts events before the web view sees them (Control+Tab, the back and forward mouse buttons).
    var eventInterceptor: ((NSEvent) -> Bool)?
    /// For Select All after a sidebar click (#302).
    weak var sidebar: SidebarView?
    /// The last click was in the sidebar with no typing since: Select All selects its tabs, as in Arc and Finder
    /// (#302).
    private(set) var sidebarHasTheClick = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        tabbingMode = .disallowed
        isReleasedWhenClosed = false
        collectionBehavior.insert(.fullScreenPrimary)
        minSize = Tokens.Metric.windowMinSize
        animationBehavior = .documentWindow
        titlebarSeparatorStyle = .none
        // Rows and buttons come and go; Tab (with Full Keyboard Access) follows whatever is on screen now.
        autorecalculatesKeyViewLoop = true
        // AppKit resets the buttons on every title bar layout; move them back.
        TrafficLightKeeper.install(in: self) { [weak self] in self?.layoutTrafficLights() }
    }

    private var buttonSpacing: CGFloat?

    override var title: String {
        didSet { if title != oldValue { layoutTrafficLights() } }
    }

    /// Parked for AI apps (Headless.park): stays off screen, never key or main.
    var isParked = false
    /// A Mini docked over a page: a borderless child of the browser window. It takes the keyboard when clicked, but it
    /// is never the window you are "in" for the Window menu or ⌘`, and never a main window of its own.
    var isOverlayChild = false

    #if DEBUG
    /// A test copy started with `ZIGZAG_ORDER_BACK=1` puts its windows behind every other app's, never in front.
    static let ordersBack = ProcessInfo.processInfo.environment["ZIGZAG_ORDER_BACK"] == "1"
    override func makeKeyAndOrderFront(_ sender: Any?) { Self.ordersBack ? orderBack(sender) : super.makeKeyAndOrderFront(sender) }
    override func orderFront(_ sender: Any?) { Self.ordersBack ? orderBack(sender) : super.orderFront(sender) }
    override func orderFrontRegardless() { Self.ordersBack ? orderBack(nil) : super.orderFrontRegardless() }
    #endif

    override var canBecomeKey: Bool { !isParked }
    override var canBecomeMain: Bool { !isParked && !isOverlayChild }

    /// A Mini docked over a page is borderless and has no close button for AppKit to press, so ⌘W, ⇧⌘W, a page's
    /// `window.close()` and an extension closing it all take this one way out.
    override func performClose(_ sender: Any?) {
        if let mini = windowController as? MiniWindowController, mini.isDockedInPage {
            mini.closeInPage()
            return
        }
        super.performClose(sender)
    }

    /// AppKit turns Close Window off for a window with no close button; a docked Mini still closes (`performClose`).
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performClose(_:)), (windowController as? MiniWindowController)?.isDockedInPage == true {
            return true
        }
        return super.validateMenuItem(item)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        isParked ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// Fingers skip `sendEvent`; the whole frame is watched for them (`TouchPress`).
    override var contentView: NSView? {
        didSet { TouchPress.watch(self) }
    }

    /// AppKit's drag by an empty space stays off in full screen (#483).
    override var isMovableByWindowBackground: Bool {
        get { super.isMovableByWindowBackground && dragMovesWindow }
        set { super.isMovableByWindowBackground = newValue }
    }

    /// Browser shortcuts win over the page: the menu bar sees key equivalents before the web view does.
    /// The last ⌘← or ⌘→ answered, to know it when WebKit hands it back.
    private var lastArrow: (timestamp: TimeInterval, keyCode: UInt16)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Z / ⇧⌘Z: the sidebar's undo, unless you were just typing on the page or in a field.
        // Only the four modifier keys count: arrow keys always carry .function and .numericPad, and Caps Lock may be
        // on, so comparing all of the flags would never match and the guards below would never run.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃Tab often comes this way instead of through sendEvent: once a page has the focus, AppKit offers it as a key
        // equivalent first, and the page would take it.
        if event.keyCode == 48, mods.contains(.control), let controller = windowController as? BrowserWindowController,
           controller.switcher.handle(event) {
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z", mods == .command || mods == [.command, .shift] {
            // On a page, the page hears it first, as in Safari and Chrome: web apps (Sheets, Docs, Figma) undo their own
            // document on ⌘Z. One that lets it pass gets it back from WebKit, and then it's Zigzag's: the sidebar's
            // undo if that was the last thing done, else the menu's Undo for what you typed.
            if let view = firstResponder as? NSView, Self.isInPage(view), super.performKeyEquivalent(with: event) { return true }
            if let controller = windowController as? BrowserWindowController, controller.handleUndoKey(redo: mods.contains(.shift)) {
                return true
            }
        }
        // ⌘← / ⌘→ move the cursor while you're typing; only away from a text field do they mean Back and Forward.
        // The key goes to the field or page here and is taken: let through, the menu bar would get it next, and its
        // Back on the same keys would go back from inside a text box.
        if mods == .command, event.keyCode == 123 || event.keyCode == 124 {
            // A key the page left alone comes back here a second time: it was answered the first time.
            if event.timestamp == lastArrow?.timestamp, event.keyCode == lastArrow?.keyCode { return true }
            lastArrow = (event.timestamp, event.keyCode)
            if let text = firstResponder as? NSText {
                text.keyDown(with: event)
                return true
            }
            if let webView = firstResponder as? WKWebView, let controller = windowController as? BrowserWindowController {
                webView.keyDown(with: event)
                let back = event.keyCode == 123
                // Typing anywhere in the page counts: inside a web component (its shadow root), and inside a frame,
                // where many editors live and the page sees only the frame. A focused button or checkbox doesn't.
                let editing = """
                    (() => {
                      let e = document.activeElement;
                      while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
                      if (!e) return false;
                      if (e.isContentEditable || /^(textarea|select|iframe|frame)$/i.test(e.tagName)) return true;
                      return e.tagName === 'INPUT' && !/^(button|submit|reset|checkbox|radio|range|color|file|image|hidden)$/i.test(e.type);
                    })()
                    """
                webView.runOwnScript(editing) { [weak controller] answer in
                    let result = try? answer.get()
                    MainActor.assumeIsolated {
                        guard (result as? Bool) != true, let controller else { return }
                        back ? controller.goBack(nil) : controller.goForward(nil)
                    }
                }
                return true
            }
        }
        // A page's own shortcuts come first, as in Safari and Chrome: ⌘A and ⌘B in Google Docs, ⌘K in Slack, Linear
        // and Notion, ⌘S in GitHub's editor, ⌘D in a design tool. Only the browser's own keys (tabs, windows, the
        // address, reload, quitting) stay Zigzag's whatever the page wants, by what they do, so a shortcut you
        // changed in Settings › Shortcuts stays the browser's on its new keys. When the page lets a key pass, WebKit
        // sends it again and the menu takes it.
        if mods.contains(.command), let view = firstResponder as? NSView, Self.isInPage(view),
           !Self.browserKeeps(event, in: NSApp.mainMenu) {
            return super.performKeyEquivalent(with: event)
        }

        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// What the browser keeps for itself whatever a page wants: tabs, windows, spaces, the address, reload and stop,
    /// quitting and hiding, the sidebar and the tab overview, and Zigzag's own windows. Everything else a page may use
    /// for its document first, as in Safari and Chrome.
    static let browserActions: Set<String> = [
        "showSettings:", "showPasswords:", "hide:", "hideOtherApplications:", "terminate:", "quitFromMenu:",
        "newTab:", "newWindow:", "newPrivateWindow:", "openLocation:", "closeTab:", "closeOtherTabs:", "performClose:",
        "reopenClosedTab:", "selectNextTab:", "selectPreviousTab:", "selectTabByNumber:",
        "nextSpace:", "previousSpace:", "selectSpaceByNumber:", "showSpaceSwitcher:", "newSpace:", "reloadPage:", "reloadPageFromOrigin:", "stopLoading:",
        "performMiniaturize:", "toggleFullScreen:", "toggleBrowserSidebar:", "toggleDeskView:", "showWebInspector:",
        "showDownloads:", "showHistory:", "hideWebApp:", "quitWebApp:",
        // ⇧⌘C copies the page's link, as in Arc, even where the page has its own (GitHub copies a file's raw text).
        "copyPageURL:", "copyPageURLAsMarkdown:",
    ]

    /// Whether the menu item these keys belong to is one the browser keeps (`browserActions`). Keys no item has are
    /// the page's.
    static func browserKeeps(_ event: NSEvent, in menu: NSMenu?) -> Bool {
        guard let menu, let pressed = Shortcuts.combo(from: event) else { return false }
        func combo(of item: NSMenuItem) -> Shortcuts.Combo? {
            guard !item.keyEquivalent.isEmpty else { return nil }
            var key = item.keyEquivalent
            var flags = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            // An uppercase letter means ⇧, as a menu reads it.
            if key.count == 1, key.lowercased() != key { key = key.lowercased(); flags.insert(.shift) }
            return Shortcuts.Combo(key: key, modifiers: flags.rawValue)
        }
        func walk(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let found = walk(sub) { return found }
                if combo(of: item) == pressed { return item }
            }
            return nil
        }
        guard let item = walk(menu), let action = item.action else { return false }
        return browserActions.contains(NSStringFromSelector(action))
    }

    /// A text field or editor becoming first responder takes ⌘A back from the sidebar.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSText || responder is NSTextField { sidebarHasTheClick = false }
        return super.makeFirstResponder(responder)
    }

    /// Select All with no page or field to take it after a sidebar click selects the sidebar's tabs. False otherwise.
    func selectAllInSidebar() -> Bool {
        guard sidebarHasTheClick, let sidebar, !sidebar.isHiddenOrHasHiddenAncestor else { return false }
        sidebar.list.selectAll(nil)
        return true
    }

    private static func isInPage(_ view: NSView) -> Bool {
        var view: NSView? = view
        while let current = view {
            if current is WKWebView || current is ZigzagPDFView { return true }
            view = current.superview
        }
        return false
    }

    /// A key nothing took (an arrow at a page's end, Return on picked sidebar rows) goes by quietly, as in Safari and
    /// Chrome: AppKit's beep there says nothing useful. A ⌘ shortcut that matches nothing still beeps, as on any Mac.
    /// The window's controller is the last to be asked, after the window, so it asks this too (`QuietKeys`).
    override func noResponder(for eventSelector: Selector) {
        if QuietKeys.passQuietly(eventSelector, currentEvent) { return }
        super.noResponder(for: eventSelector)
    }

    /// Set when Delete closes picked sidebar rows: the rest of that press, held down, goes nowhere (#375).
    var holdsBackDeleteRepeats = false

    /// Whether a key is the rest of a Delete press that closed picked rows, and whether to keep holding them back.
    nonisolated static func holdsBack(_ type: NSEvent.EventType, keyCode: UInt16, isRepeat: Bool, holding: Bool) -> (drop: Bool, keep: Bool) {
        guard holding else { return (false, false) }
        switch type {
        case .keyDown: return isRepeat && SidebarListView.isDeleteKey(keyCode) ? (true, true) : (false, false)
        case .keyUp: return SidebarListView.isDeleteKey(keyCode) ? (true, false) : (false, true)
        default: return (false, true)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if holdsBackDeleteRepeats, event.type == .keyDown || event.type == .keyUp {
            let (drop, keep) = Self.holdsBack(event.type, keyCode: event.keyCode, isRepeat: event.isARepeat, holding: true)
            holdsBackDeleteRepeats = keep
            if drop { return }
        }
        if event.type == .keyDown, !event.modifierFlags.contains(.command), firstResponder is WKWebView {
            UndoClock.lastPageEdit = Date()
            UndoClock.lastPageInput = Date()
            sidebarHasTheClick = false
        }
        if dropsSpentClick(event) { return }
        if event.type == .leftMouseDown {
            lastLeftMouseDown = ProcessInfo.processInfo.systemUptime
            notePress(at: event.locationInWindow)
        }
        if let eventInterceptor, eventInterceptor(event) { return }
        if let side = SideButton(event.type, button: event.buttonNumber) {
            // Over a docked Mini that is ordered out under the chrome, the button is the Mini's own Back and Forward.
            if sideHeldMenu == nil, let controller = windowController as? BrowserWindowController,
               controller.peekHandlesSideButton(side, at: event.locationInWindow) { return }
            handleSideButton(side, event)
            return
        }
        if event.type == .otherMouseDragged, let sideHeldMenu, MenuPanel.current === sideHeldMenu {
            sideHeldMenu.track(windowPoint: event.locationInWindow)
            return
        }
        if movesWindow(for: event) { return }
        if event.type == .scrollWheel, pdfView(at: event.locationInWindow)?.takesSwipe(event) == true { return }
        if routeTitlebarEvent(event) { return }
        if swallowsPanelPress(event) { return }
        super.sendEvent(event)
    }

    /// AppKit's click from a finger whose tap already did its one thing, and the window's tap from it (`TouchPress`).
    private var spentClick = TouchSwallow()
    private var spentTap = TouchSwallow()
    private var spentAt: TimeInterval = 0
    /// The click dropped went down: its drags and lift go too.
    private var dropsClick = false

    /// The finger at `points` (window coordinates) has done what it does: the click AppKit makes from it, unless
    /// that's what is running now (`clickToCome` false), and its tap go nowhere else.
    func spendTouch(at points: [NSPoint], clickToCome: Bool = true) {
        spentAt = ProcessInfo.processInfo.systemUptime
        if clickToCome { spentClick.arm(at: points) }
        spentTap.arm(at: points)
    }

    /// A finger's click on chrome did its tap's one thing: the tap that follows goes nowhere.
    func spendFingerClick(_ event: NSEvent?) {
        guard let event, event.windowNumber == windowNumber, isFingerClick(event) else { return }
        spendTouch(at: [event.locationInWindow], clickToCome: false)
    }

    private func isFingerClick(_ event: NSEvent) -> Bool {
        TouchPress.fingerDown || TouchDoubleTap.isFromFinger(event.timestamp, landedAt: TouchPress.landedAt)
            || ProcessInfo.processInfo.systemUptime - spentAt < 0.3
    }

    private func dropsSpentClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            dropsClick = isFingerClick(event) && spentClick.takes(at: event.locationInWindow)
            if dropsClick { TouchLog.note("dropped a spent click at \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))") }
            return dropsClick
        case .leftMouseDragged:
            return dropsClick
        case .leftMouseUp:
            defer { dropsClick = false }
            return dropsClick
        default:
            return false
        }
    }

    /// A press at `point`: whether the sidebar has the click, and a click in a page for its own undo.
    private func notePress(at point: NSPoint) {
        let hit = contentView?.hitTest(point)
        sidebarHasTheClick = sidebar.map { hit?.isDescendant(of: $0) == true } ?? false
        // A click in a page counts too: a web app (Figma, Docs) keeps its own undo, which a click can change.
        if hit.map(Self.isInPage) == true {
            UndoClock.lastPageEdit = Date()
            UndoClock.lastPageInput = Date()
        }
    }

    /// The side button held down now, and where it went down, while its hold runs (#515).
    private var sideHold: (back: Bool, point: NSPoint)?
    private var sideHoldTimer: Timer?
    /// The list a held side button opened, while that button is still down.
    private(set) weak var sideHeldMenu: MenuPanel?

    /// A quick press goes one step on release; held, the pages that way open at the pointer, as Back's do (#515).
    private func handleSideButton(_ side: SideButton, _ event: NSEvent) {
        sideHoldTimer?.invalidate()
        sideHoldTimer = nil
        guard side != .press else {
            sideHold = (event.buttonNumber == 3, event.locationInWindow)
            sideHeldMenu = nil
            let timer = Timer(timeInterval: InteractiveView.holdMenuDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.sideHoldElapsed() }
            }
            RunLoop.main.add(timer, forMode: .common)
            sideHoldTimer = timer
            return
        }
        sideHold = nil
        if let sideHeldMenu {
            self.sideHeldMenu = nil
            // Let go over a page, it's chosen; anywhere else the list stays open to click.
            if MenuPanel.current === sideHeldMenu { sideHeldMenu.chooseTracked(windowPoint: event.locationInWindow) }
            return
        }
        if let action = side.action { windowController?.tryToPerform(action, with: nil) }
    }

    /// Still held once the hold is up: the window's pages that way open under the pointer.
    func sideHoldElapsed() {
        sideHoldTimer?.invalidate()
        sideHoldTimer = nil
        guard let (back, point) = sideHold, MenuPanel.current == nil, let anchor = contentView,
              let menu = (windowController as? SideButtonHistory)?.sideButtonHistory(back: back) else { return }
        let entries = MenuPanel.entries(from: menu)
        guard !entries.isEmpty else { return }
        sideHeldMenu = MenuPanel.show(entries, from: anchor, placement: .at(point))
    }

    /// Side buttons go back and forward in every page window, as in Chrome; on release, with the press taken too (#345).
    enum SideButton: Equatable {
        case press, back, forward

        init?(_ type: NSEvent.EventType, button: Int) {
            guard type == .otherMouseDown || type == .otherMouseUp, button == 3 || button == 4 else { return nil }
            self = type == .otherMouseDown ? .press : button == 3 ? .back : .forward
        }

        /// The window controller's action: each window's own Back and Forward.
        var action: Selector? {
            switch self {
            case .press: nil
            case .back: #selector(MiniWindowController.goBack(_:))
            case .forward: #selector(MiniWindowController.goForward(_:))
            }
        }
    }

    /// A press on a floating panel's own surface (a gap between its rows, a label, its corner) stays the panel's: the
    /// window is movable by its background, so AppKit would otherwise take it as a drag of the window or a double-click
    /// on the title bar, and nothing behind the panel ever hears it (#216).
    private func swallowsPanelPress(_ event: NSEvent) -> Bool {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let content = contentView,
              let frame = content.superview else { return false }
        guard let panel = FloatingPanelView.bareSurfacePanel(frame.hitTest(frame.convert(event.locationInWindow, from: nil))) else { return false }
        if event.type == .leftMouseDown { panel.onBarePress?(event) }
        return true
    }

    // MARK: Moving the window from the page

    /// ⌥⌘ held anywhere in the window (a page, Settings, the sidebar, an empty space): a drag moves the window, as a
    /// title bar would, since a borderless page leaves nothing else to hold. Both keys sit side by side, and no page,
    /// control or macOS gesture uses them for dragging.
    static func isMoveChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .control, .shift]) == [.command, .option]
    }

    private var showsMoveHand = false

    private func movesWindow(for event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged, .mouseMoved:
            updateMoveHand(flags: event.modifierFlags, at: event.locationInWindow)
            return false
        case .leftMouseDown:
            guard Self.isMoveChord(event.modifierFlags), dragMovesWindow, isInContent(event.locationInWindow) else { return false }
            // Twice, as on a title bar: the window zooms.
            if event.clickCount == 2 { performZoom(nil) } else { trackMove(from: event) }
            return true
        default:
            return false
        }
    }

    /// Moves the window with the pointer until the button comes up. Not `performDrag`: the system's drag sees ⌥
    /// held and turns the move into window tiling, which only goes left or right.
    private func trackMove(from down: NSEvent) {
        let start = NSEvent.mouseLocation, origin = frame.origin
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
        }
    }

    /// Anywhere in the window's content, whatever is under the pointer.
    private func isInContent(_ point: NSPoint) -> Bool {
        guard let content = contentView else { return false }
        return content.bounds.contains(content.convert(point, from: nil))
    }

    /// The open hand while ⌥⌘ is held over the window, so it's clear a drag will move the window.
    private func updateMoveHand(flags: NSEvent.ModifierFlags, at point: NSPoint) {
        let wanted = isKeyWindow && Self.isMoveChord(flags) && dragMovesWindow && isInContent(point)
        guard wanted != showsMoveHand else { if wanted { NSCursor.openHand.set() }; return }
        showsMoveHand = wanted
        if wanted { NSCursor.openHand.push() } else { NSCursor.pop() }
    }

    /// The PDF under the pointer, when one is: its scrolls go to its swipe before the pages' scroll view.
    private func pdfView(at point: NSPoint) -> ZigzagPDFView? {
        // No viewer in this window: no hit test for every scroll.
        guard ZigzagPDFView.isShown(in: self) else { return nil }
        var view = contentView?.hitTest(contentView?.convert(point, from: nil) ?? .zero)
        while let current = view, !(current is ZigzagPDFView) { view = current.superview }
        return view as? ZigzagPDFView
    }

    /// Our controls sit in the title bar area, where AppKit sends presses to the title bar first, so presses on them
    /// are delivered directly.
    private weak var pressTarget: NSView?
    /// When a press last went to one of them that way, so a tap there isn't clicked twice.
    private var lastTitlebarPress: TimeInterval = 0
    /// When the window last got a left mouse-down, so a finger's tap can tell whether AppKit's click came.
    private var lastLeftMouseDown: TimeInterval = 0
    /// A finger's last tap on the strip's empty space, for a double tap.
    private var lastTitlebarTap: (time: TimeInterval, point: NSPoint)?

    /// A finger's two taps on the title bar strip's empty space. AppKit's title bar is what a finger there lands on,
    /// so it's watched there; the window's own watch never hears those touches.
    private(set) var titlebarDoubleTap: NSClickGestureRecognizer?
    private let titlebarTouchOnly = TouchOnly()

    /// On the title bar AppKit has now, again after it makes a new one (full screen).
    func attachTitlebarDoubleTap() {
        guard TouchGestures.isAvailable, let container = standardWindowButton(.closeButton)?.superview?.superview,
              container.window === self, titlebarDoubleTap?.view !== container else { return }
        let tap = titlebarDoubleTap ?? {
            let tap = NSClickGestureRecognizer(target: self, action: #selector(titlebarDoubleTapped(_:)))
            tap.numberOfClicksRequired = 2
            TouchGestures.configure(tap, titlebarTouchOnly)
            titlebarTouchOnly.simultaneous = true
            titlebarTouchOnly.accepts = { [weak self, weak tap] point in
                guard let self, let view = tap?.view else { return false }
                return self.isOnEmptyTitlebar(view.convert(point, to: nil))
            }
            titlebarDoubleTap = tap
            return tap
        }()
        tap.view?.removeGestureRecognizer(tap)
        container.addGestureRecognizer(tap)
    }

    @objc private func titlebarDoubleTapped(_ tap: NSClickGestureRecognizer) {
        titlebarDoubleTapped(at: tap.location(in: nil))
    }

    /// Two taps at `point` (window coordinates) on the strip: what a double-click there does.
    func titlebarDoubleTapped(at point: NSPoint) {
        guard isOnEmptyTitlebar(point), let event = TouchPress.mouseDown(at: point, in: self) else { return }
        lastTitlebarTap = nil
        titleBarMouseDown(event, clicks: 2)
    }

    /// Whether `point` is on the title bar strip, off the window's own buttons and ours.
    func isOnEmptyTitlebar(_ point: NSPoint) -> Bool {
        guard let container = standardWindowButton(.closeButton)?.superview?.superview, container.frame.contains(point) else { return false }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = standardWindowButton(button), !b.isHidden, b.convert(b.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(point) { return false }
        }
        return control(at: point) == nil && TouchTargets.point(for: point, in: self) == nil
    }

    private func routeTitlebarEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard let target = control(at: event.locationInWindow) else { return false }
            pressTarget = target
            lastTitlebarPress = ProcessInfo.processInfo.systemUptime
            if event.type == .leftMouseDown {
                makeKeyAndOrderFront(nil)
                target.mouseDown(with: event)
            } else if (target as? InteractiveView)?.drawsMenu == true {
                // Zigzag's own menu, which follows the press from here.
                target.rightMouseDown(with: event)
            } else if let menu = target.menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: target)
            }
            return true
        case .leftMouseDragged:
            guard let target = pressTarget else { return false }
            target.mouseDragged(with: event)
            return true
        case .leftMouseUp:
            guard let target = pressTarget else { return false }
            pressTarget = nil
            target.mouseUp(with: event)
            return true
        case .rightMouseDragged:
            guard let target = pressTarget else { return false }
            target.rightMouseDragged(with: event)
            return true
        case .rightMouseUp:
            guard let target = pressTarget else { return false }
            pressTarget = nil
            target.rightMouseUp(with: event)
            return true
        default:
            return false
        }
    }

    /// The control under a point in the title bar strip, if it's one of ours.
    private func control(at point: NSPoint) -> NSView? {
        guard let container = standardWindowButton(.closeButton)?.superview?.superview,
              container.frame.contains(point),
              let content = contentView else { return nil }
        // The system buttons keep their own behavior.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = standardWindowButton(button), !b.isHidden, b.convert(b.bounds, to: nil).contains(point) { return nil }
        }
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        var view = hit
        while let current = view, current !== content {
            if current is InteractiveView { return current }
            view = current.superview
        }
        return nil
    }

    private var buttons: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
    }

    /// Where the window is on its way into or out of full screen, from the controller's notifications (#401).
    var fullScreenPhase = FullScreenPhase.windowed

    /// Hidden while the sidebar is collapsed or sliding; shown in full screen only when AppKit wants them. Left as
    /// they are while AppKit moves them into or out of full screen.
    var trafficLightsHidden = false {
        didSet {
            guard !fullScreenPhase.isMoving else { return }
            buttons.forEach { $0.isHidden = trafficLightsHidden && !styleMask.contains(.fullScreen) }
        }
    }


    /// Moves the system buttons into our top row. AppKit re-lays them out on resize, so this runs often.
    func layoutTrafficLights() {
        attachTitlebarDoubleTap()
        guard let origin = trafficLightOrigin else { return }
        // AppKit moves the title bar between the window and the full screen bar meanwhile; resizing it then could
        // leave full screen half made (#401). The controller lays them out once it's done.
        guard !fullScreenPhase.isMoving else { return }
        // In full screen AppKit shows them in the title bar that slides down with the menu bar, flashing them in
        // the wrong place; they stay hidden there, and the sidebar's buttons move into their space.
        // In full screen they belong to the title bar that slides down with the menu bar, where AppKit puts them,
        // so you can always leave full screen. The bar and sidebar keep their room, so they sit beside the app's
        // controls rather than over them.
        guard !styleMask.contains(.fullScreen) else {
            buttons.forEach { if $0.isHidden { $0.isHidden = false } }
            watchFullScreenTitlebar()
            return
        }
        watchFullScreenTitlebar()
        buttonSpacing = placeTrafficLights(at: origin, spacing: buttonSpacing)
    }

    /// Whether the buttons are on screen: always windowed, in full screen only with the menu bar down (#542).
    var trafficLightsOnScreen: Bool { !styleMask.contains(.fullScreen) || fullScreenTitlebarShown }
    /// Called as full screen's title bar comes down with the menu bar or goes back up.
    var onTrafficLightsOnScreenChange: (() -> Void)?
    private var fullScreenTitlebarShown = false
    private var titlebarWatch: [NSObjectProtocol] = []
    private weak var watchedTitlebar: NSView?

    /// Watches full screen's title bar, which AppKit slides down with the menu bar.
    private func watchFullScreenTitlebar() {
        let fullScreen = styleMask.contains(.fullScreen)
        let container = fullScreen ? standardWindowButton(.closeButton)?.superview?.superview : nil
        if container !== watchedTitlebar {
            titlebarWatch.forEach(NotificationCenter.default.removeObserver)
            titlebarWatch = []
            watchedTitlebar = container
            if let container, let titlebarWindow = container.window {
                container.postsFrameChangedNotifications = true
                let center = NotificationCenter.default
                let changed: @Sendable (Notification) -> Void = { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshFullScreenTitlebar() }
                }
                titlebarWatch = [center.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main, using: changed),
                                 center.addObserver(forName: NSWindow.didMoveNotification, object: titlebarWindow, queue: .main, using: changed),
                                 center.addObserver(forName: NSWindow.didResizeNotification, object: titlebarWindow, queue: .main, using: changed),
                                 center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: titlebarWindow, queue: .main, using: changed)]
            }
        }
        refreshFullScreenTitlebar()
    }

    private func refreshFullScreenTitlebar() {
        let shown = watchedTitlebar != nil && Self.isShown(standardWindowButton(.closeButton))
        guard shown != fullScreenTitlebarShown else { return }
        fullScreenTitlebarShown = shown
        onTrafficLightsOnScreenChange?()
    }

    /// Whether any of the button is inside its window and on its screen.
    private static func isShown(_ button: NSButton?) -> Bool {
        guard let button, let window = button.window, window.isVisible, !button.isHidden else { return false }
        let inWindow = button.convert(button.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return inWindow.maxY > 0 && inWindow.minY < (window.contentView?.bounds.height ?? window.frame.height)
            && (window.screen?.frame.intersects(onScreen) ?? true)
    }

    /// A picture of the three buttons, so they can travel with the sidebar while it slides.
    func trafficLightsImage() -> NSImage? {
        guard let close = standardWindowButton(.closeButton), let zoom = standardWindowButton(.zoomButton),
              let titlebar = close.superview, !close.isHidden else { return nil }
        let rect = NSRect(x: close.frame.minX, y: close.frame.minY, width: zoom.frame.maxX - close.frame.minX, height: close.frame.height)
        guard let rep = titlebar.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        titlebar.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    /// Width the traffic lights take up, including their trailing gap. From their spacing once it's measured: read
    /// mid-move (AppKit putting them back at the window's left while they sit by a sidebar on the right), the
    /// buttons' own frames can come out bunched up or reversed.
    var trafficLightsWidth: CGFloat {
        guard let close = standardWindowButton(.closeButton), let zoom = standardWindowButton(.zoomButton) else { return 60 }
        if let buttonSpacing { return buttonSpacing * 2 + close.frame.width }
        let measured = zoom.frame.maxX - close.frame.minX
        return measured > close.frame.width ? measured : 60
    }

    var trafficLightHeight: CGFloat { standardWindowButton(.closeButton)?.frame.height ?? 14 }
}

/// A browser window's way into and out of full screen. Every will is followed by its did or did-fail, and a full
/// screen that doesn't start (or end) gives back the title bar the window had (#401).
enum FullScreenPhase: Equatable {
    case windowed, entering, fullScreen, exiting

    enum Event { case willEnter, didEnter, didFailToEnter, willExit, didExit, didFailToExit }

    func after(_ event: Event) -> FullScreenPhase {
        switch event {
        case .willEnter: .entering
        case .didEnter, .didFailToExit: .fullScreen
        case .willExit: .exiting
        case .didExit, .didFailToEnter: .windowed
        }
    }

    /// AppKit is moving the title bar and its buttons: Zigzag leaves them alone.
    var isMoving: Bool { self == .entering || self == .exiting }
    /// The lights' backing goes as full screen starts to end, before AppKit moves the title bar.
    var dropsTrafficLightBacking: Bool { self == .exiting }
    /// Transparent as everywhere in Zigzag, full screen included: the buttons come down with the menu bar and sit on
    /// the bar above the page, not on a bar of the system's own.
    var titlebarAppearsTransparent: Bool { true }
}

/// Keeps traffic lights where Zigzag places them. AppKit resets them on every title bar layout (title, key window,
/// resize). Moving them back immediately misses the zoom button: AppKit moves it last, and a move from inside its own
/// move notification doesn't stick. Deferring to the next run loop showed it misplaced for a frame. So this view,
/// inside the title bar, moves them again in the layout pass before drawing.
final class TrafficLightKeeper: NSView {
    private let place: () -> Void
    private var isPlacing = false

    /// `place` moves the buttons; called after each AppKit move.
    @discardableResult
    static func install(in window: NSWindow, place: @escaping () -> Void) -> TrafficLightKeeper? {
        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return nil }
        let keeper = TrafficLightKeeper(place: place)
        titlebar.addSubview(keeper)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        for view in buttons + [titlebar.superview].compactMap({ $0 }) {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(keeper, selector: #selector(moved(_:)), name: NSView.frameDidChangeNotification, object: view)
        }
        return keeper
    }

    private init(place: @escaping () -> Void) {
        self.place = place
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func moved(_ note: Notification) {
        guard !isPlacing else { return }
        #if DEBUG
        if let view = note.object as? NSView, let window { TrafficLightWatch.moved(view, in: window) }
        #endif
        placeNow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        placeNow()
    }

    private func placeNow() {
        guard !isPlacing else { return }
        isPlacing = true
        place()
        isPlacing = false
    }
}

extension NSWindow {
    /// Clear to the eye; a wholly clear window with a shadow is redrawn by the window server every frame.
    static let seeThroughBackground = NSColor(white: 0, alpha: 1.0 / 255)

    /// See-through around what it draws; without a shadow it stays wholly clear, so clicks there pass through.
    func setSeeThrough(shadow: Bool) {
        isOpaque = false
        hasShadow = shadow
        backgroundColor = shadow ? Self.seeThroughBackground : .clear
    }

    /// Places the system buttons with the close button's top left at `origin` (window coordinates from the top left).
    /// `spacing` is measured once from AppKit's layout and kept by the caller: read mid-move it can be wrong. Moving
    /// can re-enter, so it's not inout.
    @discardableResult
    func placeTrafficLights(at origin: NSPoint, spacing known: CGFloat?) -> CGFloat? {
        guard let close = standardWindowButton(.closeButton), let titlebar = close.superview else { return known }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        let height = close.frame.height
        var spacing = known
        if spacing == nil, let mini = standardWindowButton(.miniaturizeButton), mini.frame.minX > close.frame.minX {
            spacing = mini.frame.minX - close.frame.minX
        }
        // Grow the title bar so the buttons sit lower than AppKit's default. Pin its top every time: a programmatic
        // resize moves the top without changing the height.
        if let container = titlebar.superview {
            let wanted = NSWindow.titlebarHeight(forTrafficLightsAt: origin, buttonHeight: height)
            var frame = container.frame
            frame.size.height = wanted
            frame.origin.y = (contentView?.frame.height ?? frame.maxY) - wanted
            if container.frame != frame { container.frame = frame }
        }
        let origins = NSWindow.trafficLightOrigins(at: origin, step: spacing ?? 20, buttonHeight: height, titlebarHeight: titlebar.frame.height)
        for (button, point) in zip(buttons, origins) where button.frame.origin != point {
            button.setFrameOrigin(point)
        }
        return spacing
    }

    /// Title bar height for buttons with their top left at `origin`, plus a little room below.
    static func titlebarHeight(forTrafficLightsAt origin: NSPoint, buttonHeight: CGFloat) -> CGFloat {
        origin.y + buttonHeight + Tokens.Space.x1
    }

    /// Close, minimize and zoom origins in a `titlebarHeight` title bar (bottom-up coordinates), close button's top
    /// left at `origin` from the window's top left, `step` apart.
    static func trafficLightOrigins(at origin: NSPoint, step: CGFloat, buttonHeight: CGFloat, titlebarHeight: CGFloat) -> [NSPoint] {
        (0..<3).map { NSPoint(x: origin.x + CGFloat($0) * step, y: titlebarHeight - origin.y - buttonHeight) }
    }

    /// A full screen window stays put, also on its way in or out (#483).
    static func dragMovesWindow(fullScreen: Bool, phase: FullScreenPhase) -> Bool {
        !fullScreen && !phase.isMoving
    }

    var dragMovesWindow: Bool {
        Self.dragMovesWindow(fullScreen: styleMask.contains(.fullScreen),
                             phase: (self as? BrowserWindow)?.fullScreenPhase ?? .windowed)
    }

    /// A press on chrome that stands in for the title bar (the sidebar, the bar above the page): a drag moves the
    /// window, and a double-click zooms it, or does whatever the Mac's title bar double-click is set to do.
    func titleBarMouseDown(_ event: NSEvent, clicks: Int? = nil) {
        guard (clicks ?? TouchDoubleTap.clickCount(for: event)) == 2 else { if dragMovesWindow { performDrag(with: event) }; return }
        // One finger double tap can reach both the title bar strip and the view under it; it acts once.
        let now = ProcessInfo.processInfo.systemUptime
        guard event.clickCount >= 2 || now - TitleBarAction.lastAt > 0.5 else { return }
        TitleBarAction.lastAt = now
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": miniaturize(nil)
        case "None": break
        default: zoom(nil)
        }
    }
}

/// Keys no one took go by without AppKit's beep, except a ⌘ shortcut that matches nothing. Pages pass back keys they
/// use too (YouTube seeks on ← and →), so without this every arrow on a video would beep.
enum QuietKeys {
    static func passQuietly(_ selector: Selector, _ event: NSEvent?) -> Bool {
        guard selector == #selector(NSResponder.keyDown(with:)), let event, event.type == .keyDown else { return false }
        return !event.modifierFlags.contains(.command)
    }
}

/// When chrome standing in for the title bar last zoomed or minimized the window.
enum TitleBarAction {
    static var lastAt: TimeInterval = 0
}

extension BrowserWindow: TouchPress.Handling {
    /// A finger landing: the press hooks `sendEvent` runs for a mouse-down (the window controller's included).
    func touchPressed(_ event: NSEvent) {
        notePress(at: event.locationInWindow)
        _ = eventInterceptor?(event)
    }

    /// A tap on one of our controls in the title bar strip, where AppKit's click from it went to the title bar and
    /// never reached `routeTitlebarEvent`: the control is clicked.
    func touchTapped(_ event: NSEvent, downAt time: TimeInterval) {
        if spentTap.takes(at: event.locationInWindow) { return }
        // Beside a small control, the tap is that control's (`TouchTargets`).
        let point = TouchTargets.point(for: event.locationInWindow, in: self) ?? event.locationInWindow
        let event = point == event.locationInWindow ? event : TouchPress.mouseDown(at: point, in: self) ?? event
        // Two taps on the title bar strip's empty space: AppKit's own title bar takes them as single clicks.
        if isOnEmptyTitlebar(point) {
            let previous = lastTitlebarTap
            lastTitlebarTap = (time, point)
            if TouchDoubleTap.isSecondTap(after: previous, at: time, point: point, interval: NSEvent.doubleClickInterval) {
                lastTitlebarTap = nil
                titleBarMouseDown(event, clicks: 2)
            }
            return
        }
        if lastLeftMouseDown < time, clickWithoutItsClick(event) { return }
        guard lastTitlebarPress < time, let target = control(at: point) as? InteractiveView, target.isEnabled,
              let frame = contentView?.superview, let hit = frame.hitTest(point), !hit.isDescendant(of: target) else { return }
        target.onClick?(event)
        // Clicked from here, there's no click of its own to come.
        spentTap.disarm()
    }

    /// A tap AppKit made no click from: the drawn control under it gets its click all the same, and a late click is dropped.
    private func clickWithoutItsClick(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        guard let content = contentView, var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return false }
        while !(view is InteractiveView) {
            guard !(view is WKWebView), let parent = view.superview, parent !== content else { return false }
            view = parent
        }
        guard let target = view as? InteractiveView, target.isEnabled, let onClick = target.onClick else { return false }
        TouchLog.note("tap with no click: clicked \(type(of: target))")
        // Only a late click is dropped: the next tap, even on the row next to it, still counts.
        spentAt = ProcessInfo.processInfo.systemUptime
        spentClick.arm(at: [point])
        onClick(event)
        return true
    }
}

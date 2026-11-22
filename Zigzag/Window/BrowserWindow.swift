import AppKit
import WebKit

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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
        if event.type == .leftMouseDown {
            let hit = contentView?.hitTest(event.locationInWindow)
            sidebarHasTheClick = sidebar.map { hit?.isDescendant(of: $0) == true } ?? false
        }
        // A click in a page counts too: a web app (Figma, Docs) keeps its own undo, which a click can change.
        if event.type == .leftMouseDown, contentView?.hitTest(event.locationInWindow).map(Self.isInPage) == true {
            UndoClock.lastPageEdit = Date()
            UndoClock.lastPageInput = Date()
        }
        if let eventInterceptor, eventInterceptor(event) { return }
        if let side = SideButton(event.type, button: event.buttonNumber) {
            if let action = side.action { windowController?.tryToPerform(action, with: nil) }
            return
        }
        if movesWindow(for: event) { return }
        if event.type == .scrollWheel, pdfView(at: event.locationInWindow)?.takesSwipe(event) == true { return }
        if routeTitlebarEvent(event) { return }
        if swallowsPanelPress(event) { return }
        super.sendEvent(event)
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
            guard Self.isMoveChord(event.modifierFlags), isInContent(event.locationInWindow) else { return false }
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
        let wanted = isKeyWindow && Self.isMoveChord(flags) && isInContent(point)
        guard wanted != showsMoveHand else { if wanted { NSCursor.openHand.set() }; return }
        showsMoveHand = wanted
        if wanted { NSCursor.openHand.push() } else { NSCursor.pop() }
    }

    /// The PDF under the pointer, when one is: its scrolls go to its swipe before the pages' scroll view.
    private func pdfView(at point: NSPoint) -> ZigzagPDFView? {
        var view = contentView?.hitTest(contentView?.convert(point, from: nil) ?? .zero)
        while let current = view, !(current is ZigzagPDFView) { view = current.superview }
        return view as? ZigzagPDFView
    }

    /// Our controls sit in the title bar area, where AppKit sends presses to the title bar first, so presses on them
    /// are delivered directly.
    private weak var pressTarget: NSView?

    private func routeTitlebarEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard let target = control(at: event.locationInWindow) else { return false }
            pressTarget = target
            if event.type == .leftMouseDown {
                makeKeyAndOrderFront(nil)
                target.mouseDown(with: event)
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
            return
        }
        buttonSpacing = placeTrafficLights(at: origin, spacing: buttonSpacing)
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

    /// A press on chrome that stands in for the title bar (the sidebar, the bar above the page): a drag moves the
    /// window, and a double-click zooms it, or does whatever the Mac's title bar double-click is set to do.
    func titleBarMouseDown(_ event: NSEvent) {
        guard event.clickCount == 2 else { performDrag(with: event); return }
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

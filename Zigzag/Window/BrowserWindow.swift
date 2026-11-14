import AppKit
import WebKit

/// A window with no title bar and no toolbar. The traffic lights live in the sidebar's top row.
final class BrowserWindow: NSWindow {
    /// Where the traffic lights should sit, in window coordinates (top-left of the close button), or nil to hide them.
    var trafficLightOrigin: NSPoint? { didSet { layoutTrafficLights() } }
    /// Intercepts events before the web view sees them (Control+Tab, the back and forward mouse buttons).
    var eventInterceptor: ((NSEvent) -> Bool)?

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
        // AppKit puts the buttons back whenever it relays the title bar; we put them back where they belong.
        let views = buttons + [standardWindowButton(.closeButton)?.superview?.superview].compactMap { $0 }
        for view in views {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(buttonFrameChanged), name: NSView.frameDidChangeNotification, object: view)
        }
    }

    private var relayoutScheduled = false
    private var buttonSpacing: CGFloat?
    private var isPlacingTrafficLights = false

    /// Puts the buttons back the moment AppKit moves them, so the wrong spot never reaches the screen,
    /// then once more after AppKit finishes its own pass.
    @objc private func buttonFrameChanged() {
        if !isPlacingTrafficLights {
            isPlacingTrafficLights = true
            layoutTrafficLights()
            isPlacingTrafficLights = false
        }
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.relayoutScheduled = false
            self?.layoutTrafficLights()
        }
    }

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
                webView.evaluateJavaScript(editing) { [weak controller] result, _ in
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
        "showSettings:", "showPasswords:", "hide:", "hideOtherApplications:", "terminate:",
        "newTab:", "newWindow:", "newPrivateWindow:", "openLocation:", "closeTab:", "closeOtherTabs:", "performClose:",
        "reopenClosedTab:", "selectNextTab:", "selectPreviousTab:", "selectTabByNumber:", "selectLastTab:",
        "selectSpaceByNumber:", "showSpaceSwitcher:", "newSpace:", "reloadPage:", "reloadPageFromOrigin:", "stopLoading:",
        "performMiniaturize:", "toggleFullScreen:", "toggleBrowserSidebar:", "toggleDeskView:", "showWebInspector:",
        "showDownloads:", "showHistory:", "hideWebApp:", "quitWebApp:",
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), firstResponder is WKWebView {
            UndoClock.lastPageEdit = Date()
            UndoClock.lastPageInput = Date()
        }
        // A click in a page counts too: a web app (Figma, Docs) keeps its own undo, which a click can change.
        if event.type == .leftMouseDown, contentView?.hitTest(event.locationInWindow).map(Self.isInPage) == true {
            UndoClock.lastPageEdit = Date()
            UndoClock.lastPageInput = Date()
        }
        if let eventInterceptor, eventInterceptor(event) { return }
        if movesWindow(for: event) { return }
        if event.type == .scrollWheel, pdfView(at: event.locationInWindow)?.takesSwipe(event) == true { return }
        if routeTitlebarEvent(event) { return }
        if swallowsPanelPress(event) { return }
        super.sendEvent(event)
    }

    /// A press on a floating panel's own surface (a gap between its rows, a label, its corner) stays the panel's: the
    /// window is movable by its background, so AppKit would otherwise take it as a drag of the window or a double-click
    /// on the title bar, and nothing behind the panel ever hears it (#216).
    private func swallowsPanelPress(_ event: NSEvent) -> Bool {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let content = contentView,
              let frame = content.superview else { return false }
        return FloatingPanelView.isBareSurface(frame.hitTest(frame.convert(event.locationInWindow, from: nil)))
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

    /// Our controls sit where the title bar would be. AppKit sends presses there to the title bar first,
    /// so presses that land on one of our controls are delivered to it directly.
    private weak var titlebarTarget: NSView?

    private func routeTitlebarEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard let target = control(at: event.locationInWindow) else { return false }
            titlebarTarget = target
            if event.type == .leftMouseDown {
                makeKeyAndOrderFront(nil)
                target.mouseDown(with: event)
            } else if let menu = target.menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: target)
            }
            return true
        case .leftMouseDragged:
            guard let target = titlebarTarget else { return false }
            target.mouseDragged(with: event)
            return true
        case .leftMouseUp:
            guard let target = titlebarTarget else { return false }
            titlebarTarget = nil
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

    /// Hidden while the sidebar is collapsed or sliding; shown in full screen only when AppKit wants them.
    var trafficLightsHidden = false {
        didSet { buttons.forEach { $0.isHidden = trafficLightsHidden && !styleMask.contains(.fullScreen) } }
    }


    /// Moves the system buttons into our top row. AppKit re-lays them out on resize, so this runs often.
    func layoutTrafficLights() {
        guard let origin = trafficLightOrigin, let close = standardWindowButton(.closeButton),
              let titlebar = close.superview else { return }
        // In full screen AppKit shows them in the title bar that slides down with the menu bar, flashing them in
        // the wrong place; they stay hidden there, and the sidebar's buttons move into their space.
        // In full screen they belong to the title bar that slides down with the menu bar, where AppKit puts them,
        // so you can always leave full screen; the sidebar keeps no space for them.
        guard !styleMask.contains(.fullScreen) else {
            buttons.forEach { if $0.isHidden { $0.isHidden = false } }
            return
        }
        let height = close.frame.height
        // Measured once, from AppKit's own layout: read later, mid-move, it can come out wrong and bunch the buttons up.
        if buttonSpacing == nil, let mini = standardWindowButton(.miniaturizeButton), mini.frame.minX > close.frame.minX {
            buttonSpacing = mini.frame.minX - close.frame.minX
        }
        let spacing = buttonSpacing ?? 20
        // Grow the titlebar so the buttons can sit lower than AppKit's default. Its top is pinned every time, not only
        // when the height changes: a resize from code moves the window's top without touching the height.
        if let container = titlebar.superview {
            let wanted = origin.y + height + Tokens.Space.x1
            var frame = container.frame
            frame.size.height = wanted
            frame.origin.y = (contentView?.frame.height ?? frame.maxY) - wanted
            if container.frame != frame { container.frame = frame }
        }
        for (index, button) in buttons.enumerated() {
            let x = origin.x + CGFloat(index) * spacing
            let y = titlebar.frame.height - origin.y - height
            if button.frame.origin != NSPoint(x: x, y: y) {
                button.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
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

extension NSWindow {
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

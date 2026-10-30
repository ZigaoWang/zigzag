import AppKit
import WebKit

/// A window with no title bar and no toolbar. The traffic lights live in the sidebar's top row.
final class BrowserWindow: NSWindow {
    /// Where the traffic lights should sit, in window coordinates (top-left of the close button), or nil to hide them.
    var trafficLightOrigin: NSPoint? { didSet { layoutTrafficLights() } }
    /// Intercepts events before the web view sees them (pinch for desk view, Control+Tab).
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Z / ⇧⌘Z: the sidebar's undo, unless you were just typing on the page or in a field.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "z", mods == .command || mods == [.command, .shift],
           let controller = windowController as? BrowserWindowController, controller.handleUndoKey(redo: mods.contains(.shift)) {
            return true
        }
        // ⌘← / ⌘→ move the cursor while you're typing; only away from a text field do they mean Back and Forward.
        if mods == .command, event.keyCode == 123 || event.keyCode == 124 {
            if firstResponder is NSText { return false }
            if let webView = firstResponder as? WKWebView, let controller = windowController as? BrowserWindowController {
                let back = event.keyCode == 123
                let editing = "(() => { const e = document.activeElement; return !!e && (e.isContentEditable || /^(input|textarea|select)$/i.test(e.tagName)); })()"
                webView.evaluateJavaScript(editing) { [weak controller] result, _ in
                    MainActor.assumeIsolated {
                        guard (result as? Bool) != true, let controller else { return }
                        back ? controller.goBack(nil) : controller.goForward(nil)
                    }
                }
                return false
            }
        }
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), firstResponder is WKWebView {
            UndoClock.lastPageEdit = Date()
        }
        if let eventInterceptor, eventInterceptor(event) { return }
        if routeTitlebarEvent(event) { return }
        super.sendEvent(event)
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

    /// Width the traffic lights take up, including their trailing gap.
    var trafficLightsWidth: CGFloat {
        guard let close = standardWindowButton(.closeButton), let zoom = standardWindowButton(.zoomButton) else { return 60 }
        return zoom.frame.maxX - close.frame.minX
    }

    var trafficLightHeight: CGFloat { standardWindowButton(.closeButton)?.frame.height ?? 14 }
}

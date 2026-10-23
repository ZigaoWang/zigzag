import AppKit

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
        // AppKit puts the buttons back whenever it relays the title bar; we put them back where they belong.
        let views = buttons + [standardWindowButton(.closeButton)?.superview?.superview].compactMap { $0 }
        for view in views {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(buttonFrameChanged), name: NSView.frameDidChangeNotification, object: view)
        }
    }

    private var relayoutScheduled = false

    @objc private func buttonFrameChanged() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.relayoutScheduled = false
            self?.layoutTrafficLights()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Browser shortcuts win over the page: the menu bar sees key equivalents before the web view does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if let eventInterceptor, eventInterceptor(event) { return }
        super.sendEvent(event)
    }

    private var buttons: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
    }

    /// Hidden while the sidebar is collapsed or sliding; shown in full screen only when AppKit wants them.
    var trafficLightsHidden = false {
        didSet { buttons.forEach { $0.isHidden = trafficLightsHidden } }
    }


    /// Moves the system buttons into our top row. AppKit re-lays them out on resize, so this runs often.
    func layoutTrafficLights() {
        guard let origin = trafficLightOrigin, let close = standardWindowButton(.closeButton),
              let titlebar = close.superview else { return }
        guard !styleMask.contains(.fullScreen) else { return }
        let height = close.frame.height
        let spacing: CGFloat = {
            guard let mini = standardWindowButton(.miniaturizeButton) else { return 20 }
            return mini.frame.minX - close.frame.minX
        }()
        // Grow the titlebar so the buttons can sit lower than AppKit's default.
        if let container = titlebar.superview {
            let wanted = origin.y + height + Tokens.Space.x1
            var frame = container.frame
            if frame.height != wanted {
                frame.size.height = wanted
                frame.origin.y = (contentView?.frame.height ?? frame.maxY) - wanted
                container.frame = frame
            }
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

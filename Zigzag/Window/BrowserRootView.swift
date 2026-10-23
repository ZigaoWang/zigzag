import AppKit

/// Holds the sidebar. Docked it is invisible chrome; floating it becomes a card with its own shadow.
final class SidebarContainer: NSView {
    let sidebar: SidebarView
    var isFloating = false { didSet { refresh() } }
    var tint: NSColor = SpaceColor.sky.background { didSet { refresh() } }

    init(sidebar: SidebarView) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        sidebar.wantsLayer = true
        sidebar.layer?.cornerCurve = .continuous
        addSubview(sidebar)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        sidebar.frame = bounds
        layer?.shadowPath = isFloating ? CGPath(roundedRect: bounds, cornerWidth: Tokens.Radius.card, cornerHeight: Tokens.Radius.card, transform: nil) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        Tokens.Motion.withoutAnimation {
            sidebar.layer?.cornerRadius = isFloating ? Tokens.Radius.card : 0
            sidebar.layer?.backgroundColor = isFloating ? cgColor(tint) : nil
            sidebar.layer?.borderWidth = isFloating ? Tokens.Metric.hairline : 0
            sidebar.layer?.borderColor = cgColor(Tokens.Color.panelEdge)
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            layer?.shadowOpacity = isFloating ? 1 : 0
            layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
            layer?.shadowOffset = CGSize(width: 0, height: -Tokens.Space.x1)
        }
        needsLayout = true
    }
}

/// Invisible strip between sidebar and page for resizing the sidebar.
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// The window's content: one continuous tinted background, the sidebar, and the page card.
final class BrowserRootView: ColorView {
    let sidebarContainer: SidebarContainer
    let card = PageCardView()
    private let resizeHandle = ResizeHandle()
    /// Floating surfaces (command bar, previews, peek) live here, above everything.
    let overlay = PassthroughView()

    var sidebarVisible = true
    var sidebarWidth: CGFloat = Tokens.Metric.sidebarWidth
    private(set) var sidebarRevealed = false
    var onLayoutChange: (() -> Void)?
    var onSidebarWidthChange: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?
    private let revealDebouncer = Debouncer(delay: Tokens.Motion.edgeRevealDelay)
    private let hideDebouncer = Debouncer(delay: Tokens.Motion.edgeHideDelay)
    /// Keeps the floating sidebar open, e.g. while a menu from it is showing.
    var holdReveal = false

    init(sidebar: SidebarView) {
        sidebarContainer = SidebarContainer(sidebar: sidebar)
        super.init(color: SpaceColor.sky.background)
        addSubview(card)
        addSubview(resizeHandle)
        addSubview(sidebarContainer)
        addSubview(overlay)
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return }
            let width = Tokens.Space.snap(min(max(x, Tokens.Metric.sidebarMinWidth), Tokens.Metric.sidebarMaxWidth))
            guard width != self.sidebarWidth else { return }
            self.sidebarWidth = width
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        resizeHandle.onEnd = { [weak self] in
            guard let self else { return }
            self.onSidebarWidthChange?(self.sidebarWidth)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Layout

    var cardFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if sidebarVisible {
            return NSRect(x: sidebarWidth, y: inset, width: max(0, bounds.width - sidebarWidth - inset), height: max(0, bounds.height - inset * 2))
        }
        return bounds.insetBy(dx: inset, dy: inset)
    }

    var sidebarFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if sidebarVisible { return NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height) }
        let x = sidebarRevealed ? inset : -sidebarWidth - inset * 4
        return NSRect(x: x, y: inset, width: sidebarWidth, height: bounds.height - inset * 2)
    }

    override func layout() {
        super.layout()
        card.frame = cardFrame
        sidebarContainer.frame = sidebarFrame
        sidebarContainer.isFloating = !sidebarVisible
        let handleWidth = Tokens.Metric.resizeHandleWidth
        resizeHandle.frame = NSRect(x: sidebarWidth - handleWidth / 2, y: 0, width: handleWidth, height: bounds.height)
        resizeHandle.isHidden = !sidebarVisible
        overlay.frame = bounds
        onLayoutChange?()
    }

    func setSidebarVisible(_ visible: Bool, animated: Bool) {
        guard visible != sidebarVisible else { return }
        hideDebouncer.cancel()
        revealDebouncer.cancel()
        // Hiding a floating sidebar should not slide it in first.
        let wasRevealed = sidebarRevealed
        sidebarVisible = visible
        sidebarRevealed = false
        if !visible && wasRevealed { sidebarRevealed = false }
        guard animated else { needsLayout = true; return }
        sidebarContainer.isFloating = !visible
        onLayoutChange?()
        Tokens.Motion.animate(Tokens.Motion.snappy, {
            self.card.animator().frame = self.cardFrame
            self.sidebarContainer.animator().frame = visible ? self.sidebarFrame : NSRect(x: -self.sidebarWidth, y: 0, width: self.sidebarWidth, height: self.bounds.height)
        }, completion: {
            self.needsLayout = true
            self.onLayoutChange?()
        })
    }

    // MARK: Edge reveal

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !sidebarVisible else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !sidebarRevealed {
            if point.x <= Tokens.Metric.edgeRevealWidth {
                hideDebouncer.cancel()
                revealDebouncer.call { [weak self] in self?.reveal(true) }
            } else {
                revealDebouncer.cancel()
            }
        } else {
            let keep = sidebarContainer.frame.insetBy(dx: -Tokens.Space.x4, dy: -Tokens.Space.x4).contains(point)
            if keep || holdReveal { hideDebouncer.cancel() } else { hideDebouncer.call { [weak self] in self?.reveal(false) } }
        }
    }

    override func mouseExited(with event: NSEvent) {
        revealDebouncer.cancel()
    }

    func reveal(_ show: Bool) {
        guard !sidebarVisible, show != sidebarRevealed else { return }
        if !show && holdReveal { return }
        sidebarRevealed = show
        onLayoutChange?()
        Tokens.Motion.animate(Tokens.Motion.snappy, {
            self.sidebarContainer.animator().frame = self.sidebarFrame
        }, completion: { self.onLayoutChange?() })
    }

    /// True while the sidebar is in its floating, slid-in state.
    var isSidebarFloatingVisible: Bool { !sidebarVisible && sidebarRevealed }
}

/// A full-size layer for floating UI that lets clicks fall through where it has nothing.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

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

/// Invisible strip for resizing: between sidebar and page, and between split panes.
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Drags up and down (reporting y in window coordinates) instead of sideways.
    var isVertical = false { didSet { window?.invalidateCursorRects(for: self) } }
    private var startX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isVertical ? .rowResize : .columnResize)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(isVertical ? event.locationInWindow.y : event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// The window's content: one continuous tinted background, the sidebar, and the page card.
final class BrowserRootView: ColorView {
    let sidebarContainer: SidebarContainer
    let card = PageCardView()
    /// The second page in split view.
    let secondCard = PageCardView()
    private let splitHandle = ResizeHandle()
    /// Share of the page area the left pane takes; nil when not split.
    var splitRatio: CGFloat? { didSet { needsLayout = true } }
    var splitVertical = false { didSet { needsLayout = true; splitHandle.isVertical = splitVertical } }

    /// Opens, closes or rotates the split. The pages slide to their new places; the new pane fades in beside.
    func setSplit(ratio: CGFloat?, vertical: Bool, animated: Bool) {
        let wasSplit = splitRatio != nil
        guard ratio != splitRatio || vertical != splitVertical else { return }
        let oldLeft = card.frame
        splitRatio = ratio
        splitVertical = vertical
        guard animated, !Tokens.Motion.isKeyboardDriven, window != nil else { needsLayout = true; return }
        layoutSubtreeIfNeeded()
        let panes = paneFrames
        card.frame = oldLeft
        if let right = panes.right, !wasSplit {
            secondCard.alphaValue = 0
            secondCard.frame = vertical ? right.offsetBy(dx: 0, dy: Tokens.Space.x6) : right.offsetBy(dx: Tokens.Space.x6, dy: 0)
        }
        Tokens.Motion.animate(Tokens.Motion.gentle) {
            self.card.animator().frame = panes.left
            if let right = panes.right {
                self.secondCard.animator().frame = right
                self.secondCard.animator().alphaValue = 1
            }
        }
    }
    var onSplitRatioChange: ((CGFloat, Bool) -> Void)?
    /// Highlights where a dragged tab would open beside the current page.
    let splitDropHint = SplitDropHint()
    private let resizeHandle = ResizeHandle()
    /// Floating surfaces (command bar, previews, peek) live here, above everything.
    let overlay = PassthroughView()

    var sidebarVisible = true
    var sidebarWidth: CGFloat = Tokens.Metric.sidebarWidth
    private(set) var sidebarRevealed = false
    var onLayoutChange: (() -> Void)?
    /// Called when the sidebar starts a slide, with how long it lasts (0 = no animation).
    var onSlide: ((TimeInterval) -> Void)?
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
        secondCard.isHidden = true
        addSubview(secondCard)
        splitHandle.isHidden = true
        addSubview(splitHandle)
        splitHandle.onDrag = { [weak self] value in
            guard let self else { return }
            let area = self.cardFrame
            if self.splitVertical {
                // Window y runs bottom-up; this view is flipped.
                let y = self.convert(NSPoint(x: 0, y: value), from: nil).y
                self.splitRatio = min(max((y - area.minY) / area.height, 0.2), 0.8)
            } else {
                self.splitRatio = min(max((value - area.minX) / area.width, 0.2), 0.8)
            }
            self.layoutSubtreeIfNeeded()
            self.onSplitRatioChange?(self.splitRatio ?? 0.5, false)
        }
        splitHandle.onEnd = { [weak self] in
            guard let self, let ratio = self.splitRatio else { return }
            self.onSplitRatioChange?(ratio, true)
        }
        splitHandle.onDoubleClick = { [weak self] in
            self?.splitRatio = 0.5
            self?.onSplitRatioChange?(0.5, true)
        }
        addSubview(resizeHandle)
        addSubview(sidebarContainer)
        addSubview(splitDropHint)
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

    /// The left (or only) pane and the right pane, inside the page area.
    var paneFrames: (left: NSRect, right: NSRect?) {
        let area = cardFrame
        guard let ratio = splitRatio else { return (area, nil) }
        let gap = Tokens.Metric.cardInset
        if splitVertical {
            let topHeight = floor((area.height - gap) * ratio)
            let top = NSRect(x: area.minX, y: area.minY, width: area.width, height: topHeight)
            return (top, NSRect(x: area.minX, y: top.maxY + gap, width: area.width, height: area.maxY - top.maxY - gap))
        }
        let leftWidth = floor((area.width - gap) * ratio)
        let left = NSRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
        let right = NSRect(x: left.maxX + gap, y: area.minY, width: area.maxX - left.maxX - gap, height: area.height)
        return (left, right)
    }

    private func layoutCards() {
        let panes = paneFrames
        card.frame = panes.left
        if let right = panes.right {
            secondCard.isHidden = false
            secondCard.frame = right
            splitHandle.isHidden = false
            splitHandle.frame = splitVertical
                ? NSRect(x: right.minX, y: panes.left.maxY - 2, width: right.width, height: right.minY - panes.left.maxY + 4)
                : NSRect(x: panes.left.maxX - 2, y: right.minY, width: right.minX - panes.left.maxX + 4, height: right.height)
        } else {
            secondCard.isHidden = true
            splitHandle.isHidden = true
        }
        splitDropHint.frame = cardFrame
    }

    var sidebarFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if sidebarVisible { return NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height) }
        let x = sidebarRevealed ? inset : -sidebarWidth - inset * 4
        return NSRect(x: x, y: inset, width: sidebarWidth, height: bounds.height - inset * 2)
    }

    override func layout() {
        super.layout()
        layoutCards()
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
        let oldSidebar = sidebarContainer.frame
        sidebarVisible = visible
        sidebarRevealed = false
        watchPointer(false)
        sidebarContainer.isFloating = !visible
        guard animated, !Tokens.Motion.isKeyboardDriven, !Tokens.Motion.reduceMotion else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        // The page card resizes with AppKit's animator; the sidebar slides on the render server.
        let targetSidebar = visible ? sidebarFrame : NSRect(x: -sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height)
        Tokens.Motion.withoutAnimation { sidebarContainer.frame = targetSidebar }
        let duration = Tokens.Motion.slide(sidebarContainer, fromOffsetX: oldSidebar.minX - targetSidebar.minX, curve: Tokens.Motion.slide)
        onSlide?(duration)
        Tokens.Motion.animate(Tokens.Motion.slide, {
            self.card.animator().frame = self.paneFrames.left
            if let right = self.paneFrames.right { self.secondCard.animator().frame = right }
        }, completion: {
            self.needsLayout = true
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
                reveal(true)
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

    private var pointerTimer: Timer?

    /// While the sidebar floats, follow the pointer itself: web views swallow mouse-moved events,
    /// so tracking areas alone can't tell when you've left.
    private func watchPointer(_ on: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard on else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, self.sidebarRevealed else { return }
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                let keep = self.sidebarContainer.frame.insetBy(dx: -Tokens.Space.x2, dy: -Tokens.Space.x2).contains(point)
                if keep || self.holdReveal || NSEvent.pressedMouseButtons != 0 {
                    self.pointerLeftAt = nil
                } else if let left = self.pointerLeftAt {
                    if Date().timeIntervalSince(left) > Tokens.Motion.edgeHideDelay { self.pointerLeftAt = nil; self.reveal(false) }
                } else {
                    self.pointerLeftAt = Date()
                }
            }
        }
    }

    private var pointerLeftAt: Date?

    func reveal(_ show: Bool) {
        guard !sidebarVisible, show != sidebarRevealed else { return }
        if !show && holdReveal { return }
        let old = sidebarContainer.frame
        sidebarRevealed = show
        watchPointer(show)
        let target = sidebarFrame
        Tokens.Motion.withoutAnimation { sidebarContainer.frame = target }
        // Frames are final at once; only the drawing slides. The real traffic lights can't follow,
        // so a picture of them rides inside the sidebar until the slide ends.
        let duration = Tokens.Motion.slide(sidebarContainer, fromOffsetX: old.minX - target.minX, curve: Tokens.Motion.slide)
        onSlide?(duration)
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

/// Shown while a tab is dragged over the page: which half it would open in, beside what's there.
final class SplitDropHint: NSView {
    enum Side { case left, right }
    private let zone = ColorView()
    private let label = Label("", font: Tokens.Font.body(.semibold), color: .white)
    private(set) var side: Side?

    override init(frame: NSRect) {
        super.init(frame: frame)
        zone.wantsLayer = true
        zone.layer?.cornerRadius = Tokens.Radius.card
        zone.layer?.cornerCurve = .continuous
        zone.layer?.borderWidth = 2
        addSubview(zone)
        zone.addSubview(label)
        label.alignment = .center
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ side: Side?) {
        guard side != self.side else { return }
        self.side = side
        isHidden = side == nil
        guard let side else { return }
        let half = bounds.width / 2
        let target = NSRect(x: side == .left ? 0 : half, y: 0, width: half, height: bounds.height).insetBy(dx: Tokens.Space.x2, dy: Tokens.Space.x2)
        zone.color = Tokens.Color.accent.withAlphaComponent(0.16)
        zone.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
        label.stringValue = side == .left ? "Open on the Left" : "Open on the Right"
        label.textColor = Tokens.Color.accent
        Tokens.Motion.animate(Tokens.Motion.feedback) { self.zone.animator().frame = target }
        if zone.frame.isEmpty { zone.frame = target }
        let h = label.lineHeight
        label.frame = NSRect(x: 0, y: (target.height - h) / 2, width: target.width, height: h)
    }

    /// Which half of the page a window point is over, or nil if it isn't over the page.
    func side(at windowPoint: NSPoint) -> Side? {
        guard let superview else { return nil }
        let p = convert(windowPoint, from: nil)
        _ = superview
        guard bounds.contains(p) else { return nil }
        return p.x < bounds.midX ? .left : .right
    }
}

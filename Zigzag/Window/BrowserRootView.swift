import AppKit

/// Holds the sidebar. Docked it is invisible chrome; floating it becomes a card with its own shadow.
final class SidebarContainer: NSView {
    let sidebar: SidebarView
    var isFloating = false { didSet { refresh() } }
    var tint: NSColor = SpaceColor.sky.background { didSet { refresh() } }
    /// Floating, it carries the window's look with it: the gradient (the same slice of it the window shows there)
    /// and the grain, so sliding it out never strips them.
    var gradient: (end: NSColor, angle: Double)? { didSet { refresh() } }
    var grain: Double = 0 { didSet { refresh() } }
    private let gradientLayer = CAGradientLayer()
    private let grainLayer = CALayer()

    init(sidebar: SidebarView) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        sidebar.wantsLayer = true
        sidebar.layer?.cornerCurve = .continuous
        addSubview(sidebar)
        // Behind the sidebar's own views, inside its rounded shape.
        let backdrop = CALayer()
        backdrop.masksToBounds = true
        backdrop.cornerCurve = .continuous
        // Top-down, like the window, so the gradient's slice lines up with the window around it.
        backdrop.isGeometryFlipped = true
        backdrop.addSublayer(gradientLayer)
        grainLayer.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
        grainLayer.compositingFilter = "overlayBlendMode"
        backdrop.addSublayer(grainLayer)
        sidebar.layer?.insertSublayer(backdrop, at: 0)
        self.backdrop = backdrop
        // Links and files dropped on the sidebar open as tabs.
        registerForDraggedTypes([.URL, .fileURL, .string])
        dropRing.isHidden = true
        dropRing.borderWidth = 2
        dropRing.cornerCurve = .continuous
        dropRing.zPosition = 50
        layer?.addSublayer(dropRing)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var backdrop: CALayer?
    private let dropRing = CALayer()

    // MARK: Dropping links and files

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let board = info.draggingPasteboard
        // A tab being moved inside Zigzag is its own kind of drag, handled by the list.
        if let source = info.draggingSource as? NSView, source.window?.windowController is BrowserWindowController { return [] }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
        }
        if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil {
            return [url]
        }
        return []
    }

    private func showDropRing(_ on: Bool) {
        Tokens.Motion.withoutAnimation {
            dropRing.frame = bounds.insetBy(dx: 4, dy: 4)
            dropRing.cornerRadius = Tokens.Radius.card
            dropRing.borderColor = cgColor(Tokens.Color.accent)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = on ? 0 : 1
        fade.toValue = on ? 1 : 0
        fade.duration = 0.15
        dropRing.add(fade, forKey: "fade")
        dropRing.isHidden = !on
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedURLs(sender).isEmpty else { return [] }
        showDropRing(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { showDropRing(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropRing(false)
        let urls = droppedURLs(sender)
        guard !urls.isEmpty, let controller = window?.windowController as? BrowserWindowController else { return false }
        // The first opens in front; any others wait behind it.
        for (i, url) in urls.prefix(20).enumerated() {
            controller.open(url, disposition: i == 0 ? .foregroundTab : .backgroundTab, allowSwitch: false)
        }
        return true
    }

    /// The window-sized gradient, placed so this slice matches the window around it, wherever the sidebar is.
    private func placeGradient() {
        let window = superview?.bounds ?? bounds
        Tokens.Motion.withoutAnimation {
            gradientLayer.frame = CGRect(x: -frame.minX, y: -frame.minY, width: window.width, height: window.height)
        }
    }

    // Sliding out moves the sidebar without resizing it, so layout alone wouldn't follow.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        placeGradient()
    }

    override func layout() {
        super.layout()
        sidebar.frame = bounds
        Tokens.Motion.withoutAnimation {
            backdrop?.frame = sidebar.bounds
            backdrop?.cornerRadius = isFloating ? Tokens.Radius.card : 0
            placeGradient()
            grainLayer.frame = sidebar.bounds
            // The same fine noise as the window: drawn at the screen's resolution, not doubled up.
            let scale = self.window?.backingScaleFactor ?? 2
            backdrop?.contentsScale = scale
            grainLayer.contentsScale = scale
        }
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
            // The grain blends inside this clipped layer, so the color sits here too, under it, as in the window.
            backdrop?.backgroundColor = isFloating ? cgColor(tint) : nil
            backdrop?.isHidden = !isFloating
            if let gradient, isFloating {
                let r = gradient.angle * .pi / 180
                let dx = cos(r) / 2, dy = sin(r) / 2
                // A gradient's points count up from the bottom even in a top-down layer: the vertical turns over.
                gradientLayer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
                gradientLayer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)
                gradientLayer.colors = [cgColor(tint), cgColor(gradient.end)]
                gradientLayer.isHidden = false
            } else {
                gradientLayer.isHidden = true
            }
            grainLayer.opacity = Float(min(max(grain, 0), 1) * 0.22)
            sidebar.layer?.borderWidth = isFloating ? Tokens.Metric.hairline : 0
            sidebar.layer?.borderColor = cgColor(Tokens.Color.panelEdge)
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            layer?.shadowOpacity = isFloating ? 1 : 0
            layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
            layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
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
    /// With no tab open, the page steps away and leaves the space's color, with one way to start.
    let emptyHint = EmptySpaceMark()
    var isEmpty = false {
        didSet {
            guard oldValue != isEmpty else { return }
            Tokens.Motion.animate(Tokens.Motion.feedback) {
                self.card.animator().alphaValue = self.isEmpty ? 0 : 1
                self.emptyHint.animator().alphaValue = self.isEmpty ? 1 : 0
            }
        }
    }
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
        // Like the sidebar, a split moves the window's layout: it animates from the keyboard too.
        guard animated, !Tokens.Motion.reduceMotion, window != nil else { needsLayout = true; return }
        layoutSubtreeIfNeeded()
        let panes = paneFrames
        card.frame = oldLeft
        if let right = panes.right, !wasSplit {
            secondCard.alphaValue = 0
            secondCard.frame = vertical ? right.offsetBy(dx: 0, dy: Tokens.Space.x6) : right.offsetBy(dx: Tokens.Space.x6, dy: 0)
        }
        Tokens.Motion.animate(Tokens.Motion.gentle, evenFromKeyboard: true) {
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
    /// Keeps the floating sidebar open, e.g. while a menu from it is showing.
    var holdReveal = false
    /// Also keeps it open: a panel that came out of it (the site panel, downloads) is still showing.
    var keepsRevealed: (() -> Bool)?
    private var isHeld: Bool { holdReveal || keepsRevealed?() == true }

    init(sidebar: SidebarView) {
        sidebarContainer = SidebarContainer(sidebar: sidebar)
        super.init(color: SpaceColor.sky.background)
        addSubview(card)
        emptyHint.alphaValue = 0
        addSubview(emptyHint)
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
        NotificationCenter.default.addObserver(forName: Self.borderlessChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Tokens.Motion.animate(Tokens.Motion.gentle) {
                    self.needsLayout = true
                    self.layoutSubtreeIfNeeded()
                }
            }
        }
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

    /// With the sidebar hidden, the page is the whole window, no frame around it; the sidebar that slides out from
    /// the edge is what moves and zooms the window. With the sidebar showing, the page floats in its frame.
    var isEdgeToEdge: Bool {
        !sidebarVisible && (Self.isBorderless || window?.styleMask.contains(.fullScreen) == true)
    }

    /// With the sidebar hidden, the page runs to the window's edges. On unless turned off in Settings.
    static var isBorderless: Bool {
        get { UserDefaults.standard.object(forKey: "borderlessPage") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "borderlessPage")
            NotificationCenter.default.post(name: borderlessChanged, object: nil)
        }
    }
    static let borderlessChanged = Notification.Name("BorderlessPageChanged")

    var cardFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if isEdgeToEdge { return bounds }
        if sidebarVisible {
            return NSRect(x: sidebarWidth, y: inset, width: max(0, bounds.width - sidebarWidth - inset), height: max(0, bounds.height - inset * 2))
        }
        return bounds.insetBy(dx: inset, dy: inset)
    }

    /// The left (or only) pane and the right pane, inside the page area.
    var paneFrames: (left: NSRect, right: NSRect?) {
        let area = cardFrame
        guard let ratio = splitRatio else { return (area, nil) }
        // Borderless, the two pages meet at a hairline instead of floating apart.
        let gap = isEdgeToEdge ? 1 : Tokens.Metric.cardInset
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

    private static func markFrame(in page: NSRect) -> NSRect {
        let size = EmptySpaceMark.size
        return NSRect(x: round(page.midX - size.width / 2), y: round(page.midY - size.height / 2), width: size.width, height: size.height)
    }

    private func layoutCards() {
        let panes = paneFrames
        emptyHint.frame = Self.markFrame(in: panes.left)
        card.isEdgeToEdge = isEdgeToEdge
        secondCard.isEdgeToEdge = isEdgeToEdge
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

    /// Frosted glass behind the frame, for spaces that want the desktop to show through.
    private lazy var glassView: NSVisualEffectView = {
        let glass = NSVisualEffectView()
        glass.blendingMode = .behindWindow
        glass.material = .underWindowBackground
        glass.state = .active
        glass.isHidden = true
        addSubview(glass, positioned: .below, relativeTo: nil)
        glass.wantsLayer = true
        glass.layer?.zPosition = -3
        return glass
    }()

    func setGlass(_ on: Bool) {
        glassView.isHidden = !on
        if on { glassView.frame = bounds }
    }

    /// A second color the frame fades into, corner to corner, under the grain.
    private lazy var gradientLayer: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.zPosition = -2
        gradient.opacity = 0
        layer?.insertSublayer(gradient, at: 0)
        return gradient
    }()
    private var gradientColors: (NSColor, NSColor)?

    func setGradient(from start: NSColor, to end: NSColor?, angle: Double = 45, animated: Bool) {
        gradientColors = end.map { (start, $0) }
        // The angle as two points on the unit square, through its middle (0° runs left to right, 90° top to bottom;
        // the view is flipped, so y grows downward here too).
        let r = angle * .pi / 180
        let dx = cos(r) / 2, dy = sin(r) / 2
        Tokens.Motion.withoutAnimation {
            gradientLayer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            gradientLayer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        }
        applyGradient(animated: animated)
    }

    private func applyGradient(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.large)
        if let (start, end) = gradientColors {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                gradientLayer.colors = [start.cgColor, end.cgColor]
            }
            gradientLayer.opacity = 1
        } else {
            gradientLayer.opacity = 0
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGradient(animated: false)
    }

    /// The frame's grain, under everything else: the same fine noise as Zigzag's own branded screens.
    private lazy var grainLayer: CALayer = {
        let grain = CALayer()
        grain.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
        grain.compositingFilter = "overlayBlendMode"
        grain.opacity = 0
        grain.zPosition = -1
        layer?.insertSublayer(grain, at: 0)
        return grain
    }()

    /// 0 is smooth; 1 is as much as reads as texture without becoming noise.
    func setGrain(_ amount: Double, animated: Bool) {
        let target = Float(min(max(amount, 0), 1) * 0.22)
        guard grainLayer.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.standard)
        grainLayer.opacity = target
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation { grainLayer.frame = bounds; gradientLayer.frame = bounds }
        if !glassView.isHidden { glassView.frame = bounds }
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
        let oldSidebar = sidebarContainer.frame
        sidebarVisible = visible
        sidebarRevealed = false
        watchPointer(false)
        sidebarContainer.isFloating = !visible
        // It slides however it was asked for, the keyboard included: where the sidebar went is worth seeing.
        guard animated, !Tokens.Motion.reduceMotion else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        // The page card resizes with AppKit's animator; the sidebar slides on the render server.
        let targetSidebar = visible ? sidebarFrame : NSRect(x: -sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height)
        Tokens.Motion.withoutAnimation { sidebarContainer.frame = targetSidebar }
        let duration = Tokens.Motion.slide(sidebarContainer, fromOffsetX: oldSidebar.minX - targetSidebar.minX, curve: Tokens.Motion.slide, fromKeyboard: true)
        onSlide?(duration)
        // Borderless: the corners square off as the page grows to the window's edges, and round again as it shrinks.
        card.setEdgeToEdge(isEdgeToEdge, duration: duration)
        secondCard.setEdgeToEdge(isEdgeToEdge, duration: duration)
        Tokens.Motion.animate(Tokens.Motion.slide, evenFromKeyboard: true, {
            self.card.animator().frame = self.paneFrames.left
            self.emptyHint.animator().frame = Self.markFrame(in: self.paneFrames.left)
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
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= Tokens.Metric.edgeRevealWidth { reveal(true) }
    }

    /// Crossing the left edge opens the sidebar, however fast: a quick flick out of the window
    /// may never land a moved event inside the edge strip, but it always leaves through it.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= Tokens.Metric.edgeRevealWidth, point.y >= bounds.minY, point.y <= bounds.maxY { reveal(true) }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= Tokens.Metric.edgeRevealWidth { reveal(true) }
    }

    private var pointerTimer: Timer?
    private var pointerLeftAt: Date?

    /// While the sidebar floats, follow the pointer itself: web views swallow mouse-moved events,
    /// and nothing arrives at all once the pointer is outside the window.
    private func watchPointer(_ on: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLeftAt = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            // The view went away while the sidebar floated: nothing left to follow for.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    isolated deinit { pointerTimer?.invalidate() }

    private func followPointer() {
        guard let window, !sidebarVisible, sidebarRevealed else { watchPointer(false); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let sidebar = sidebarContainer.frame
        // Anywhere left of the sidebar counts as on it: that's where the pointer goes to summon it.
        let keep = sidebar.insetBy(dx: -Tokens.Space.x1, dy: -Tokens.Space.x1).contains(point)
            || (point.x < sidebar.minX && point.y >= bounds.minY && point.y <= bounds.maxY)
        if keep || isHeld || NSEvent.pressedMouseButtons != 0 {
            pointerLeftAt = nil
        } else if let left = pointerLeftAt {
            if Date().timeIntervalSince(left) > Tokens.Motion.edgeHideDelay { reveal(false) }
        } else {
            pointerLeftAt = Date()
        }
    }

    func reveal(_ show: Bool) {
        guard !sidebarVisible, show != sidebarRevealed else { return }
        if !show && isHeld { return }
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


/// What a space with no tabs shows on its color: the wordmark, faint, like a mark pressed into it. Nothing to
/// click or dismiss; ⌘T and the sidebar's New Tab are where a tab comes from.
final class EmptySpaceMark: NSView {
    static let size = NSSize(width: 28 * WordmarkView.aspect, height: 28)
    private let wordmark = WordmarkView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(wordmark)
        setAccessibilityElement(false)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Drawn solid and faded as one piece: the letters' strokes overlap, and a see-through color would darken where
    /// they cross.
    private func refresh() {
        wordmark.color = Tokens.Color.textPrimary
        // On the mark itself: this view's own opacity is what fades it in and out with the page.
        wordmark.wantsLayer = true
        wordmark.layer?.allowsGroupOpacity = true
        wordmark.alphaValue = 0.07
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        wordmark.frame = bounds
    }
}

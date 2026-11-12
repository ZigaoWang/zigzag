import AppKit

/// Holds the sidebar. Docked it is invisible chrome; floating it becomes a card of glass with its own shadow: the page
/// under it blurred, the space's color over the blur (`Frame.floatingCover`), so it stays that space's.
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
    /// Floating, the page under it is frosted, so it shows as soft color and never reads through the sidebar's own
    /// rows. Liquid Glass where the Mac has it; the sidebar's own frosting before.
    private let frost = NSVisualEffectView()
    private var liquidGlass: NSView?
    /// Reduce Transparency, or Low Power Mode on a Mac with Liquid Glass: floating it's the space's solid color, as
    /// before glass. On battery alone it stays glass: it's there only while the sidebar is out.
    private var isGlass: Bool {
        isFloating && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            && !(SpaceInfo.hasClearGlass && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    init(sidebar: SidebarView) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        frost.blendingMode = .withinWindow
        frost.material = .sidebar
        frost.state = .followsWindowActiveState
        frost.isHidden = true
        frost.wantsLayer = true
        frost.layer?.cornerCurve = .continuous
        frost.layer?.masksToBounds = true
        addSubview(frost)
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
        grainLayer.backgroundColor = MaterialImages.grain.cgColor
        backdrop.addSublayer(grainLayer)
        sidebar.layer?.insertSublayer(backdrop, at: 0)
        self.backdrop = backdrop
        // Links and files dropped on the sidebar open as tabs.
        registerForDraggedTypes([.URL, .fileURL, .string])
        dropRing.opacity = 0
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

    /// The links and files a drag from another app carries, the ones Zigzag opens: shared with the page area.
    static func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
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

    private func showDropRing(_ on: Bool) { Self.showDropRing(dropRing, on, around: bounds.insetBy(dx: 4, dy: 4), in: self) }

    /// The ring that says "let go here": the same for the sidebar and the page.
    static func showDropRing(_ ring: CALayer, _ on: Bool, around frame: NSRect, in view: NSView) {
        Tokens.Motion.withoutAnimation {
            ring.frame = frame
            ring.cornerRadius = Tokens.Radius.card
            ring.borderColor = view.cgColor(Tokens.Color.accent)
        }
        // In and out from wherever it is, so it fades away too instead of vanishing.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ring.presentation()?.opacity ?? ring.opacity
        fade.toValue = on ? 1 : 0
        fade.duration = Tokens.Motion.selection
        fade.timingFunction = Tokens.Motion.easeOut
        Tokens.Motion.withoutAnimation { ring.opacity = on ? 1 : 0 }
        ring.isHidden = false
        ring.add(fade, forKey: "fade")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.droppedURLs(sender).isEmpty else { return [] }
        showDropRing(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { showDropRing(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropRing(false)
        return Self.open(Self.droppedURLs(sender), in: window)
    }

    /// Dropped links and files as tabs, the first in front and any others behind it.
    static func open(_ urls: [URL], in window: NSWindow?) -> Bool {
        guard !urls.isEmpty, let controller = window?.windowController as? BrowserWindowController else { return false }
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
        frost.frame = bounds
        liquidGlass?.frame = bounds
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

    /// Liquid Glass, made the first time the sidebar floats as glass.
    private func showLiquidGlass(_ on: Bool) {
        guard #available(macOS 26.0, *) else { return }
        guard on else { liquidGlass?.isHidden = true; return }
        let glass = liquidGlass as? NSGlassEffectView ?? {
            let made = NSGlassEffectView()
            // Regular: blurred enough that a page behind reads as color and shape, never as text under the rows.
            made.style = .regular
            made.cornerRadius = Tokens.Radius.card
            addSubview(made, positioned: .below, relativeTo: sidebar)
            liquidGlass = made
            return made
        }()
        glass.isHidden = false
        glass.frame = bounds
    }

    /// The space's color as it lies over the glass: thinned to the floating cover, or thinner if it already is
    /// (see-through spaces).
    private func overGlass(_ color: NSColor) -> CGColor {
        let solid = cgColor(color)
        guard isGlass else { return solid }
        let cover = effectiveAppearance.isDark ? Tokens.Frame.floatingCoverDark : Tokens.Frame.floatingCover
        return solid.copy(alpha: min(solid.alpha, cover)) ?? solid
    }

    private func refresh() {
        Tokens.Motion.withoutAnimation {
            sidebar.layer?.cornerRadius = isFloating ? Tokens.Radius.card : 0
            // As glass the color lies once, in the backdrop: twice would thicken it.
            sidebar.layer?.backgroundColor = isFloating && !isGlass ? cgColor(tint) : nil
            let liquid = isGlass && SpaceInfo.hasClearGlass
            showLiquidGlass(liquid)
            frost.isHidden = !isFloating || liquid || (!isGlass && cgColor(tint).alpha > 0.99)
            frost.layer?.cornerRadius = Tokens.Radius.card
            // The grain blends inside this clipped layer, so the color sits here too, under it, as in the window.
            backdrop?.backgroundColor = isFloating ? overGlass(tint) : nil
            backdrop?.isHidden = !isFloating
            if let gradient, isFloating {
                let r = gradient.angle * .pi / 180
                let dx = cos(r) / 2, dy = sin(r) / 2
                // A gradient's points count up from the bottom even in a top-down layer: the vertical turns over.
                gradientLayer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
                gradientLayer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)
                gradientLayer.colors = [overGlass(tint), overGlass(gradient.end)]
                gradientLayer.isHidden = false
            } else {
                gradientLayer.isHidden = true
            }
            grainLayer.opacity = Float(min(max(grain, 0), 1) * 0.18)
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
    var onBegin: (() -> Void)?
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
        onBegin?()
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(isVertical ? event.locationInWindow.y : event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// The window's content: one continuous tinted background, the sidebar, and the page card.
final class BrowserRootView: SpaceFrameView {
    /// The least a pane gets while you drag the line between two: room for its header's six buttons and some of its
    /// address, or for its header and a little page when stacked.
    static let minimumPaneWidth: CGFloat = 260
    static let minimumPaneHeight: CGFloat = 160
    let sidebarContainer: SidebarContainer
    let card = PageCardView()
    /// With no tab open, the page steps away and leaves the space's color, with one way to start.
    let emptyHint = EmptySpaceMark()
    var isEmpty = false {
        didSet {
            guard oldValue != isEmpty else { return }
            refreshGlassFrame()
            Tokens.Motion.animate(Tokens.Motion.feedback) {
                self.card.animator().alphaValue = self.isEmpty || self.pagesHidden ? 0 : 1
                self.emptyHint.animator().alphaValue = self.isEmpty ? 1 : 0
            }
        }
    }
    /// Desk view hides the pages while their picture flies into or out of a card, so the two never show at once.
    /// They stay in the window and keep drawing, so they're ready the moment they show again.
    var pagesHidden = false {
        didSet {
            guard oldValue != pagesHidden else { return }
            Tokens.Motion.withoutAnimation {
                card.alphaValue = isEmpty || pagesHidden ? 0 : 1
                extraCards.forEach { $0.alphaValue = pagesHidden ? 0 : 1 }
            }
            refreshGlassOcclusion()
        }
    }
    /// The second page in split view.
    let secondCard = PageCardView()
    /// A tile group's third and fourth pages (#160).
    let thirdCard = PageCardView()
    let fourthCard = PageCardView()
    /// Every pane's card, in the group's order: the first is `card`.
    var paneCards: [PageCardView] { [card, secondCard, thirdCard, fourthCard] }
    /// The cards beside the first, there only in split view.
    private var extraCards: [PageCardView] { [secondCard, thirdCard, fourthCard] }
    /// The strips between panes you drag to resize them: the line between the columns, and between the rows.
    private let columnHandle = ResizeHandle()
    private let rowHandle = ResizeHandle()
    /// How the panes share the page area, a split's two or a tile group's three or four; nil with one page.
    private(set) var tiles: TileShape? { didSet { if tiles != oldValue { needsLayout = true } } }
    /// Share of the page area the left (or top) pane takes; nil when not split. Set alone, it makes a split of two.
    var splitRatio: CGFloat? {
        get { tiles.map { $0.isStacked ? $0.row : $0.column } }
        set {
            guard let newValue else { tiles = nil; return }
            var shape = tiles ?? TileShape(regions: [.left, .right])
            if shape.isStacked { shape.row = newValue } else { shape.column = newValue }
            tiles = shape
        }
    }
    /// A split of two stacked; set, it turns a split of two the other way at the same share.
    var splitVertical: Bool {
        get { tiles?.isStacked ?? false }
        set {
            guard let ratio = splitRatio, tiles?.regions.count == 2, newValue != splitVertical else { return }
            tiles = TileShape.pair(ratio: ratio, vertical: newValue)
        }
    }

    /// Opens, closes or rotates the split. The pages slide to their new places; the new pane fades in beside.
    func setSplit(ratio: CGFloat?, vertical: Bool, animated: Bool) {
        setTiles(ratio.map { TileShape.pair(ratio: $0, vertical: vertical) }, animated: animated)
    }

    /// Lays the panes out as `shape` (nil: one page). Panes that stay slide to their new places, new ones fade in
    /// beside, and ones that go stay where they are and fade while the rest grow over their place.
    func setTiles(_ shape: TileShape?, animated: Bool) {
        guard shape != tiles else { return }
        let before = tiles?.regions.count ?? 1, after = shape?.regions.count ?? 1
        let old = paneCards.map(\.frame)
        tiles = shape
        // Like the sidebar, a split moves the window's layout: it animates from the keyboard too.
        guard animated, !Tokens.Motion.reduceMotion, window != nil else { needsLayout = true; return }
        placeStrips(animated: true)
        let cards = paneCards
        let leaving = after < before ? Array(cards[after..<before]) : []
        leavingCards.formUnion(leaving.map(ObjectIdentifier.init))
        layoutSubtreeIfNeeded()
        let frames = tileFrames
        for i in 0..<min(before, after) { cards[i].frame = old[i] }
        for i in before..<max(before, after) {
            let target = frames[i], region = shape?.regions[i]
            cards[i].alphaValue = 0
            // From a little way off on its own side.
            let dx: CGFloat = region.map { $0.columns == 1...1 ? Tokens.Space.x6 : $0.columns == 0...0 ? -Tokens.Space.x6 : 0 } ?? 0
            let dy: CGFloat = region.map { $0.rows == 1...1 ? Tokens.Space.x6 : $0.rows == 0...0 ? -Tokens.Space.x6 : 0 } ?? 0
            cards[i].frame = target.offsetBy(dx: dx == 0 && dy == 0 ? Tokens.Space.x6 : dx, dy: dy)
        }
        for (i, card) in leaving.enumerated() { card.frame = old[after + i] }
        // At the standard pace, like the sidebar: a split is a change of layout you watch, not a show.
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, moves: true, {
            for i in 0..<after {
                cards[i].animator().frame = frames[i]
                if i >= before { cards[i].animator().alphaValue = self.pagesHidden ? 0 : 1 }
            }
            leaving.forEach { $0.animator().alphaValue = 0 }
        }, completion: {
            let count = self.tiles?.regions.count ?? 1
            for (i, card) in leaving.enumerated() where after + i >= count {
                self.leavingCards.remove(ObjectIdentifier(card))
                card.alphaValue = self.pagesHidden ? 0 : 1
            }
            self.needsLayout = true
        })
    }
    /// While closed panes fade, layout leaves them showing where they were.
    private var leavingCards: Set<ObjectIdentifier> = []

    // MARK: Zoom (#160)

    /// The pane enlarged over the others for a moment (its index in the group), nil for none. Nothing in the layout
    /// changes: the others stay where they are, live, under Peek's dimming, and the pane goes back to its place.
    private(set) var zoomedPane: Int?
    /// Over the other panes, under the enlarged one, dimmed as under Peek; a click on it puts the pane back.
    let zoomScrim = ScrimView()

    /// The enlarged pane's frame: the page area inset as Peek's card is, so it reads as the same layer over the page.
    var zoomFrame: NSRect {
        let area = cardFrame
        let dx = max(Tokens.Space.x8, Tokens.Space.snap(area.width * Tokens.Metric.peekInsetRatio))
        let dy = max(Tokens.Space.x6, Tokens.Space.snap(area.height * Tokens.Metric.peekInsetRatio * 0.6))
        return area.insetBy(dx: dx, dy: dy)
    }

    /// Enlarges the pane at `index` over the rest (nil: puts it back), growing out of its place and settling back
    /// into it; with Reduce Motion, a crossfade.
    func setZoomedPane(_ index: Int?, animated: Bool) {
        let index = index.flatMap { paneCards.indices.contains($0) && tiles != nil ? $0 : nil }
        guard index != zoomedPane else { return }
        let old = zoomedPane
        zoomedPane = index
        let cards = paneCards
        if let index {
            if zoomScrim.superview !== self { addSubview(zoomScrim) }
            zoomScrim.color = Tokens.Color.peekScrim
            zoomScrim.frame = cardFrame
            orderForZoom(cards[index])
            if animated { zoomScrim.show() } else { zoomScrim.alphaValue = 1 }
        } else if zoomScrim.superview != nil {
            if animated { zoomScrim.hide(evenFromKeyboard: true) } else { zoomScrim.removeFromSuperview() }
        }
        let frames = tileFrames
        // The pane that leaves the zoom goes back to its place; the one that comes in grows out of it.
        let moving = [old, index].compactMap { $0 }.filter { cards.indices.contains($0) && frames.indices.contains($0) }
        let target = { (i: Int) -> NSRect in i == index ? self.zoomFrame : (i == 0 ? self.cardViewFrame(frames[0]) : frames[i]) }
        guard animated, window != nil else {
            moving.forEach { cards[$0].frame = target($0) }
            needsLayout = true
            return
        }
        if Tokens.Motion.reduceMotion {
            for i in moving {
                cards[i].alphaValue = 0
                cards[i].frame = target(i)
            }
            Tokens.Motion.animate(Tokens.Motion.feedback, evenFromKeyboard: true) { moving.forEach { cards[$0].animator().alphaValue = 1 } }
            needsLayout = true
            return
        }
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, moves: true, {
            moving.forEach { cards[$0].animator().frame = target($0) }
        }, completion: { self.needsLayout = true })
    }

    /// The scrim and then the enlarged pane just above the panes, under everything else (the sidebar floating in, the
    /// bar, what floats over the page), without taking any page out of the window to do it.
    private func orderForZoom(_ zoomed: PageCardView) {
        let original = subviews
        guard let last = original.lastIndex(where: { view in paneCards.contains { $0 === view } }) else { return }
        var ranks: [ObjectIdentifier: Double] = [:]
        for (i, view) in original.enumerated() { ranks[ObjectIdentifier(view)] = Double(i) }
        ranks[ObjectIdentifier(zoomScrim)] = Double(last) + 0.5
        ranks[ObjectIdentifier(zoomed)] = Double(last) + 0.7
        let box = Unmanaged.passRetained(RankBox(ranks))
        defer { box.release() }
        sortSubviews({ a, b, context in
            guard let context else { return .orderedSame }
            let ranks = Unmanaged<RankBox>.fromOpaque(context).takeUnretainedValue().ranks
            let x = ranks[ObjectIdentifier(a)] ?? 0, y = ranks[ObjectIdentifier(b)] ?? 0
            return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }, context: box.toOpaque())
    }

    private final class RankBox {
        let ranks: [ObjectIdentifier: Double]
        init(_ ranks: [ObjectIdentifier: Double]) { self.ranks = ranks }
    }
    /// The panes' lines moved: the new shape, and whether the drag is done.
    var onTilesChange: ((TileShape, Bool) -> Void)?
    /// Back, forward, reload and the address above the page, when they're there (`addressAbovePage`).
    let topBar = TopBarView()
    var showsTopBar = false {
        didSet {
            guard oldValue != showsTopBar else { return }
            topBar.isHidden = !showsTopBar
            needsLayout = true
            refreshGlassFrame()
            refreshGlassOcclusion()
        }
    }
    /// Highlights where a dragged tab would open beside the current page.
    let splitDropHint = SplitDropHint()
    private let resizeHandle = ResizeHandle()
    /// Floating surfaces (command bar, previews, peek) live here, above everything.
    let overlay = PassthroughView()
    /// An extension's side panel, docked right of the page while open.
    let sidePanel = ExtensionSidePanelView()
    var showsSidePanel = false {
        didSet {
            guard oldValue != showsSidePanel else { return }
            sidePanel.isHidden = !showsSidePanel
            needsLayout = true
        }
    }

    var sidebarVisible = true
    var sidebarWidth: CGFloat = Tokens.Metric.sidebarWidth
    private(set) var sidebarRevealed = false
    var onLayoutChange: (() -> Void)?
    /// Called when the sidebar starts a slide, with how long it lasts (0 = no animation).
    var onSlide: ((TimeInterval) -> Void)?
    var onSidebarWidthChange: ((CGFloat) -> Void)?
    /// The width when a drag on the sidebar's edge began, kept if the drag closes it.
    private var widthBeforeDrag: CGFloat = Tokens.Metric.sidebarMinWidth
    /// Through the whole drag, closed or not, so it can be dragged back out.
    private var isDraggingSidebarEdge = false

    private var trackingArea: NSTrackingArea?
    private var borderlessToken: NSObjectProtocol?
    /// Keeps the floating sidebar open, e.g. while a menu from it is showing.
    var holdReveal = false
    /// Also keeps it open: a panel that came out of it (the site panel, downloads) is still showing.
    var keepsRevealed: (() -> Bool)?
    private var isHeld: Bool { holdReveal || keepsRevealed?() == true }

    init(sidebar: SidebarView) {
        sidebarContainer = SidebarContainer(sidebar: sidebar)
        super.init(color: SpaceColor.sky.background)
        addSubview(card)
        sidePanel.isHidden = true
        addSubview(sidePanel)
        emptyHint.alphaValue = 0
        addSubview(emptyHint)
        for extra in extraCards {
            extra.isHidden = true
            addSubview(extra)
        }
        rowHandle.isVertical = true
        for handle in [columnHandle, rowHandle] {
            handle.isHidden = true
            addSubview(handle)
        }
        topBar.isHidden = true
        addSubview(topBar)
        // Never so narrow (or short) that a pane's header loses its buttons: a share of the window, and points too.
        columnHandle.onDrag = { [weak self] x in
            guard let self, var shape = self.tiles else { return }
            let area = self.cardFrame
            shape.column = TileShape.clamped((x - area.minX) / area.width, length: area.width, minimum: Self.minimumPaneWidth)
            self.tiles = shape
            self.layoutSubtreeIfNeeded()
            self.onTilesChange?(shape, false)
        }
        rowHandle.onDrag = { [weak self] value in
            guard let self, var shape = self.tiles else { return }
            let area = self.cardFrame
            // Window y runs bottom-up; this view is flipped.
            let y = self.convert(NSPoint(x: 0, y: value), from: nil).y
            shape.row = TileShape.clamped((y - area.minY) / area.height, length: area.height, minimum: Self.minimumPaneHeight)
            self.tiles = shape
            self.layoutSubtreeIfNeeded()
            self.onTilesChange?(shape, false)
        }
        for handle in [columnHandle, rowHandle] {
            handle.onEnd = { [weak self] in
                guard let self, let shape = self.tiles else { return }
                self.onTilesChange?(shape, true)
            }
        }
        // Even again: the panes glide to halves rather than jumping.
        columnHandle.onDoubleClick = { [weak self] in
            guard let self, var shape = self.tiles else { return }
            shape.column = 0.5
            self.setTiles(shape, animated: true)
            self.onTilesChange?(shape, true)
        }
        rowHandle.onDoubleClick = { [weak self] in
            guard let self, var shape = self.tiles else { return }
            shape.row = 0.5
            self.setTiles(shape, animated: true)
            self.onTilesChange?(shape, true)
        }
        addSubview(resizeHandle)
        addSubview(sidebarContainer)
        addSubview(splitDropHint)
        addSubview(overlay)
        borderlessToken = NotificationCenter.default.addObserver(forName: Self.borderlessChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Tokens.Motion.animate(Tokens.Motion.gentle, moves: true) {
                    self.needsLayout = true
                    self.layoutSubtreeIfNeeded()
                }
            }
        }
        resizeHandle.onBegin = { [weak self] in
            guard let self else { return }
            self.widthBeforeDrag = self.sidebarWidth
            self.isDraggingSidebarEdge = true
        }
        resizeHandle.onDrag = { [weak self] point in
            guard let self else { return }
            let x = Self.reach(of: point, in: self.bounds, onRight: self.sidebarOnRight)
            // Dragged well past its narrowest, it closes, as a Mac sidebar does; dragged back out in the same drag, it
            // opens again. Closed this way it keeps the width it had, for when it opens next.
            let closesAt = Tokens.Metric.sidebarMinWidth / 2
            if self.sidebarVisible, x < closesAt {
                self.sidebarWidth = self.widthBeforeDrag
                self.setSidebarVisible(false, animated: true)
                return
            }
            if !self.sidebarVisible {
                guard x >= closesAt else { return }
                self.sidebarWidth = Tokens.Metric.sidebarMinWidth
                self.setSidebarVisible(true, animated: true)
                return
            }
            let width = Tokens.Space.snap(min(max(x, Tokens.Metric.sidebarMinWidth), Tokens.Metric.sidebarMaxWidth))
            guard width != self.sidebarWidth else { return }
            self.sidebarWidth = width
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        resizeHandle.onEnd = { [weak self] in
            guard let self else { return }
            self.isDraggingSidebarEdge = false
            self.needsLayout = true
            self.onSidebarWidthChange?(self.sidebarWidth)
        }
        // Links and files dropped on the page area open as tabs too: an empty window, or with the sidebar hidden.
        // A page itself takes its own drops (a file into an upload box), as WebKit does.
        registerForDraggedTypes([.URL, .fileURL, .string])
        pageDropRing.isHidden = true
        pageDropRing.borderWidth = 2
        pageDropRing.cornerCurve = .continuous
        pageDropRing.zPosition = 50
        layer?.addSublayer(pageDropRing)
    }

    required init?(coder: NSCoder) { fatalError() }

    private let pageDropRing = CALayer()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !SidebarContainer.droppedURLs(sender).isEmpty else { return [] }
        SidebarContainer.showDropRing(pageDropRing, true, around: cardFrame.insetBy(dx: 4, dy: 4), in: self)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        SidebarContainer.showDropRing(pageDropRing, false, around: cardFrame.insetBy(dx: 4, dy: 4), in: self)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        SidebarContainer.showDropRing(pageDropRing, false, around: cardFrame.insetBy(dx: 4, dy: 4), in: self)
        return SidebarContainer.open(SidebarContainer.droppedURLs(sender), in: window)
    }

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

    /// Back, forward, reload and the address in a bar above the page instead of at the top of the sidebar, as in Arc.
    /// Off unless turned on in Settings.
    static var addressAbovePage: Bool {
        get { UserDefaults.standard.bool(forKey: "addressAbovePage") }
        set {
            UserDefaults.standard.set(newValue, forKey: "addressAbovePage")
            NotificationCenter.default.post(name: addressPlaceChanged, object: nil)
        }
    }
    static let addressPlaceChanged = Notification.Name("AddressPlaceChanged")

    /// The sidebar along the window's right edge instead of its left (#166), as Arc's Sidebar on the Right. Off unless
    /// turned on in Settings › Appearance or the View menu.
    static var sidebarOnRight: Bool {
        get { UserDefaults.standard.bool(forKey: "sidebarOnRight") }
        set {
            UserDefaults.standard.set(newValue, forKey: "sidebarOnRight")
            NotificationCenter.default.post(name: sidebarSideChanged, object: nil)
        }
    }
    static let sidebarSideChanged = Notification.Name("SidebarSideChanged")

    /// Which edge this window's sidebar is on now: the setting, followed by `setSidebarOnRight`.
    private(set) var sidebarOnRight = BrowserRootView.sidebarOnRight

    /// Every frame is worked out with the sidebar on the left; on the right, it's the same frame turned over the
    /// window's middle, so the two layouts are mirror images and nothing has a side of its own to get wrong.
    static func mirrored(_ rect: NSRect, in bounds: NSRect, if onRight: Bool) -> NSRect {
        guard onRight else { return rect }
        return NSRect(x: bounds.minX + bounds.maxX - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// With the sidebar on the right, the traffic lights stay at the window's top left, as on every Mac window: the
    /// page leaves them a strip of the frame as tall as the sidebar's top row, so its top lines up with the sidebar's
    /// address. Not with the bar above the page, which holds them, nor in full screen, where they're the menu bar's.
    static let lightsStripHeight: CGFloat = Tokens.Sidebar.addressTop

    /// The room above the page for the traffic lights (`lightsStripHeight`), or 0.
    var lightsRoom: CGFloat {
        sidebarOnRight && sidebarVisible && !showsTopBar && window?.styleMask.contains(.fullScreen) != true ? Self.lightsStripHeight : 0
    }

    /// The bar above the page: from the sidebar's edge, or the window's with the sidebar hidden, to the window's other
    /// edge. `inset`: framed, the bar starts the frame's inset down, the top of the card it makes with the page, so its
    /// buttons and address sit in that card's middle.
    static func topBarFrame(in bounds: NSRect, sidebarVisible: Bool, sidebarWidth: CGFloat, inset: CGFloat = 0, onRight: Bool = false) -> NSRect {
        let x = sidebarVisible ? sidebarWidth : 0
        let y = min(bounds.height, inset)
        let bar = NSRect(x: bounds.minX + x, y: y, width: max(0, bounds.width - x), height: min(bounds.height - y, TopBarView.height))
        return mirrored(bar, in: bounds, if: onRight)
    }

    var topBarFrame: NSRect {
        Self.topBarFrame(in: bounds, sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth, inset: topBarInset, onRight: sidebarOnRight)
    }

    /// Framed, the bar is the top of the page's card; borderless or edge to edge, it starts at the window's top.
    private var topBarInset: CGFloat { isEdgeToEdge || Self.isBorderless ? 0 : Tokens.Metric.cardInset }

    var cardFrame: NSRect {
        let whole = pageAreaFrame
        guard showsSidePanel else { return whole }
        // The side panel takes the right, a gap away; the page keeps at least a pane's worth.
        let width = min(ExtensionSidePanelView.width, max(0, whole.width - Self.minimumPaneWidth - Tokens.Metric.cardInset))
        let gap = isEdgeToEdge ? 1 : Tokens.Metric.cardInset
        return NSRect(x: whole.minX, y: whole.minY, width: whole.width - width - gap, height: whole.height)
    }

    /// Where the side panel sits: beside the page, a gap away, over the same height, reaching as far right as the page
    /// would have. It reads as a second pane, like a split's.
    var sidePanelFrame: NSRect {
        let whole = pageAreaFrame, page = cardFrame
        let gap = isEdgeToEdge ? 1 : Tokens.Metric.cardInset
        return NSRect(x: page.maxX + gap, y: whole.minY, width: max(0, whole.maxX - page.maxX - gap), height: whole.height)
    }

    /// The page area as a whole, before a side panel takes its share.
    private var pageAreaFrame: NSRect {
        Self.pageArea(in: bounds, sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth, edgeToEdge: isEdgeToEdge,
                      borderless: Self.isBorderless, topBar: showsTopBar, barInset: topBarInset, onRight: sidebarOnRight, lightsRoom: lightsRoom)
    }

    /// Where the pages go. With the bar above the page, they start under it: framed, the bar stands in for the gap
    /// above the page; borderless or edge to edge, the page meets it in a straight line, as Zigzag Mini's meets its strip.
    /// `onRight`: the sidebar is on the right, and the page is the mirror image of its place beside a left one.
    /// `lightsRoom`: the page starts at least this far down, under the traffic lights (`lightsStripHeight`).
    static func pageArea(in bounds: NSRect, sidebarVisible: Bool, sidebarWidth: CGFloat, edgeToEdge: Bool, borderless: Bool, topBar: Bool,
                         barInset: CGFloat = 0, onRight: Bool = false, lightsRoom: CGFloat = 0) -> NSRect {
        let inset = Tokens.Metric.cardInset
        var area: NSRect
        if edgeToEdge {
            area = bounds
        } else if sidebarVisible {
            // Borderless, the page meets the window's edges and only its side by the sidebar is rounded.
            area = borderless ? NSRect(x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: bounds.height)
                : NSRect(x: sidebarWidth, y: inset, width: max(0, bounds.width - sidebarWidth - inset), height: max(0, bounds.height - inset * 2))
        } else {
            area = bounds.insetBy(dx: inset, dy: inset)
        }
        area = mirrored(area, in: bounds, if: onRight)
        if !topBar, lightsRoom > 0 {
            let top = bounds.minY + min(bounds.height, lightsRoom)
            if area.minY < top {
                area.size.height = max(0, area.maxY - top)
                area.origin.y = top
            }
        }
        guard topBar else { return area }
        let top = bounds.minY + min(bounds.height, barInset + TopBarView.height)
        area.size.height = max(0, area.maxY - top)
        area.origin.y = top
        return area
    }

    /// The left (or only) pane and the right pane, inside the page area: the first two of `tileFrames`.
    var paneFrames: (left: NSRect, right: NSRect?) {
        let frames = tileFrames
        return (frames[0], frames.count > 1 ? frames[1] : nil)
    }

    /// The gap between panes. Borderless, the pages meet at a hairline instead of floating apart.
    var paneGap: CGFloat { isEdgeToEdge ? 1 : Tokens.Metric.cardInset }

    /// Every pane's frame inside the page area, in the group's order; the whole of it with one page.
    var tileFrames: [NSRect] {
        guard let tiles else { return [cardFrame] }
        return tiles.frames(in: cardFrame, gap: paneGap)
    }

    /// Splits `area` (top-down) into a split's two panes, `gap` apart; the whole of it when there's no split. Desk
    /// cards draw a split the same way, so a card is the page area in small.
    static func paneFrames(in area: NSRect, ratio: CGFloat?, vertical: Bool, gap: CGFloat) -> (left: NSRect, right: NSRect?) {
        guard let ratio else { return (area, nil) }
        if vertical {
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

    /// Which of a pane's outer corners (its right ones, or its left ones with the sidebar on the right) are the
    /// window's own corners: on the window's edge across from the sidebar and its top or bottom. The window rounds
    /// those itself, so they're square; every other corner, a split's at the gap included, stays round.
    /// Under the bar above the page, or the strip for the traffic lights, the top outer corner meets it and the
    /// window's edge in a line, as the window's own corner would, so it's square too.
    private func windowCorners(of pane: NSRect, attached: Bool) -> (top: Bool, bottom: Bool) {
        let outer = sidebarOnRight ? pane.minX <= bounds.minX + 1 : pane.maxX >= bounds.maxX - 1
        guard attached, outer else { return (false, false) }
        let top = showsTopBar ? topBarFrame.maxY : bounds.minY + lightsRoom
        return (pane.minY <= top + 1, pane.maxY >= bounds.maxY - 1)
    }

    /// Squares a pane's window corners (`windowCorners`) on its side across from the sidebar; the other side rounds.
    private func squareCorners(of card: PageCardView, pane: NSRect?, attached: Bool) {
        let corners = pane.map { windowCorners(of: $0, attached: attached) } ?? (false, false)
        card.squaresRightCorners = sidebarOnRight ? (false, false) : corners
        card.squaresLeftCorners = sidebarOnRight ? corners : (false, false)
    }

    /// The shown page's own color, for the bar above it (`paintTopBar`).
    private var pageColor: NSColor?

    /// The bar above the page in the page's color, nil for none: the page's card grows up under the bar, its top in
    /// that color, so the two read as one card and move as one. Not in split view, where two pages have two colors.
    func paintTopBar(_ color: NSColor?) {
        let before = (color: pageColor, painted: paintsTopBar)
        pageColor = color
        topBar.pageColor = paintsTopBar ? color : nil
        // The same color again (asked on every load, navigation and color report, mostly unchanged) leaves the
        // window's layout alone: laying the whole window out each time kept the main thread busy (#89).
        if before.color != color || before.painted != paintsTopBar { needsLayout = true }
        refreshGlassOcclusion()
    }

    private var paintsTopBar: Bool { showsTopBar && pageColor != nil && tiles == nil && !isEmpty }

    /// The page card's own frame for `pane`: under a bar in the page's color, it reaches up to the bar's top.
    private func cardViewFrame(_ pane: NSRect) -> NSRect {
        guard paintsTopBar else { return pane }
        let top = min(pane.minY, topBarFrame.minY)
        return NSRect(x: pane.minX, y: top, width: pane.width, height: pane.maxY - top)
    }

    private func layoutCards() {
        let frames = tileFrames
        emptyHint.frame = Self.markFrame(in: frames[0])
        paneCards.forEach { $0.isEdgeToEdge = isEdgeToEdge }
        let left = cardViewFrame(frames[0])
        card.frame = left
        card.band = left.height - frames[0].height
        topBar.pageColor = paintsTopBar ? pageColor : nil
        let attached = sidebarVisible && Self.isBorderless
        squareCorners(of: card, pane: left, attached: attached)
        card.isAttached = attached
        for (i, extra) in extraCards.enumerated() {
            let pane = frames.count > i + 1 ? frames[i + 1] : nil
            squareCorners(of: extra, pane: pane, attached: attached)
            extra.isAttached = attached
            if let pane {
                extra.isHidden = false
                extra.frame = pane
            } else {
                extra.isHidden = !leavingCards.contains(ObjectIdentifier(extra))
            }
        }
        let lines = tiles?.dividers(in: cardFrame, gap: paneGap, slop: 2)
        // While a pane is enlarged the lines between the panes rest under the dimming.
        columnHandle.isHidden = lines?.column == nil || zoomedPane != nil
        rowHandle.isHidden = lines?.row == nil || zoomedPane != nil
        if let column = lines?.column { columnHandle.frame = column }
        if let row = lines?.row { rowHandle.frame = row }
        splitDropHint.frame = cardFrame
        if let zoomed = zoomedPane, tiles != nil, paneCards.indices.contains(zoomed) {
            if zoomed == 0 { card.band = 0 }
            paneCards[zoomed].frame = zoomFrame
            zoomScrim.frame = cardFrame
        }
        if showsSidePanel {
            let frame = sidePanelFrame
            sidePanel.frame = frame
            // Shaped like a page pane: the same corners, square where they're the window's own.
            let attached = sidebarVisible && Self.isBorderless
            // Beside a sidebar on the right it sits between the page and the sidebar, with no window corners.
            sidePanel.setShape(radius: isEdgeToEdge ? 0 : attached ? PageCardView.attachedRadius : Tokens.Radius.card,
                               squareRight: sidebarOnRight ? (false, false) : windowCorners(of: frame, attached: attached))
        }
    }

    var sidebarFrame: NSRect {
        Self.sidebarFrame(in: bounds, width: sidebarWidth, visible: sidebarVisible, revealed: sidebarRevealed, onRight: sidebarOnRight)
    }

    /// The sidebar's frame: docked along the window's edge, floating a frame's inset in from it while slid out, or
    /// out of sight past that edge.
    static func sidebarFrame(in bounds: NSRect, width: CGFloat, visible: Bool, revealed: Bool, onRight: Bool) -> NSRect {
        let inset = Tokens.Metric.cardInset
        if visible { return mirrored(NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height), in: bounds, if: onRight) }
        let x = bounds.minX + (revealed ? inset : -width - inset * 4)
        return mirrored(NSRect(x: x, y: bounds.minY + inset, width: width, height: bounds.height - inset * 2), in: bounds, if: onRight)
    }

    /// Where a panel `width` wide goes beside the sidebar, a little way out over the page: right of it, or left of it
    /// when it's on the right (tab previews, the space editor, the icon picker).
    func besideSidebar(width: CGFloat) -> CGFloat {
        let sidebar = sidebarContainer.frame
        return sidebarOnRight ? sidebar.minX - Tokens.Space.x2 - width : sidebar.maxX + Tokens.Space.x2
    }

    /// The resize handle, on the sidebar's edge that faces the page.
    static func resizeHandleFrame(in bounds: NSRect, sidebarWidth: CGFloat, onRight: Bool) -> NSRect {
        let width = Tokens.Metric.resizeHandleWidth
        return mirrored(NSRect(x: bounds.minX + sidebarWidth - width / 2, y: bounds.minY, width: width, height: bounds.height), in: bounds, if: onRight)
    }

    /// The sidebar's width for a drag of its edge to `x`: how far that is from the window's edge it's on.
    static func reach(of x: CGFloat, in bounds: NSRect, onRight: Bool) -> CGFloat { onRight ? bounds.maxX - x : x - bounds.minX }

    /// Where the glass needs to be: only what you can see through. With the page meeting the sidebar, that's the
    /// sidebar alone; the page covers the rest, and a live blur under it would cost the window server a fresh blur
    /// of the whole window every frame the page changes (a video, an animation). Otherwise the whole window.
    override var glassFrame: NSRect {
        // Edge to edge under the bar above the page, only the bar shows the frame, as in Zigzag Mini.
        if showsTopBar, isEdgeToEdge, !card.isHidden, !isEmpty { return topBarFrame }
        // Beside the sidebar too, the frame shows along the top and the side: glass under all of it.
        if showsTopBar { return bounds }
        // An empty space shows the frame where the page would be: glass under all of it.
        // A split view's seam between its two pages shows the frame too: glass under all of it then.
        // So does the strip above the page for the traffic lights, beside a sidebar on the right.
        guard sidebarVisible, lightsRoom == 0, card.isAttached, !card.isHidden, !isEmpty,
              extraCards.allSatisfy({ $0.isHidden || $0.alphaValue == 0 }) else { return bounds }
        return Self.mirrored(NSRect(x: 0, y: 0, width: min(bounds.width, sidebarWidth + Tokens.Radius.attached * 2), height: bounds.height),
                             in: bounds, if: sidebarOnRight)
    }

    /// Set while something opaque with glass of its own covers the whole window (the tab overview): the window's
    /// glass rests and the pages under it are hidden, so neither costs anything while out of sight.
    var glassCovered = false {
        didSet {
            guard oldValue != glassCovered else { return }
            paneCards.forEach { $0.isCoveredOver = glassCovered }
            refreshGlassOcclusion()
        }
    }

    /// Nothing to see through: the page runs edge to edge, or the tab overview covers the window with its own glass.
    override var glassIsCovered: Bool { (isEdgeToEdge && (!showsTopBar || paintsTopBar) && !card.isHidden && !isEmpty) || glassCovered }

    override func layout() {
        super.layout()
        placeStrips(animated: false)
        layoutCards()
        layoutTopBar()
        sidebarContainer.frame = sidebarFrame
        sidebarContainer.isFloating = !sidebarVisible && !leavesDocked
        // Docked beside the bar above the page, the sidebar's top row stays on the bar's middle line.
        sidebarContainer.sidebar.topRowDrop = sidebarTopRowDrop
        resizeHandle.frame = Self.resizeHandleFrame(in: bounds, sidebarWidth: sidebarWidth, onRight: sidebarOnRight)
        resizeHandle.isHidden = !sidebarVisible && !isDraggingSidebarEdge
        overlay.frame = bounds
        onLayoutChange?()
    }

    /// Full screen with the frame on: the page runs edge to edge while the sidebar is hidden, so the frame comes and
    /// goes with the sidebar, and the bar above the page moves down and up by its inset as it does.
    private var frameComesWithSidebar: Bool { !Self.isBorderless && window?.styleMask.contains(.fullScreen) == true }

    /// How far down the docked sidebar's top row sits, to stay on the middle line of the bar above the page. Not
    /// where the frame comes and goes with the sidebar: there the row would move as the sidebar is shown, and its
    /// toggle, the one thing you reach for in that corner, stays where it is with the sidebar hidden.
    var sidebarTopRowDrop: CGFloat {
        showsTopBar && !sidebarContainer.isFloating && !frameComesWithSidebar ? topBarFrame.minY : 0
    }

    private func layoutTopBar() {
        guard showsTopBar else { return }
        let page = pageAreaFrame
        placeTopBar()
        // Beside it, the sidebar's favorites and tabs start where the page does.
        if sidebarVisible { sidebarContainer.sidebar.contentTop = page.minY - sidebarFrame.minY }
    }

    /// The address's end is over the page's card, the bar being its top: not beside an extension's side panel, where
    /// it runs on over the panel.
    private var addressEndsOnCard: Bool { paintsTopBar && !showsSidePanel }

    /// The bar's controls run from the page's left edge to its right: at the frame's inset, or just inside the
    /// window's edges when the page meets them.
    private func placeTopBar() {
        let bar = topBarSlideFrame ?? topBarFrame
        topBar.frame = bar
        topBar.rowTop = topBarFrame.minY - bar.minY
        (topBar.leadingInset, topBar.trailingInset) = TopBarView.insets(bar: bar, page: pageAreaFrame, window: bounds, onCard: addressEndsOnCard)
        let frames = tileFrames
        let over = liftedCards.map { lifted in paneCards.firstIndex { $0 === lifted }.flatMap { frames.indices.contains($0) ? frames[$0] : nil } ?? frames[0] }
        topBar.setStrips(liftedCards.map(\.header), panes: over.map { ($0.minX - bar.minX)...max($0.minX, $0.maxX) - bar.minX })
        topBar.stripInset = TopBarView.edgeInset(page: cardFrame, window: bounds)
    }

    // MARK: Split view under the bar

    /// The cards whose strips are up in the bar's row now.
    private var liftedCards: [PageCardView] = []
    private var stripFades = 0

    /// Under the bar above the page, a split's strips are the bar: each pane's moves up into the bar's row, over its
    /// pane, and the bar's own back, forward, reload and address, which would belong to neither page, step aside.
    /// Stacked, the top pane's goes up; the bottom one keeps its own on its card. In a tile group, the panes along
    /// the top, left to right.
    private var cardsForBar: [PageCardView] {
        guard showsTopBar, tiles != nil else { return [] }
        let frames = tileFrames, top = cardFrame.minY
        return frames.indices.filter { frames[$0].minY <= top + 0.5 }.sorted { frames[$0].minX < frames[$1].minX }.map { paneCards[$0] }
    }

    /// Whether the panes' strips are in the bar's row.
    var stripsInBar: Bool { !liftedCards.isEmpty }

    /// Moves the strips up into the bar or gives them back to their cards. Into a split or out of one, the bar holds
    /// still and its own controls and the strips cross-fade in place as the panes slide (the first pane's back, forward
    /// and reload come in where the bar's were); anything else changes at once.
    private func placeStrips(animated: Bool) {
        let cards = cardsForBar
        guard cards != liftedCards else { return }
        let entering = liftedCards.isEmpty, leaving = cards.isEmpty
        liftedCards = cards
        stripFades += 1
        let fade = stripFades
        for card in cards { card.liftsHeader = true }
        placeTopBar()
        let given = paneCards.filter { $0.liftsHeader && !cards.contains($0) }
        let own = topBar.ownControls
        guard animated, entering || leaving, window != nil, !Tokens.Motion.reduceMotion else {
            Tokens.Motion.withoutAnimation {
                given.forEach { $0.liftsHeader = false }
                cards.forEach { $0.header.alphaValue = $0.headerAlpha }
                own.forEach { $0.alphaValue = 1; $0.isHidden = !cards.isEmpty }
            }
            return
        }
        Tokens.Motion.withoutAnimation {
            if entering { cards.forEach { $0.header.alphaValue = 0 } } else { own.forEach { $0.alphaValue = 0; $0.isHidden = false } }
            topBar.layoutSubtreeIfNeeded()
        }
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, {
            for card in cards { card.header.animator().alphaValue = card.headerAlpha }
            for card in given { card.header.animator().alphaValue = 0 }
            for view in own { view.animator().alphaValue = entering ? 0 : 1 }
        }, completion: {
            // Not if another change took over meanwhile: that one settles it.
            guard self.stripFades == fade else { return }
            given.forEach { $0.liftsHeader = false }
            if entering { own.forEach { $0.isHidden = true; $0.alphaValue = 1 } }
        })
    }

    /// Where a click picks a pane in split view: the pane, and its strip up in the bar.
    var paneTargets: (left: NSRect, right: NSRect?) {
        let targets = tileTargets
        return (targets[0], targets.count > 1 ? targets[1] : nil)
    }

    /// The same for every pane, in the group's order.
    var tileTargets: [NSRect] {
        let frames = tileFrames
        guard stripsInBar else { return frames }
        let top = topBarFrame.minY
        return frames.indices.map { i in
            let pane = frames[i]
            guard liftedCards.contains(where: { $0 === paneCards[i] }) else { return pane }
            return NSRect(x: pane.minX, y: top, width: pane.width, height: pane.maxY - top)
        }
    }

    /// While the sidebar slides, the bar holds still over both where it was and where it's going, and only its
    /// controls move: a view gliding inside one that's moving too can't keep them in step.
    private var topBarSlideFrame: NSRect?
    private var topBarSlides = 0

    /// Under the bar above the page, the sidebar leaves as it sat, part of the window's frame like the bar, rather
    /// than as a floating card whose edge would cut across the bar; it floats once it's out of sight.
    private var leavesDocked = false

    func setSidebarVisible(_ visible: Bool, animated: Bool) {
        guard visible != sidebarVisible else { return }
        let oldSidebar = sidebarContainer.frame
        let oldBar = topBar.frame, oldControls = topBar.controlPositions
        topBarSlides += 1
        let slide = topBarSlides
        sidebarVisible = visible
        sidebarRevealed = false
        watchPointer(false)
        leavesDocked = !visible && showsTopBar && animated && !Tokens.Motion.reduceMotion
        sidebarContainer.isFloating = !visible && !leavesDocked
        // It slides however it was asked for, the keyboard included: where the sidebar went is worth seeing.
        guard animated, !Tokens.Motion.reduceMotion else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        // The page card resizes with AppKit's animator; the sidebar slides on the render server.
        let targetSidebar = visible ? sidebarFrame
            : Self.mirrored(NSRect(x: -sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height), in: bounds, if: sidebarOnRight)
        Tokens.Motion.withoutAnimation { sidebarContainer.frame = targetSidebar }
        let duration = Tokens.Motion.slide(sidebarContainer, fromOffsetX: oldSidebar.minX - targetSidebar.minX, curve: Tokens.Motion.slide, fromKeyboard: true)
        if showsTopBar, duration > 0 {
            topBarSlideFrame = (topBarSlideFrame ?? oldBar).union(topBarFrame)
            placeTopBar()
        }
        onSlide?(duration)
        // Borderless: the corners square off as the page grows to the window's edges, and round again as it shrinks.
        // Beside the sidebar, borderless, the page rounds like the window's corner; floating, like a card.
        let frames = tileFrames
        let cards = paneCards
        for (i, pageCard) in cards.enumerated() {
            let pane = frames.indices.contains(i) ? (i == 0 ? cardViewFrame(frames[0]) : frames[i]) : nil
            squareCorners(of: pageCard, pane: pane, attached: visible && Self.isBorderless)
            pageCard.isAttached = visible && Self.isBorderless
            pageCard.setEdgeToEdge(isEdgeToEdge, duration: duration)
        }
        refreshGlassOcclusion()
        // The bar's controls and the page move as one: nothing in the bar jumps to its new place.
        if topBarSlideFrame != nil { topBar.slideControls(from: oldControls, curve: Tokens.Motion.slide) }
        Tokens.Motion.animate(Tokens.Motion.slide, evenFromKeyboard: true, moves: true, {
            if self.topBarSlideFrame == nil, self.showsTopBar { self.topBar.animator().frame = self.topBarFrame }
            let frames = self.tileFrames
            self.card.animator().frame = self.cardViewFrame(frames[0])
            self.emptyHint.animator().frame = Self.markFrame(in: frames[0])
            for i in frames.indices.dropFirst() { cards[i].animator().frame = frames[i] }
        }, completion: {
            self.leavesDocked = false
            // Not if another slide took over meanwhile: that one ends it.
            if self.topBarSlideFrame != nil, self.topBarSlides == slide { self.topBarSlideFrame = nil }
            self.needsLayout = true
        })
    }

    /// Moves the sidebar to the window's other edge (Settings › Appearance › Sidebar on the right). Frames are final
    /// at once; the sidebar slides across on the render server while the pages glide over to their new places and
    /// the bar's controls with them, as the sidebar's show and hide moves them. A slid-out sidebar tucks away first.
    func setSidebarOnRight(_ onRight: Bool, animated: Bool) {
        guard onRight != sidebarOnRight else { return }
        if sidebarRevealed { reveal(false) }
        let oldSidebar = sidebarContainer.frame
        let oldCards = paneCards.map(\.frame), oldHint = emptyHint.frame
        let oldBar = topBar.frame, oldControls = topBar.controlPositions
        topBarSlides += 1
        let slide = topBarSlides
        sidebarOnRight = onRight
        window?.invalidateCursorRects(for: resizeHandle)
        needsLayout = true
        layoutSubtreeIfNeeded()
        refreshGlassFrame()
        refreshGlassOcclusion()
        guard animated, sidebarVisible, !Tokens.Motion.reduceMotion, window != nil else { onSlide?(0); return }
        let curve = Tokens.Motion.gentle
        let duration = Tokens.Motion.slide(sidebarContainer, fromOffsetX: oldSidebar.minX - sidebarContainer.frame.minX, curve: curve, fromKeyboard: true)
        onSlide?(duration)
        if showsTopBar, duration > 0 {
            topBarSlideFrame = oldBar.union(topBarFrame)
            placeTopBar()
            topBar.slideControls(from: oldControls, curve: curve)
        }
        let cards = paneCards, frames = cards.map(\.frame), hint = emptyHint.frame
        Tokens.Motion.withoutAnimation {
            for (card, old) in zip(cards, oldCards) where !card.isHidden && !old.isEmpty { card.frame = old }
            emptyHint.frame = oldHint
        }
        Tokens.Motion.animate(curve, evenFromKeyboard: true, moves: true, {
            for (card, frame) in zip(cards, frames) where !card.isHidden { card.animator().frame = frame }
            self.emptyHint.animator().frame = hint
        }, completion: {
            if self.topBarSlideFrame != nil, self.topBarSlides == slide { self.topBarSlideFrame = nil }
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

    /// The sidebar's edge of the window as the pointer meets it while the sidebar is hidden: where the pointer brings
    /// the sidebar out and where it keeps it out, worked out in one place (`SidebarEdgeZone`).
    private var edgeZone: SidebarEdgeZone {
        // The bar's strip at the window's left edge holds the traffic lights while the sidebar is hidden: reaching
        // for them there leaves the sidebar be, so they don't move off into it under the pointer. (A sidebar on the
        // right comes out at the other edge, clear of them.)
        let lights = showsTopBar && !sidebarVisible && !sidebarOnRight ? topBarFrame.maxY : 0
        let out = Self.sidebarFrame(in: bounds, width: sidebarWidth, visible: false, revealed: true, onRight: sidebarOnRight)
        return SidebarEdgeZone(bounds: bounds, sidebar: out, onRight: sidebarOnRight, reservedTop: lights)
    }

    /// Where the pointer is now, in this view's terms, whatever event is being handled and wherever the pointer is
    /// on screen, outside the window included.
    private var pointer: NSPoint? {
        window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if edgeZone.opens(at: convert(event.locationInWindow, from: nil)) { pointerAtEdge() }
    }

    /// Crossing the sidebar's edge of the window opens the sidebar, however fast: a quick flick out of the window
    /// may never land a moved event inside the edge strip, but it always leaves through it.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if edgeZone.opens(at: convert(event.locationInWindow, from: nil)) { pointerAtEdge() }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if edgeZone.opens(at: convert(event.locationInWindow, from: nil)) { pointerAtEdge() }
    }

    /// A breath before it opens, so touching the edge and coming straight back to the page (a web app's own list
    /// along that side) leaves it be. Still at the edge, or gone out past it, it opens.
    private static let edgeGrace: TimeInterval = 0.1
    private var edgeTimer: Timer?

    private func pointerAtEdge() {
        guard edgeTimer == nil, !sidebarVisible, !sidebarRevealed else { return }
        edgeTimer = Timer.scheduledTimer(withTimeInterval: Self.edgeGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.edgeTimer = nil
                if let point = self.pointer, self.edgeZone.opens(at: point) { self.reveal(true) }
            }
        }
    }

    private var pointerTimer: Timer?
    private var pointerLeftAt: Date?
    private var pointerObservers: [NSObjectProtocol] = []

    /// While the sidebar floats, follow the pointer itself: web views swallow mouse-moved events,
    /// and nothing arrives at all once the pointer is outside the window.
    private func watchPointer(_ on: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLeftAt = nil
        pointerObservers.forEach(NotificationCenter.default.removeObserver)
        pointerObservers = []
        guard on, let window else { return }
        // How closely to follow depends on whether you're using this window, so it's rechecked whenever that changes.
        let app: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        let own: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification]
        for (names, object) in [(app, nil as NSWindow?), (own, window)] {
            for name in names {
                pointerObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pacePointer() }
                })
            }
        }
        pacePointer()
    }

    /// Every frame while you're using the window, so the sidebar hides the moment you leave it. Otherwise a
    /// look twice a second is plenty to tuck it away, and none at all while the window can't be seen.
    private func pacePointer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard let window, !sidebarVisible, sidebarRevealed, window.occlusionState.contains(.visible) else { return }
        // Every frame only once the pointer has left, to time the hide exactly; while it rests on the sidebar a tenth of
        // a second is quick enough to notice it leave, and doesn't wake the Mac sixty times a second meanwhile.
        let attentive = NSApp.isActive && window.isKeyWindow
        let interval = !attentive ? 0.5 : pointerLeftAt == nil ? 0.1 : 1.0 / 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            // The view went away while the sidebar floated: nothing left to follow for.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.followPointer() }
        }
        timer.tolerance = interval < 0.05 ? 0.004 : interval / 2
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    isolated deinit {
        pointerTimer?.invalidate()
        pointerObservers.forEach(NotificationCenter.default.removeObserver)
        if let borderlessToken { NotificationCenter.default.removeObserver(borderlessToken) }
    }

    private func followPointer() {
        guard let point = pointer, !sidebarVisible, sidebarRevealed else { watchPointer(false); return }
        if edgeZone.keeps(at: point) || isHeld || NSEvent.pressedMouseButtons != 0 {
            if pointerLeftAt != nil { pointerLeftAt = nil; pacePointer() }
        } else if let left = pointerLeftAt {
            if Date().timeIntervalSince(left) > Tokens.Motion.edgeHideDelay { reveal(false) }
        } else {
            pointerLeftAt = Date()
            pacePointer()
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

    #if DEBUG
    /// Testing builds: a drag on the sidebar's edge, step by step ("begin", an x, "end"), as the handle reports it.
    func debugEdgeDrag(_ step: String) {
        switch step {
        case "begin": resizeHandle.onBegin?()
        case "end": resizeHandle.onEnd?()
        default: if let x = Double(step) { resizeHandle.onDrag?(CGFloat(x)) }
        }
    }
    #endif
}

/// The sidebar's edge of a window whose sidebar is hidden, as the pointer meets it: where the pointer brings the
/// sidebar out (`opens`), and where it keeps it out once it's there (`keeps`). Both read the same shape, so they
/// can't disagree: wherever the pointer opens the sidebar, it also keeps it. Top-down, in the window's own terms, and
/// the pointer may be anywhere on screen, outside the window included. Worked out for a sidebar on the left, as the
/// window's frames are; on the right it's the same shape turned over the window's middle.
struct SidebarEdgeZone: Equatable {
    /// The window's whole area.
    var bounds: NSRect
    /// Where the sidebar sits once it's out.
    var sidebar: NSRect
    /// The sidebar is along the window's right edge.
    var onRight = false
    /// A strip along the top, measured from the window's top, where the edge doesn't open the sidebar: the bar above
    /// the page keeps the traffic lights there.
    var reservedTop: CGFloat = 0
    /// How far out past the window's edge the pointer still counts as at it.
    var reach: CGFloat = .infinity

    /// The point, and the sidebar, as they'd be with the sidebar on the left.
    private func turned(_ point: NSPoint) -> NSPoint {
        onRight ? NSPoint(x: bounds.minX + bounds.maxX - point.x, y: point.y) : point
    }
    private var turnedSidebar: NSRect { BrowserRootView.mirrored(sidebar, in: bounds, if: onRight) }

    /// The strip just inside the window's edge ends here.
    private var stripEnd: CGFloat { bounds.minX + Tokens.Metric.edgeRevealWidth }

    /// Level with the window, and no further out past its edge than the reach.
    private func isBeside(_ point: NSPoint) -> Bool {
        point.y >= bounds.minY && point.y <= bounds.maxY && point.x >= bounds.minX - reach
    }

    /// At the sidebar's edge of the window: in the strip just inside it, or out past it.
    func opens(at point: NSPoint) -> Bool {
        let point = turned(point)
        return isBeside(point) && point.x <= stripEnd && point.y >= bounds.minY + reservedTop
    }

    /// On the sidebar, a little around it, or past it toward the window's edge: that's where the pointer went to
    /// summon it. The whole strip counts, so the pointer that opened it never lets it go by standing still.
    func keeps(at point: NSPoint) -> Bool {
        let point = turned(point), sidebar = turnedSidebar
        return sidebar.insetBy(dx: -Tokens.Space.x1, dy: -Tokens.Space.x1).contains(point)
            || (isBeside(point) && point.x <= max(stripEnd, sidebar.minX))
    }
}

/// A full-size layer for floating UI that lets clicks fall through where it has nothing.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Shown while a tab is dragged over the page: where it would open, beside what's there (`TileDrop`): a half or a
/// quarter of the page, or in place of a page that can't split again.
final class SplitDropHint: NSView {
    private let zone = ColorView()
    /// What the hint says, on a toast's pill so it reads over any page, kept clear of what the pointer carries.
    private let pill = FloatingPanelView()
    private let label = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    /// The pointer, in this view's terms, while something is carried over the page: the label keeps out from under
    /// the picture that hangs below it.
    private var pointer: CGPoint?
    /// Where a drop now would go, in this view's terms (it covers the page area); nil while it's not over the page.
    private(set) var drop: TileDrop?

    override init(frame: NSRect) {
        super.init(frame: frame)
        zone.wantsLayer = true
        zone.layer?.cornerRadius = Tokens.Radius.card
        zone.layer?.cornerCurve = .continuous
        zone.layer?.borderWidth = 2
        addSubview(zone)
        pill.radius = Tokens.Metric.toastHeight / 2
        // Laid out with the pill, inside its surface, as a toast lays out its label.
        pill.onLayout = { [weak self] in self?.layoutLabel() }
        pill.addSubview(label)
        addSubview(pill)
        label.alignment = .center
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where a pane dragged by its strip would go now (`PaneMove`), in this view's terms; nil while it would stay.
    private(set) var move: PaneMove?

    func show(_ drop: TileDrop?) {
        guard drop != self.drop || move != nil else { return }
        self.drop = drop
        move = nil
        present(drop?.frame, title: drop.map { Self.title(for: $0.kind) })
    }

    /// The same hint for a pane picked up by its strip: where it lands, the same zone, named for the move.
    func show(move: PaneMove?) {
        guard move != self.move || drop != nil else { return }
        self.move = move
        drop = nil
        present(move?.frame, title: move.map { Self.title(forMove: $0.kind) })
    }

    private func present(_ frame: CGRect?, title: String?) {
        isHidden = frame == nil
        guard let frame else { return }
        let target = frame.insetBy(dx: Tokens.Space.x2, dy: Tokens.Space.x2)
        zone.color = Tokens.Color.accent.withAlphaComponent(0.16)
        zone.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
        label.stringValue = title ?? ""
        let place = labelFrame(in: target)
        Tokens.Motion.animate(Tokens.Motion.feedback, moves: true) {
            self.zone.animator().frame = target
            self.pill.animator().frame = place
        }
        if zone.frame.isEmpty { zone.frame = target }
        if pill.frame.isEmpty { pill.frame = place }
        pill.needsLayout = true
    }

    /// The pointer moved (a window point; nil: nothing carried): the label moves out of its way if it has to.
    func follow(_ windowPoint: NSPoint?) {
        pointer = windowPoint.map { convert($0, from: nil) }
        guard !isHidden, !zone.frame.isEmpty else { return }
        let place = labelFrame(in: zone.frame)
        guard place != pill.frame else { return }
        Tokens.Motion.animate(Tokens.Motion.feedback, moves: true) { self.pill.animator().frame = place }
    }

    /// The label's pill in `zone`: centered across it, near its top, or near its bottom while the pointer is in its
    /// upper half, as what's carried hangs below the pointer.
    private func labelFrame(in zone: CGRect) -> CGRect {
        let h = Tokens.Metric.toastHeight, inset = Tokens.Space.x4
        // A few points in hand, as a field's text keeps before it cuts.
        let w = min(ceil(label.inkWidth) + Tokens.Space.x2 + inset * 2, max(0, zone.width - inset * 2))
        // Clear of a pane's strip at the top, so the pane's address still shows.
        let top = zone.minY + Tokens.Pane.height + Tokens.Space.x3
        let high = pointer.map { $0.y < zone.midY } ?? false
        let y = high ? max(top, zone.maxY - inset - h) : min(top, max(zone.minY, zone.maxY - inset - h))
        return CGRect(x: round(zone.midX - w / 2), y: round(y), width: w, height: h)
    }

    private func layoutLabel() {
        let h = label.lineHeight
        label.frame = NSRect(x: Tokens.Space.x4 - Label.inset, y: (pill.bounds.height - h) / 2,
                             width: max(0, pill.bounds.width - Tokens.Space.x4 * 2 + Label.inset * 2), height: h)
    }

    /// What the hint says over where the page would open.
    static func title(for kind: TileDrop.Kind) -> String {
        guard case .place(let region, _) = kind else {
            return String(localized: "Open Here", comment: "Shown over a page of a split view while a tab is dragged there: the tab opens in that page's place, and the page goes back to being a tab of its own.")
        }
        return switch region {
        case .left: String(localized: "Open on the Left", comment: "Shown over the left half of the page while a link or tab is dragged there, to open it in a split view.")
        case .right: String(localized: "Open on the Right", comment: "Shown over the right half of the page while a link or tab is dragged there, to open it in a split view.")
        case .top: String(localized: "Open at the Top", comment: "Shown over the top half of the page while a tab is dragged there, to open it in a split view, above the page.")
        case .bottom: String(localized: "Open at the Bottom", comment: "Shown over the bottom half of the page while a tab is dragged there, to open it in a split view, below the page.")
        case .topLeft: String(localized: "Open Top Left", comment: "Shown over the top left quarter of the page while a tab is dragged there, to open it there in a split view.")
        case .topRight: String(localized: "Open Top Right", comment: "Shown over the top right quarter of the page while a tab is dragged there, to open it there in a split view.")
        case .bottomLeft: String(localized: "Open Bottom Left", comment: "Shown over the bottom left quarter of the page while a tab is dragged there, to open it there in a split view.")
        case .bottomRight: String(localized: "Open Bottom Right", comment: "Shown over the bottom right quarter of the page while a tab is dragged there, to open it there in a split view.")
        }
    }

    /// Where a drop at a window point would go beside the panes on screen (`shape`, nil for a page alone, `gap`
    /// apart), or nil if it isn't over the page.
    func drop(at windowPoint: NSPoint, shape: TileShape?, gap: CGFloat) -> TileDrop? {
        let p = convert(windowPoint, from: nil)
        // Beside a page alone, the halves meet in the middle, as they always did.
        return TileDrop.target(at: p, in: bounds, shape: shape, gap: shape == nil ? 0 : gap)
    }

    /// Where the pane at `index` of the group on screen would go, let go at a window point; nil where it stays.
    func move(moving index: Int, at windowPoint: NSPoint, shape: TileShape, gap: CGFloat) -> PaneMove? {
        PaneMove.target(moving: index, at: convert(windowPoint, from: nil), in: bounds, shape: shape, gap: gap)
    }

    /// What the hint says over where a pane would go.
    static func title(forMove kind: PaneMove.Kind) -> String {
        guard case .place(let region, _) = kind else {
            return String(localized: "Swap Places", comment: "Shown over a page of a split view while another page of it is dragged there by its strip: the two trade places.")
        }
        return switch region {
        case .left: String(localized: "Move to the Left", comment: "Shown over the left half of the page while a page of a split view is dragged there by its strip.")
        case .right: String(localized: "Move to the Right", comment: "Shown over the right half of the page while a page of a split view is dragged there by its strip.")
        case .top: String(localized: "Move to the Top", comment: "Shown over the top half of the page while a page of a split view is dragged there by its strip.")
        case .bottom: String(localized: "Move to the Bottom", comment: "Shown over the bottom half of the page while a page of a split view is dragged there by its strip.")
        case .topLeft: String(localized: "Move Top Left", comment: "Shown over the top left quarter of the page while a page of a split view is dragged there by its strip.")
        case .topRight: String(localized: "Move Top Right", comment: "Shown over the top right quarter of the page while a page of a split view is dragged there by its strip.")
        case .bottomLeft: String(localized: "Move Bottom Left", comment: "Shown over the bottom left quarter of the page while a page of a split view is dragged there by its strip.")
        case .bottomRight: String(localized: "Move Bottom Right", comment: "Shown over the bottom right quarter of the page while a page of a split view is dragged there by its strip.")
        }
    }
}


/// What a space with no tabs shows on its color: the wordmark lightly engraved into it. The letters' floor is a
/// shade darker, their upper wall casts a soft shadow inside them, and their lower rim catches a thin line of light,
/// so it reads as pressed in on any color, black and white included. Nothing to click or dismiss; ⌘T and the
/// sidebar's New Tab are where a tab comes from.
final class EmptySpaceMark: NSView {
    static let size = NSSize(width: 28 * WordmarkView.aspect, height: 28)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func layout() { super.layout(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A dark space has little to shade, so light carries the cut; a light one has little to light, so shade does.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = WordmarkView.outline(in: bounds.insetBy(dx: 2, dy: 2))
        let below = CGMutablePath(); below.addPath(ink, transform: CGAffineTransform(translationX: 0, y: -1))

        // The rim of light under each letter: the outline nudged down, less the letters themselves.
        context.saveGState()
        context.addPath(below.subtracting(ink))
        context.setFillColor(NSColor.white.withAlphaComponent(dark ? 0.2 : 0.75).cgColor)
        context.fillPath()
        context.restoreGState()

        // The floor: a shade darker than a light surface; on a dark one, darker can't show, so it takes a breath of light.
        context.saveGState()
        context.addPath(ink)
        context.setFillColor((dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.025)).cgColor)
        context.fillPath()
        context.restoreGState()

        // The upper wall's shadow, inside the letters: everything but the letters casts it, clipped to them.
        context.saveGState()
        context.addPath(ink); context.clip()
        let surround = CGMutablePath(); surround.addRect(bounds.insetBy(dx: -20, dy: -20)); surround.addPath(ink)
        context.setShadow(offset: CGSize(width: 0, height: -1.2), blur: 1.4,
                          color: NSColor.black.withAlphaComponent(dark ? 0.6 : 0.13).cgColor)
        context.addPath(surround)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }
}

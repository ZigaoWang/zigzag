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
                secondCard.alphaValue = pagesHidden ? 0 : 1
            }
            refreshGlassOcclusion()
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
        // Closing: the pane that goes stays where it is and fades while the other grows over its place.
        let closingFrame = wasSplit && ratio == nil ? secondCard.frame : nil
        if closingFrame != nil { secondCardLeaving = true }
        layoutSubtreeIfNeeded()
        let panes = paneFrames
        card.frame = oldLeft
        if let right = panes.right, !wasSplit {
            secondCard.alphaValue = 0
            secondCard.frame = vertical ? right.offsetBy(dx: 0, dy: Tokens.Space.x6) : right.offsetBy(dx: Tokens.Space.x6, dy: 0)
        }
        // At the standard pace, like the sidebar: a split is a change of layout you watch, not a show.
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, moves: true, {
            self.card.animator().frame = panes.left
            if let right = panes.right {
                self.secondCard.animator().frame = right
                self.secondCard.animator().alphaValue = self.pagesHidden ? 0 : 1
            } else if closingFrame != nil {
                self.secondCard.animator().alphaValue = 0
            }
        }, completion: {
            guard closingFrame != nil, self.splitRatio == nil else { return }
            self.secondCardLeaving = false
            self.secondCard.alphaValue = 1
            self.needsLayout = true
        })
    }
    /// While the closed pane fades, layout leaves it showing where it was.
    private var secondCardLeaving = false
    var onSplitRatioChange: ((CGFloat, Bool) -> Void)?
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
        secondCard.isHidden = true
        addSubview(secondCard)
        splitHandle.isHidden = true
        addSubview(splitHandle)
        topBar.isHidden = true
        addSubview(topBar)
        splitHandle.onDrag = { [weak self] value in
            guard let self else { return }
            let area = self.cardFrame
            // Never so narrow (or short) that a pane's header loses its buttons: a share of the window, and points too.
            func clamp(_ ratio: CGFloat, length: CGFloat, minimum: CGFloat) -> CGFloat {
                let floor = max(0.2, minimum / max(length, 1)), ceiling = min(0.8, 1 - floor)
                return floor < ceiling ? min(max(ratio, floor), ceiling) : 0.5
            }
            if self.splitVertical {
                // Window y runs bottom-up; this view is flipped.
                let y = self.convert(NSPoint(x: 0, y: value), from: nil).y
                self.splitRatio = clamp((y - area.minY) / area.height, length: area.height, minimum: Self.minimumPaneHeight)
            } else {
                self.splitRatio = clamp((value - area.minX) / area.width, length: area.width, minimum: Self.minimumPaneWidth)
            }
            self.layoutSubtreeIfNeeded()
            self.onSplitRatioChange?(self.splitRatio ?? 0.5, false)
        }
        splitHandle.onEnd = { [weak self] in
            guard let self, let ratio = self.splitRatio else { return }
            self.onSplitRatioChange?(ratio, true)
        }
        splitHandle.onDoubleClick = { [weak self] in
            guard let self else { return }
            // Even again: the two panes glide to halves rather than jumping.
            self.setSplit(ratio: 0.5, vertical: self.splitVertical, animated: true)
            self.onSplitRatioChange?(0.5, true)
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
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return }
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

    /// The bar above the page: from the sidebar's edge, or the window's with the sidebar hidden, to the window's right.
    /// `inset`: framed, the bar starts the frame's inset down, the top of the card it makes with the page, so its
    /// buttons and address sit in that card's middle.
    static func topBarFrame(in bounds: NSRect, sidebarVisible: Bool, sidebarWidth: CGFloat, inset: CGFloat = 0) -> NSRect {
        let x = sidebarVisible ? sidebarWidth : 0
        let y = min(bounds.height, inset)
        return NSRect(x: x, y: y, width: max(0, bounds.width - x), height: min(bounds.height - y, TopBarView.height))
    }

    var topBarFrame: NSRect { Self.topBarFrame(in: bounds, sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth, inset: topBarInset) }

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
                      borderless: Self.isBorderless, topBar: showsTopBar, barInset: topBarInset)
    }

    /// Where the pages go. With the bar above the page, they start under it: framed, the bar stands in for the gap
    /// above the page; borderless or edge to edge, the page meets it in a straight line, as Zigzag Mini's meets its strip.
    static func pageArea(in bounds: NSRect, sidebarVisible: Bool, sidebarWidth: CGFloat, edgeToEdge: Bool, borderless: Bool, topBar: Bool, barInset: CGFloat = 0) -> NSRect {
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
        guard topBar else { return area }
        let top = bounds.minY + min(bounds.height, barInset + TopBarView.height)
        area.size.height = max(0, area.maxY - top)
        area.origin.y = top
        return area
    }

    /// The left (or only) pane and the right pane, inside the page area.
    var paneFrames: (left: NSRect, right: NSRect?) {
        // Borderless, the two pages meet at a hairline instead of floating apart.
        Self.paneFrames(in: cardFrame, ratio: splitRatio, vertical: splitVertical, gap: isEdgeToEdge ? 1 : Tokens.Metric.cardInset)
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

    /// Which of a pane's right corners are the window's own corners: on the window's right edge and its top or
    /// bottom. The window rounds those itself, so they're square; every other corner, a split's at the gap
    /// included, stays round.
    /// Under the bar above the page, the top right corner meets the bar and the window's edge in a line, as the
    /// window's own corner would, so it's square too.
    private func windowCorners(of pane: NSRect, attached: Bool) -> (top: Bool, bottom: Bool) {
        guard attached, pane.maxX >= bounds.maxX - 1 else { return (false, false) }
        let top = showsTopBar ? topBarFrame.maxY : bounds.minY
        return (pane.minY <= top + 1, pane.maxY >= bounds.maxY - 1)
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

    private var paintsTopBar: Bool { showsTopBar && pageColor != nil && splitRatio == nil && !isEmpty }

    /// The page card's own frame for `pane`: under a bar in the page's color, it reaches up to the bar's top.
    private func cardViewFrame(_ pane: NSRect) -> NSRect {
        guard paintsTopBar else { return pane }
        let top = min(pane.minY, topBarFrame.minY)
        return NSRect(x: pane.minX, y: top, width: pane.width, height: pane.maxY - top)
    }

    private func layoutCards() {
        let panes = paneFrames
        emptyHint.frame = Self.markFrame(in: panes.left)
        card.isEdgeToEdge = isEdgeToEdge
        secondCard.isEdgeToEdge = isEdgeToEdge
        let left = cardViewFrame(panes.left)
        card.frame = left
        card.band = left.height - panes.left.height
        card.bandColor = paintsTopBar ? pageColor : nil
        topBar.pageColor = paintsTopBar ? pageColor : nil
        let attached = sidebarVisible && Self.isBorderless
        card.squaresRightCorners = windowCorners(of: left, attached: attached)
        secondCard.squaresRightCorners = panes.right.map { windowCorners(of: $0, attached: attached) } ?? (false, false)
        card.isAttached = attached
        secondCard.isAttached = attached
        if let right = panes.right {
            secondCard.isHidden = false
            secondCard.frame = right
            splitHandle.isHidden = false
            splitHandle.frame = splitVertical
                ? NSRect(x: right.minX, y: panes.left.maxY - 2, width: right.width, height: right.minY - panes.left.maxY + 4)
                : NSRect(x: panes.left.maxX - 2, y: right.minY, width: right.minX - panes.left.maxX + 4, height: right.height)
        } else {
            secondCard.isHidden = !secondCardLeaving
            splitHandle.isHidden = true
        }
        splitDropHint.frame = cardFrame
        if showsSidePanel {
            let frame = sidePanelFrame
            sidePanel.frame = frame
            // Shaped like a page pane: the same corners, square where they're the window's own.
            let attached = sidebarVisible && Self.isBorderless
            sidePanel.setShape(radius: isEdgeToEdge ? 0 : attached ? PageCardView.attachedRadius : Tokens.Radius.card,
                               squareRight: windowCorners(of: frame, attached: attached))
        }
    }

    /// The mini player's card: over the pages and the sidebar, so it can go anywhere in the window; under everything
    /// floating (the command bar, popovers, sheets).
    func showMiniPlayer(_ view: NSView) {
        addSubview(view, positioned: .below, relativeTo: splitDropHint)
    }

    var sidebarFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if sidebarVisible { return NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height) }
        let x = sidebarRevealed ? inset : -sidebarWidth - inset * 4
        return NSRect(x: x, y: inset, width: sidebarWidth, height: bounds.height - inset * 2)
    }

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
        guard sidebarVisible, card.isAttached, !card.isHidden, !isEmpty, secondCard.isHidden || secondCard.alphaValue == 0 else { return bounds }
        return NSRect(x: 0, y: 0, width: min(bounds.width, sidebarWidth + Tokens.Radius.attached * 2), height: bounds.height)
    }

    /// Set while something opaque with glass of its own covers the whole window (the tab overview): the window's
    /// glass rests and the pages under it are hidden, so neither costs anything while out of sight.
    var glassCovered = false {
        didSet {
            guard oldValue != glassCovered else { return }
            card.isCoveredOver = glassCovered
            secondCard.isCoveredOver = glassCovered
            refreshGlassOcclusion()
        }
    }

    /// Nothing to see through: the page runs edge to edge, or the tab overview covers the window with its own glass.
    override var glassIsCovered: Bool { (isEdgeToEdge && (!showsTopBar || paintsTopBar) && !card.isHidden && !isEmpty) || glassCovered }

    override func layout() {
        super.layout()
        layoutCards()
        layoutTopBar()
        sidebarContainer.frame = sidebarFrame
        sidebarContainer.isFloating = !sidebarVisible && !leavesDocked
        // Docked beside the bar above the page, the sidebar's top row stays on the bar's middle line.
        sidebarContainer.sidebar.topRowDrop = showsTopBar && !sidebarContainer.isFloating ? topBarFrame.minY : 0
        let handleWidth = Tokens.Metric.resizeHandleWidth
        resizeHandle.frame = NSRect(x: sidebarWidth - handleWidth / 2, y: 0, width: handleWidth, height: bounds.height)
        resizeHandle.isHidden = !sidebarVisible && !isDraggingSidebarEdge
        overlay.frame = bounds
        onLayoutChange?()
    }

    private func layoutTopBar() {
        guard showsTopBar else { return }
        let page = pageAreaFrame
        placeTopBar()
        // Beside it, the sidebar's favorites and tabs start where the page does.
        if sidebarVisible { sidebarContainer.sidebar.contentTop = page.minY - sidebarFrame.minY }
    }

    /// The bar's controls run from the page's left edge to its right: at the frame's inset, or just inside the
    /// window's edges when the page meets them.
    private func placeTopBar() {
        let bar = topBarSlideFrame ?? topBarFrame
        topBar.frame = bar
        (topBar.leadingInset, topBar.trailingInset) = TopBarView.insets(bar: bar, page: pageAreaFrame, window: bounds)
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
        let targetSidebar = visible ? sidebarFrame : NSRect(x: -sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height)
        Tokens.Motion.withoutAnimation { sidebarContainer.frame = targetSidebar }
        let duration = Tokens.Motion.slide(sidebarContainer, fromOffsetX: oldSidebar.minX - targetSidebar.minX, curve: Tokens.Motion.slide, fromKeyboard: true)
        if showsTopBar, duration > 0 {
            topBarSlideFrame = (topBarSlideFrame ?? oldBar).union(topBarFrame)
            placeTopBar()
        }
        onSlide?(duration)
        // Borderless: the corners square off as the page grows to the window's edges, and round again as it shrinks.
        // Beside the sidebar, borderless, the page rounds like the window's corner; floating, like a card.
        let panes = paneFrames
        card.squaresRightCorners = windowCorners(of: cardViewFrame(panes.left), attached: visible && Self.isBorderless)
        secondCard.squaresRightCorners = panes.right.map { windowCorners(of: $0, attached: visible && Self.isBorderless) } ?? (false, false)
        card.isAttached = visible && Self.isBorderless
        secondCard.isAttached = visible && Self.isBorderless
        card.setEdgeToEdge(isEdgeToEdge, duration: duration)
        secondCard.setEdgeToEdge(isEdgeToEdge, duration: duration)
        refreshGlassOcclusion()
        // The bar's controls and the page move as one: nothing in the bar jumps to its new place.
        if topBarSlideFrame != nil { topBar.slideControls(from: oldControls, curve: Tokens.Motion.slide) }
        Tokens.Motion.animate(Tokens.Motion.slide, evenFromKeyboard: true, moves: true, {
            if self.topBarSlideFrame == nil, self.showsTopBar { self.topBar.animator().frame = self.topBarFrame }
            self.card.animator().frame = self.cardViewFrame(self.paneFrames.left)
            self.emptyHint.animator().frame = Self.markFrame(in: self.paneFrames.left)
            if let right = self.paneFrames.right { self.secondCard.animator().frame = right }
        }, completion: {
            self.leavesDocked = false
            // Not if another slide took over meanwhile: that one ends it.
            if self.topBarSlideFrame != nil, self.topBarSlides == slide {
                self.topBarSlideFrame = nil
                self.topBar.endSlide()
            }
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
        if point.x <= Tokens.Metric.edgeRevealWidth, !isOverTopBarLights(point) { pointerAtEdge() }
    }

    /// The bar's strip at the window's left edge holds the traffic lights while the sidebar is hidden: reaching for
    /// them there leaves the sidebar be, so they don't move off into it under the pointer.
    private func isOverTopBarLights(_ point: NSPoint) -> Bool {
        showsTopBar && !sidebarVisible && point.y < topBarFrame.maxY
    }

    /// Crossing the left edge opens the sidebar, however fast: a quick flick out of the window
    /// may never land a moved event inside the edge strip, but it always leaves through it.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= Tokens.Metric.edgeRevealWidth, point.y >= bounds.minY, point.y <= bounds.maxY, !isOverTopBarLights(point) { pointerAtEdge() }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if point.x <= Tokens.Metric.edgeRevealWidth, !isOverTopBarLights(point) { pointerAtEdge() }
    }

    /// A breath before it opens, so touching the edge and coming straight back to the page (a web app's own list
    /// along that side) leaves it be. Still at the edge, or gone out past it, it opens.
    private static let edgeGrace: TimeInterval = 0.1
    private var edgeTimer: Timer?

    private func pointerAtEdge() {
        guard edgeTimer == nil, !sidebarVisible, !sidebarRevealed else { return }
        edgeTimer = Timer.scheduledTimer(withTimeInterval: Self.edgeGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.edgeTimer = nil
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if point.x <= Tokens.Metric.edgeRevealWidth, point.y >= self.bounds.minY, point.y <= self.bounds.maxY,
                   !self.isOverTopBarLights(point) { self.reveal(true) }
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
        guard let window, !sidebarVisible, sidebarRevealed else { watchPointer(false); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let sidebar = sidebarContainer.frame
        // Anywhere left of the sidebar counts as on it: that's where the pointer goes to summon it.
        let keep = sidebar.insetBy(dx: -Tokens.Space.x1, dy: -Tokens.Space.x1).contains(point)
            || (point.x < sidebar.minX && point.y >= bounds.minY && point.y <= bounds.maxY)
        if keep || isHeld || NSEvent.pressedMouseButtons != 0 {
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
        label.stringValue = side == .left ? String(localized: "Open on the Left", comment: "Shown over the left half of the page while a link or tab is dragged there, to open it in a split view.")
                                           : String(localized: "Open on the Right", comment: "Shown over the right half of the page while a link or tab is dragged there, to open it in a split view.")
        label.textColor = Tokens.Color.accent
        Tokens.Motion.animate(Tokens.Motion.feedback, moves: true) { self.zone.animator().frame = target }
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

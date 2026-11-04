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
    /// Floating over the page in a see-through space: the page under it is frosted, the way the desktop is under the
    /// docked sidebar, so it never reads through the sidebar's own rows.
    private let frost = NSVisualEffectView()

    init(sidebar: SidebarView) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        frost.blendingMode = .withinWindow
        frost.material = .sidebar
        frost.state = .active
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
        grainLayer.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
        grainLayer.compositingFilter = "overlayBlendMode"
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
            frost.isHidden = !isFloating || cgColor(tint).alpha > 0.99
            frost.layer?.cornerRadius = Tokens.Radius.card
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
        emptyHint.alphaValue = 0
        addSubview(emptyHint)
        secondCard.isHidden = true
        addSubview(secondCard)
        splitHandle.isHidden = true
        addSubview(splitHandle)
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

    var cardFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if isEdgeToEdge { return bounds }
        if sidebarVisible {
            // Borderless, the page meets the window's edges and only its side by the sidebar is rounded.
            if Self.isBorderless { return NSRect(x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: bounds.height) }
            return NSRect(x: sidebarWidth, y: inset, width: max(0, bounds.width - sidebarWidth - inset), height: max(0, bounds.height - inset * 2))
        }
        return bounds.insetBy(dx: inset, dy: inset)
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
    private func windowCorners(of pane: NSRect, attached: Bool) -> (top: Bool, bottom: Bool) {
        guard attached, pane.maxX >= bounds.maxX - 1 else { return (false, false) }
        return (pane.minY <= bounds.minY + 1, pane.maxY >= bounds.maxY - 1)
    }

    private func layoutCards() {
        let panes = paneFrames
        emptyHint.frame = Self.markFrame(in: panes.left)
        card.isEdgeToEdge = isEdgeToEdge
        secondCard.isEdgeToEdge = isEdgeToEdge
        card.frame = panes.left
        let attached = sidebarVisible && Self.isBorderless
        card.squaresRightCorners = windowCorners(of: panes.left, attached: attached)
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
    }

    var sidebarFrame: NSRect {
        let inset = Tokens.Metric.cardInset
        if sidebarVisible { return NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height) }
        let x = sidebarRevealed ? inset : -sidebarWidth - inset * 4
        return NSRect(x: x, y: inset, width: sidebarWidth, height: bounds.height - inset * 2)
    }

    /// Frosted glass behind the frame, for spaces that want the desktop to show through: blurred, so what's behind
    /// reads as soft shapes and never as text under the sidebar's own. The sidebar's material, the clearest there is.
    private lazy var glassView: NSVisualEffectView = {
        let glass = NSVisualEffectView()
        glass.blendingMode = .behindWindow
        glass.material = .sidebar
        // Live while the window is in front; a still frosting behind other apps' windows, as macOS's own sidebars.
        glass.state = .followsWindowActiveState
        glass.isHidden = true
        addSubview(glass, positioned: .below, relativeTo: nil)
        glass.wantsLayer = true
        glass.layer?.zPosition = -3
        return glass
    }()

    /// The frosting always covers all of what's behind: anything thinner lets it through sharp, and its text then
    /// reads under the sidebar's own. See-through spaces thin their color over the blur instead.
    /// `clear`: Liquid Glass, really transparent and still blurred, tinted with `tint` (it draws over the frame's own
    /// wash, so the color goes in the glass). Before macOS 26 the frosted glass stands in.
    func setGlass(_ on: Bool, clear: Bool = false, tint: NSColor? = nil) {
        glassWanted = on
        defer { refreshGlassOcclusion() }
        if #available(macOS 26.0, *), clear {
            glassView.isHidden = true
            let glass = clearGlass as? NSGlassEffectView ?? {
                let made = NSGlassEffectView()
                // Regular, not the clear style: still plainly see-through, but blurred enough that what's behind reads
                // as color and shape, never as text under the sidebar's own.
                made.style = .regular
                made.cornerRadius = 0
                made.wantsLayer = true
                made.layer?.zPosition = -3
                addSubview(made, positioned: .below, relativeTo: nil)
                clearGlass = made
                return made
            }()
            glass.isHidden = !on
            glass.tintColor = tint
            if on { glass.frame = glassFrame }
            // The glass draws over the frame's own grain, so it carries its own, kept in step by `setGrain`.
            if glass.contentView == nil {
                let content = NSView()
                content.wantsLayer = true
                content.layer?.addSublayer(glassGrain)
                glass.contentView = content
            }
            Tokens.Motion.withoutAnimation { glassGrain.frame = glassGrainBounds }
            return
        }
        clearGlass?.isHidden = true
        glassView.isHidden = !on
        glassView.material = .sidebar
        if on { glassView.frame = glassFrame }
    }
    /// Where the glass needs to be: only what you can see through. With the page meeting the sidebar, that's the
    /// sidebar alone; the page covers the rest, and a live blur under it would cost the window server a fresh blur
    /// of the whole window every frame the page changes (a video, an animation). Otherwise the whole window.
    private var glassFrame: NSRect {
        guard sidebarVisible, card.isAttached, !card.isHidden else { return bounds }
        return NSRect(x: 0, y: 0, width: min(bounds.width, sidebarWidth + Tokens.Radius.attached * 2), height: bounds.height)
    }
    private var glassGrainBounds: NSRect { NSRect(origin: .zero, size: glassFrame.size) }

    /// Whether the space wants glass; `refreshGlassOcclusion` keeps it off while the window can't be seen.
    private var glassWanted = false

    /// A window you can't see (behind others, minimized, on another desktop) needs no live blur: the glass goes
    /// until it shows again, so the window server isn't re-blurring a window nobody is looking at.
    func refreshGlassOcclusion() {
        let visible = window?.occlusionState.contains(.visible) ?? true
        let on = glassWanted && visible
        if let clearGlass, !clearGlass.isHidden || on { clearGlass.alphaValue = on ? 1 : 0 }
        glassView.alphaValue = on ? 1 : 0
    }

    /// The clear glass, once a clear space has asked for it.
    private var clearGlass: NSView?
    /// Grain inside the clear glass, matching the frame's.
    private lazy var glassGrain: CALayer = {
        let grain = CALayer()
        grain.backgroundColor = NSColor(patternImage: BrandSurface.noise).cgColor
        grain.compositingFilter = "overlayBlendMode"
        grain.opacity = 0
        return grain
    }()

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
        guard grainLayer.opacity != target || glassGrain.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.standard)
        grainLayer.opacity = target
        glassGrain.opacity = target
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation { grainLayer.frame = bounds; gradientLayer.frame = bounds }
        if !glassView.isHidden { glassView.frame = glassFrame }
        if let clearGlass, !clearGlass.isHidden {
            clearGlass.frame = glassFrame
            Tokens.Motion.withoutAnimation { glassGrain.frame = glassGrainBounds }
        }
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
        // Beside the sidebar, borderless, the page rounds like the window's corner; floating, like a card.
        let panes = paneFrames
        card.squaresRightCorners = windowCorners(of: panes.left, attached: visible && Self.isBorderless)
        secondCard.squaresRightCorners = panes.right.map { windowCorners(of: $0, attached: visible && Self.isBorderless) } ?? (false, false)
        card.isAttached = visible && Self.isBorderless
        secondCard.isAttached = visible && Self.isBorderless
        card.setEdgeToEdge(isEdgeToEdge, duration: duration)
        secondCard.setEdgeToEdge(isEdgeToEdge, duration: duration)
        Tokens.Motion.animate(Tokens.Motion.slide, evenFromKeyboard: true, moves: true, {
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
                    MainActor.assumeIsolated { self?.pacePointer(); self?.refreshGlassOcclusion() }
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
        let attentive = NSApp.isActive && window.isKeyWindow
        let timer = Timer(timeInterval: attentive ? 1.0 / 60 : 0.5, repeats: true) { [weak self] timer in
            // The view went away while the sidebar floated: nothing left to follow for.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.followPointer() }
        }
        timer.tolerance = attentive ? 0.004 : 0.25
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

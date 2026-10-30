import AppKit

/// A space's heading in desk view. Clicking it selects every tab in the space.
final class DeskHeaderView: InteractiveView {
    let dot = ColorView()
    let label = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    let count = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        [dot, label, count].forEach { addSubview($0) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        dot.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - 8) / 2, width: 8, height: 8)
        label.frame = NSRect(x: dot.frame.maxX + Tokens.Space.x2, y: (bounds.height - h) / 2, width: label.textWidth, height: h)
        count.frame = NSRect(x: label.frame.maxX + Tokens.Space.x1, y: (bounds.height - h) / 2, width: count.textWidth, height: h)
    }

    var fittingWidth: CGFloat { Tokens.Space.x2 * 3 + 8 + label.textWidth + Tokens.Space.x1 + count.textWidth }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// The desk's content: every tab as a card, grouped by space, in sidebar order.
final class DeskCanvasView: NSView {
    weak var desk: DeskController?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { desk?.backgroundMouseDown(event) }
    override func keyDown(with event: NSEvent) { if desk?.keyDown(event) != true { super.keyDown(with: event) } }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Holds the page's picture as it flies. Not flipped, so its layer's coordinates are a view's, and never in the
/// way of a click.
final class DeskFlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Desk view: zoom out to see every tab at once and tidy up. Not for everyday switching.
final class DeskController {
    private weak var controller: BrowserWindowController?
    private let backdrop = ColorView()
    private let scrollView = NSScrollView()
    private let canvas = DeskCanvasView()
    private let actionBar = FloatingPanelView()
    private let closeButton = TextButton(title: "Close Tabs", font: Tokens.Font.body(.medium))
    private let doneButton = TextButton(title: "Done", font: Tokens.Font.body(.medium))
    private var headers: [UUID: DeskHeaderView] = [:]
    private var cards: [UUID: TabThumbnailView] = [:]
    private var selection: Set<UUID> = []
    /// The card the arrow keys are on, and what Return opens: the tab you were on when the desk opens, the best
    /// match while searching.
    private var focused: UUID?
    private(set) var isVisible = false
    private var marquee: CAShapeLayer?
    /// The page's picture while it flies between the page area and its card, over the desk.
    private let flightView = DeskFlightView()
    private var flight: PagePicture?
    /// Counts opens and closes, so one that's been taken over doesn't finish what the next one started.
    private var transition = 0
    private var magnifyTotal: CGFloat = 0
    private var gestureClaimed = false
    /// Find a tab by typing: the field at the top, and typing anywhere on the desk goes into it.
    private let searchBox = ColorView()
    private let searchIcon = NSImageView()
    private let searchField = PlainTextField(font: Tokens.Font.body(), placeholder: "Search Tabs")
    private let searchDelegate = DeskSearchDelegate()
    private let noMatches = Label("No tabs match", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var query = ""
    private static let searchHeight = Tokens.Space.x8
    private static let searchArea = Tokens.Space.x6 + Tokens.Space.x8 + Tokens.Space.x2

    /// Cards shrink with more tabs down to this, where a title still reads, and grow with fewer up to the largest.
    private let minCardWidth = Tokens.Metric.deskCardWidth
    private let maxCardWidth = Tokens.Metric.deskCardMaxWidth
    /// Room around a card's picture for its hover and current-tab fill.
    private let cardInset = Tokens.Space.x1
    private let gap = Tokens.Space.x6
    private let spaceGap = Tokens.Space.x8
    private let margin = Tokens.Space.x10

    init(window: BrowserWindowController) {
        controller = window
        canvas.desk = self
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        scrollView.useSlimScroller()
        backdrop.addSubview(scrollView)
        // The window resized, went full screen or the sidebar moved: the cards take the page area's new shape.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.applyLayout(animated: false)
            }
        }
        actionBar.radius = Tokens.Radius.row + Tokens.Space.x1
        actionBar.addSubview(closeButton)
        actionBar.addSubview(doneButton)
        closeButton.onClick = { [weak self] _ in self?.closeSelected() }
        doneButton.onClick = { [weak self] _ in self?.hide(openingTab: nil) }

        searchBox.wantsLayer = true
        searchBox.layer?.cornerRadius = Self.searchHeight / 2
        searchBox.layer?.cornerCurve = .continuous
        searchIcon.image = Tokens.Symbol.image("magnifyingglass", size: Tokens.TypeSize.body)
        searchIcon.contentTintColor = Tokens.Color.textSecondary
        searchBox.addSubview(searchIcon)
        searchBox.addSubview(searchField)
        backdrop.addSubview(searchBox)
        noMatches.isHidden = true
        canvas.addSubview(noMatches)
        searchField.delegate = searchDelegate
        searchDelegate.changed = { [weak self] text in self?.search(text) }
        searchDelegate.command = { [weak self] selector in
            guard let self else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                self.openFocused()
                return true
            case #selector(NSResponder.moveLeft(_:)): self.moveFocus(.left); return true
            case #selector(NSResponder.moveRight(_:)): self.moveFocus(.right); return true
            case #selector(NSResponder.moveUp(_:)): self.moveFocus(.up); return true
            case #selector(NSResponder.moveDown(_:)): self.moveFocus(.down); return true
            case #selector(NSResponder.deleteBackward(_:)) where self.searchField.stringValue.isEmpty:
                // With nothing typed, ⌫ closes the card, as it does in the sidebar.
                self.closeFocused()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc clears the search first, then leaves the desk.
                if self.query.isEmpty { self.hide(openingTab: nil) } else { self.searchField.stringValue = ""; self.search("") }
                return true
            default:
                return false
            }
        }
    }

    private var manager: TabManager? { controller?.tabManager }

    // MARK: Showing

    func toggle() { isVisible ? hide(openingTab: nil) : show() }

    func show() {
        guard !isVisible, let controller else { return }
        isVisible = true
        transition += 1
        selection = []
        controller.previews.hide()
        // The page's link preview would float over the cards.
        controller.linkStatus.show(nil, in: controller.root.cardFrame)
        controller.commandBar.dismiss(restoringFocus: false)
        let root = controller.root
        backdrop.color = controller.tabManager.currentSpace.background
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        scrollView.autoresizingMask = [.width, .height]
        // Opened again while still closing: the desk is there, and carries on from where it is.
        let reopening = backdrop.superview != nil
        if !reopening { Tokens.Motion.withoutAnimation { backdrop.alphaValue = 0 } }
        root.overlay.addSubview(backdrop)
        flightView.frame = root.overlay.bounds
        root.overlay.addSubview(flightView)
        query = ""
        searchField.stringValue = ""
        layoutSearch()
        reload()
        // The window's own controls would sit on top of the desk; tuck them away.
        (controller.window as? BrowserWindow)?.trafficLightsHidden = false
        // Typing filters straight away, and the arrow keys move between cards from the field too.
        controller.window?.makeFirstResponder(searchField)
        backdrop.layoutSubtreeIfNeeded()
        setFocus(currentCardID, scroll: false)
        if !reopening, let card = currentCard { canvas.scrollToVisible(card.frame.insetBy(dx: 0, dy: -margin)) }

        guard !Tokens.Motion.reduceMotion else {
            Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true) { self.backdrop.animator().alphaValue = 1 }
            return
        }
        if reopening {
            zoomOut(settle: false)
            return
        }
        // The page's picture is taken fresh, so what shrinks is exactly what was on screen. That's quick; if it
        // isn't, the last picture will do.
        let id = transition
        var started = false
        let start = { [weak self] in
            guard let self, !started, self.isVisible, self.transition == id else { return }
            started = true
            self.cards.values.forEach { $0.refreshImage() }
            self.zoomOut(settle: true)
        }
        capturePages(start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { start() } }
    }

    /// Takes new pictures of the page on screen, both pages with a split, then calls `completion` once.
    private func capturePages(_ completion: @escaping () -> Void) {
        guard let manager, let tab = manager.selectedTab else { completion(); return }
        let pages = [tab] + (manager.partner(of: tab).map { [$0] } ?? [])
        var waiting = pages.count
        for page in pages {
            page.captureSnapshot {
                waiting -= 1
                if waiting == 0 { completion() }
            }
        }
    }

    /// Opening: the page shrinks from where it is on screen into its card, in one continuous move, while the desk
    /// fades in behind it and the other cards settle in around it. `settle` is false when a close is turned around
    /// mid-way, with the cards still in place.
    private func zoomOut(settle: Bool) {
        guard let controller else { return }
        let id = transition
        let current = currentCard
        fade(backdrop, to: 1, duration: Tokens.Motion.large)
        if settle { settleIn(except: current) }
        guard let current, let tab = current.tab else { return }
        let target = current.imageClip.convert(current.imageClip.bounds, to: flightView)
        let flight = self.flight ?? makeFlight(at: flightView.convert(controller.root.cardFrame, from: controller.root), radius: pageRadius)
        // Only its picture flies; the title arrives with the other cards.
        Tokens.Motion.withoutAnimation { current.imageClip.alphaValue = 0 }
        flight.show(Self.picture(of: tab), current.partner?.snapshot, split: current.split)
        fly(flight, to: target, radius: Tokens.Radius.thumbnail) { [weak self] in
            guard let self, self.transition == id else { return }
            // Landed: the card takes over in the same frame, so nothing moves.
            Tokens.Motion.withoutAnimation {
                self.cards.values.forEach { $0.imageClip.alphaValue = 1 }
                self.endFlight()
            }
        }
    }

    /// The flying picture, page-sized so it stays sharp, scaled to show over `frame` (in the flight view) with
    /// `radius` corners. The live pages under it are hidden so the two never show at once; they keep drawing, so
    /// they're ready the moment it lands.
    private func makeFlight(at frame: NSRect, radius: CGFloat) -> PagePicture {
        let picture = PagePicture()
        let layer = picture.layer
        let page = controller?.root.cardFrame.size ?? frame.size
        let scale = (x: frame.width / max(page.width, 1), y: frame.height / max(page.height, 1))
        layer.anchorPoint = .zero
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        Tokens.Motion.withoutAnimation {
            layer.backgroundColor = flightView.cgColor(Tokens.Color.cardBackground)
            picture.divider.backgroundColor = flightView.cgColor(Tokens.Color.cardEdge)
            picture.layout(size: page)
            layer.position = frame.origin
            layer.transform = CATransform3DMakeScale(scale.x, scale.y, 1)
            layer.cornerRadius = radius / max(min(scale.x, scale.y), 0.01)
            flightView.layer?.addSublayer(layer)
        }
        controller?.root.pagesHidden = true
        flight = picture
        return picture
    }

    /// The corners of the page on screen: square when it runs to the window's edges.
    private var pageRadius: CGFloat { controller?.root.isEdgeToEdge == true ? 0 : Tokens.Radius.card }

    /// Moves the flying picture onto `target` (in the flight view), its corners ending at `radius`, on a critically
    /// damped spring. It starts from wherever it is on screen right now, so a move taken over mid-way turns around
    /// without a jump.
    private func fly(_ flight: PagePicture, to target: NSRect, radius: CGFloat, completion: @escaping () -> Void) {
        let layer = flight.layer
        let size = layer.bounds.size
        guard size.width > 0, size.height > 0 else { completion(); return }
        let sx = target.width / size.width, sy = target.height / size.height
        let shown = layer.presentation() ?? layer
        let from: [String: Any] = ["position": shown.position, "transform": shown.transform, "cornerRadius": shown.cornerRadius]
        let to: [String: Any] = ["position": target.origin, "transform": CATransform3DMakeScale(sx, sy, 1),
                                 "cornerRadius": radius / max(min(sx, sy), 0.01)]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        for key in ["position", "transform", "cornerRadius"] {
            let spring = Tokens.Motion.springAnimation(keyPath: key, duration: Tokens.Motion.zoom)
            spring.fromValue = from[key]
            spring.toValue = to[key]
            layer.setValue(to[key], forKeyPath: key)
            layer.add(spring, forKey: key)
        }
        CATransaction.commit()
    }

    /// The picture is done with: it goes, and the live pages show again.
    private func endFlight() {
        flight?.layer.removeFromSuperlayer()
        flight = nil
        controller?.root.pagesHidden = false
    }

    /// The picture a card's first page shows, or none for one that hasn't drawn.
    private static func picture(of tab: Tab) -> NSImage? { TabThumbnailView.isBlank(tab.snapshot) ? nil : tab.snapshot }

    /// Fades a view to `value` on a spring, from wherever it is now.
    private func fade(_ view: NSView, to value: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        guard let layer = view.layer else { completion?(); return }
        let spring = Tokens.Motion.springAnimation(keyPath: "opacity", duration: duration)
        spring.fromValue = layer.presentation()?.opacity ?? layer.opacity
        spring.toValue = Float(value)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        Tokens.Motion.withoutAnimation { view.alphaValue = value }
        layer.add(spring, forKey: "deskFade")
        CATransaction.commit()
    }

    /// The other cards come in around the page: each fades in while growing the last few percent from its own
    /// middle, a beat after the one before it in reading order, all landing with the page.
    private func settleIn(except current: NSView?) {
        let ordered = cards.values.filter { $0.frame.intersects(canvas.visibleRect) }.sorted {
            $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        let now = CACurrentMediaTime()
        for (i, card) in ordered.enumerated() {
            guard let layer = card.layer else { continue }
            let fade = Tokens.Motion.springAnimation(keyPath: "opacity", duration: Tokens.Motion.zoom)
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            if card === current {
                // Its picture is the page flying in; only its title fades in.
                group.animations = [fade]
            } else {
                let k: CGFloat = 0.96, size = card.bounds.size
                let small = CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                                CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0))
                let grow = Tokens.Motion.springAnimation(keyPath: "transform", duration: Tokens.Motion.zoom)
                grow.fromValue = NSValue(caTransform3D: small)
                grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                group.animations = [grow, fade]
            }
            group.duration = fade.duration
            group.beginTime = now + min(Double(i) * 0.01, 0.06) * Tokens.Motion.debugSlowdown
            group.fillMode = .backwards
            layer.add(group, forKey: "settle")
        }
    }

    func hide(openingTab tab: Tab?) {
        guard isVisible, let controller else { return }
        isVisible = false
        transition += 1
        let id = transition
        actionBar.removeFromSuperview()
        // The window's controls go back to how the sidebar has them.
        controller.layoutTrafficLights()
        let root = controller.root
        let target = tab ?? controller.tabManager.selectedTab
        let card = target.flatMap { target in cards[manager?.split(for: target)?.left ?? target.id] ?? cards[target.id] }
        if let tab { controller.tabManager.select(tab) }
        if let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
        let finish = { [weak self] in
            // Opened again before this finished: it stays.
            guard let self, self.transition == id else { return }
            Tokens.Motion.withoutAnimation {
                self.backdrop.removeFromSuperview()
                self.backdrop.alphaValue = 1
                self.cards.values.forEach { $0.imageClip.alphaValue = 1 }
            }
        }
        // Closed before the desk ever showed (pressed twice quickly): nothing to take back.
        let shown = backdrop.layer?.presentation()?.opacity ?? Float(backdrop.alphaValue)
        guard !Tokens.Motion.reduceMotion, shown > 0.01 || flight != nil, let card, let page = card.tab else {
            // Nothing to grow, or Reduce Motion: the desk simply fades away.
            endFlight()
            Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, { self.backdrop.animator().alphaValue = 0 }, completion: finish)
            return
        }
        // Closing: the chosen card grows to fill the page area, exactly where its page is, and hands over to it.
        let flight = self.flight ?? makeFlight(at: card.imageClip.convert(card.imageClip.bounds, to: flightView), radius: Tokens.Radius.thumbnail)
        root.pagesHidden = true
        Tokens.Motion.withoutAnimation { card.imageClip.alphaValue = 0 }
        flight.show(Self.picture(of: page), card.partner?.snapshot, split: card.split)
        // The desk is gone, and out of the way of clicks, a moment before the page lands.
        fade(backdrop, to: 0, duration: Tokens.Motion.large, completion: finish)
        fly(flight, to: flightView.convert(root.cardFrame, from: root), radius: pageRadius) { [weak self] in
            guard let self, self.transition == id else { return }
            self.handOff(flight)
        }
    }

    /// The picture has grown into the page area: the live pages show under it, and it fades off them quickly. When
    /// the picture is current that's invisible; when the page has changed since, it reads as the page refreshing.
    private func handOff(_ flight: PagePicture) {
        controller?.root.pagesHidden = false
        self.flight = nil
        let layer = flight.layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Tokens.Motion.quick * Tokens.Motion.debugSlowdown
        Tokens.Motion.withoutAnimation { layer.opacity = 0 }
        layer.add(fade, forKey: "handOff")
        CATransaction.commit()
    }

    // MARK: Layout

    /// The page area's shape. Every card is the page area in small, so the page can fly into its card and back
    /// without stretching.
    var pageAspect: CGFloat {
        guard let card = controller?.root.cardFrame, card.width > 0, card.height > 0 else { return 0.625 }
        return min(max(card.height / card.width, 0.3), 1.5)
    }

    private func cardHeight(width: CGFloat) -> CGFloat {
        round((width - cardInset * 2) * pageAspect) + TabThumbnailView.titleHeight + cardInset
    }

    /// Lays out every space and its cards. Positions follow sidebar order, so they never move on their own.
    /// Cards are as big as they can be while every tab still fits on screen: a few tabs get big cards, many get
    /// smaller ones, down to a size whose titles still read, and then the desk scrolls.
    private func layoutFrames(dragging: (id: UUID, space: UUID, index: Int)? = nil) -> (headers: [UUID: NSRect], cards: [UUID: NSRect], height: CGFloat) {
        guard manager != nil else { return ([:], [:], 0) }
        let width = max(scrollView.contentSize.width, minCardWidth + margin * 2)
        let visible = scrollView.contentSize.height
        var groups: [(space: UUID, ids: [UUID])] = []
        for space in Library.shared.spaces {
            var ids = cardTabs(in: space.id).map(\.id)
            if let dragging {
                ids.removeAll { $0 == dragging.id }
                if dragging.space == space.id { ids.insert(dragging.id, at: min(dragging.index, ids.count)) }
            }
            // A space with nothing to show has no heading, except the only one when not searching. While searching
            // the headings of empty spaces would stand over "No tabs match".
            if ids.isEmpty && dragging == nil && (Library.shared.spaces.count > 1 || !query.isEmpty) { continue }
            groups.append((space.id, ids))
        }
        let heading = Tokens.Space.x8 + Tokens.Space.x3
        func widthOfCards(_ columns: Int) -> CGFloat {
            let fit = floor((width - margin * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns))
            // One card on its own is never taller than the desk.
            let tallest = (visible - margin * 2 - heading - TabThumbnailView.titleHeight - cardInset) / pageAspect + cardInset * 2
            return max(minCardWidth, min(fit, maxCardWidth, floor(tallest)))
        }
        func contentHeight(columns: Int) -> CGFloat {
            let rowHeight = self.cardHeight(width: widthOfCards(columns)) + gap
            let spaces = groups.map { heading + CGFloat(max(1, Int(ceil(Double($0.ids.count) / Double(columns))))) * rowHeight - gap }
            return spaces.reduce(0, +) + CGFloat(max(0, spaces.count - 1)) * spaceGap
        }
        // The fewest columns, so the biggest cards, that show every tab at once; with too many for that, as many
        // columns as fit.
        let most = max(1, Int((width - margin * 2 + gap) / (minCardWidth + gap)))
        let widest = max(1, min(most, groups.map(\.ids.count).max() ?? 1))
        let columns = (1...widest).first { contentHeight(columns: $0) <= visible - margin * 2 } ?? widest
        let cardWidth = widthOfCards(columns)
        let cardHeight = self.cardHeight(width: cardWidth)
        let rowWidth = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap
        let left = floor((width - rowWidth) / 2)
        // A desk that fits sits in the middle of the window, like Mission Control.
        let total = contentHeight(columns: columns)
        var y = max(margin, floor((visible - total) / 2))
        var headerFrames: [UUID: NSRect] = [:]
        var cardFrames: [UUID: NSRect] = [:]
        for group in groups {
            headerFrames[group.space] = NSRect(x: left - Tokens.Space.x2, y: y, width: 320, height: Tokens.Space.x8)
            y += heading
            for (i, id) in group.ids.enumerated() {
                let col = i % columns, row = i / columns
                cardFrames[id] = NSRect(x: left + CGFloat(col) * (cardWidth + gap), y: y + CGFloat(row) * (cardHeight + gap), width: cardWidth, height: cardHeight)
            }
            let rows = max(1, Int(ceil(Double(group.ids.count) / Double(columns))))
            y += CGFloat(rows) * (cardHeight + gap) - gap + spaceGap
        }
        return (headerFrames, cardFrames, y - spaceGap + margin)
    }

    /// The tabs that get a card: a split's second page shares the first one's card, as it shares its sidebar row.
    /// While searching, only the ones whose title or address match (either page, for a split).
    private func cardTabs(in space: UUID) -> [Tab] {
        guard let manager else { return [] }
        let tabs = manager.tabs(in: space)
        let cards = tabs.filter { tab in
            guard let pair = manager.split(for: tab), pair.right == tab.id else { return true }
            return !tabs.contains { $0.id == pair.left }
        }
        guard !query.isEmpty else { return cards }
        return cards.filter { matches($0) || partner(of: $0).map(matches) == true }
    }

    private func matches(_ tab: Tab) -> Bool {
        tab.displayTitle.localizedCaseInsensitiveContains(query) || (tab.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces)
        selection = []
        reload(animated: true)
        // Return opens the best match; with the search cleared, it's back on the tab you were on.
        setFocus(query.isEmpty ? currentCardID : orderedCardIDs.first)
    }

    /// The search field, centered at the top, clear of the window's buttons.
    private func layoutSearch() {
        let b = backdrop.bounds
        let width = min(360, b.width - Tokens.Space.x10 * 4)
        let h = Self.searchHeight
        let top = backdrop.isFlipped ? Tokens.Space.x6 : b.height - Tokens.Space.x6 - h
        searchBox.frame = NSRect(x: round((b.width - width) / 2), y: top, width: width, height: h)
        searchBox.autoresizingMask = [.minXMargin, .maxXMargin, backdrop.isFlipped ? .maxYMargin : .minYMargin]
        searchBox.color = Tokens.Color.fieldFill
        let icon: CGFloat = 16
        searchIcon.frame = NSRect(x: Tokens.Space.x3, y: (h - icon) / 2, width: icon, height: icon)
        let textHeight = ceil(searchField.intrinsicContentSize.height)
        let x = searchIcon.frame.maxX + Tokens.Space.x2
        searchField.frame = NSRect(x: x, y: (h - textHeight) / 2, width: width - x - Tokens.Space.x3, height: textHeight)
        scrollView.frame = NSRect(x: 0, y: backdrop.isFlipped ? Self.searchArea : 0, width: b.width, height: b.height - Self.searchArea)
    }

    private func partner(of tab: Tab) -> Tab? {
        guard let manager, let pair = manager.split(for: tab), pair.left == tab.id else { return nil }
        return manager.tab(with: pair.right)
    }

    /// How a split card's two pages share it, as they share the page area.
    private func splitShape(of tab: Tab) -> (ratio: CGFloat, vertical: Bool)? {
        guard let pair = manager?.split(for: tab) else { return nil }
        return (CGFloat(pair.ratio), pair.vertical)
    }

    /// The card for the tab you're on, which with a split is the one both pages share.
    private var currentCard: TabThumbnailView? {
        guard let manager, let tab = manager.selectedTab else { return nil }
        return cards[manager.split(for: tab)?.left ?? tab.id] ?? cards[tab.id]
    }

    private var currentCardID: UUID? { cards.first { $0.value === currentCard }?.key }

    /// Tabs opened or closed while the desk is up (⌘W, a link opening a tab): the cards follow.
    func tabsChanged() { if isVisible { reload(animated: true) } }

    private func reload(animated: Bool = false) {
        guard let manager else { return }
        let allTabs = Library.shared.spaces.flatMap { cardTabs(in: $0.id) }
        let ids = Set(allTabs.map(\.id))
        for (id, view) in cards where !ids.contains(id) {
            cards[id] = nil
            if animated { collapse(view) } else { view.removeFromSuperview() }
        }
        var fresh: [TabThumbnailView] = []
        selection = selection.intersection(ids)
        // Cards kept from last time show what each tab is now.
        for tab in allTabs { cards[tab.id]?.configure(tab, partner: partner(of: tab), split: splitShape(of: tab)) }
        for tab in allTabs where cards[tab.id] == nil {
            let card = TabThumbnailView()
            card.inset = cardInset
            card.showsRing = true
            card.configure(tab, partner: partner(of: tab), split: splitShape(of: tab))
            card.onClick = { [weak self, weak tab, weak card] event in
                guard let self, let tab else { return }
                self.cardClicked(card?.tab(at: event) ?? tab, event: event)
            }
            // The ×, or a middle-click anywhere on the card, as on a tab in the sidebar.
            card.onClose = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.close([tab.id])
            }
            card.onMiddleClick = card.onClose
            card.onDragStart = { [weak self, weak tab] event in
                // While searching, the cards in between are hidden, so where a drop lands in the list is a guess:
                // no reordering until the search is cleared.
                guard let self, let tab, self.query.isEmpty else { return false }
                return self.beginDrag(tab, event: event)
            }
            card.onRightClick = { [weak self, weak tab] _ in
                guard let self, let tab else { return nil }
                if !self.selection.contains(tab.id) { self.selection = [tab.id]; self.updateSelection() }
                let menu = NSMenu()
                menu.addItem(SidebarMenus.Item(self.selection.count > 1 ? "Close \(self.selection.count) Tabs" : "Close Tab") { self.closeSelected() })
                return menu
            }
            cards[tab.id] = card
            canvas.addSubview(card)
            fresh.append(card)
        }
        for space in Library.shared.spaces where headers[space.id] == nil {
            let header = DeskHeaderView()
            header.onClick = { [weak self] _ in self?.selectSpace(space.id) }
            headers[space.id] = header
            canvas.addSubview(header)
        }
        for (id, header) in headers where Library.shared.space(id) == nil { header.removeFromSuperview(); headers[id] = nil }
        let current = currentCard
        for card in cards.values { card.isCurrent = card === current }
        // New cards (a search cleared, a tab opened) start where they belong and grow in there, rather than flying
        // in from a corner.
        if animated {
            let frames = layoutFrames().cards
            for card in fresh { card.frame = frames[cards.first { $0.value === card }?.key ?? UUID()] ?? .zero }
            appear(fresh)
        }
        applyLayout(animated: animated)
        updateSelection()
        if let focused, cards[focused] == nil { self.focused = nil }
        for (id, card) in cards { card.isFocused = id == focused }
    }

    private func applyLayout(animated: Bool, dragging: (id: UUID, space: UUID, index: Int)? = nil) {
        let layout = layoutFrames(dragging: dragging)
        canvas.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(layout.height, scrollView.contentSize.height))
        for (id, header) in headers {
            guard let space = Library.shared.space(id) else { continue }
            header.label.stringValue = space.name
            let count = manager?.tabs(in: id).count ?? 0
            header.count.stringValue = count == 1 ? "1 tab" : "\(count) tabs"
            header.dot.color = space.swatch
            if let frame = layout.headers[id] {
                header.isHidden = false
                var f = frame
                f.size.width = header.fittingWidth
                if animated && !header.isHidden && header.frame != .zero { move(header, to: f) } else { header.frame = f }
            } else {
                header.isHidden = true
            }
        }
        noMatches.isHidden = query.isEmpty || !layout.cards.isEmpty
        if !noMatches.isHidden {
            // In the middle of what you can see, not at the top of the canvas.
            let w = noMatches.textWidth + 4, visible = scrollView.documentVisibleRect
            noMatches.frame = NSRect(x: round((canvas.bounds.width - w) / 2), y: round(visible.midY - noMatches.lineHeight / 2),
                                     width: w, height: noMatches.lineHeight)
        }
        for (id, card) in cards {
            guard let frame = layout.cards[id], id != dragging?.id else { continue }
            if animated { move(card, to: frame) } else { card.frame = frame }
        }
    }

    // MARK: Reflow

    /// Moves a card or heading to `frame` on a spring. The view is there at once, for clicks and layout; what's
    /// drawn slides over from wherever it is on screen, growing or shrinking to fit, so a move that's taken over
    /// mid-way carries on from there.
    private func move(_ view: NSView, to frame: NSRect) {
        guard let layer = view.layer else { view.frame = frame; return }
        let shown = layer.presentation()?.frame ?? view.frame
        view.frame = frame
        guard !Tokens.Motion.reduceMotion, frame.width > 0, frame.height > 0, shown.width > 0,
              abs(shown.minX - frame.minX) + abs(shown.minY - frame.minY) + abs(shown.width - frame.width) > 0.5 else { return }
        // A view's layer is anchored at its corner: scale from there, then move.
        let from = CATransform3DConcat(CATransform3DMakeScale(shown.width / frame.width, shown.height / frame.height, 1),
                                       CATransform3DMakeTranslation(shown.minX - frame.minX, shown.minY - frame.minY, 0))
        let spring = Tokens.Motion.springAnimation(keyPath: "transform", duration: Tokens.Motion.large)
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(spring, forKey: "reflow")
    }

    /// A closed (or filtered out) card folds away into its own middle while it fades, and the others close the gap.
    private func collapse(_ view: NSView) {
        guard let layer = view.layer, !Tokens.Motion.reduceMotion else { view.removeFromSuperview(); return }
        let size = view.bounds.size, k: CGFloat = 0.9
        let shrink = Tokens.Motion.springAnimation(keyPath: "transform", duration: Tokens.Motion.large)
        shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                                                    CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0)))
        let fade = Tokens.Motion.springAnimation(keyPath: "opacity", duration: Tokens.Motion.standard)
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [shrink, fade]
        group.duration = shrink.duration
        CATransaction.begin()
        CATransaction.setCompletionBlock { view.removeFromSuperview() }
        Tokens.Motion.withoutAnimation { view.alphaValue = 0 }
        layer.add(group, forKey: "collapse")
        CATransaction.commit()
    }

    /// Cards that come back as a search clears grow in where they belong, as they do when the desk opens.
    private func appear(_ cards: [TabThumbnailView]) {
        guard !Tokens.Motion.reduceMotion else { return }
        for card in cards {
            guard let layer = card.layer else { continue }
            let k: CGFloat = 0.96, size = card.bounds.size
            let grow = Tokens.Motion.springAnimation(keyPath: "transform", duration: Tokens.Motion.large)
            grow.fromValue = NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                                                        CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0)))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let fade = Tokens.Motion.springAnimation(keyPath: "opacity", duration: Tokens.Motion.large)
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = grow.duration
            group.fillMode = .backwards
            layer.add(group, forKey: "settle")
        }
    }

    // MARK: Selection

    private func cardClicked(_ tab: Tab, event: NSEvent) {
        if let id = cards.first(where: { $0.value.tab === tab || $0.value.partner === tab })?.key { setFocus(id, scroll: false) }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            if selection.contains(tab.id) { selection.remove(tab.id) } else { selection.insert(tab.id) }
            updateSelection()
        } else if !selection.isEmpty {
            selection = [tab.id]
            updateSelection()
        } else {
            hide(openingTab: tab)
        }
    }

    private func selectSpace(_ id: UUID) {
        guard let manager else { return }
        let ids = Set(manager.tabs(in: id).map(\.id))
        selection = ids.isSubset(of: selection) ? selection.subtracting(ids) : selection.union(ids)
        updateSelection()
    }

    private func updateSelection() {
        for (id, card) in cards { card.isSelected = selection.contains(id) }
        guard let controller else { return }
        if selection.isEmpty {
            if actionBar.superview != nil { actionBar.dismiss() }
            return
        }
        closeButton.title = selection.count == 1 ? "Close Tab" : "Close \(selection.count) Tabs"
        doneButton.title = "Done"
        let cw = closeButton.fittingWidth, dw = doneButton.fittingWidth
        let pad = Tokens.Space.x2
        let height = Tokens.Space.x10 + Tokens.Space.x1
        let width = pad * 3 + cw + dw
        let root = controller.root.bounds
        actionBar.frame = NSRect(x: round(root.midX - width / 2), y: root.maxY - height - Tokens.Space.x6, width: width, height: height)
        closeButton.frame = NSRect(x: pad, y: (height - Tokens.Space.x8) / 2, width: cw, height: Tokens.Space.x8)
        doneButton.frame = NSRect(x: closeButton.frame.maxX + pad, y: closeButton.frame.minY, width: dw, height: Tokens.Space.x8)
        if actionBar.superview == nil {
            controller.root.overlay.addSubview(actionBar)
            actionBar.present()
        }
    }

    private func closeSelected() {
        guard !selection.isEmpty else { return }
        let ids = selection
        selection = []
        close(ids)
    }

    /// ⌫ or ⌘W on the desk: the selected cards if there are any, otherwise the one the arrow keys are on.
    func closeFocused() {
        if !selection.isEmpty { closeSelected() } else if let focused { close([focused]) }
    }

    /// Closes the tabs behind these cards, a split's two pages together. ⌘Z brings them back, like closing them
    /// from the sidebar. The arrow keys move on to the next card, or the one before at the end.
    private func close(_ ids: Set<UUID>) {
        guard let manager else { return }
        let tabs = ids.compactMap { id in cards[id]?.tab ?? manager.tab(with: id) }
        let pages = tabs + tabs.compactMap { partner(of: $0) }
        guard !pages.isEmpty else { return }
        if let focused, ids.contains(focused) {
            let order = orderedCardIDs
            let index = order.firstIndex(of: focused) ?? 0
            let after = order[index...].first { !ids.contains($0) } ?? order[..<index].last { !ids.contains($0) }
            setFocus(after, scroll: false)
        }
        if let controller { controller.closeManyWithUndo(pages) } else { manager.close(pages) }
        reload(animated: true)
    }

    // MARK: Keyboard focus

    /// Every card, space by space, in the order they read.
    private var orderedCardIDs: [UUID] {
        Library.shared.spaces.flatMap { cardTabs(in: $0.id).map(\.id) }.filter { cards[$0] != nil }
    }

    private func setFocus(_ id: UUID?, scroll: Bool = true) {
        focused = id
        for (key, card) in cards { card.isFocused = key == id }
        if scroll, let id, let card = cards[id] { canvas.scrollToVisible(card.frame.insetBy(dx: 0, dy: -gap)) }
    }

    private enum Direction { case left, right, up, down }

    /// Left and right step through the cards in reading order, on from one space into the next. Up and down go to
    /// the row above or below, to the card most nearly in line.
    private func moveFocus(_ direction: Direction) {
        let order = orderedCardIDs
        guard let focused, let from = cards[focused]?.frame, let index = order.firstIndex(of: focused) else {
            setFocus(order.first)
            return
        }
        switch direction {
        case .left: setFocus(order[max(0, index - 1)])
        case .right: setFocus(order[min(order.count - 1, index + 1)])
        case .up, .down:
            let frames = order.compactMap { id in cards[id].map { (id: id, frame: $0.frame) } }
            let rows = frames.filter { direction == .down ? $0.frame.minY > from.minY + 1 : $0.frame.minY < from.minY - 1 }
            guard let row = direction == .down ? rows.map(\.frame.minY).min() : rows.map(\.frame.minY).max() else { return }
            let next = rows.filter { abs($0.frame.minY - row) < 1 }.min { abs($0.frame.midX - from.midX) < abs($1.frame.midX - from.midX) }
            setFocus(next?.id)
        }
    }

    /// Return: the card the arrow keys are on, or the first match.
    private func openFocused() {
        guard let id = focused ?? orderedCardIDs.first, let tab = cards[id]?.tab else { return }
        hide(openingTab: tab)
    }

    // MARK: Marquee selection

    func backgroundMouseDown(_ event: NSEvent) {
        guard let window = canvas.window else { return }
        let start = canvas.convert(event.locationInWindow, from: nil)
        let additive = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        let base = additive ? selection : []
        if !additive { selection = []; updateSelection() }
        var moved = false
        let layer = CAShapeLayer()
        layer.fillColor = canvas.cgColor(Tokens.Color.accent.withAlphaComponent(0.12))
        layer.strokeColor = canvas.cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
        layer.lineWidth = 1
        canvas.wantsLayer = true
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            let point = self.canvas.convert(event.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            if !moved, rect.width + rect.height > 4 {
                moved = true
                self.canvas.layer?.addSublayer(layer)
            }
            guard moved else { return }
            Tokens.Motion.withoutAnimation { layer.path = CGPath(rect: rect, transform: nil) }
            self.selection = base.union(self.cards.filter { $0.value.frame.intersects(rect) }.map(\.key))
            self.updateSelection()
        }
        layer.removeFromSuperlayer()
        if !moved && !additive { hide(openingTab: nil) }
    }

    // MARK: Dragging cards

    private func beginDrag(_ tab: Tab, event: NSEvent) -> Bool {
        guard let window = canvas.window, let card = cards[tab.id], let manager else { return false }
        let start = canvas.convert(event.locationInWindow, from: nil)
        let offset = NSPoint(x: start.x - card.frame.minX, y: start.y - card.frame.minY)
        card.removeFromSuperview()
        canvas.addSubview(card)
        card.layer?.shadowOpacity = 1
        card.layer?.shadowRadius = Tokens.Space.x3
        card.layer?.shadowColor = canvas.cgColor(Tokens.Color.panelShadow)
        var target = (id: tab.id, space: tab.spaceID, index: cardTabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0)
        let origin = target
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            let point = self.canvas.convert(event.locationInWindow, from: nil)
            Tokens.Motion.withoutAnimation { card.frame.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y) }
            self.canvas.autoscroll(with: event)
            if let slot = self.slot(at: NSPoint(x: card.frame.midX, y: card.frame.midY), excluding: tab.id), slot.space != target.space || slot.index != target.index {
                target = (tab.id, slot.space, slot.index)
                self.applyLayout(animated: true, dragging: target)
            }
        }
        card.layer?.shadowOpacity = 0
        // Through the window, so the selection moves on with it and ⌘Z puts it back.
        if target != origin { controller?.moveWithUndo(tab, to: listIndex(ofCard: target.index, in: target.space, moving: tab), in: target.space) }
        applyLayout(animated: true)
        return true
    }

    /// Where a card's position puts the tab in the space's list, which also holds a split's second pages.
    private func listIndex(ofCard index: Int, in space: UUID, moving tab: Tab) -> Int {
        guard let manager else { return index }
        let list = manager.tabs(in: space).filter { $0 !== tab }
        let cards = cardTabs(in: space).filter { $0 !== tab }
        guard index < cards.count else { return list.count }
        return list.firstIndex { $0 === cards[index] } ?? index
    }

    /// The space and position a dragged card would land in.
    private func slot(at point: NSPoint, excluding id: UUID) -> (space: UUID, index: Int)? {
        let layout = layoutFrames()
        let ordered = layout.headers.sorted { $0.value.minY < $1.value.minY }
        guard let space = ordered.last(where: { $0.value.minY <= point.y })?.key ?? ordered.first?.key else { return nil }
        let ids = cardTabs(in: space).map(\.id).filter { $0 != id }
        var index = 0
        for (i, cardID) in ids.enumerated() {
            guard let frame = layout.cards[cardID] else { continue }
            if point.y > frame.maxY || (point.y >= frame.minY && point.x > frame.midX) { index = i + 1 }
        }
        return (space, index)
    }

    // MARK: Keyboard

    func keyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            if !selection.isEmpty { selection = []; updateSelection() } else { hide(openingTab: nil) }
            return true
        case 51, 117: // delete, forward delete
            closeFocused()
            return true
        case 36, 76: // return, enter
            openFocused()
            return true
        case 123: moveFocus(.left); return true
        case 124: moveFocus(.right); return true
        case 125: moveFocus(.down); return true
        case 126: moveFocus(.up); return true
        case 0 where event.modifierFlags.contains(.command): // cmd-A
            selection = Set(cards.keys)
            updateSelection()
            return true
        default:
            // Typing anywhere searches. The key goes to the field itself rather than being appended, so input
            // methods (Chinese, Japanese) compose there as usual.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let chars = event.characters,
                  let scalar = chars.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
                  scalar.value < 0xF700, canvas.window?.makeFirstResponder(searchField) == true,
                  let editor = searchField.currentEditor() as? NSTextView else { return false }
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            editor.keyDown(with: event)
            return true
        }
    }

    #if DEBUG
    /// Debug bridge: a key as the search field gets it (left, right, up, down, return, delete, esc), or text typed.
    func debugKey(_ name: String) {
        let selectors = ["left": #selector(NSResponder.moveLeft(_:)), "right": #selector(NSResponder.moveRight(_:)),
                         "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:)),
                         "return": #selector(NSResponder.insertNewline(_:)), "delete": #selector(NSResponder.deleteBackward(_:)),
                         "esc": #selector(NSResponder.cancelOperation(_:))]
        if let selector = selectors[name] {
            _ = searchDelegate.command?(selector)
        } else {
            searchField.stringValue = name == "-" ? "" : name
            search(searchField.stringValue)
        }
    }
    #endif

    // MARK: Pinch

    /// Pinching out on a page (that isn't zoomed in) opens the desk; pinching in on a card opens it.
    func handleMagnify(_ event: NSEvent) -> Bool {
        guard event.type == .magnify, let controller else { return false }
        if event.phase == .began {
            magnifyTotal = 0
            gestureClaimed = false
        }
        magnifyTotal += event.magnification
        if isVisible {
            if event.phase == .ended || event.phase == .cancelled {
                defer { magnifyTotal = 0 }
                if magnifyTotal > 0.12 {
                    let point = canvas.convert(event.locationInWindow, from: nil)
                    let hit = cards.first { $0.value.frame.contains(point) }?.key
                    hide(openingTab: hit.flatMap { controller.tabManager.tab(with: $0) })
                }
            }
            return true
        }
        if gestureClaimed {
            if event.phase == .ended || event.phase == .cancelled { gestureClaimed = false }
            return true
        }
        // Zoomed in, a pinch out zooms back out first. A PDF zooms itself, so it counts while it's bigger than fitting.
        let pageZoomed = (controller.selectedTab?.pdfViewer?.isZoomedIn ?? false) || (controller.selectedWebView?.magnification ?? 1) > 1.01
        guard !pageZoomed, magnifyTotal < -0.15 else { return false }
        gestureClaimed = true
        show()
        return true
    }
}


/// The desk's search field reports here: each change, and Return and Esc.
private final class DeskSearchDelegate: NSObject, NSTextFieldDelegate {
    var changed: ((String) -> Void)?
    var command: ((Selector) -> Bool)?

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        changed?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        command?(selector) ?? false
    }
}

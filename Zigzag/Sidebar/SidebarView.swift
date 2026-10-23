import AppKit

protocol SidebarDelegate: SidebarListDelegate {
    func sidebarOpenCommandBar()
    func sidebarSwitchSpace(_ id: UUID)
    func sidebarNewSpace()
    func sidebarShowDownloads(from view: NSView)
    func sidebarSpaceMenu(for id: UUID) -> NSMenu?
}

/// The address at the top of the sidebar. Shows only the domain; clicking opens the command bar.
final class AddressView: InteractiveView {
    private let label = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private let lock = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        lock.imageScaling = .scaleNone
        lock.contentTintColor = Tokens.Color.textTertiary
        addSubview(lock)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Opens the command bar")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(url: URL?, isSecure: Bool) {
        if let url, let host = url.host() {
            label.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else if let url, url.isFileURL {
            label.stringValue = url.lastPathComponent
        } else {
            label.stringValue = ""
        }
        label.textColor = label.stringValue.isEmpty ? Tokens.Color.textTertiary : Tokens.Color.textSecondary
        if label.stringValue.isEmpty { label.stringValue = "Search or enter address" }
        let insecure = url?.scheme == "http"
        lock.image = insecure ? Tokens.Symbol.image("exclamationmark.triangle", size: Tokens.TypeSize.small) : nil
        lock.isHidden = !insecure
        setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        var x = pad
        if !lock.isHidden {
            lock.frame = NSRect(x: x, y: 0, width: Tokens.Space.x3, height: bounds.height)
            x = lock.frame.maxX + Tokens.Space.x1
        }
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: bounds.width - x - pad, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
    }
}

/// One dot per space at the bottom of the sidebar.
final class SpaceDotView: InteractiveView {
    let spaceID: UUID
    private let dot = CALayer()
    var color: NSColor = .gray { didSet { stateDidChange(animated: false) } }
    var isDropTarget = false { didSet { stateDidChange(animated: true) } }

    init(spaceID: UUID) {
        self.spaceID = spaceID
        super.init(frame: NSRect(x: 0, y: 0, width: Tokens.Space.x6, height: Tokens.Space.x6))
        layer?.cornerRadius = Tokens.Radius.control
        layer?.addSublayer(dot)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        let size: CGFloat = isSelected ? Tokens.Space.x2 : Tokens.Space.x2 - 2
        Tokens.Motion.withoutAnimation {
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
            dot.cornerRadius = size / 2
            dot.backgroundColor = cgColor(isSelected ? color : Tokens.Color.textTertiary)
        }
        let fill: NSColor? = isDropTarget ? Tokens.Color.pressedFill : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// The sidebar: navigation, address, bookmarks, tabs and spaces. Drawn entirely by us.
final class SidebarView: NSView {
    weak var delegate: SidebarDelegate? {
        didSet { list.delegate = delegate }
    }

    let backButton = IconButton(symbol: "chevron.left", toolTip: "Back")
    let forwardButton = IconButton(symbol: "chevron.right", toolTip: "Forward")
    let reloadButton = IconButton(symbol: "arrow.clockwise", toolTip: "Reload")
    let address = AddressView()
    let list = SidebarListView()
    private let scrollView = NSScrollView()
    private let bottomBar = NSView()
    private let downloadsButton = IconButton(symbol: "arrow.down.circle", toolTip: "Downloads")
    private let newSpaceButton = IconButton(symbol: "plus", toolTip: "New Space")
    private var dots: [SpaceDotView] = []
    private let topSeparator = ColorView(color: Tokens.Color.separator)
    /// Width reserved on the left of the top row for the traffic lights.
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }
    var showsTrafficLights = true { didSet { needsLayout = true } }

    /// Translation while a two-finger swipe between spaces is in progress.
    private var swipeOffset: CGFloat = 0
    private var swipeTracking = false
    private var swipeDecided: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        for button in [backButton, forwardButton, reloadButton] { addSubview(button) }
        addSubview(address)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = list
        addSubview(scrollView)
        topSeparator.alphaValue = 0
        addSubview(topSeparator)
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        bottomBar.addSubview(downloadsButton)
        bottomBar.addSubview(newSpaceButton)
        addSubview(bottomBar)
        downloadsButton.isHidden = true
        downloadsButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.delegate?.sidebarShowDownloads(from: self.downloadsButton)
        }
        newSpaceButton.onClick = { [weak self] _ in self?.delegate?.sidebarNewSpace() }
        address.onClick = { [weak self] _ in self?.delegate?.sidebarOpenCommandBar() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func listScrolled() {
        let scrolled = scrollView.contentView.bounds.minY > 1
        if (topSeparator.alphaValue > 0) != scrolled {
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.topSeparator.animator().alphaValue = scrolled ? 1 : 0 }
        }
    }

    // MARK: Layout

    /// The y position (from the top) where the traffic lights should be centered.
    var trafficLightCenterY: CGFloat { Tokens.Metric.topRowHeight / 2 + Tokens.Space.x1 }

    override func layout() {
        super.layout()
        let pad = Tokens.Metric.sidebarPadding
        let width = bounds.width
        let rowCenter = trafficLightCenterY
        let button = Tokens.Metric.iconButton
        var x = width - pad - button
        for b in [reloadButton, forwardButton, backButton] {
            b.frame = NSRect(x: x, y: rowCenter - button / 2, width: button, height: button)
            x -= button
        }
        let topRowBottom = Tokens.Metric.topRowHeight + Tokens.Space.x2
        address.frame = NSRect(x: pad, y: topRowBottom, width: width - pad * 2, height: Tokens.Metric.addressHeight)

        let bottomHeight = Tokens.Metric.bottomBarHeight
        bottomBar.frame = NSRect(x: 0, y: bounds.height - bottomHeight - pad, width: width, height: bottomHeight)
        let listTop = address.frame.maxY + Tokens.Metric.sectionGap
        scrollView.frame = NSRect(x: pad + swipeOffset, y: listTop, width: width - pad * 2, height: bottomBar.frame.minY - listTop)
        topSeparator.frame = NSRect(x: pad * 2, y: listTop - Tokens.Metric.hairline, width: width - pad * 4, height: Tokens.Metric.hairline)
        if list.frame.width != scrollView.contentSize.width {
            list.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(list.frame.height, scrollView.contentSize.height)))
        }
        layoutBottomBar()
    }

    private func layoutBottomBar() {
        let pad = Tokens.Metric.sidebarPadding
        let button = Tokens.Metric.iconButton
        let h = bottomBar.bounds.height
        downloadsButton.frame = NSRect(x: pad, y: (h - button) / 2, width: button, height: button)
        newSpaceButton.frame = NSRect(x: bottomBar.bounds.width - pad - button, y: (h - button) / 2, width: button, height: button)
        let dotSize = Tokens.Space.x6
        let total = CGFloat(dots.count) * dotSize
        var x = (bottomBar.bounds.width - total) / 2
        for dot in dots {
            dot.frame = NSRect(x: x, y: (h - dotSize) / 2, width: dotSize, height: dotSize)
            x += dotSize
        }
    }

    // MARK: Updating

    func update(tab: Tab?) {
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
        reloadButton.symbol = (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise"
        reloadButton.toolTip = (tab?.isLoading ?? false) ? "Stop" : "Reload"
        address.show(url: tab?.url, isSecure: tab?.url?.scheme == "https")
    }

    func reloadSpaces(current: UUID) {
        let spaces = Library.shared.spaces
        if dots.map(\.spaceID) != spaces.map(\.id) {
            dots.forEach { $0.removeFromSuperview() }
            dots = spaces.map { space in
                let dot = SpaceDotView(spaceID: space.id)
                dot.onClick = { [weak self] _ in self?.delegate?.sidebarSwitchSpace(space.id) }
                dot.onRightClick = { [weak self] _ in self?.delegate?.sidebarSpaceMenu(for: space.id) }
                bottomBar.addSubview(dot)
                return dot
            }
        }
        for dot in dots {
            guard let space = Library.shared.space(dot.spaceID) else { continue }
            dot.color = space.color.swatch
            dot.isSelected = space.id == current
            dot.toolTip = space.name
            dot.setAccessibilityLabel("Space \(space.name)")
        }
        // A single space needs no switcher.
        dots.forEach { $0.isHidden = false }
        layoutBottomBar()
    }

    func updateDownloads(active: Int, hasAny: Bool) {
        downloadsButton.isHidden = !hasAny
        downloadsButton.symbol = active > 0 ? "arrow.down.circle.dotted" : "arrow.down.circle"
    }

    var downloadsAnchor: NSView { downloadsButton }

    /// Highlights the space dot under a window point during a drag, returning its space.
    func spaceDot(at windowPoint: NSPoint) -> UUID? {
        var found: UUID?
        for dot in dots where !dot.isHidden {
            let inside = dot.bounds.contains(dot.convert(windowPoint, from: nil))
            dot.isDropTarget = inside
            if inside { found = dot.spaceID }
        }
        return found
    }

    func clearDropTargets() { dots.forEach { $0.isDropTarget = false } }

    // MARK: Space transition

    /// Slides the old list out and the new one in, in the direction of travel.
    func transitionList(direction: CGFloat, from snapshot: NSImage?) {
        guard let snapshot, direction != 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            list.reload(animated: false)
            return
        }
        let width = scrollView.frame.width + Tokens.Metric.sidebarPadding * 2
        let ghost = NSImageView(frame: scrollView.frame)
        ghost.image = snapshot
        ghost.imageScaling = .scaleNone
        ghost.imageAlignment = .alignTopLeft
        addSubview(ghost)
        list.reload(animated: false)
        var finalFrame = scrollView.frame
        finalFrame.origin.x = Tokens.Metric.sidebarPadding
        var start = finalFrame
        start.origin.x += direction * width
        scrollView.frame = start
        var ghostEnd = ghost.frame
        ghostEnd.origin.x -= direction * width
        Tokens.Motion.animate(Tokens.Motion.snappy, {
            self.scrollView.animator().frame = finalFrame
            ghost.animator().frame = ghostEnd
        }, completion: { ghost.removeFromSuperview() })
    }

    func listSnapshot() -> NSImage? {
        let rect = scrollView.bounds
        guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        scrollView.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Two-finger swipe between spaces

    var onSwipeSpace: ((Int) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { super.scrollWheel(with: event); return }
        if event.phase == .began {
            swipeDecided = nil
            swipeTracking = false
        }
        if swipeDecided == nil, event.phase == .began || event.phase == .changed {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 && abs(event.scrollingDeltaX) > 0.5 {
                swipeDecided = true
                swipeTracking = true
            } else if abs(event.scrollingDeltaY) > 0.5 {
                swipeDecided = false
            }
        }
        guard swipeTracking else {
            scrollView.scrollWheel(with: event)
            return
        }
        switch event.phase {
        case .changed:
            swipeOffset += event.scrollingDeltaX
            // Resist when there is no space in that direction.
            let limit = bounds.width * 0.5
            swipeOffset = max(-limit, min(limit, swipeOffset))
            needsLayout = true
            layoutSubtreeIfNeeded()
        case .ended, .cancelled:
            swipeTracking = false
            let threshold = bounds.width * 0.18
            var switched = false
            if event.phase == .ended, abs(swipeOffset) > threshold {
                // Fingers moving right reveal the space to the left.
                switched = onSwipeSpace?(swipeOffset > 0 ? -1 : 1) ?? false
            }
            let offset = swipeOffset
            swipeOffset = 0
            if !switched {
                var frame = scrollView.frame
                frame.origin.x = Tokens.Metric.sidebarPadding
                if offset != 0 {
                    Tokens.Motion.animate { self.scrollView.animator().frame = frame }
                }
            }
        default:
            break
        }
    }

    /// Where a space switch triggered by a swipe should start sliding in from.
    var currentSwipeOffset: CGFloat { swipeOffset }
}

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
    /// Shows while the page uses the camera or microphone; click for options.
    /// Buttons inside the field: the same size, the same gap all round, corners that follow the field's.
    static let buttonSide: CGFloat = Tokens.Space.x7Height
    static let buttonInset: CGFloat = 4
    let captureButton = IconButton(symbol: "video.fill", size: AddressView.buttonSide, toolTip: "Camera and Microphone")
    /// Shown on articles: opens Reader.
    let readerButton = IconButton(symbol: "doc.plaintext", size: AddressView.buttonSide, toolTip: "Show Reader")

    func setCapture(camera: Bool, microphone: Bool) {
        captureButton.isHidden = !(camera || microphone)
        captureButton.symbol = camera ? "video.fill" : "mic.fill"
        captureButton.tint = .systemOrange
        captureButton.toolTip = camera && microphone ? "Using your camera and microphone" : camera ? "Using your camera" : "Using your microphone"
        needsLayout = true
    }

    /// Extension buttons at the trailing end, like Safari's address bar.
    private(set) var actionButtons: [IconButton] = []

    struct ActionButton {
        var image: NSImage?
        var symbol = "puzzlepiece.extension"
        var label: String
        /// A short count or word in the corner; "!" when the extension needs the person.
        var badge = ""
        var needsAttention = false
        var action: (NSView) -> Void
        var menu: () -> NSMenu?
    }

    func setActions(_ items: [ActionButton]) {
        actionButtons.forEach { $0.removeFromSuperview() }
        actionButtons = items.map { item in
            let button = IconButton(symbol: item.symbol, size: AddressView.buttonSide, toolTip: item.label)
            if let image = item.image { button.image = image }
            button.onClick = { [weak button] _ in if let button { item.action(button) } }
            button.onRightClick = { _ in item.menu() }
            let badge = item.needsAttention ? "!" : item.badge
            if !badge.isEmpty { button.addSubview(BadgeView(text: badge, attention: item.needsAttention)) }
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Its buttons sit 4pt in, with 6pt corners: 10 here keeps the two curves running side by side.
        layer?.cornerRadius = Tokens.Radius.control + AddressView.buttonInset
        layer?.cornerCurve = .continuous
        lock.imageScaling = .scaleNone
        lock.contentTintColor = Tokens.Color.textTertiary
        addSubview(lock)
        addSubview(label)
        captureButton.isHidden = true
        addSubview(captureButton)
        readerButton.isHidden = true
        addSubview(readerButton)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Opens the command bar")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setReader(available: Bool, active: Bool) {
        readerButton.isHidden = !available && !active
        readerButton.isSelected = active
        readerButton.toolTip = (active ? "Hide Reader" : "Show Reader") + Shortcuts.hint(for: #selector(BrowserWindowController.toggleReader(_:)))
        needsLayout = true
    }

    func show(url: URL?, isSecure: Bool) {
        if #available(macOS 15.4, *), let url, url.scheme == "webkit-extension",
           let context = ExtensionHost.shared.contexts.first(where: { $0.baseURL.host() == url.host() }) {
            // An extension's own page (its settings) is named after the extension, not its random address.
            label.stringValue = context.webExtension.displayName ?? "Extension"
        } else if HistoryPage.isHistory(url) {
            label.stringValue = "History"
        } else if let url, let host = url.host() {
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
        let side = AddressView.buttonSide, inset = (bounds.height - side) / 2
        var right = bounds.width - inset
        let trailingButtons = [readerButton, captureButton].filter { !$0.isHidden } + actionButtons
        for button in trailingButtons.reversed() {
            button.frame = NSRect(x: right - side, y: inset, width: side, height: side)
            button.radius = Tokens.Radius.control
            right = button.frame.minX - 2
        }
        let trailing = trailingButtons.isEmpty ? bounds.width - pad : right - Tokens.Space.x1
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: trailing - x, height: h)
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
    /// While a swipe pulls toward or away from this space: how much it looks like the space you're in, 0 to 1,
    /// following the fingers. Nil the rest of the time; clearing it eases back to what's really selected.
    var swipeShare: CGFloat? {
        didSet {
            guard oldValue != swipeShare else { return }
            settlesFromSwipe = swipeShare == nil
            stateDidChange(animated: false)
        }
    }
    private var settlesFromSwipe = false

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

    /// The space you're in is a short pill in the sidebar's own text color, readable on any space's color; the
    /// others are small, quieter dots. Switching stretches one and shrinks the other.
    private var wasSelected: Bool?

    override func stateDidChange(animated: Bool) {
        let height: CGFloat = 6
        let share = swipeShare ?? (isSelected ? 1 : 0)
        let width: CGFloat = 6 + 10 * share
        let ink = Tokens.Color.textPrimary
        let resting: CGFloat = isHovered ? 0.5 : 0.28
        let tint = ink.withAlphaComponent(resting + (0.78 - resting) * share)
        let changed = (wasSelected != nil && wasSelected != isSelected && swipeShare == nil) || settlesFromSwipe
        wasSelected = isSelected
        settlesFromSwipe = false
        let apply = {
            self.dot.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            self.dot.position = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            self.dot.cornerRadius = height / 2
            self.dot.backgroundColor = self.cgColor(tint)
        }
        if changed && !Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
            apply()
            CATransaction.commit()
        } else {
            Tokens.Motion.withoutAnimation(apply)
        }
        let fill: NSColor? = isDropTarget ? Tokens.Color.pressedFill : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// The sidebar: navigation, address, bookmarks, tabs and spaces. Drawn entirely by us.
final class SidebarView: NSView {
    weak var delegate: SidebarDelegate? {
        didSet { list.delegate = delegate; neighborList.delegate = delegate }
    }

    /// The top row's buttons are a size up from the rest, level with the traffic lights, so they're easy to hit.
    static let toolbarButton: CGFloat = 30
    static let toolbarSymbol: CGFloat = 16
    let backButton = IconButton(symbol: "chevron.left", size: toolbarButton, symbolSize: toolbarSymbol, toolTip: "Back")
    let forwardButton = IconButton(symbol: "chevron.right", size: toolbarButton, symbolSize: toolbarSymbol, toolTip: "Forward")
    let reloadButton = IconButton(symbol: "arrow.clockwise", size: toolbarButton, symbolSize: toolbarSymbol, toolTip: "Reload")
    /// Stand-in for the traffic lights while the sidebar slides.
    private let trafficLightsPicture = NSImageView()
    let sidebarButton = IconButton(symbol: "sidebar.left", size: toolbarButton, symbolSize: toolbarSymbol, toolTip: "Hide Sidebar")
    let address = AddressView()
    let favorites = FavoritesView()
    let list = SidebarListView()
    private let scrollView = NSScrollView()
    /// Tabs running on below the bottom of the list fade out there, rather than being sliced off by the footer.
    private let bottomFade = CAGradientLayer()
    /// The space next door, which slides in beside the current one while you swipe.
    private let neighborList = SidebarListView()
    private let neighborScroll = NSScrollView()
    private let neighborFade = CAGradientLayer()

    private let bottomBar = NSView()
    let nowPlaying = NowPlayingView()

    private let downloadsButton = IconButton(symbol: "arrow.down.circle", toolTip: "Downloads")
    private let newSpaceButton = IconButton(symbol: "plus", toolTip: "New Space")
    private var dots: [SpaceDotView] = []
    private let topSeparator = ColorView(color: Tokens.Color.separator)
    /// Width reserved on the left of the top row for the traffic lights.
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }
    var showsTrafficLights = true { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        for button in [sidebarButton, backButton, forwardButton, reloadButton] { addSubview(button) }
        trafficLightsPicture.imageScaling = .scaleNone
        trafficLightsPicture.isHidden = true
        addSubview(trafficLightsPicture)
        addSubview(address)
        addSubview(favorites)
        favorites.onHeightChange = { [weak self] in self?.needsLayout = true }

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = list
        // Like Arc, the sidebar scrolls without showing a scroll bar.
        scrollView.hasVerticalScroller = false
        addSubview(scrollView)
        scrollView.wantsLayer = true
        scrollView.layer?.mask = bottomFade
        neighborScroll.drawsBackground = false
        neighborScroll.hasVerticalScroller = false
        neighborScroll.hasHorizontalScroller = false
        neighborScroll.automaticallyAdjustsContentInsets = false
        neighborScroll.documentView = neighborList
        neighborScroll.isHidden = true
        neighborScroll.wantsLayer = true
        neighborScroll.layer?.mask = neighborFade
        addSubview(neighborScroll)
        topSeparator.alphaValue = 0
        addSubview(topSeparator)
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        nowPlaying.isHidden = true
        addSubview(nowPlaying)

        bottomBar.addSubview(downloadsButton)
        bottomBar.addSubview(newSpaceButton)
        addSubview(bottomBar)
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

    /// The sidebar is the window's title bar: drag it to move the window, and double-click it to zoom (or
    /// whatever the Mac's title bar double-click is set to do).
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else { window.performDrag(with: event); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    @objc private func listScrolled() {
        list.pinHeader()
        updateBottomFade()
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
        let button = Self.toolbarButton
        var x = width - pad - button + 2
        for b in [reloadButton, forwardButton, backButton] {
            b.frame = NSRect(x: x, y: rowCenter - button / 2, width: button, height: button)
            x -= button
        }
        // The sidebar toggle sits right after the traffic lights, where Arc and Safari put it.
        // Without traffic lights (full screen) the sidebar button starts the row.
        let lead = trafficLightsWidth > 0 ? pad + Tokens.Space.x2 + trafficLightsWidth + Tokens.Space.x2 : pad
        sidebarButton.frame = NSRect(x: lead, y: rowCenter - button / 2, width: button, height: button)
        let topRowBottom = Tokens.Metric.topRowHeight + Tokens.Space.x2
        address.frame = NSRect(x: pad, y: topRowBottom, width: width - pad * 2, height: Tokens.Metric.addressHeight)

        let bottomHeight = Tokens.Metric.bottomBarHeight
        // Its buttons sit as far from the bottom edge as from the side.
        let buttonInset = (bottomHeight - Tokens.Metric.iconButton) / 2
        bottomBar.frame = NSRect(x: 0, y: bounds.height - bottomHeight + buttonInset - pad, width: width, height: bottomHeight)
        let favoritesHeight = favorites.preferredHeight
        favorites.isHidden = favoritesHeight == 0
        favorites.frame = NSRect(x: pad, y: address.frame.maxY + Tokens.Space.x2, width: width - pad * 2, height: favoritesHeight)
        let listTop = (favoritesHeight > 0 ? favorites.frame.maxY : address.frame.maxY) + Tokens.Metric.sectionGap
        let frames = bottomFrames()
        nowPlaying.frame = frames.nowPlaying
        let listBottom = frames.listBottom
        scrollView.frame = NSRect(x: pad + swipeOffset, y: listTop, width: width - pad * 2, height: listBottom - listTop)
        topSeparator.frame = NSRect(x: pad * 2, y: listTop - Tokens.Metric.hairline, width: width - pad * 4, height: Tokens.Metric.hairline)
        if list.frame.width != scrollView.contentSize.width {
            list.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(list.frame.height, scrollView.contentSize.height)))
        }
        layoutBottomBar()
        updateBottomFade()
        if !neighborScroll.isHidden { placeNeighbor() }
    }

    private func updateBottomFade() {
        Self.fade(bottomFade, for: scrollView, list: list)
    }

    /// Tabs running on below the bottom of a list fade out there.
    private static func fade(_ bottomFade: CAGradientLayer, for scrollView: NSScrollView, list: NSView) {
        let bounds = scrollView.bounds
        let clip = scrollView.contentView.bounds
        let more = list.frame.height - clip.maxY > 1
        let fade = bounds.height > 0 ? min(Tokens.Space.x6 / bounds.height, 0.5) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomFade.frame = bounds
        // The mask's y runs up from the bottom: clear there while there's more below, solid everywhere else.
        bottomFade.colors = [more ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        bottomFade.locations = [0, NSNumber(value: Double(fade)), 1]
        bottomFade.startPoint = CGPoint(x: 0.5, y: 0)
        bottomFade.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
    }

    private func layoutBottomBar() {
        let pad = Tokens.Metric.sidebarPadding
        let button = Tokens.Metric.iconButton
        let h = bottomBar.bounds.height
        downloadsButton.frame = NSRect(x: pad, y: (h - button) / 2, width: button, height: button)
        newSpaceButton.frame = NSRect(x: bottomBar.bounds.width - pad - button, y: (h - button) / 2, width: button, height: button)
        let available = newSpaceButton.frame.minX - downloadsButton.frame.maxX - Tokens.Space.x2
        let dotSize = min(Tokens.Space.x6, floor(available / CGFloat(max(dots.count, 1))))
        let total = CGFloat(dots.count) * dotSize
        var x = downloadsButton.frame.maxX + Tokens.Space.x1 + (available - total) / 2
        for dot in dots {
            dot.frame = NSRect(x: x, y: (h - dotSize) / 2, width: dotSize, height: dotSize)
            x += dotSize
        }
    }

    func showTrafficLightsPicture(_ image: NSImage?) {
        trafficLightsPicture.image = image
        trafficLightsPicture.isHidden = image == nil
        if let image {
            let x = Tokens.Metric.sidebarPadding + Tokens.Space.x2
            trafficLightsPicture.frame = NSRect(x: x, y: trafficLightCenterY - image.size.height / 2, width: image.size.width, height: image.size.height)
        }
    }

    // MARK: Updating

    func update(tab: Tab?) {
        backButton.isEnabled = tab?.canGoBackOrReturn ?? false
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
                dot.onClick = { [weak self, weak dot] _ in
                    guard let self, let dot else { return }
                    // Clicking the space you're in edits it; clicking another switches to it.
                    if dot.isSelected { self.onEditSpace?(space.id) } else { self.delegate?.sidebarSwitchSpace(space.id) }
                }
                dot.onDoubleClick = { [weak self] in self?.onEditSpace?(space.id) }
                dot.onRightClick = { [weak self] _ in self?.delegate?.sidebarSpaceMenu(for: space.id) }
                bottomBar.addSubview(dot)
                return dot
            }
        }
        for dot in dots {
            guard let space = Library.shared.space(dot.spaceID) else { continue }
            dot.color = space.swatch
            dot.isSelected = space.id == current
            dot.toolTip = space.name
            dot.setAccessibilityLabel("Space \(space.name)")
        }
        // A single space needs no switcher.
        dots.forEach { $0.isHidden = false }
        layoutBottomBar()
    }

    func dot(for spaceID: UUID) -> NSView? { dots.first { $0.spaceID == spaceID } }

    /// The row of space dots.
    var dotsAnchor: NSView { bottomBar }
    /// The first space's dot, or the row when there's only one.
    var firstDotAnchor: NSView { dots.count > 1 ? dots[0] : bottomBar }
    /// The + that makes a space.
    var newSpaceAnchor: NSView { newSpaceButton }
    var onEditSpace: ((UUID) -> Void)?

    /// The bottom stack: the now-playing control sits above the dots.
    private func bottomFrames() -> (nowPlaying: NSRect, listBottom: CGFloat) {
        let pad = Tokens.Metric.sidebarPadding
        var bottom = bottomBar.frame.minY
        let playingHeight = Tokens.Space.x10
        let playing = NSRect(x: pad, y: bottom - (nowPlaying.isHidden ? 0 : playingHeight), width: bounds.width - pad * 2, height: playingHeight)
        if !nowPlaying.isHidden { bottom = playing.minY - Tokens.Space.x1 }
        return (playing, bottom)
    }

    /// Shows (or hides) the now-playing control, making room above the dots.
    func setNowPlaying(_ tab: Tab?, paused: Bool) {
        let show = tab != nil
        if let tab { nowPlaying.isPaused = paused; nowPlaying.show(tab) }
        guard show == nowPlaying.isHidden else { return }
        nowPlaying.isHidden = !show
        needsLayout = true
        if show {
            nowPlaying.alphaValue = 0
            Tokens.Motion.animate(Tokens.Motion.snappy) { self.nowPlaying.animator().alphaValue = 1 }
        }
    }

    func previewDotColor(_ color: NSColor, for spaceID: UUID) {
        dots.first { $0.spaceID == spaceID }?.color = color
    }

    /// A thin ring around the button that fills as downloads run, and a check for a moment when they're done.
    private let downloadsRing = CAShapeLayer()
    private var wasDownloading = false

    func updateDownloads(active: Int, hasAny: Bool, progress: Double = 1) {
        // Always there, in the same place, so the space dots never shift; with nothing downloaded, its panel says so.
        downloadsButton.isHidden = false
        let downloading = active > 0
        if downloadsRing.superlayer == nil, let host = downloadsButton.layer {
            downloadsRing.fillColor = nil
            downloadsRing.lineWidth = 2
            downloadsRing.lineCap = .round
            downloadsRing.strokeEnd = 0
            host.addSublayer(downloadsRing)
        }
        let b = downloadsButton.bounds
        let d = min(b.width, b.height) - 6
        let rect = CGRect(x: (b.width - d) / 2, y: (b.height - d) / 2, width: d, height: d)
        // Starts at the top and runs clockwise, like the system's own progress rings.
        var flip = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi / 2).scaledBy(x: -1, y: 1).translatedBy(x: -rect.midX, y: -rect.midY)
        downloadsRing.path = CGPath(ellipseIn: rect, transform: &flip)
        downloadsRing.frame = b
        downloadsRing.strokeColor = cgColor(Brand.Theme.current.accent)
        downloadsRing.opacity = downloading ? 1 : 0
        downloadsRing.strokeEnd = downloading ? CGFloat(max(0.04, min(progress, 1))) : 0
        downloadsButton.symbol = downloading ? "arrow.down" : (wasDownloading ? "checkmark.circle" : "arrow.down.circle")
        if wasDownloading, !downloading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, !self.wasDownloading else { return }
                self.downloadsButton.symbol = "arrow.down.circle"
            }
        }
        wasDownloading = downloading
    }

    /// The button answers when a download lands in it: a small press inward and back.
    func pulseDownloads() {
        guard !Tokens.Motion.reduceMotion, let layer = downloadsButton.layer else { return }
        // Struck by the download landing: a short press inward and back, like a click.
        let size = downloadsButton.bounds.size
        func scaled(_ k: CGFloat) -> NSValue {
            NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                                       CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0)))
        }
        let pulse = CAKeyframeAnimation(keyPath: "transform")
        pulse.values = [scaled(1), scaled(0.86), scaled(1)]
        pulse.keyTimes = [0, 0.35, 1]
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
        pulse.duration = 0.26
        layer.add(pulse, forKey: "pulse")
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
    /// If a swipe is in progress, the new list continues from where the fingers left it.
    func transitionList(direction: CGFloat, from snapshot: NSImage?) {
        let fromSwipe = scrollView.frame.minX - Tokens.Metric.sidebarPadding
        // Let go of a swipe past the line: the spring carries on at the fingers' speed. Any other switch (a click
        // on a dot, ⌃2) ends a swipe in progress, and the new list simply slides in from where the old one was.
        let landing = landingVelocity
        landingVelocity = nil
        if swipeState == .tracking { swipeState = .finished }
        swipeEndWork?.cancel()
        swipeOffset = 0
        neighborScroll.isHidden = true
        clearSwipeDots()
        var finalFrame = scrollView.frame
        finalFrame.origin.x = Tokens.Metric.sidebarPadding
        // Space switches slide even from the keyboard (⌃1, ⌃2…): the motion tells you which way you went.
        let animate = snapshot != nil && direction != 0 && !Tokens.Motion.reduceMotion
        Tokens.Motion.withoutAnimation { scrollView.frame = finalFrame }
        // Mid-drag the list keeps its gap and hidden row; otherwise it simply reloads.
        if list.isDragging { list.refreshDuringDrag() } else { list.reload(animated: false) }
        guard animate, let snapshot else { return }
        let width = bounds.width
        let ghost = NSImageView(frame: finalFrame)
        ghost.image = snapshot
        ghost.imageScaling = .scaleNone
        ghost.imageAlignment = .alignTopLeft
        ghost.wantsLayer = true
        addSubview(ghost)
        swipeGhost = ghost
        // The old list leaves from where it is; the new one arrives from the other side.
        var ghostEnd = finalFrame
        ghostEnd.origin.x -= direction * width
        Tokens.Motion.withoutAnimation { ghost.frame = ghostEnd }
        let curve = landing == nil ? Tokens.Motion.spaceSwitch : Tokens.Motion.swipeSettle
        let velocity = landing ?? 0
        let duration = Tokens.Motion.slide(ghost, fromOffsetX: direction * width + fromSwipe, curve: curve, fromKeyboard: true, velocity: velocity)
        Tokens.Motion.slide(scrollView, fromOffsetX: direction * width + fromSwipe, curve: curve, fromKeyboard: true, velocity: velocity)
        // A landing swipe keeps both lists solid, side by side as the fingers had them. Otherwise the outgoing list
        // fades as it leaves, so the two never compete.
        guard landing == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { ghost.removeFromSuperview() }
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.18
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        ghost.layer?.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { ghost.removeFromSuperview() }
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

    /// Where a gesture over the sidebar is: not yet known to be sideways or up and down, following the fingers
    /// sideways, scrolling the list, or let go (its momentum still to swallow).
    private enum SwipeState { case idle, deciding, tracking, scrolling, finished }
    private var swipeState = SwipeState.idle

    /// Called by the window for every scroll over the sidebar. From the first sideways movement the list follows
    /// the fingers, with the next space sliding in beside it, so you can move a little and come back. Letting go
    /// lands on whichever space is nearer, or the next one after a flick that way; otherwise the list springs home.
    /// Up and down scrolls the list as usual: the first few points decide which way a gesture goes, for all of it.
    /// Returns true when it handled the event.
    func handleSwipe(_ event: NSEvent) -> Bool {
        let now = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        let gap = now - lastSwipeEventTime
        lastSwipeEventTime = now

        // A mouse wheel that tilts sideways: one notch, one space.
        if !event.hasPreciseScrollingDeltas {
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 else { return false }
            if now - lastWheelSwitch > 0.35 {
                lastWheelSwitch = now
                _ = onSwipeSpace?(event.scrollingDeltaX > 0 ? -1 : 1)
            }
            return true
        }

        let momentum = event.momentumPhase != []
        let phaseless = event.phase == [] && !momentum
        // A new gesture starts on its first phase, or after the fingers have been still for a moment.
        if event.phase == .began || event.phase == .mayBegin || (phaseless && gap > 0.2) {
            // The last one's end never came: it lets go where it is before this one starts.
            if swipeState == .tracking { finishSwipe(velocity: 0) }
            beginSwipe()
        }

        switch swipeState {
        case .idle:
            // Momentum from a scroll that's over, or a gesture that started before the pointer came over the sidebar.
            if momentum || phaseless { return false }
            beginSwipe()
        case .scrolling:
            // Its momentum, if any, scrolls the list too (idle lets it through).
            if event.phase == .ended || event.phase == .cancelled { swipeState = .idle }
            return false
        case .finished:
            // The rest of a sideways gesture is part of it, momentum included, so the list never drifts after it.
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swipeState = .idle; return true }
            // Fingers still down after the end went missing: pick the list back up.
            guard event.phase == .changed else { return true }
            startTracking()
        case .deciding, .tracking:
            break
        }
        if momentum { return true }

        if swipeState == .deciding {
            if event.phase == .ended || event.phase == .cancelled { swipeState = .idle; return false }
            swipeAccumX += event.scrollingDeltaX
            swipeAccumY += event.scrollingDeltaY
            if abs(swipeAccumY) >= SpaceSwipe.axisLock, abs(swipeAccumY) > abs(swipeAccumX) {
                swipeState = .scrolling
                return false
            }
            guard abs(swipeAccumX) >= SpaceSwipe.axisLock, abs(swipeAccumX) > abs(swipeAccumY) else {
                // Still deciding; hold sideways movement so the list doesn't twitch.
                return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            startTracking()
            swipeTravel += swipeAccumX
            swipeSamples.append((now, swipeAccumX))
            moveSwipe()
            scheduleSwipeEnd(phaseless: phaseless)
            return true
        }

        // Following the fingers.
        if event.phase == .ended || event.phase == .cancelled {
            swipeSamples.append((now, 0))
            finishSwipe(velocity: event.phase == .ended ? SpaceSwipe.velocity(swipeSamples, at: now) : 0, cancelled: event.phase == .cancelled)
            return true
        }
        swipeTravel += event.scrollingDeltaX
        swipeSamples.append((now, event.scrollingDeltaX))
        swipeSamples.removeAll { now - $0.time > SpaceSwipe.velocityWindow }
        moveSwipe()
        scheduleSwipeEnd(phaseless: phaseless)
        return true
    }

    private var lastSwipeEventTime: TimeInterval = 0
    private var lastWheelSwitch: TimeInterval = 0
    private var swipeAccumX: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    /// How far the fingers have moved sideways since the list started following them.
    private var swipeTravel: CGFloat = 0
    /// Where that puts the list: the travel, held back past the first and last space.
    private var swipeTarget: CGFloat = 0
    /// How far the list is drawn from home right now (stays 0 with Reduce Motion, where nothing moves until it lands).
    private var swipeOffset: CGFloat = 0
    private var swipeSamples: [(time: TimeInterval, dx: CGFloat)] = []
    /// The spaces on either side of the one this gesture started in.
    private var swipeNeighbors: (left: UUID?, right: UUID?) = (nil, nil)
    /// -1 when the neighbor showing is the space on the left, 1 on the right.
    private var neighborSide: CGFloat = 0
    /// Set while a swipe lands, so the new list carries on at the fingers' speed.
    private var landingVelocity: CGFloat?
    private weak var swipeGhost: NSView?
    private var swipeEndWork: DispatchWorkItem?
    /// Counts gestures, so a spring-back finishing late doesn't hide the neighbor a newer gesture is showing.
    private var swipeGeneration = 0

    private func beginSwipe() {
        swipeGeneration += 1
        swipeState = .deciding
        swipeAccumX = 0
        swipeAccumY = 0
        swipeEndWork?.cancel()
        let spaces = Library.shared.spaces
        let index = spaces.firstIndex { $0.id == currentSpaceID }
        swipeNeighbors = (index.flatMap { $0 > 0 ? spaces[$0 - 1].id : nil },
                          index.flatMap { $0 + 1 < spaces.count ? spaces[$0 + 1].id : nil })
    }

    /// The gesture is sideways: from here the list follows the fingers. Caught while still settling from the last
    /// swipe, it's picked up from where it is on screen.
    private func startTracking() {
        swipeState = .tracking
        swipeSamples = []
        var shown: CGFloat = 0
        if let layer = scrollView.layer, layer.animation(forKey: "slide") != nil,
           let x = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat {
            shown = x
        }
        scrollView.layer?.removeAnimation(forKey: "slide")
        neighborScroll.layer?.removeAnimation(forKey: "slide")
        swipeGhost?.removeFromSuperview()
        swipeTravel = SpaceSwipe.travel(toOffset: swipeOffset + shown, width: bounds.width,
                                        hasLeft: swipeNeighbors.left != nil, hasRight: swipeNeighbors.right != nil)
        moveSwipe()
    }

    private func moveSwipe() {
        swipeTarget = SpaceSwipe.offset(forTravel: swipeTravel, width: bounds.width,
                                        hasLeft: swipeNeighbors.left != nil, hasRight: swipeNeighbors.right != nil)
        // With Reduce Motion nothing slides: the gesture still decides, and the space changes in place.
        guard !Tokens.Motion.reduceMotion else { return }
        swipeOffset = swipeTarget
        Tokens.Motion.withoutAnimation {
            scrollView.frame.origin.x = Tokens.Metric.sidebarPadding + swipeOffset
            showNeighbor()
        }
        // The dots follow too: the pill shrinks on this space and grows on the one coming in.
        let width = bounds.width
        let share = width > 0 ? min(abs(swipeOffset) / width, 1) : 0
        let incoming = swipeOffset > 0 ? swipeNeighbors.left : swipeOffset < 0 ? swipeNeighbors.right : nil
        for dot in dots {
            dot.swipeShare = dot.spaceID == currentSpaceID ? 1 - share : dot.spaceID == incoming ? share : nil
        }
    }

    /// The dots go back to showing only the space you're in.
    private func clearSwipeDots() { dots.forEach { $0.swipeShare = nil } }

    /// Puts the space the fingers are pulling in one sidebar width beside the current list.
    private func showNeighbor() {
        let side: CGFloat = swipeOffset > 0 ? -1 : 1
        guard swipeOffset != 0, let neighbor = side < 0 ? swipeNeighbors.left : swipeNeighbors.right else {
            neighborScroll.isHidden = true
            return
        }
        if neighborScroll.isHidden || neighborList.spaceOverride != neighbor {
            neighborSide = side
            neighborScroll.frame = scrollView.frame
            neighborList.spaceOverride = neighbor
            neighborList.privateLabel = list.privateLabel
            neighborList.setFrameSize(neighborScroll.contentSize)
            neighborList.reload(animated: false)
            neighborScroll.contentView.scroll(to: .zero)
            Self.fade(neighborFade, for: neighborScroll, list: neighborList)
            neighborScroll.isHidden = false
        }
        placeNeighbor()
    }

    private func placeNeighbor() {
        var frame = scrollView.frame
        frame.origin.x += neighborSide * bounds.width
        neighborScroll.frame = frame
    }

    /// For trackpads that don't mark a gesture's phases, the fingers going quiet is letting go. With phases, it's a
    /// safety net for an end that never arrives (macOS sometimes drops it); still fingers send nothing, so it waits.
    private func scheduleSwipeEnd(phaseless: Bool) {
        swipeEndWork?.cancel()
        let lastMove = lastSwipeEventTime
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.swipeState == .tracking else { return }
            self.finishSwipe(velocity: phaseless ? SpaceSwipe.velocity(self.swipeSamples, at: lastMove) : 0)
        }
        swipeEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (phaseless ? 0.12 : 0.6), execute: work)
    }

    /// Letting go: lands on the next space or springs home, carrying on at the fingers' speed either way.
    private func finishSwipe(velocity: CGFloat, cancelled: Bool = false) {
        swipeEndWork?.cancel()
        guard swipeState == .tracking else { return }
        swipeState = .finished
        let direction = cancelled ? 0 : SpaceSwipe.landing(offset: swipeTarget, velocity: velocity, width: bounds.width)
        let neighbor = direction < 0 ? swipeNeighbors.left : direction > 0 ? swipeNeighbors.right : nil
        if neighbor != nil {
            // The switch slides the new list in from where the neighbor is now (transitionList).
            landingVelocity = velocity
            if onSwipeSpace?(direction) == true { Haptics.snap(); return }
            landingVelocity = nil
        }
        settleHome(velocity: velocity)
    }

    private func settleHome(velocity: CGFloat) {
        let offset = swipeOffset
        swipeOffset = 0
        swipeTarget = 0
        clearSwipeDots()
        guard offset != 0 else { neighborScroll.isHidden = true; return }
        Tokens.Motion.withoutAnimation {
            scrollView.frame.origin.x = Tokens.Metric.sidebarPadding
            placeNeighbor()
        }
        let curve = Tokens.Motion.swipeSettle
        Tokens.Motion.slide(scrollView, fromOffsetX: offset, curve: curve, velocity: velocity)
        guard !neighborScroll.isHidden else { return }
        let duration = Tokens.Motion.slide(neighborScroll, fromOffsetX: offset, curve: curve, velocity: velocity)
        let generation = swipeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.swipeGeneration == generation, self.swipeState != .tracking else { return }
            self.neighborScroll.isHidden = true
        }
    }

    /// The space this sidebar shows; set by the window.
    var currentSpaceID: UUID?

}

/// The rules of a swipe between spaces, apart from the views so they can be checked on their own. Offsets and
/// velocities are in points, positive when the list moves right (which brings in the space on the left).
enum SpaceSwipe {
    /// How far the fingers move before a gesture counts as sideways or up and down, for the rest of it.
    static let axisLock: CGFloat = 4
    /// Letting go past this share of the width lands on the next space: whichever space is nearer wins.
    static let landingShare: CGFloat = 0.5
    /// A flick at least this fast (points per second) lands, however short.
    static let flickSpeed: CGFloat = 500
    /// How much recent movement counts toward the speed at letting go.
    static let velocityWindow: TimeInterval = 0.08
    /// Past the first or last space the list gives less the further it's pulled, up to this share of the width.
    static let edgeGive: CGFloat = 0.5
    private static let edgeStiffness: CGFloat = 0.55

    /// Where the fingers' travel puts the list: one to one toward a neighbor (at most a full width), held back
    /// like a rubber band where there's none.
    static func offset(forTravel travel: CGFloat, width: CGFloat, hasLeft: Bool, hasRight: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        if travel > 0 ? hasLeft : hasRight { return max(-width, min(width, travel)) }
        let limit = width * edgeGive
        let pulled = (1 - 1 / (abs(travel) * edgeStiffness / limit + 1)) * limit
        return travel < 0 ? -pulled : pulled
    }

    /// The travel that puts the list at `offset`: the reverse of `offset(forTravel:)`, to pick a moving list up.
    static func travel(toOffset offset: CGFloat, width: CGFloat, hasLeft: Bool, hasRight: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        if offset > 0 ? hasLeft : hasRight { return offset }
        let limit = width * edgeGive
        let share = min(abs(offset) / limit, 0.95)
        let travel = (1 / (1 - share) - 1) * limit / edgeStiffness
        return offset < 0 ? -travel : travel
    }

    /// Which way letting go goes: -1 to the space on the left, 1 to the right, 0 back home. A flick decides on its
    /// own (the way the list is already pulled lands; back toward home doesn't); otherwise it's how far it went.
    static func landing(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Int {
        guard offset != 0 else { return 0 }
        let toward = offset > 0 ? -1 : 1
        if abs(velocity) >= flickSpeed { return (velocity > 0) == (offset > 0) ? toward : 0 }
        return abs(offset) >= width * landingShare ? toward : 0
    }

    /// The fingers' speed at `now`, in points per second, from the movement in the last moment.
    static func velocity(_ samples: [(time: TimeInterval, dx: CGFloat)], at now: TimeInterval) -> CGFloat {
        let recent = samples.filter { now - $0.time <= velocityWindow }
        guard let first = recent.first, recent.count > 1, now > first.time else { return 0 }
        // The first sample's movement happened before its time, so it's the start of the span, not part of it.
        return recent.dropFirst().reduce(0) { $0 + $1.dx } / CGFloat(now - first.time)
    }
}

/// The little capsule on an extension's button: a blocked count, a word, or "!" when it needs you.
final class BadgeView: NSView {
    private let label: Label
    private let attention: Bool

    init(text: String, attention: Bool) {
        self.attention = attention
        // Needing attention is a small dot, not a shout: the tooltip and the click say what's needed.
        label = Label(attention ? "" : String(text.prefix(4)), font: .systemFont(ofSize: 8, weight: .bold), color: .white)
        super.init(frame: .zero)
        wantsLayer = true
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let superview else { return }
        // A ring in the address field's color keeps the badge apart from the icon under it.
        let ring: CGFloat = 1.5
        let height: CGFloat = (attention ? 6 : 10) + ring * 2
        let text = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 8)]).width
        let width = attention ? height : max(height, ceil(text) + 6 + ring * 2)
        // A count sits bottom-right, like Safari's; the attention dot top-right, clear of the icon's artwork.
        let y = attention ? 1 : superview.bounds.height - height
        frame = NSRect(x: superview.bounds.width - width - (attention ? 1 : 0), y: y, width: width, height: height)
        label.frame = NSRect(x: 0, y: (height - label.lineHeight) / 2, width: width, height: label.lineHeight)
        layer?.cornerRadius = height / 2
        layer?.borderWidth = ring
        layer?.borderColor = cgColor(Tokens.Color.fieldFill)
        layer?.backgroundColor = cgColor(attention ? .systemOrange : Tokens.Color.badge)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

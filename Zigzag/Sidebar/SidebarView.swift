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
    private let label = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textSecondary)
    private let lock = NSImageView()
    /// Shows while the page uses the camera or microphone; click for options.
    /// Buttons inside the field: the same size, the same gap all round, corners that follow the field's.
    static let buttonSide: CGFloat = Tokens.Sidebar.addressButton
    static let buttonInset: CGFloat = (Tokens.Sidebar.addressHeight - buttonSide) / 2
    static func button(_ symbol: String, toolTip: String) -> IconButton {
        IconButton(symbol: symbol, size: buttonSide, symbolSize: Tokens.Sidebar.addressGlyph, toolTip: toolTip)
    }
    let captureButton = AddressView.button("video.fill", toolTip: "Camera and Microphone")
    /// Shown on articles: opens Reader.
    let readerButton = AddressView.button("doc.plaintext", toolTip: "Show Reader")

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
            let button = AddressView.button(item.symbol, toolTip: item.label)
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
        layer?.cornerRadius = Tokens.Sidebar.addressRadius
        layer?.cornerCurve = .continuous
        // Keyboard focus: the accent ring, as a field's.
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
            label.stringValue = "history"
        } else if SettingsPage.isSettings(url) {
            label.stringValue = "settings"
        } else if let url, let host = url.host() {
            label.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else if let url, url.isFileURL {
            label.stringValue = url.lastPathComponent
        } else {
            label.stringValue = ""
        }
        // The host crisp, in the text's own color; the prompt quiet.
        label.textColor = label.stringValue.isEmpty ? Tokens.Color.textTertiary : Tokens.Color.textPrimary
        if label.stringValue.isEmpty { label.stringValue = "Search or enter address" }
        // Only a plain http page marks itself, with the not-secure symbol before the host.
        let insecure = url?.scheme == "http"
        lock.image = insecure ? Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline) : nil
        lock.isHidden = !insecure
        lock.toolTip = insecure ? SitePanel.notSecure : nil
        setAccessibilityLabel(insecure ? "\(label.stringValue), \(SitePanel.notSecure)" : label.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The host sits clear of the field's rounded edge, as far in as the buttons are from its right end, so the
        // text has room to breathe. After the not-secure mark when there is one.
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
            // Concentric with the field's corners.
            button.radius = Tokens.Sidebar.addressRadius - inset
            right = button.frame.minX - 2
        }
        let trailing = trailingButtons.isEmpty ? bounds.width - pad : right - Tokens.Space.x1
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - h) / 2, width: trailing - x + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        // A soft field of the space's own color, a step lighter under the pointer and pressed.
        let fill = isPressed ? Tokens.Chrome.pressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = 0
        }
    }
}

/// One dot per space at the bottom of the sidebar.
final class SpaceDotView: InteractiveView {
    let spaceID: UUID
    private let dot = CALayer()
    /// A space with an icon shows it here instead of a dot, quiet until it's the space you're in.
    private let iconView = NSImageView()
    var icon: String? {
        didSet {
            guard icon != oldValue else { return }
            iconView.image = icon.map { IconChoice.image($0, size: Tokens.Sidebar.glyph) }
            stateDidChange(animated: false)
        }
    }
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
        super.init(frame: NSRect(x: 0, y: 0, width: Tokens.Sidebar.button, height: Tokens.Sidebar.button))
        pressSinks = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.addSublayer(dot)
        iconView.imageScaling = .scaleNone
        iconView.isHidden = true
        addSubview(iconView)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    /// Each space is a small key with its number, set in tabular figures like a dial marking. The space you're in
    /// is pressed in: a lighter, lit face of the frame's color with a short warm tick under its number (`Color.live`);
    /// the others are quiet keys, their numbers faint. A space with an icon shows the icon in place of its number.
    var number = 0 { didSet { if oldValue != number { numberLayer.string = "\(number)"; stateDidChange(animated: false) } } }
    private lazy var numberLayer: CATextLayer = {
        let text = CATextLayer()
        text.alignmentMode = .center
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.font = Tokens.Font.figures(10, weight: .regular)
        text.fontSize = 10
        layer?.addSublayer(text)
        return text
    }()
    private let tick = CALayer()
    private var wasSelected: Bool?

    override func stateDidChange(animated: Bool) {
        // VoiceOver says which space you're in.
        setAccessibilityValue(isSelected ? "current space" : nil)
        setAccessibilitySelected(isSelected)
        let side = Tokens.Sidebar.spaceKey
        let share = swipeShare ?? (isSelected ? 1 : 0)
        let ink = Tokens.Color.textPrimary
        let resting: CGFloat = isHovered ? 0.55 : 0.36
        let tint = ink.withAlphaComponent(resting + (0.86 - resting) * share)
        let changed = (wasSelected != nil && wasSelected != isSelected && swipeShare == nil) || settlesFromSwipe
        wasSelected = isSelected
        settlesFromSwipe = false
        let key = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        // Pressed, the face goes a step darker as the key sinks.
        let held: CGFloat = isPressed ? 0.75 : 1
        let face = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: (0.18 + 0.67 * share) * held),
                                        dark: Tokens.Color.hex(0xFFFFFF, alpha: (0.04 + 0.13 * share) * held))
        let apply = {
            self.dot.frame = key
            self.dot.cornerRadius = Tokens.Sidebar.spaceKeyRadius
            self.dot.cornerCurve = .continuous
            self.dot.backgroundColor = self.cgColor(face)
            self.dot.borderWidth = Tokens.Metric.hairline
            self.dot.borderColor = self.cgColor(Tokens.Chrome.keyEdge)
            // Pressed in: the key you're in sits a touch lower, its shadow tucked under it.
            self.dot.shadowColor = self.cgColor(Tokens.Chrome.cardShadow)
            self.dot.shadowOpacity = Float(share)
            self.dot.shadowRadius = 0.5
            self.dot.shadowOffset = CGSize(width: 0, height: self.isFlipped ? 0.5 : -0.5)
            let h: CGFloat = 13
            self.numberLayer.frame = CGRect(x: key.minX, y: key.midY - h / 2 + (self.isFlipped ? 0 : 0.5), width: key.width, height: h)
            self.numberLayer.foregroundColor = self.cgColor(tint)
            self.tick.frame = CGRect(x: key.midX - 2.5, y: self.isFlipped ? key.maxY + 2 : key.minY - 3, width: 5, height: 1)
            self.tick.cornerRadius = 0.5
            self.tick.backgroundColor = self.cgColor(Tokens.Color.live)
            self.tick.opacity = Float(share)
        }
        if tick.superlayer == nil { layer?.addSublayer(tick) }
        numberLayer.isHidden = icon != nil
        numberLayer.contentsScale = window?.backingScaleFactor ?? 2
        iconView.frame = bounds
        iconView.isHidden = icon == nil
        iconView.contentTintColor = tint
        // An emoji keeps its colors, so it says which space is yours by how strongly it shows.
        iconView.alphaValue = icon.map(IconChoice.isSymbol) == false ? 0.45 + 0.55 * share : 1
        if changed && !Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.standard)
            CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
            apply()
            CATransaction.commit()
        } else {
            Tokens.Motion.withoutAnimation(apply)
        }
        // The key itself is what answers the pointer; a drop over it lights it as the drop target.
        let fill: NSColor? = isDropTarget ? Tokens.Chrome.pressed : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// The sidebar: navigation, address, bookmarks, tabs and spaces. Drawn entirely by us.
final class SidebarView: NSView {
    weak var delegate: SidebarDelegate? {
        didSet { list.delegate = delegate; neighborList.delegate = delegate }
    }

    /// The top row's and bottom bar's buttons: 26pt, 14pt glyphs, every glyph's ink on the traffic lights' line.
    static let toolbarButton: CGFloat = Tokens.Sidebar.button
    static func chromeButton(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: toolbarButton, symbolSize: Tokens.Sidebar.glyph, toolTip: toolTip)
        button.isChrome = true
        return button
    }
    let backButton = SidebarView.chromeButton("chevron.left", toolTip: "Back")
    let forwardButton = SidebarView.chromeButton("chevron.right", toolTip: "Forward")
    let reloadButton = SidebarView.chromeButton("arrow.clockwise", toolTip: "Reload")
    /// Stand-in for the traffic lights while the sidebar slides.
    private let trafficLightsPicture = NSImageView()
    let sidebarButton: IconButton = {
        let button = SidebarView.chromeButton("sidebar.left", toolTip: "Hide Sidebar")
        button.glyph = LineGlyph.sidebar
        return button
    }()
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

    /// A circle with an arrow, drawn in code so the progress ring lies exactly on the circle: one center, one size.
    let downloadsButton: IconButton = {
        let button = SidebarView.chromeButton("arrow.down.circle", toolTip: "Downloads")
        button.glyph = DownloadGlyph.image(.arrow)
        return button
    }()
    let newSpaceButton: IconButton = {
        let button = SidebarView.chromeButton("plus", toolTip: "New Space")
        button.glyph = LineGlyph.plus
        return button
    }()
    private var dots: [SpaceDotView] = []
    /// A private window keeps to one space and makes none: no dots to switch, no button to add one.
    var isPrivate = false {
        didSet {
            newSpaceButton.isHidden = isPrivate
            dots.forEach { $0.isHidden = isPrivate }
        }
    }
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
        themeToken = Brand.themeChanged.observe { [weak self] in self?.tintDownloadsRing() }
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

    /// Where the traffic lights start, from the sidebar's left edge.
    static let trafficLightsX = Tokens.Sidebar.lightsX

    /// The y position (from the top) where the traffic lights should be centered.
    var trafficLightCenterY: CGFloat { Tokens.Sidebar.lightsCenter }

    override func layout() {
        super.layout()
        let pad = Tokens.Sidebar.edge
        let width = bounds.width
        let rowCenter = trafficLightCenterY
        let button = Self.toolbarButton
        // Back, forward and reload at the trailing end, their glyphs a button apart, reload's ink as far from the
        // sidebar's edge as the lights' from the other.
        let reloadInk = Tokens.Symbol.inkSize("arrow.clockwise", size: Tokens.Sidebar.glyph).width
        var x = round(width - Self.trafficLightsX - reloadInk / 2 - button / 2)
        for b in [reloadButton, forwardButton, backButton] {
            b.frame = NSRect(x: x, y: rowCenter - button / 2, width: button, height: button)
            x -= button
        }
        // The sidebar toggle sits right after the traffic lights, where Arc and Safari put it.
        // Without traffic lights (full screen) the sidebar button starts the row.
        // Its glyph sits `Sidebar.lightsGap` after the lights (the button's own padding inside that), on their line.
        let glyphWidth = Tokens.Symbol.inkSize(sidebarButton.symbol, size: Tokens.Sidebar.glyph).width
        let lead = trafficLightsWidth > 0
            ? round(Self.trafficLightsX + trafficLightsWidth + Tokens.Sidebar.lightsGap - (button - glyphWidth) / 2) : pad
        sidebarButton.frame = NSRect(x: lead, y: rowCenter - button / 2, width: button, height: button)
        address.frame = NSRect(x: pad, y: Tokens.Sidebar.addressTop, width: width - pad * 2, height: Tokens.Sidebar.addressHeight)

        let bottomHeight = Tokens.Sidebar.bottomBarHeight
        // Its buttons sit as far from the bottom edge as from the side.
        let buttonInset = (bottomHeight - Tokens.Sidebar.button) / 2
        bottomBar.frame = NSRect(x: 0, y: bounds.height - bottomHeight + buttonInset - pad, width: width, height: bottomHeight)
        let favoritesHeight = favorites.preferredHeight
        favorites.isHidden = favoritesHeight == 0
        favorites.frame = NSRect(x: pad, y: address.frame.maxY + Tokens.Space.x2, width: width - pad * 2, height: favoritesHeight)
        let listTop = (favoritesHeight > 0 ? favorites.frame.maxY : address.frame.maxY) + Tokens.Sidebar.sectionGap
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

    /// Tabs running on below the bottom of a list fade out there. Only the bottom: the top holds the space's name,
    /// pinned while you scroll, and a hairline already says there's more above.
    private static func fade(_ mask: CAGradientLayer, for scrollView: NSScrollView, list: NSView) {
        let bounds = scrollView.bounds
        let clip = scrollView.contentView.bounds
        let moreBelow = list.frame.height - clip.maxY > 1
        let fade = bounds.height > 0 ? min(Tokens.Space.x6 / bounds.height, 0.5) : 0
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        // Drawn top to bottom in the list's own terms; the gradient's y runs the other way in an unflipped layer.
        mask.colors = [solid, solid, moreBelow ? clear : solid]
        mask.locations = [0, NSNumber(value: Double(1 - fade)), 1]
        let flipped = scrollView.layer?.isGeometryFlipped == true || scrollView.isFlipped
        mask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        CATransaction.commit()
    }

    private func layoutBottomBar() {
        let button = Tokens.Sidebar.button
        // Downloads' glyph centered on the icon column, + mirrored at the other end.
        let pad = round(Tokens.Sidebar.iconColumn + Tokens.Sidebar.favicon / 2 - button / 2)
        let h = bottomBar.bounds.height
        downloadsButton.frame = NSRect(x: pad, y: (h - button) / 2, width: button, height: button)
        newSpaceButton.frame = NSRect(x: bottomBar.bounds.width - pad - button, y: (h - button) / 2, width: button, height: button)
        let available = newSpaceButton.frame.minX - downloadsButton.frame.maxX - Tokens.Space.x2
        let dotSize = min(Tokens.Sidebar.button, floor(available / CGFloat(max(dots.count, 1))))
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
            let x = Self.trafficLightsX
            trafficLightsPicture.frame = NSRect(x: x, y: trafficLightCenterY - image.size.height / 2, width: image.size.width, height: image.size.height)
        }
    }

    // MARK: Updating

    func update(tab: Tab?) {
        backButton.isEnabled = tab?.canGoBackOrReturn ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
        reloadButton.symbol = (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise"
        reloadButton.toolTip = Self.reloadTip(loading: tab?.isLoading ?? false)
        address.show(url: tab?.url, isSecure: tab?.url?.scheme == "https")
    }

    /// "Reload (⌘R)", or "Stop (⌘.)" while the page loads: what the button does now, with its shortcut.
    static func reloadTip(loading: Bool) -> String {
        loading ? "Stop" + Shortcuts.hint(for: #selector(BrowserWindowController.stopLoading(_:)))
                : "Reload" + Shortcuts.hint(for: #selector(BrowserWindowController.reloadPage(_:)))
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
        for (i, dot) in dots.enumerated() {
            guard let space = Library.shared.space(dot.spaceID) else { continue }
            dot.number = i + 1
            dot.color = space.swatch
            dot.icon = space.icon
            dot.isSelected = space.id == current
            // The first nine have ⌃1 to ⌃9 (fixed keys, not in Settings › Shortcuts), so the name says which.
            dot.toolTip = i < 9 ? "\(space.name) (⌃\(i + 1))" : space.name
            dot.setAccessibilityLabel("Space \(space.name)")
        }
        // A single space needs no switcher, and a private window switches nothing.
        dots.forEach { $0.isHidden = isPrivate || dots.count < 2 }
        layoutBottomBar()
    }

    func dot(for spaceID: UUID) -> NSView? { dots.first { $0.spaceID == spaceID } }

    #if DEBUG
    func debugDots() -> [(String, NSRect)] {
        guard let window else { return [] }
        return dots.filter { !$0.isHidden }.map { ("dot:" + (Library.shared.space($0.spaceID)?.name ?? ""), $0.convert($0.bounds, to: nil).flippedIn(window)) }
    }
    #endif

    /// The row of space dots.
    var dotsAnchor: NSView { bottomBar }
    /// The first space's dot, or the row when there's only one.
    var firstDotAnchor: NSView { dots.count > 1 ? dots[0] : bottomBar }
    /// The + that makes a space.
    var newSpaceAnchor: NSView { newSpaceButton }
    var onEditSpace: ((UUID) -> Void)?

    /// The bottom stack: the now-playing control sits above the dots.
    private func bottomFrames() -> (nowPlaying: NSRect, listBottom: CGFloat) {
        let pad = Tokens.Sidebar.edge
        var bottom = bottomBar.frame.minY
        let playingHeight = Tokens.Sidebar.nowPlayingHeight
        let playing = NSRect(x: pad, y: bottom - (nowPlaying.isHidden ? 0 : playingHeight), width: bounds.width - pad * 2, height: playingHeight)
        if !nowPlaying.isHidden { bottom = playing.minY - Tokens.Space.x1 }
        return (playing, bottom)
    }

    /// Shows (or hides) the now-playing control, making room above the dots.
    func setNowPlaying(_ tab: Tab?, paused: Bool) {
        let show = tab != nil
        if let tab { nowPlaying.isPaused = paused; nowPlaying.show(tab) }
        guard show == (nowPlaying.isHidden || nowPlayingFadingOut) else { return }
        nowPlayingFadingOut = false
        if show {
            nowPlaying.isHidden = false
            needsLayout = true
            nowPlaying.alphaValue = 0
            Tokens.Motion.animate(Tokens.Motion.snappy) { self.nowPlaying.animator().alphaValue = 1 }
            return
        }
        // Fades out where it is first; only then does the list take back its room, so nothing vanishes at once.
        nowPlayingFadingOut = true
        Tokens.Motion.animate(Tokens.Motion.snappy, { self.nowPlaying.animator().alphaValue = 0 }, completion: {
            // Playing again before the fade finished: it stays.
            guard self.nowPlayingFadingOut else { return }
            self.nowPlayingFadingOut = false
            self.nowPlaying.isHidden = true
            self.nowPlaying.alphaValue = 1
            self.needsLayout = true
        })
    }

    /// True while the now-playing control fades away, before it gives its room back to the list.
    private var nowPlayingFadingOut = false

    func previewDotColor(_ color: NSColor, for spaceID: UUID) {
        dots.first { $0.spaceID == spaceID }?.color = color
    }

    /// The accent drawn over the icon's own circle as downloads run, exactly on it, so nothing changes size as one
    /// starts or ends; a check in the same circle for a moment when they're done.
    private let downloadsRing = CAShapeLayer()
    private var wasDownloading = false
    private var shownMark = DownloadGlyph.Mark.arrow
    private var themeToken: SignalToken?

    func updateDownloads(active: Int, hasAny: Bool, progress: Double = 1) {
        // Always there, in the same place, so the space dots never shift; with nothing downloaded, its panel says so.
        downloadsButton.isHidden = false
        let downloading = active > 0
        if downloadsRing.superlayer == nil, let host = downloadsButton.layer {
            downloadsRing.fillColor = nil
            // A hair heavier than the glyph's line, so the accent covers it cleanly.
            downloadsRing.lineWidth = DownloadGlyph.line + 0.3
            downloadsRing.lineCap = .round
            downloadsRing.strokeEnd = 0
            downloadsRing.opacity = 0
            host.addSublayer(downloadsRing)
        }
        let b = downloadsButton.bounds
        // The glyph's own circle: the button centers the glyph, so the ring is centered the same way, at its size.
        let d = DownloadGlyph.circle
        let rect = CGRect(x: (b.width - d) / 2, y: (b.height - d) / 2, width: d, height: d)
        // Shape, place and color are set as they are: animating them on every progress tick restarted a fade a few
        // times a second, which is what made the ring jump.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if downloadsRing.frame != b {
            // Starts at the top and runs clockwise, like the system's own progress rings. The button's layer counts y
            // downward, so the top is -90° and growing angles turn clockwise on screen.
            let ring = CGMutablePath()
            ring.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: d / 2, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
            downloadsRing.path = ring
            downloadsRing.frame = b
        }
        tintDownloadsRing()
        CATransaction.commit()
        // The fill only moves forward while a download runs, easing from wherever it is on screen to the new amount.
        let target = downloading ? CGFloat(max(0.04, min(progress, 1))) : (wasDownloading ? 1 : 0)
        let shown = downloadsRing.presentation()?.strokeEnd ?? downloadsRing.strokeEnd
        let to = downloading && wasDownloading ? max(target, downloadsRing.strokeEnd) : target
        if to != downloadsRing.strokeEnd {
            let ease = CABasicAnimation(keyPath: "strokeEnd")
            ease.fromValue = shown
            ease.toValue = to
            ease.duration = downloading ? 0.35 : 0.2
            ease.timingFunction = CAMediaTimingFunction(name: downloading ? .linear : .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            downloadsRing.strokeEnd = to
            CATransaction.commit()
            downloadsRing.add(ease, forKey: "progress")
        }
        // Comes and goes with a short fade, never in a single frame.
        let opacity: Float = downloading ? 1 : 0
        if downloadsRing.opacity != opacity {
            for layer in [downloadsRing] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = opacity
                fade.duration = Tokens.Motion.selection
                fade.timingFunction = Tokens.Motion.easeOut
                Tokens.Motion.withoutAnimation { layer.opacity = opacity }
                layer.add(fade, forKey: "fade")
            }
        }
        let mark: DownloadGlyph.Mark = wasDownloading && !downloading ? .check : .arrow
        if shownMark != mark {
            shownMark = mark
            downloadsButton.glyph = DownloadGlyph.image(mark)
        }
        if wasDownloading, !downloading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, !self.wasDownloading else { return }
                self.shownMark = .arrow
                self.downloadsButton.glyph = DownloadGlyph.image(.arrow)
            }
        }
        wasDownloading = downloading
    }

    /// The ring is in this window's space accent, resolved for light or dark; set again when either changes.
    private func tintDownloadsRing() {
        downloadsRing.strokeColor = cgColor(Brand.Theme.for(self).accent)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tintDownloadsRing()
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
        // A switch on top of a switch: the list carries on from where it's drawn now, and the last ghost goes, so
        // quick ⌃1 ⌃2 ⌃3 never stacks ghosts or jumps.
        var fromSwipe = scrollView.frame.minX - Tokens.Sidebar.edge
        if let layer = scrollView.layer, layer.animation(forKey: "slide") != nil, let drawn = layer.presentation()?.transform {
            fromSwipe += drawn.m41
        }
        if let old = swipeGhost, old !== neighborScroll { old.removeFromSuperview() }
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
        finalFrame.origin.x = Tokens.Sidebar.edge
        // Space switches slide even from the keyboard (⌃1, ⌃2…): the motion tells you which way you went.
        let animate = snapshot != nil && direction != 0
        Tokens.Motion.withoutAnimation { scrollView.frame = finalFrame }
        // Mid-drag the list keeps its gap and hidden row; otherwise it simply reloads.
        if list.isDragging { list.refreshDuringDrag() } else { list.reload(animated: false); restoreListScroll() }
        guard animate, let snapshot else { return }
        let width = bounds.width
        let ghost = NSImageView(frame: finalFrame)
        ghost.image = snapshot
        ghost.imageScaling = .scaleNone
        ghost.imageAlignment = .alignTopLeft
        ghost.wantsLayer = true
        addSubview(ghost)
        swipeGhost = ghost
        // Reduce Motion: nothing slides, but the old list still fades into the new one where it stands.
        if Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setCompletionBlock { ghost.removeFromSuperview() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Tokens.Motion.standard
            fade.timingFunction = Tokens.Motion.easeOut
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            ghost.layer?.add(fade, forKey: "fade")
            CATransaction.commit()
            return
        }
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
        fade.duration = Tokens.Motion.slideDuration
        fade.timingFunction = Tokens.Motion.easeOut
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

        // A mouse: a notched wheel tilted sideways or turned with Shift, or one that scrolls smoothly (Logi Options+,
        // Mos) and so sends fine steps with no gesture phases. A tiny nudge sideways switches straight away.
        let momentum = event.momentumPhase != []
        if !event.hasPreciseScrollingDeltas || (event.phase == [] && !momentum) {
            return handleWheel(event, now: now, gap: gap)
        }

        // A new gesture starts on its first phase.
        if event.phase == .began || event.phase == .mayBegin {
            // The last one's end never came: it lets go where it is before this one starts.
            if swipeState == .tracking { finishSwipe(velocity: 0) }
            beginSwipe()
        }

        switch swipeState {
        case .idle:
            // Momentum from a scroll that's over, or a gesture that started before the pointer came over the sidebar.
            if momentum { return false }
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
            // It may have landed on another space meanwhile: its neighbors are the ones now.
            swipeGeneration += 1
            findNeighbors()
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
            scheduleSwipeEnd()
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
        scheduleSwipeEnd()
        return true
    }

    /// One turn of the wheel, however many notches or fine steps it sends, moves one space: steps closer together
    /// than a moment belong to the same turn, so a free spinning wheel never races through every space.
    private func handleWheel(_ event: NSEvent, now: TimeInterval, gap: TimeInterval) -> Bool {
        if gap > SpaceSwipe.wheelTurnGap {
            wheelAccumX = 0
            wheelAccumY = 0
            wheelTurnSwitched = false
        }
        wheelAccumX += event.scrollingDeltaX
        wheelAccumY += event.scrollingDeltaY
        // Up and down scrolls the list as usual.
        guard abs(wheelAccumX) > abs(wheelAccumY) else { return false }
        // A notch is enough; fine steps need the same few points that tell a trackpad gesture is sideways.
        if !wheelTurnSwitched, abs(wheelAccumX) > (event.hasPreciseScrollingDeltas ? SpaceSwipe.axisLock : 0) {
            wheelTurnSwitched = true
            _ = onSwipeSpace?(wheelAccumX > 0 ? -1 : 1)
        }
        return true
    }

    private var lastSwipeEventTime: TimeInterval = 0
    private var wheelAccumX: CGFloat = 0
    private var wheelAccumY: CGFloat = 0
    private var wheelTurnSwitched = false
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
        findNeighbors()
    }

    /// The spaces either side of the one in front now.
    private func findNeighbors() {
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
            scrollView.frame.origin.x = Tokens.Sidebar.edge + swipeOffset
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

    /// A safety net for an end that never arrives (macOS sometimes drops it): resting fingers send nothing, so it
    /// waits long, and then only springs home, never switching space under fingers that may still be down.
    private func scheduleSwipeEnd() {
        swipeEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.swipeState == .tracking else { return }
            self.finishSwipe(velocity: 0, cancelled: true)
        }
        swipeEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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
            scrollView.frame.origin.x = Tokens.Sidebar.edge
            placeNeighbor()
        }
        let curve = Tokens.Motion.swipeSettle
        Tokens.Motion.slide(scrollView, fromOffsetX: offset, curve: curve, velocity: velocity)
        guard !neighborScroll.isHidden else { return }
        let duration = Tokens.Motion.slide(neighborScroll, fromOffsetX: offset, curve: curve, velocity: velocity)
        // Hidden once home, unless a new swipe has it out again: a hidden neighbor is reloaded when it next shows,
        // so it never comes back with old rows.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.swipeState != .tracking else { return }
            self.neighborScroll.isHidden = true
        }
    }

    /// The space this sidebar shows; set by the window. Leaving one remembers how far down its list was scrolled.
    var currentSpaceID: UUID? {
        didSet {
            guard let old = oldValue, old != currentSpaceID else { return }
            listScroll[old] = scrollView.contentView.bounds.origin.y
        }
    }
    /// How far down each space's list was, so coming back to a space finds it where you left it.
    private var listScroll: [UUID: CGFloat] = [:]

    /// The list where it was when you last left this space, or at the top for one you haven't scrolled.
    #if DEBUG
    /// listscroll <y>: the list scrolled to y, or with no number, how far it's scrolled (in debug.log).
    func debugListScroll(_ y: CGFloat?) {
        if let y { scrollView.contentView.scroll(to: NSPoint(x: 0, y: y)); scrollView.reflectScrolledClipView(scrollView.contentView) }
        debugLog("listscroll \(scrollView.contentView.bounds.origin.y) of \(list.frame.height)")
    }
    #endif

    private func restoreListScroll() {
        list.layoutSubtreeIfNeeded()
        let saved = currentSpaceID.flatMap { listScroll[$0] } ?? 0
        let maxY = max(0, list.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(saved, maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

}

/// The rules of a swipe between spaces, apart from the views so they can be checked on their own. Offsets and
/// velocities are in points, positive when the list moves right (which brings in the space on the left).
enum SpaceSwipe {
    /// How far the fingers move before a gesture counts as sideways or up and down, for the rest of it.
    static let axisLock: CGFloat = 4
    /// Letting go past this share of the width lands on the next space: a third of the way is enough to mean it.
    static let landingShare: CGFloat = 0.35
    /// A flick at least this fast (points per second) lands, however short: an easy flick, not a hard one.
    static let flickSpeed: CGFloat = 300
    /// How much recent movement counts toward the speed at letting go.
    static let velocityWindow: TimeInterval = 0.08
    /// A mouse wheel going quiet this long ends one turn of it; the next turn can move another space.
    static let wheelTurnGap: TimeInterval = 0.25
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
        label = Label(attention ? "" : String(text.prefix(4)), font: .systemFont(ofSize: Tokens.TypeSize.badge, weight: .bold), color: .white)
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
        let text = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: Tokens.TypeSize.badge)]).width
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

/// The download button's picture, drawn to match the sidebar's 13pt symbols in size and weight: a circle, and an
/// arrow or (for a moment, when downloads finish) a check in it.
enum DownloadGlyph {
    enum Mark { case arrow, check }
    /// Drawn to the size of the bottom bar's other symbols (`Sidebar.glyph`): the circle's diameter through the middle
    /// of its line, and the line, as SF's arrow.down.circle has them.
    static let circle: CGFloat = (Tokens.Sidebar.glyph * 1.046 * 10).rounded() / 10
    static let line: CGFloat = LineGlyph.stroke
    /// The arrow and the check were drawn for a 13.6pt circle; they grow with it.
    private static let k = circle / 13.6

    static func image(_ mark: Mark) -> NSImage {
        let line = Self.line, k = Self.k
        let side = circle + line
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            NSColor.black.setStroke()
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: line / 2, dy: line / 2))
            ring.lineWidth = line
            ring.stroke()
            let path = NSBezierPath()
            path.lineWidth = line
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c.x + x * k, y: c.y + y * k) }
            switch mark {
            case .arrow:
                path.move(to: p(0, -3.6))
                path.line(to: p(0, 3.4))
                path.move(to: p(-2.9, 0.6))
                path.line(to: p(0, 3.5))
                path.line(to: p(2.9, 0.6))
            case .check:
                path.move(to: p(-3.1, 0.2))
                path.line(to: p(-0.9, 2.5))
                path.line(to: p(3.3, -2.4))
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

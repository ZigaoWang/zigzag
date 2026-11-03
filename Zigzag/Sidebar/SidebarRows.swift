import AppKit

/// A row in the sidebar list. Tabs, bookmarks and "New Tab" all share one look.
class SidebarRowView: InteractiveView {
    let icon = FaviconView()
    let title = Label()
    /// 1 = just looked at, down to the faded floor for tabs left alone a long time.
    var freshness: CGFloat = 1 { didSet { if oldValue != freshness { applyFreshness() } } }
    /// While lifted for dragging, the row draws as selected-ish with a shadow.
    var isLifted = false { didSet { stateDidChange(animated: false) } }
    /// On its way out of the list: it takes no more clicks while it folds away.
    var isLeaving = false
    override func hitTest(_ point: NSPoint) -> NSView? { isLeaving ? nil : super.hitTest(point) }

    /// Set while the list's sliding card travels to this row: the row draws no card of its own until it lands.
    var holdsCardBack = false { didSet { if oldValue != holdsCardBack { stateDidChange(animated: false) } } }
    /// Picked with ⌘ or ⇧ along with others, to drag or act on together.
    var isMarked = false { didSet { if oldValue != isMarked { stateDidChange(animated: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        title.font = Tokens.Font.sidebarRow()
        addSubview(icon)
        addSubview(title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Space reserved at the trailing edge for accessory buttons.
    var trailingAccessoryWidth: CGFloat { 0 }

    /// From the row's edge to its icon.
    static let inset = Tokens.Sidebar.rowInset
    /// Where a title's text frame starts after an icon frame ends: the icon gap, less the label's own padding, so the
    /// first letter sits exactly `Sidebar.iconGap` from the icon.
    static let titleOffset = Tokens.Sidebar.iconGap - Label.inset
    /// Where every title's first letter sits in a row: the text column.
    static var textX: CGFloat { inset + Tokens.Sidebar.favicon + Tokens.Sidebar.iconGap }
    /// A row's own buttons sit this far in from its trailing edge, as far as from its top and bottom.
    static var buttonEdge: CGFloat { (Tokens.Sidebar.rowHeight - Tokens.Sidebar.rowButton) / 2 }

    override func layout() {
        super.layout()
        let iconSize = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: Self.inset, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let titleX = icon.frame.maxX + Self.titleOffset
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let trailing = trailingAccessoryWidth > 0 ? trailingAccessoryWidth + Self.buttonEdge : Self.inset - Label.inset
        title.frame = NSRect(x: titleX, y: (bounds.height - titleHeight) / 2, width: max(0, bounds.width - titleX - trailing), height: titleHeight)
        if layer?.sublayers?.contains(where: { $0.name == "rim" && !$0.isHidden }) == true { setCardRim(true) }
    }

    override func stateDidChange(animated: Bool) {
        let base: NSColor?
        // While the list slides the card here from the row it was on, this row leaves its own card to it.
        let showsCard = (isSelected && !holdsCardBack) || isLifted
        if showsCard {
            base = isHovered ? Tokens.Chrome.cardHover : Tokens.Chrome.card
        } else if isMarked {
            base = Brand.Theme.for(self).accent.withAlphaComponent(isHovered ? 0.26 : 0.2)
        } else if isPressed {
            base = Tokens.Chrome.pressed
        } else if isHovered {
            base = Tokens.Chrome.hover
        } else {
            base = nil
        }
        layer?.set(backgroundColor: base.map { cgColor($0) }, animated: animated && !isHovered)
        // The tab you're on: a soft light card of the space's color, a crisp quiet edge and a shadow-sm. A row picked
        // up to carry stands off the list.
        if isLifted {
            setLifted(true)
        } else {
            Tokens.Motion.withoutAnimation {
                layer?.borderWidth = showsCard ? Tokens.Metric.hairline : 0
                layer?.borderColor = cgColor(Tokens.Chrome.cardEdge)
                setCardShadow(showsCard)
            }
            setCardRim(showsCard)
        }
        applyFreshness()
    }

    /// While the pointer is on Clear, the rows it would close sink back, so you see what goes before you click.
    var isAboutToClear = false {
        didSet {
            guard oldValue != isAboutToClear else { return }
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.applyFreshness(animated: true) }
        }
    }

    private func applyFreshness(animated: Bool = false) {
        let visible = isAboutToClear ? 0.18 : isSelected || isHovered || isLifted || isMarked ? 1 : freshness
        (animated ? icon.animator() : icon).alphaValue = visible
        (animated ? title.animator() : title).alphaValue = visible
    }
}

/// The selected tab's card on its own, for the moment it slides between rows: the same fill, edge and shadow-sm.
final class SelectionCardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Tokens.Metric.hairline
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh() {
        Tokens.Motion.withoutAnimation {
            layer?.backgroundColor = cgColor(Tokens.Chrome.card)
            layer?.borderColor = cgColor(Tokens.Chrome.cardEdge)
            setCardShadow(true)
        }
        setCardRim(true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}

/// A tab (or a bookmark's live page).
final class TabRowView: SidebarRowView, NSTextFieldDelegate {
    private(set) var tab: Tab?
    private var token: SignalToken?
    let closeButton = TabRowView.rowButton("xmark", toolTip: "Close Tab")
    /// The speaker beside the page that's playing (or muted): this row's own, and in a split, its partner's beside
    /// the partner's half. Clicking one mutes or unmutes that page.
    let audioButton = TabRowView.rowButton("speaker.wave.2.fill", toolTip: "Mute Tab")
    let partnerAudioButton = TabRowView.rowButton("speaker.wave.2.fill", toolTip: "Mute Tab")

    static func rowButton(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: Tokens.Sidebar.rowButton, symbolSize: Tokens.Sidebar.rowGlyph, toolTip: toolTip)
        button.radius = Tokens.Radius.small + 1
        return button
    }
    var onClose: (() -> Void)?
    /// Bookmarks keep their own title; only the icon and state follow the page.
    var fixedTitle: String? { didSet { refresh() } }
    var isBookmark = false
    /// Called with the new name when a rename is committed (empty: go back to the page's own title).
    var onRename: ((String) -> Void)?
    private var renameField: PlainTextField?

    /// Double-click: the title becomes a field, the whole name selected. Return keeps it, Escape doesn't.
    func beginRename() {
        guard renameField == nil, let window else { return }
        let field = PlainTextField(font: title.font ?? Tokens.Font.body(), placeholder: "Name")
        field.stringValue = title.stringValue
        field.delegate = self
        field.onCancel = { [weak self] in self?.endRename(commit: false) }
        title.isHidden = true
        addSubview(field)
        renameField = field
        // The whole row is the name while you edit it: no close or audio button in the way.
        refreshAccessories()
        layoutRenameField()
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        title.isHidden = false
        refreshAccessories()
        if commit { onRename?(name) }
        window?.makeFirstResponder(window?.contentView)
    }

    /// The pinned page's own name, shown before the mark while it's away: "Apple / MacBook Pro".
    var pinName: String? { didSet { pinLabel.stringValue = pinName ?? ""; needsLayout = true } }
    private lazy var pinLabel: Label = {
        let label = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textSecondary)
        addSubview(label)
        return label
    }()

    /// A pinned tab showing a different page from its pinned one: the close button takes it back instead.
    var isAway = false {
        didSet {
            guard oldValue != isAway else { return }
            closeButton.symbol = isAway ? "arrow.uturn.backward" : "xmark"
            awayMark.isHidden = !isAway
            pinLabel.isHidden = !isAway
            refreshAccessories()
            needsLayout = true
        }
    }

    /// Always there while a pinned tab is away from its page: a short slanted stroke, the ribbon's own slant,
    /// between the icon and the title, so you can tell at a glance it isn't on its pinned page.
    private lazy var awayMark: CAShapeLayer = {
        let mark = CAShapeLayer()
        mark.lineWidth = 1.6
        mark.lineCap = .round
        mark.fillColor = nil
        mark.isHidden = true
        layer?.addSublayer(mark)
        return mark
    }()
    var isUnloaded = false { didSet { refreshTitleColor() } }
    /// The other half of a split: shown in the same row, to the right.
    private(set) var partner: Tab?
    /// A pinned split's other page, by its pinned name and icon: there whether or not its page is open.
    private var pinnedPartner: (title: String, icon: NSImage?, unloaded: Bool)?
    /// Two pages in one row: a split of tabs, or a pinned split.
    var isSplit: Bool { partner != nil || pinnedPartner != nil }
    /// Which page you're working in, when split (0 = this row's own, 1 = its partner).
    var focusedHalf = 0 { didSet { refreshTitleColor() } }
    /// The partner is on the left of the page, so it's on the left of the row too (a pinned page beside a tab).
    var partnerLeads = false { didSet { if oldValue != partnerLeads { needsLayout = true } } }
    private var partnerToken: SignalToken?
    private let partnerIcon = FaviconView()
    private let partnerTitle = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    private let divider = ColorView(color: Tokens.Color.separator)
    /// While another tab is dragged over this row's right half: where it would open.
    private let dropHalf = ColorView()
    /// 0 = would open on the left, 1 = on the right, nil = not a drop target.
    var splitDropSide: Int? {
        didSet {
            guard oldValue != splitDropSide else { return }
            layoutDropHalf()
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.dropHalf.animator().alphaValue = self.splitDropSide == nil ? 0 : 1 }
        }
    }

    private func layoutDropHalf() {
        let inset = Tokens.Metric.dropInset
        let width = bounds.width / 2 - inset
        let x = splitDropSide == 0 ? inset : bounds.midX
        Tokens.Motion.withoutAnimation { dropHalf.frame = NSRect(x: x, y: inset, width: width, height: bounds.height - inset * 2) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Chosen on release, so pressing a row to drag it never switches the page first.
        clicksOnMouseDown = false
        closeButton.onClick = { [weak self] _ in self?.onClose?() }
        closeButton.isHidden = true
        audioButton.onClick = { [weak self] _ in
            guard let tab = self?.tab else { return }
            tab.setMuted(!tab.isMuted)
        }
        audioButton.isHidden = true
        partnerAudioButton.onClick = { [weak self] _ in
            guard let partner = self?.partner else { return }
            partner.setMuted(!partner.isMuted)
        }
        partnerAudioButton.isHidden = true
        dropHalf.wantsLayer = true
        dropHalf.layer?.cornerRadius = Tokens.Sidebar.rowRadius - Tokens.Metric.dropInset
        dropHalf.layer?.cornerCurve = .continuous
        dropHalf.layer?.borderWidth = Tokens.Metric.dropEdge
        dropHalf.alphaValue = 0
        addSubview(dropHalf, positioned: .below, relativeTo: icon)
        partnerIcon.isHidden = true
        partnerTitle.isHidden = true
        divider.isHidden = true
        [partnerIcon, partnerTitle, divider].forEach { addSubview($0) }
        addSubview(audioButton)
        addSubview(partnerAudioButton)
        addSubview(closeButton)
    }

    func configure(partner: Tab?) {
        guard partner !== self.partner else { return }
        self.partner = partner
        partnerToken = partner?.changed.observe { [weak self] change in
            if change == .title || change == .favicon || change == .loading || change == .url || change == .audio { self?.refreshPartner() }
        }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
    }

    func configure(pinnedPartner title: String?, icon: NSImage?, unloaded: Bool) {
        pinnedPartner = title.map { ($0, icon, unloaded) }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
    }

    private func refreshPartner() {
        partnerTitle.stringValue = pinnedPartner?.title ?? partner?.displayTitle ?? ""
        partnerIcon.image = partner?.favicon ?? pinnedPartner?.icon
        partnerIcon.isLoading = (partner?.isLoading ?? false) && !(partner?.isSuspended ?? true)
        partnerAudioButton.symbol = partner?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        partnerAudioButton.toolTip = partner?.isMuted == true ? "Unmute Tab" : "Mute Tab"
        refreshAccessories()
        refreshAccessibilityLabel()
        refreshTitleColor()
        needsLayout = true
    }

    /// A split row reads out both of its pages.
    private func refreshAccessibilityLabel() {
        setAccessibilityLabel(!isSplit ? title.stringValue : "\(title.stringValue), split with \(partnerTitle.stringValue)")
        // What VoiceOver says after the name: the tab you're on, and whether either page is playing or muted.
        func sound(_ tab: Tab?, _ name: String?) -> String? {
            let state = tab?.isMuted == true ? "muted" : tab?.isPlayingAudio == true ? "playing audio" : nil
            return state.map { state in name.map { "\($0) \(state)" } ?? state }
        }
        let split = partner != nil
        let state = [isSelected ? "current tab" : nil, sound(tab, split ? title.stringValue : nil), sound(partner, partnerTitle.stringValue)]
            .compactMap { $0 }.joined(separator: ", ")
        setAccessibilityValue(state.isEmpty ? nil : state)
        setAccessibilitySelected(isSelected)
    }

    /// Which half of a split row a point (in this view) falls in.
    /// Which page the point is over: 0 for this row's own, 1 for its partner.
    func half(at point: NSPoint) -> Int {
        isSplit && (point.x > bounds.midX) != partnerLeads ? 1 : 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tab: Tab?) {
        guard tab !== self.tab || token == nil else { refresh(); return }
        self.tab = tab
        token = tab?.changed.observe { [weak self] change in self?.tabChanged(change) }
        refresh()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .title, .url, .favicon, .loading, .audio, .themeColor, .webView, .activity: refresh()
        default: break
        }
    }

    var showsAudio: Bool { tab?.isPlayingAudio == true || tab?.isMuted == true }
    var partnerShowsAudio: Bool { partner?.isPlayingAudio == true || partner?.isMuted == true }

    /// The gap between two of a row's buttons side by side.
    private static let buttonGap: CGFloat = 2

    private var showsClose: Bool { !closeButton.isHidden }

    override var trailingAccessoryWidth: CGFloat {
        let close = showsClose ? closeButton.frame.width : 0
        // In a split each half's speaker sits at that half's end (laid out with the halves).
        let audio = isSplit ? 0 : showsAudio ? audioButton.frame.width + (close > 0 ? Self.buttonGap : 0) : 0
        return close + audio
    }

    func refresh() {
        title.stringValue = fixedTitle ?? tab?.displayTitle ?? ""
        icon.image = tab?.favicon ?? (fixedTitle != nil ? bookmarkIcon : nil)
        icon.isLoading = (tab?.isLoading ?? false) && !(tab?.isSuspended ?? true)
        audioButton.symbol = tab?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        audioButton.toolTip = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
        refreshAccessibilityLabel()
        refreshTitleColor()
        refreshAccessories()
    }

    var bookmarkIcon: NSImage?

    private func refreshTitleColor() {
        // A pinned tab that isn't loaded reads the same as one that is: faded means old elsewhere in Zigzag.
        let ink = Brand.Theme.for(self).rowInk
        title.textColor = ink
        // One weight always: selection shows in the fill, never by text getting wider and shifting.
        partnerTitle.textColor = ink
        dropHalf.color = Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropAlpha)
        dropHalf.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
    }

    private func refreshAccessories() {
        let showClose = (isHovered || isSelected) && !isLifted && (!isBookmark || !isUnloaded) && renameField == nil
        closeButton.isHidden = !showClose
        closeButton.toolTip = isAway ? "Back to Pinned Page" : isBookmark ? "Unload Page" : "Close Tab"
        audioButton.isHidden = !showsAudio || renameField != nil
        partnerAudioButton.isHidden = !isSplit || !partnerShowsAudio || renameField != nil
        needsLayout = true
    }

    private func layoutRenameField() {
        guard let field = renameField else { return }
        let x = title.frame.minX
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - Self.inset), height: height)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        refreshTitleColor()
        refreshAccessories()
        refreshAccessibilityLabel()
    }


    override func layout() {
        super.layout()
        layoutButtonsAndHalves()
        if isAway {
            // The pin's own name, then the mark, then the page it's on now. The name takes what it needs up to
            // two fifths of the room, so the page's own title always shows too.
            let room = title.frame.width - 6 - Tokens.Space.x1 * 2
            let nameWidth = pinName == nil ? 0 : min(pinLabel.inkWidth, floor(room * 0.4))
            pinLabel.frame = NSRect(x: title.frame.minX, y: title.frame.minY, width: nameWidth + Label.inset * 2, height: title.frame.height)
            pinLabel.frame.origin.x -= Label.inset
            pinLabel.isHidden = nameWidth == 0
            let shift = nameWidth > 0 ? nameWidth + Tokens.Space.x1 : 0
            title.frame.origin.x += shift
            title.frame.size.width = max(0, title.frame.width - shift)
            let x = title.frame.minX
            let h: CGFloat = 11
            Tokens.Motion.withoutAnimation {
                awayMark.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: 6, height: h)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 5, y: isFlipped ? 1 : h - 1))
                path.addLine(to: CGPoint(x: 1, y: isFlipped ? h - 1 : 1))
                awayMark.path = path
                awayMark.strokeColor = cgColor(Tokens.Color.textTertiary)
            }
            title.frame.origin.x += 6 + Tokens.Space.x1
            title.frame.size.width = max(0, title.frame.width - 6 - Tokens.Space.x1)
        }
        layoutRenameField()
    }

    private func layoutButtonsAndHalves() {
        let size = closeButton.frame.size
        let edge = Self.buttonEdge
        let y = (bounds.height - size.height) / 2
        closeButton.frame.origin = NSPoint(x: bounds.width - edge - size.width, y: y)
        let end = showsClose ? closeButton.frame.minX - Self.buttonGap : bounds.width - edge
        layoutDropHalf()

        guard isSplit else {
            audioButton.frame.origin = NSPoint(x: end - size.width, y: y)
            return
        }
        // A split shows both pages in one row: two halves with a hairline between, each with its icon, its title
        // and, while that page plays or is muted, its own speaker at the half's end. The row's close is at its end.
        let mid = bounds.midX
        divider.frame = NSRect(x: mid, y: Tokens.Space.x2, width: Tokens.Metric.hairline, height: bounds.height - Tokens.Space.x4)
        let iconY = icon.frame.minY, side = icon.frame.width
        let titleY = title.frame.minY, titleH = title.frame.height
        func place(icon: NSView, title: NSView, audio: IconButton, from start: CGFloat, to stop: CGFloat) {
            icon.frame = NSRect(x: start + Self.inset, y: iconY, width: side, height: side)
            var textEnd = stop
            if !audio.isHidden {
                audio.frame.origin = NSPoint(x: stop - size.width, y: y)
                textEnd = audio.frame.minX - Self.buttonGap
            }
            let x = icon.frame.maxX + Self.titleOffset
            title.frame = NSRect(x: x, y: titleY, width: max(0, textEnd + Label.inset - x), height: titleH)
        }
        let leadEnd = mid - edge, trailEnd = showsClose ? end : bounds.width - edge
        if partnerLeads {
            place(icon: partnerIcon, title: partnerTitle, audio: partnerAudioButton, from: 0, to: leadEnd)
            place(icon: icon, title: title, audio: audioButton, from: mid, to: trailEnd)
        } else {
            place(icon: icon, title: title, audio: audioButton, from: 0, to: leadEnd)
            place(icon: partnerIcon, title: partnerTitle, audio: partnerAudioButton, from: mid, to: trailEnd)
        }
    }
}

/// "New Tab" at the top of the tab list.
final class NewTabRowView: SidebarRowView {
    private let plus = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.stringValue = "New Tab"
        icon.isHidden = true
        plus.image = LineGlyph.plus
        plus.imageScaling = .scaleNone
        addSubview(plus)
        setAccessibilityLabel("New Tab")
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        title.textColor = Brand.Theme.for(self).quietInk
        plus.contentTintColor = title.textColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        plus.frame = icon.frame
    }
}

/// A folder of pinned pages: a chevron that turns as it opens, a folder, and its name. Click to open or close it;
/// double-click to rename it. Pinned pages dropped on it go in.
final class FolderRowView: SidebarRowView, NSTextFieldDelegate {
    private let chevron = NSImageView()
    private let folderIcon = NSImageView()
    var isOpen = true { didSet { if oldValue != isOpen { turnChevron(animated: true) } } }
    /// While a pinned page or tab is dragged over it: it lights up to say it will take it.
    var isDropTarget = false { didSet { stateDidChange(animated: true) } }
    var onRename: ((String) -> Void)?
    private var renameField: PlainTextField?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.image = Tokens.Symbol.image("chevron.right", size: Tokens.Symbol.inline)
        chevron.contentTintColor = Tokens.Color.textTertiary
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        addSubview(chevron)
        icon.isHidden = true
        folderIcon.imageScaling = .scaleNone
        folderIcon.contentTintColor = Tokens.Color.textSecondary
        addSubview(folderIcon)
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, open: Bool, count: Int, icon: String? = nil) {
        title.stringValue = name
        folderIcon.image = IconChoice.folder(icon, open: open, size: Tokens.Sidebar.favicon)
        isOpen = open
        setAccessibilityLabel("\(name), folder, \(count) pinned")
        setAccessibilityValue(open ? 1 : 0)
        needsLayout = true
    }

    private func turnChevron(animated: Bool) {
        guard let layer = chevron.layer else { return }
        let size = chevron.bounds.size
        let angle: CGFloat = isOpen ? .pi / 2 : 0
        let turn = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                           CATransform3DMakeRotation(angle, 0, 0, 1)),
                                       CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        if animated && !Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.standard)
            CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
            layer.transform = turn
            CATransaction.commit()
        } else {
            Tokens.Motion.withoutAnimation { layer.transform = turn }
        }
    }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x3
        chevron.frame = NSRect(x: bounds.width - Self.inset - side, y: (bounds.height - side) / 2, width: side, height: side)
        folderIcon.frame = icon.frame
        turnChevron(animated: false)
        title.frame.size.width = max(0, chevron.frame.minX - Tokens.Space.x1 - title.frame.minX)
        if let field = renameField {
            let height = ceil(field.intrinsicContentSize.height)
            field.frame = NSRect(x: title.frame.minX, y: (bounds.height - height) / 2, width: max(0, bounds.width - title.frame.minX - Self.inset), height: height)
        }
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        if isDropTarget {
            // The one drop target look, as on the favorites and a split's half.
            setLifted(false)
            layer?.set(backgroundColor: cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropAlpha)), animated: animated)
            layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
            layer?.borderWidth = Tokens.Metric.dropEdge
        } else {
            layer?.borderWidth = 0
        }
        chevron.alphaValue = isHovered || !isOpen || isDropTarget ? 1 : 0.6
    }

    func beginRename() {
        guard renameField == nil, let window else { return }
        let field = PlainTextField(font: title.font ?? Tokens.Font.body(), placeholder: "Folder name")
        field.stringValue = title.stringValue
        field.delegate = self
        field.onCancel = { [weak self] in self?.endRename(commit: false) }
        title.isHidden = true
        addSubview(field)
        renameField = field
        needsLayout = true
        layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        title.isHidden = false
        if commit, !name.isEmpty { onRename?(name) }
        window?.makeFirstResponder(window?.contentView)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }
}

/// The space name above its bookmarks. Click it, or the chevron beside it, to fold the
/// bookmarks away.
final class SpaceHeaderView: InteractiveView {
    let label = Label("", font: Tokens.Font.spaceName(), color: Tokens.Color.textPrimary)
    /// After the space's color changes: the name takes its new ink.
    func refreshInk() { stateDidChange(animated: false) }
    /// The space's name, set large, light and lowercase, a little tight, in the space's own ink.
    var name = "" {
        didSet {
            guard name != oldValue else { return }
            label.stringValue = name.lowercased()
            stateDidChange(animated: false)
            needsLayout = true
        }
    }
    private let chevron = NSImageView()
    private let iconView = NSImageView()
    /// The space's icon, before its name. Nil: the name alone.
    var icon: String? {
        didSet {
            guard icon != oldValue else { return }
            iconView.image = icon.map { IconChoice.image($0, size: Self.iconSide - 2) }
            iconView.isHidden = icon == nil
            needsLayout = true
        }
    }
    var isCollapsed = false { didSet { stateDidChange(animated: false) } }
    /// Only spaces with bookmarks can fold.
    var canCollapse = false { didSet { stateDidChange(animated: false) } }
    /// Folds or opens the pinned tabs, for VoiceOver (a click on the chevron does too).
    var onToggleCollapsed: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = Tokens.Color.textTertiary
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.contentTintColor = Tokens.Color.textTertiary
        iconView.isHidden = true
        addSubview(iconView)
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        // Large, the name stands flush with the icons' edge, the way a heading does. At 26pt the first letter's own
        // side bearing sets its ink a point in: pulled back so the ink, not the box, meets the icons' edge.
        // Low in its slot, near the pinned tabs it names, with the room above it.
        let pad = Tokens.Space.x1
        let y = isFlipped ? bounds.height - h - pad : pad
        // Icons and the chevron center on the lowercase letters' middle (the x-height), not the text box, so they sit
        // level with the name.
        let font = Tokens.Font.spaceName()
        let baseline = isFlipped ? y + (h + font.ascender + font.descender) / 2 : y + (h - font.ascender - font.descender) / 2
        let xMiddle = isFlipped ? baseline - font.xHeight / 2 : baseline + font.xHeight / 2
        var x = SidebarRowView.inset - Label.inset - Tokens.Sidebar.spaceNameBearing
        if icon != nil {
            // The space's icon leads the name at the name's own scale, as one mark, not a row icon beside a heading.
            // As tall as the name's capitals, its middle on the lowercase letters' middle, and fit to that square
            // whatever its drawing's shape; centered over the rows' icon column, so it lines up with the + below.
            let side = ceil(font.capHeight) + 2
            let column = SidebarRowView.inset + Tokens.Sidebar.favicon / 2
            iconView.frame = NSRect(x: round(column - side / 2), y: round(xMiddle - side / 2), width: side, height: side)
            x = iconView.frame.maxX + Tokens.Space.x2 - Label.inset
        }
        label.frame = NSRect(x: x, y: y, width: min(label.textWidth, bounds.width - x - Tokens.Space.x6), height: h)
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: label.frame.maxX + Tokens.Space.x2, y: xMiddle - side / 2, width: side, height: side)
    }

    /// The icon before a space's name: about the name's x-height and a little more, so the two read as one.
    static let iconSide: CGFloat = 20

    /// Whether a click lands on the chevron (or just past the name, where it shows), rather than on the name.
    func isOnChevron(_ event: NSEvent) -> Bool {
        canCollapse && convert(event.locationInWindow, from: nil).x >= label.frame.maxX
    }

    override func stateDidChange(animated: Bool) {
        // The name in light type and the space's own ink, quietly fuller under the pointer; its icon a step back.
        let ink = Brand.Theme.for(self).ink
        label.attributedStringValue = Tokens.Font.voiceText(label.stringValue, color: isHovered ? ink : ink.withAlphaComponent(0.86))
        // A symbol takes the name's own ink; an emoji keeps its colors.
        iconView.contentTintColor = ink.withAlphaComponent(0.86)
        chevron.image = Tokens.Symbol.image(isCollapsed ? "chevron.right" : "chevron.down", size: Tokens.TypeSize.body)
        // The chevron shows on hover, and stays while folded so you know something is tucked away.
        chevron.isHidden = !canCollapse || !(isHovered || isCollapsed)
        setAccessibilityLabel(label.stringValue + (isCollapsed ? ", pinned tabs hidden" : ""))
        setAccessibilityHelp(isCollapsed ? "Show pinned tabs" : "Hide pinned tabs")
        setAccessibilityCustomActions(canCollapse ? [
            NSAccessibilityCustomAction(name: isCollapsed ? "Show Pinned Tabs" : "Hide Pinned Tabs") { [weak self] in
                self?.onToggleCollapsed?()
                return true
            },
        ] : [])
    }
}

/// The quiet "Tabs" label above today's tabs, with generous room above it in place of a line. Clear sits at its end,
/// as in Arc: on a line of its own, apart from New Tab and the pinned tabs it leaves alone, and only while the
/// pointer is over the list and there are tabs to clear.
final class SeparatorRowView: NSView {
    private let label = Label("Tabs", font: Tokens.Font.sidebarLabel(), color: Tokens.Color.textTertiary)
    let clearButton = ClearTabsButton()
    /// The label in the space's quiet ink.
    func refreshInk() { label.textColor = Brand.Theme.for(self).quietInk }
    var showsClear = false { didSet { if showsClear != oldValue { refreshClear() } } }
    var hasTabs = false { didSet { if hasTabs != oldValue { refreshClear() } } }
    /// Shown under the pointer, or while Tab has brought keyboard focus to it.
    private var clearShown: Bool { (showsClear || clearButton.hasKeyboardFocus) && hasTabs }
    /// When Clear last came into view. A click right as it appears was meant for whatever was under the pointer
    /// a moment before (New Tab, just below), so it counts only once Clear has been there a beat.
    private var clearShownAt = Date.distantPast
    var clearIsArmed: Bool { clearButton.hasKeyboardFocus || (clearShown && Date().timeIntervalSince(clearShownAt) > 0.35) }
    /// With Full Keyboard Access on, Clear stays in the Tab order while there are tabs to clear, see-through until
    /// focus reaches it; otherwise it's hidden whenever it isn't shown.
    private var clearInTabOrder: Bool { NSApp.isFullKeyboardAccessEnabled && hasTabs }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        clearButton.alphaValue = 0
        clearButton.isHidden = true
        clearButton.keyboardFocusChanged = { [weak self] _ in self?.refreshClear() }
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refreshClear() {
        let show = clearShown
        if show || clearInTabOrder { clearButton.isHidden = false }
        if show { clearShownAt = Date() }
        needsLayout = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.selection
            context.allowsImplicitAnimation = true
            clearButton.animator().alphaValue = show ? 1 : 0
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.clearShown, !self.clearInTabOrder else { return }
                self.clearButton.isHidden = true
            }
        })
    }

    override func layout() {
        super.layout()
        // The label sits low, nearer the tabs it names than the pinned tabs above.
        let h = label.lineHeight
        let mid = bounds.height - Tokens.Space.x3
        label.frame = NSRect(x: SidebarRowView.textX - Label.inset, y: floor(mid - h / 2), width: label.inkWidth + Label.inset * 2, height: h)
        let cw = clearButton.fittingWidth, ch: CGFloat = 20
        clearButton.frame = NSRect(x: bounds.width - cw, y: floor(mid - ch / 2), width: cw, height: ch)
        clearButton.layoutSubtreeIfNeeded()
    }
}

enum SiteTint {
    /// Keyed by the icon itself, held, so a new icon at a freed one's address never takes its color.
    private static var iconColors: [ObjectIdentifier: (icon: NSImage, color: NSColor?)] = [:]

    static func color(for tab: Tab) -> NSColor? {
        if let theme = tab.themeColor, let usable = usable(theme) { return usable }
        guard let icon = tab.favicon else { return nil }
        let key = ObjectIdentifier(icon)
        if let cached = iconColors[key], cached.icon === icon { return cached.color }
        let color = FaviconStore.shared.dominantColor(of: icon)
        if iconColors.count > 500 { iconColors.removeAll() }
        iconColors[key] = (icon, color)
        return color
    }

    /// Ignores pale, gray and near-black theme colors: they say nothing about the site,
    /// and a gray wash would read as a hover state.
    private static func usable(_ color: NSColor) -> NSColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        if rgb.saturationComponent < 0.35 { return nil }
        if rgb.brightnessComponent < 0.3 { return nil }
        return rgb
    }

    /// 1 for recently used tabs, easing down to the floor for tabs left alone for days.
    static func freshness(lastActivated: Date, now: Date = Date()) -> CGFloat {
        let age = now.timeIntervalSince(lastActivated)
        guard age > Tokens.Fade.start else { return 1 }
        let t = min(1, (age - Tokens.Fade.start) / (Tokens.Fade.full - Tokens.Fade.start))
        let eased = 1 - pow(1 - t, 2)
        return 1 - CGFloat(eased) * (1 - Tokens.Opacity.fadedFloor)
    }
}

/// Where a dragged tab will land: a short accent line with round ends.
final class InsertionLineView: NSView {
    private let line = ColorView(color: Tokens.Color.accent)

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.wantsLayer = true
        line.layer?.cornerRadius = 1
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: SidebarRowView.inset, y: floor((bounds.height - 2) / 2), width: bounds.width - SidebarRowView.inset * 2, height: 2)
    }
}

/// Clear, on the line above the tabs: small, quiet text with a downward arrow (it clears what's below), the same
/// grey as the line until the pointer is on it.
final class ClearTabsButton: InteractiveView {
    /// The tabs below get swept away, the way Arc says it: an arrow pointing down at them.
    private let arrow = NSImageView()
    private let label = Label("Clear", font: Tokens.Font.sidebarLabel(), color: Tokens.Color.textTertiary)
    private static let arrowSide: CGFloat = Tokens.Symbol.inline

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerCurve = .continuous
        arrow.image = Tokens.Symbol.image("arrow.down", size: Tokens.Symbol.inline)
        arrow.imageScaling = .scaleNone
        [arrow, label].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        step = .others(0)
        stateDidChange(animated: false)
    }

    /// What a click does now, and its label says so: the old (faded) tabs while there are any, then every tab but
    /// the one you're on. Never yours.
    enum Step: Equatable { case old(Int), others(Int), last(Int) }
    var step: Step = .others(0) {
        didSet {
            switch step {
            case .old(let n):
                label.stringValue = "Clear Old"
                toolTip = n == 1 ? "Close the tab you haven’t used in a while" : "Close the \(n) tabs you haven’t used in a while"
            case .others(let n):
                label.stringValue = "Clear"
                toolTip = n == 1 ? "Close the other tab" : "Close the other \(n) tabs"
            case .last(let n):
                label.stringValue = "Clear"
                toolTip = n == 1 ? "Close this tab too, leaving the space empty" : "Close these tabs too, leaving the space empty"
            }
            setAccessibilityLabel(toolTip)
            if oldValue != step { needsLayout = true; superview?.needsLayout = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(6 + Self.arrowSide + 3 + label.inkWidth + Tokens.Space.x2) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A capsule, so its hover fill reads as one small button on the line.
        layer?.cornerRadius = bounds.height / 2
        arrow.frame = NSRect(x: 6, y: (bounds.height - Self.arrowSide) / 2, width: Self.arrowSide, height: Self.arrowSide)
        let h = label.lineHeight
        label.frame = NSRect(x: arrow.frame.maxX + 3 - Label.inset, y: (bounds.height - h) / 2, width: label.inkWidth + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let active = isHovered || isPressed
        label.textColor = active ? Tokens.Color.textPrimary : Tokens.Color.textTertiary
        arrow.contentTintColor = label.textColor
        let fill: NSColor? = isPressed ? Tokens.Chrome.pressed : isHovered ? Tokens.Chrome.hover : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }
}

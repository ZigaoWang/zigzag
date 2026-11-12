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
    /// A pinned page that's open: a fine edge, as on a favorite's tile, so you can tell which are loaded.
    var showsOpenEdge = false { didSet { if oldValue != showsOpenEdge { stateDidChange(animated: false) } } }

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
        refreshCardShadowPath()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshCardShadowPath()
    }

    override func stateDidChange(animated: Bool) {
        let base: NSColor?
        // While the list slides the card here from the row it was on, this row leaves its own card to it.
        let showsCard = (isSelected && !holdsCardBack) || isLifted
        if showsCard {
            base = isHovered ? Tokens.Chrome.cardHover : Tokens.Chrome.card
        } else if isMarked {
            base = Brand.Theme.for(self).accent.withAlphaComponent(isHovered ? 0.26 : 0.2)
        } else if isSelected {
            // Waiting for the sliding card: no wash of its own under the pointer, so one card arrives, not a second box.
            base = nil
        } else if isPressed {
            base = Tokens.Chrome.pressed
        } else if isHovered {
            base = Tokens.Chrome.hover
        } else {
            base = nil
        }
        // Hover comes and goes at once, both ways: you sweep over these rows all day, and a fade there only reads
        // as lag. Only a change you made (picking rows) eases in.
        let animates = animated && !isHovered && isMarked
        if !animates { layer?.removeAnimation(forKey: "backgroundColor") }
        layer?.set(backgroundColor: base.map { cgColor($0) }, animated: animates)
        // The tab you're on: a soft light card of the space's color, a crisp quiet edge and a shadow-sm. A row picked
        // up to carry stands off the list.
        if isLifted {
            setLifted(true)
        } else {
            Tokens.Motion.withoutAnimation {
                layer?.borderWidth = showsCard || showsOpenEdge ? Tokens.Metric.hairline : 0
                layer?.borderColor = cgColor(showsCard ? Tokens.Chrome.cardEdge : Tokens.Chrome.openEdge)
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

    override func layout() {
        super.layout()
        refreshCardShadowPath()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshCardShadowPath()
    }

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
    let closeButton = TabRowView.rowButton("xmark", toolTip: String(localized: "Close Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))
    /// The speaker beside the page that's playing (or muted): this row's own, and in a split, its partner's beside
    /// the partner's half. Clicking one mutes or unmutes that page.
    let audioButton = TabRowView.rowButton("speaker.wave.2", toolTip: String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))
    let partnerAudioButton = TabRowView.rowButton("speaker.wave.2", toolTip: String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))

    static func rowButton(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: Tokens.Sidebar.rowButton, symbolSize: Tokens.Sidebar.rowGlyph, toolTip: toolTip)
        button.radius = Tokens.Radius.small + 1
        return button
    }
    var onClose: (() -> Void)?

    /// Whether tabs are nested under this one, and shown or folded away; nil when none are.
    enum NestedTabs { case expanded, collapsed }
    var nestedTabs: NestedTabs? {
        didSet {
            guard oldValue != nestedTabs else { return }
            if let nestedTabs {
                let open = nestedTabs == .expanded
                // The folder's chevron: down while they show, right while they're folded, turning between the two.
                nestedButton.symbol = open ? "chevron.down" : "chevron.right"
                if oldValue != nil { FolderRowView.turn(nestedButton.layer, opening: open, size: nestedButton.bounds.size) }
                nestedButton.toolTip = open ? String(localized: "Hide Nested Tabs", comment: "Tooltip of the chevron on a tab's row in the sidebar that has tabs nested under it: folds them away.")
                    : String(localized: "Show Nested Tabs", comment: "Tooltip of the chevron on a tab's row in the sidebar whose nested tabs are folded away: shows them.")
                nestedButton.setAccessibilityValue(open ? 1 : 0)
            }
            setAccessibilityDisclosed(nestedTabs == .expanded)
            refreshAccessories()
        }
    }
    var onToggleNested: (() -> Void)?
    /// The chevron of a tab with tabs nested under it, in the column a folder's sits in.
    private lazy var nestedButton: IconButton = {
        let button = TabRowView.rowButton("chevron.down", toolTip: "")
        button.tint = Tokens.Color.textTertiary
        button.wantsLayer = true
        button.setAccessibilityRole(.disclosureTriangle)
        button.onClick = { [weak self] _ in self?.onToggleNested?() }
        button.isHidden = true
        addSubview(button)
        return button
    }()
    private var showsNested: Bool { nestedTabs != nil && renameField == nil }

    /// Bookmarks keep their own title; only the icon and state follow the page.
    var fixedTitle: String? { didSet { if fixedTitle != oldValue { refresh() } } }
    var isBookmark = false
    /// Called with the new name when a rename is committed (empty: go back to the page's own title).
    var onRename: ((String) -> Void)?
    private var renameField: PlainTextField?

    /// The page being renamed: in a row of several pages, the one whose part was double-clicked.
    private(set) var renamingPage: Tab?
    /// Which part's name is being edited (`half(at:)`'s numbering).
    private var renamingPart = 0

    /// Double-click: the title becomes a field, the whole name selected. Return keeps it, Escape doesn't. In a row of
    /// several pages, the part at `point` (or `page`'s part): the field takes that part's title, its icon staying; a
    /// part too narrow for a title gives the field the whole row for the moment, beside its own icon.
    func beginRename(at point: NSPoint? = nil, page: Tab? = nil) {
        guard renameField == nil, let window else { return }
        let index = point.map(half(at:)) ?? page.flatMap { page in pages.firstIndex { $0 === page } } ?? 0
        renamingPart = partTitles.indices.contains(index) && (index == 0 || isSplit) ? index : 0
        let label = partTitles[renamingPart]
        renamingPage = renamingPart == 0 ? tab : pages.indices.contains(renamingPart) ? pages[renamingPart] : nil
        let field = PlainTextField(font: label.font ?? Tokens.Font.body(), placeholder: String(localized: "Name", comment: "Placeholder of the field that renames a tab, in its sidebar row."))
        field.stringValue = label.stringValue
        field.delegate = self
        field.onCancel = { [weak self] in self?.endRename(commit: false) }
        label.isHidden = true
        addSubview(field)
        renameField = field
        // The whole row is the name while you edit it: no close or audio button in the way.
        refreshAccessories()
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
        partTitles[renamingPart].isHidden = false
        // A group's other parts, set aside while one of them had the whole row.
        partViews.flatMap { $0 }.forEach { $0.alphaValue = 1 }
        ([divider] + (extraViews ?? []).map(\.divider)).forEach { $0.alphaValue = 1 }
        refreshAccessories()
        if commit { onRename?(name) }
        renamingPage = nil
        renamingPart = 0
        window?.makeFirstResponder(window?.contentView)
    }

    /// Each part's icon and title, in `half(at:)`'s order.
    private var partViews: [[NSView]] {
        [[icon, title], [partnerIcon, partnerTitle]] + (extraViews ?? []).map { [$0.icon, $0.title] }
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
    var isUnloaded = false { didSet { if oldValue != isUnloaded { refreshTitleColor() }; showsOpenEdge = isBookmark && !isUnloaded } }
    /// The other half of a split: shown in the same row, to the right.
    private(set) var partner: Tab?
    /// A pinned split's other page, by its pinned name and icon: there whether or not its page is open.
    private var pinnedPartner: (title: String, icon: NSImage?, unloaded: Bool)?
    /// Two pages in one row: a split of tabs, or a pinned split.
    var isSplit: Bool { partner != nil || pinnedPartner != nil }
    /// Which page you're working in, when split (0 = this row's own, 1 = its partner).
    var focusedHalf = 0 { didSet { if oldValue != focusedHalf { refreshTitleColor() } } }
    /// The part whose page is zoomed over the rest of its split or group (`half(at:)`'s numbering), lit; nil for none.
    var zoomedPart: Int? { didSet { if oldValue != zoomedPart { needsLayout = true } } }
    /// The light under the zoomed part: the row's own pressed fill, inset as the split drop's half is.
    /// Made the first time a part of this row is zoomed.
    private var zoomMarkView: ColorView?

    private func layoutZoomMark() {
        guard let part = zoomedPart, isSplit else {
            zoomMarkView?.isHidden = true
            return
        }
        let zoomMark = zoomMarkView ?? {
            let mark = ColorView(color: Tokens.Color.pressedFill)
            mark.layer?.cornerRadius = Tokens.Sidebar.rowRadius - Tokens.Metric.dropInset
            mark.layer?.cornerCurve = .continuous
            addSubview(mark, positioned: .below, relativeTo: icon)
            zoomMarkView = mark
            return mark
        }()
        // The part as laid out, left to right: in a split of two the partner's half can lead.
        let spatial = extraPartners.isEmpty && partnerLeads ? 1 - part : part
        let spans = partSpans
        guard spans.indices.contains(spatial) else { zoomMark.isHidden = true; return }
        let inset = Tokens.Metric.dropInset
        let span = spans[spatial]
        // The row's own ends keep the row's inset; between parts, the middle of the gap.
        zoomMark.frame = NSRect(x: span.start + inset, y: inset, width: max(0, span.end - span.start - inset * 2), height: bounds.height - inset * 2)
        zoomMark.isHidden = false
    }
    /// The partner is on the left of the page, so it's on the left of the row too (a pinned page beside a tab).
    var partnerLeads = false { didSet { if oldValue != partnerLeads { needsLayout = true } } }
    private var partnerToken: SignalToken?
    private let partnerIcon = FaviconView()
    private let partnerTitle = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    private let divider = ColorView(color: Tokens.Color.separator)
    /// A tile group's third and fourth pages, after the partner (#160): each its own part of the row, as the
    /// partner's half is, with its icon, its title while there's room for it, and its speaker.
    private(set) var extraPartners: [Tab] = []
    private var extraTokens: [SignalToken] = []
    private typealias ExtraViews = (icon: FaviconView, title: Label, divider: ColorView, audio: IconButton)
    /// Made the first time the row shows a group of more than two.
    private var extraViews: [ExtraViews]?
    private var extras: [ExtraViews] {
        if let extraViews { return extraViews }
        let made: [ExtraViews] = (0..<2).map { i in
            let icon = FaviconView(), title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
            let divider = ColorView(color: Tokens.Color.separator)
            let audio = TabRowView.rowButton("speaker.wave.2", toolTip: String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))
            audio.onClick = { [weak self] _ in
                guard let self, self.extraPartners.indices.contains(i) else { return }
                let page = self.extraPartners[i]
                page.setMuted(!page.isMuted)
            }
            [icon, title, divider].forEach { $0.isHidden = true; addSubview($0, positioned: .below, relativeTo: closeButton) }
            audio.isHidden = true
            addSubview(audio, positioned: .below, relativeTo: closeButton)
            return (icon, title, divider, audio)
        }
        extraViews = made
        return made
    }
    /// Every page the row shows, its own first, in the group's order.
    var pages: [Tab] { ([tab, partner] + extraPartners).compactMap { $0 } }
    /// How many parts the row is split into: one, two halves, or a tile group's three or four.
    private var segmentCount: Int { isSplit ? 2 + extraPartners.count : 1 }
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
            // `.webView`: it went to sleep or woke, which its icon shows.
            if change == .title || change == .favicon || change == .loading || change == .url || change == .audio || change == .webView { self?.refreshPartner() }
        }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
    }

    /// A split's other page or a tile group's other pages, in order: the first is the partner, any more follow it.
    func configure(partners: [Tab]) {
        configure(partner: partners.first)
        let more = Array(partners.dropFirst().prefix(2))
        guard more.count != extraPartners.count || zip(more, extraPartners).contains(where: { $0 !== $1 }) else { return }
        extraPartners = more
        extraTokens = more.map { page in
            page.changed.observe { [weak self] change in
                if change == .title || change == .favicon || change == .loading || change == .url || change == .audio || change == .webView { self?.refreshExtras() }
            }
        }
        refreshExtras()
    }

    private func refreshExtras() {
        guard !extraPartners.isEmpty || extraViews != nil else { return }
        for (i, views) in extras.enumerated() {
            let page = extraPartners.indices.contains(i) ? extraPartners[i] : nil
            views.icon.image = page?.displayIcon
            views.icon.isLoading = (page?.isLoading ?? false) && !(page?.isSuspended ?? true)
            views.icon.isAsleep = page?.isAsleep == true
            views.title.stringValue = page?.displayTitle ?? ""
            let sound = page?.isMuted == true ? "speaker.slash" : "speaker.wave.2"
            if views.audio.symbol != sound { views.audio.symbol = sound }
            views.audio.toolTip = page?.isMuted == true ? String(localized: "Unmute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.") : String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
            [views.icon, views.title, views.divider].forEach { $0.isHidden = page == nil }
            if renameField != nil, renamingPart == i + 2 { views.title.isHidden = true }
        }
        refreshAccessories()
        refreshAccessibilityLabel()
        refreshTitleColor()
        needsLayout = true
    }

    func configure(pinnedPartner title: String?, icon: NSImage?, unloaded: Bool) {
        // Not a pinned split, and wasn't: nothing to redo.
        guard title != nil || pinnedPartner != nil else { return }
        pinnedPartner = title.map { ($0, icon, unloaded) }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
    }

    private func refreshPartner() {
        partnerTitle.stringValue = pinnedPartner?.title ?? partner?.displayTitle ?? ""
        partnerIcon.image = partner?.displayIcon ?? pinnedPartner?.icon
        partnerIcon.isLoading = (partner?.isLoading ?? false) && !(partner?.isSuspended ?? true)
        partnerIcon.isAsleep = partner?.isAsleep == true
        // A symbol set again is drawn again: only when it changes.
        let partnerSound = partner?.isMuted == true ? "speaker.slash" : "speaker.wave.2"
        if partnerAudioButton.symbol != partnerSound { partnerAudioButton.symbol = partnerSound }
        partnerAudioButton.toolTip = partner?.isMuted == true ? String(localized: "Unmute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.") : String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
        refreshAccessories()
        refreshAccessibilityLabel()
        refreshTitleColor()
        needsLayout = true
    }

    /// A split row reads out both of its pages.
    private func refreshAccessibilityLabel() {
        let others = extraPartners.isEmpty ? partnerTitle.stringValue : Words.list([partnerTitle.stringValue] + extraPartners.map(\.displayTitle))
        setAccessibilityLabel(!isSplit ? title.stringValue : String(localized: "\(title.stringValue), split with \(others)", comment: "Accessibility label of a split view's row in the sidebar: the two pages' titles."))
        // What VoiceOver says after the name: the tab you're on, and whether either page is playing or muted.
        func sound(_ tab: Tab?, _ name: String?) -> String? {
            if tab?.isMuted == true {
                return name.map { String(localized: "\($0) muted", comment: "Spoken by VoiceOver after a tab row's name, for one page of a split: that page's title, then that it's muted.") }
                    ?? String(localized: "muted", comment: "Spoken by VoiceOver after a tab row's name: the tab is muted.")
            }
            guard tab?.isPlayingAudio == true else { return nil }
            return name.map { String(localized: "\($0) playing audio", comment: "Spoken by VoiceOver after a tab row's name, for one page of a split: that page's title, then that it plays sound.") }
                ?? String(localized: "playing audio", comment: "Spoken by VoiceOver after a tab row's name: the tab plays sound.")
        }
        let split = partner != nil
        let state = ([isSelected ? String(localized: "current tab", comment: "Spoken by VoiceOver after a tab row's name: it's the tab you're on.") : nil, sound(tab, split ? title.stringValue : nil), sound(partner, partnerTitle.stringValue)]
            + extraPartners.map { sound($0, $0.displayTitle) })
            .compactMap { $0 }.joined(separator: String(localized: "accessibility.state-separator", defaultValue: ", ", comment: "Separates the states VoiceOver reads after a tab row's name, like “current tab, playing audio”."))
        setAccessibilityValue(state.isEmpty ? nil : state)
        setAccessibilitySelected(isSelected)
    }

    /// Which page the point is over: 0 for this row's own, 1 for its partner, 2 and 3 for a tile group's others.
    func half(at point: NSPoint) -> Int {
        guard extraPartners.isEmpty else {
            let count = segmentCount
            // The parts as laid out, each reaching to the middle of the gap on either side of it.
            guard partEdges.count == count - 1 else { return min(count - 1, max(0, Int(point.x / max(1, bounds.width / CGFloat(count))))) }
            return partEdges.filter { point.x >= $0 }.count
        }
        return isSplit && (point.x > bounds.midX) != partnerLeads ? 1 : 0
    }

    /// Where one part of a split or tile group's row ends and the next begins (the middle of the gap between them).
    private var partEdges: [CGFloat] = []

    /// Each part's span across the row, in the row's order of parts (the partner's half first when it leads).
    private var partSpans: [(start: CGFloat, end: CGFloat)] {
        let edges = [0] + partEdges + [bounds.width]
        return (0..<(edges.count - 1)).map { (edges[$0], edges[$0 + 1]) }
    }

    /// The title labels of the row's parts, in `half(at:)`'s order: its own, the partner's, a group's others.
    private var partTitles: [Label] { [title, partnerTitle] + (extraViews ?? []).map(\.title) }

    /// Pointing at a part of a row of several pages names that page, as its title may be cut short or not shown.
    private var showsPartTips = false

    private func refreshPartTips() {
        guard isSplit || showsPartTips else { return }
        removeAllToolTips()
        showsPartTips = isSplit
        guard isSplit else { return }
        for (start, end) in partSpans where end > start {
            addToolTip(NSRect(x: start, y: 0, width: end - start, height: bounds.height), owner: self, userData: nil)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = half(at: point)
        return partTitles.indices.contains(index) ? partTitles[index].stringValue : title.stringValue
    }

    /// The page the point is over.
    func page(at point: NSPoint) -> Tab? {
        let pages = [tab, partner] + extraPartners.map { Optional($0) }
        let index = half(at: point)
        return pages.indices.contains(index) ? pages[index] ?? tab : tab
    }

    /// A row split into `count` parts from `start` to `end`, each `gap` short of the next; with two, the halves meet in
    /// the middle of the whole row (`mid`), as a split's always have.
    static func segments(count: Int, start: CGFloat, end: CGFloat, mid: CGFloat, gap: CGFloat) -> [(start: CGFloat, end: CGFloat)] {
        guard count > 1 else { return [(start, end)] }
        if count == 2 { return [(start, mid - gap), (mid, end)] }
        let width = (end - start) / CGFloat(count)
        return (0..<count).map { i in
            let from = start + CGFloat(i) * width
            return (round(from), round(i == count - 1 ? end : from + width - gap))
        }
    }

    /// Whether a part this wide has room for its title beside its icon, or shows the icon alone.
    /// A title cut to its first letter or two reads as noise: only where a few words fit.
    static func segmentShowsTitle(width: CGFloat) -> Bool { width >= 84 }

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

    /// While ⌘ is held: the number that goes to this row with ⌘, where its close button sits (which steps aside).
    var number: Int? {
        didSet {
            guard oldValue != number else { return }
            if let number {
                let hint = numberHint ?? NumberHintView()
                if numberHint == nil { numberHint = hint; addSubview(hint) }
                hint.number = number
                hint.show(true)
            } else {
                numberHint?.show(false)
            }
            refreshAccessories()
        }
    }
    private var numberHint: NumberHintView?
    private var showsNumber: Bool { number != nil && numberHint != nil }
    /// The close button's place at the row's end, or the number's while it's there.
    private var endSlot: CGFloat { showsClose ? closeButton.frame.width : showsNumber ? numberHint?.width ?? 0 : 0 }

    override var trailingAccessoryWidth: CGFloat {
        let close = endSlot
        let nested = showsNested ? Tokens.Sidebar.rowButton + (close > 0 ? Self.buttonGap : 0) : 0
        // In a split each half's speaker sits at that half's end (laid out with the halves).
        let audio = isSplit ? 0 : showsAudio ? audioButton.frame.width + (close + nested > 0 ? Self.buttonGap : 0) : 0
        return close + nested + audio
    }

    func refresh() {
        title.stringValue = fixedTitle ?? tab?.displayTitle ?? ""
        icon.image = tab?.displayIcon ?? (fixedTitle != nil ? bookmarkIcon : nil)
        icon.isLoading = (tab?.isLoading ?? false) && !(tab?.isSuspended ?? true)
        // Why it sleeps, and what that freed, is in its hover card (`TabPreviewView`), not a tooltip on top of it.
        icon.isAsleep = tab?.isAsleep == true
        let sound = tab?.isMuted == true ? "speaker.slash" : "speaker.wave.2"
        if audioButton.symbol != sound { audioButton.symbol = sound }
        audioButton.toolTip = tab?.isMuted == true ? String(localized: "Unmute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.") : String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
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
        extraViews?.forEach { $0.title.textColor = ink }
        dropHalf.color = Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropAlpha)
        dropHalf.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
    }

    private func refreshAccessories() {
        // A pinned tab you're on stays clean, as Arc's does: its button (unload, or back to its page) comes with the
        // pointer. A plain tab you're on keeps its close button in view.
        let showClose = (isHovered || (isSelected && !isBookmark)) && !isLifted && (!isBookmark || !isUnloaded) && renameField == nil && number == nil
        closeButton.isHidden = !showClose
        closeButton.toolTip = isAway ? String(localized: "Back to Pinned Page", comment: "Tooltip of a button on a tab's row in the sidebar. The pinned tab wandered off; this goes back to its page.")
            : isBookmark ? String(localized: "Unload Page", comment: "Tooltip of a button on a tab's row in the sidebar. Unloads a pinned tab's page; the pin stays.") : String(localized: "Close Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
        audioButton.isHidden = !showsAudio || renameField != nil
        partnerAudioButton.isHidden = !isSplit || !partnerShowsAudio || renameField != nil
        for (i, views) in (extraViews ?? []).enumerated() {
            let page = extraPartners.indices.contains(i) ? extraPartners[i] : nil
            views.audio.isHidden = page.map { !($0.isPlayingAudio || $0.isMuted) } ?? true || renameField != nil
        }
        if nestedTabs != nil || renameField != nil { nestedButton.isHidden = !showsNested }
        // Quiet at rest as a folder's is, clear under the pointer or while the tabs are folded away.
        if nestedTabs != nil { nestedButton.alphaValue = isHovered || nestedTabs == .collapsed ? 1 : 0.6 }
        needsLayout = true
    }

    private func layoutRenameField() {
        guard let field = renameField else { return }
        let height = ceil(field.intrinsicContentSize.height)
        let y = (bounds.height - height) / 2
        guard isSplit else {
            let x = title.frame.minX
            field.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - Self.inset), height: height)
            return
        }
        let views = partViews
        guard views.indices.contains(renamingPart) else { return }
        let icon = views[renamingPart][0], label = views[renamingPart][1]
        // The part as laid out: from where its title starts to the end of its span, short of the next part.
        let spans = partSpans
        let span = spans.first { $0.start <= icon.frame.midX && icon.frame.midX < $0.end } ?? (0, bounds.width)
        let roomy = label.frame.width > 0 && span.end - label.frame.minX >= 48
        if roomy {
            let end = span.end >= bounds.width - 1 ? bounds.width - Self.inset : span.end - Self.buttonEdge / 2
            field.frame = NSRect(x: label.frame.minX, y: y, width: max(0, end - label.frame.minX), height: height)
            return
        }
        // Too narrow for a name: for now the row is this page's alone, its icon where a tab's is, the field after it.
        for (i, part) in views.enumerated() where i != renamingPart { part.forEach { $0.alphaValue = 0 } }
        ([divider] + (extraViews ?? []).map(\.divider)).forEach { $0.alphaValue = 0 }
        icon.frame.origin.x = Self.inset
        let x = icon.frame.maxX + Self.titleOffset
        field.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - Self.inset), height: height)
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
        if let hint = numberHint, showsNumber {
            let height = NumberHintView.height
            hint.frame = NSRect(x: bounds.width - edge - hint.width, y: (bounds.height - height) / 2, width: hint.width, height: height)
        }
        // A row of several pages keeps the close button's room whether or not it shows, so its parts never move as
        // the pointer comes and goes.
        let slot = isSplit ? max(endSlot, size.width) : endSlot
        var end = slot > 0 ? bounds.width - edge - slot - Self.buttonGap : bounds.width - edge
        if showsNested {
            nestedButton.frame = NSRect(x: end - size.width, y: y, width: size.width, height: size.height)
            end = nestedButton.frame.minX - Self.buttonGap
        }
        layoutDropHalf()
        defer {
            refreshPartTips()
            layoutZoomMark()
        }

        guard isSplit else {
            partEdges = []
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
        let leadEnd = mid - edge, trailEnd = end
        partEdges = [mid]
        if !extraPartners.isEmpty, let views = extraViews {
            // A tile group: a part for each page, in its order, a hairline between; a title only where it has room.
            let parts = Self.segments(count: segmentCount, start: 0, end: trailEnd, mid: mid, gap: edge)
            partEdges = parts.dropFirst().map { round($0.start - edge / 2) }
            let lines = [divider] + views.map(\.divider)
            let pieces: [(NSView, NSView, IconButton)] = [(icon, title, audioButton), (partnerIcon, partnerTitle, partnerAudioButton)]
                + views.map { ($0.icon, $0.title, $0.audio) }
            // Every part the same: titles in all of them or in none. Without titles each part's icon (and its speaker,
            // while it plays) sits in the middle of the part, so the row reads as even steps rather than icons pushed
            // to the left of empty room; pointing at a part names its page.
            let titles = parts.first.map { Self.segmentShowsTitle(width: $0.end - $0.start) } ?? false
            for (i, part) in parts.enumerated() where i < pieces.count {
                let (icon, title, audio) = pieces[i]
                if titles {
                    place(icon: icon, title: title, audio: audio, from: part.start, to: part.end)
                } else {
                    let width = side + (audio.isHidden ? 0 : Self.buttonGap + size.width)
                    icon.frame = NSRect(x: round((part.start + part.end - width) / 2), y: iconY, width: side, height: side)
                    if !audio.isHidden { audio.frame.origin = NSPoint(x: icon.frame.maxX + Self.buttonGap, y: y) }
                    title.frame = NSRect(x: icon.frame.maxX, y: titleY, width: 0, height: titleH)
                }
                // In the middle of the gap between two parts.
                if i > 0 {
                    lines[i - 1].frame = NSRect(x: partEdges[i - 1], y: Tokens.Space.x2, width: Tokens.Metric.hairline, height: bounds.height - Tokens.Space.x4)
                }
            }
            return
        }
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
        title.stringValue = String(localized: "New Tab", comment: "The New Tab row in the sidebar, above the tabs.")
        icon.isHidden = true
        plus.image = LineGlyph.plus
        plus.imageScaling = .scaleNone
        addSubview(plus)
        setAccessibilityLabel(String(localized: "New Tab", comment: "The New Tab row in the sidebar, above the tabs."))
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        // Quieter than the tabs under it, coming up when you point at it, with a lighter wash than theirs.
        let ink = Brand.Theme.for(self).quietInk
        title.textColor = isHovered || isPressed ? ink : ink.withAlphaComponent(ink.alphaComponent * 0.75)
        plus.contentTintColor = title.textColor
        if isHovered, !isPressed, !isSelected, !isMarked { layer?.backgroundColor = cgColor(Tokens.Chrome.quietHover) }
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
    var isOpen = true { didSet { if oldValue != isOpen { showChevron(turning: true) } } }
    /// While a pinned page or tab is dragged over it: it lights up to say it will take it.
    var isDropTarget = false { didSet { stateDidChange(animated: true) } }
    var onRename: ((String) -> Void)?
    private var renameField: PlainTextField?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.image = Tokens.Symbol.image("chevron.down", size: Tokens.Symbol.inline)
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
        setAccessibilityLabel(String(localized: "\(name), folder, \(count) pinned", comment: "Accessibility label of a folder in the sidebar: its name, then how many pinned tabs it holds."))
        setAccessibilityValue(open ? 1 : 0)
        needsLayout = true
    }

    /// Down while the folder is open, right while it's shut, at every depth: the chevron is drawn pointing that way
    /// rather than kept turned, since AppKit can put a view's layer back as it was when it lays the view out. Opened
    /// or shut with a click, it turns there from where it pointed.
    private func showChevron(turning: Bool) {
        chevron.image = Tokens.Symbol.image(isOpen ? "chevron.down" : "chevron.right", size: Tokens.Symbol.inline)
        guard turning, window != nil else { return }
        Self.turn(chevron.layer, opening: isOpen, size: chevron.bounds.size)
    }

    /// A chevron just redrawn pointing its new way turns there from where it pointed: a quarter turn back, about its
    /// middle, and on to rest. A folder's, and a tab's with tabs nested under it.
    static func turn(_ layer: CALayer?, opening: Bool, size: NSSize) {
        guard let layer, !Tokens.Motion.reduceMotion else { return }
        let from = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                           CATransform3DMakeRotation(opening ? -.pi / 2 : .pi / 2, 0, 0, 1)),
                                       CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        let turn = Tokens.Motion.easeAnimation(keyPath: "transform")
        turn.fromValue = from
        turn.toValue = CATransform3DIdentity
        layer.add(turn, forKey: "turn")
    }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x3
        // Centered where a tab's close button is, so the trailing marks run down one column.
        let column = bounds.width - Self.buttonEdge - Tokens.Sidebar.rowButton / 2
        chevron.frame = NSRect(x: round(column - side / 2), y: (bounds.height - side) / 2, width: side, height: side)
        folderIcon.frame = icon.frame
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
        let field = PlainTextField(font: title.font ?? Tokens.Font.body(), placeholder: String(localized: "Folder name", comment: "Placeholder of the field that renames a folder, in its sidebar row."))
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
    /// The space's name large and light (Zigzag's own style), or at row size. Always as typed: it's yours. A setting.
    static var isLarge: Bool {
        get { UserDefaults.standard.object(forKey: "LargeSpaceNames") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "LargeSpaceNames")
            NotificationCenter.default.post(name: styleChanged, object: nil)
        }
    }
    static let styleChanged = Notification.Name("SpaceNameStyleChanged")
    /// The name's font for the style in use.
    static var nameFont: NSFont { isLarge ? Tokens.Font.spaceName() : .systemFont(ofSize: Tokens.Sidebar.rowText, weight: .semibold) }
    /// How tall the name's row is for the style in use.
    static var rowHeight: CGFloat { isLarge ? Tokens.Sidebar.spaceNameHeight : Tokens.Sidebar.rowHeight }
    let label = Label("", font: Tokens.Font.spaceName(), color: Tokens.Color.textPrimary)
    /// After the space's color changes: the name takes its new ink.
    func refreshInk() { stateDidChange(animated: false) }
    /// The space's name, set large and light, a little tight, in the space's own ink.
    var name = "" {
        didSet {
            guard name != oldValue else { return }
            // Set in the voice by `stateDidChange`.
            label.stringValue = name
            stateDidChange(animated: false)
            needsLayout = true
        }
    }
    private let chevron = NSImageView()
    private let iconView = NSImageView()
    /// The profile the space is on, quiet at the end of the line, once there's more than one profile to tell apart.
    /// It gives way to the name: where the two don't both fit, it isn't shown.
    private let profileLabel = Label("", font: Tokens.Font.sidebarLabel(), color: Tokens.Color.textTertiary)
    var profileName: String? {
        didSet {
            guard profileName != oldValue else { return }
            profileLabel.stringValue = profileName ?? ""
            stateDidChange(animated: false)
            needsLayout = true
        }
    }
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
        profileLabel.lineBreakMode = .byTruncatingTail
        profileLabel.alignment = .right
        addSubview(profileLabel)
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
        // Large, low in its slot; at row size, centered in its row like the rows below it.
        let y = !Self.isLarge ? round((bounds.height - h) / 2) : isFlipped ? bounds.height - h - pad : pad
        // Icons and the chevron center on the lowercase letters' middle (the x-height), not the text box, so they sit
        // level with the name.
        let font = Self.nameFont
        let baseline = isFlipped ? y + (h + font.ascender + font.descender) / 2 : y + (h - font.ascender - font.descender) / 2
        let xMiddle = isFlipped ? baseline - font.xHeight / 2 : baseline + font.xHeight / 2
        let bearing = Self.isLarge ? Tokens.Sidebar.spaceNameBearing : 0
        var x = SidebarRowView.inset - Label.inset - bearing
        if icon != nil {
            // The space's icon leads the name at the name's own scale, as one mark, not a row icon beside a heading.
            // As tall as the name's capitals, its middle on the lowercase letters' middle, and fit to that square
            // whatever its drawing's shape; centered over the rows' icon column, so it lines up with the + below.
            let side = Self.isLarge ? ceil(font.capHeight) + 2 : Tokens.Sidebar.favicon
            let column = SidebarRowView.inset + Tokens.Sidebar.favicon / 2
            // Its bottom on the name's baseline and its top at the capitals', so it stands in the line like a letter.
            let capMiddle = isFlipped ? baseline - font.capHeight / 2 : baseline + font.capHeight / 2
            iconView.frame = NSRect(x: round(column - side / 2), y: round(capMiddle - side / 2), width: side, height: side)
            x = iconView.frame.maxX + Tokens.Space.x2 - Label.inset - bearing - (Self.isLarge ? 2 : 0)
        }
        label.frame = NSRect(x: x, y: y, width: min(label.textWidth, bounds.width - x - Tokens.Space.x6), height: h)
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: label.frame.maxX + Tokens.Space.x2, y: xMiddle - side / 2, width: side, height: side)
        // The profile's name, at the line's end where Clear ends on the row below, standing on the name's baseline.
        // It has what the name and its chevron leave, and under a few letters' room it isn't there at all.
        let room = bounds.width - SidebarRowView.inset - (chevron.frame.maxX + Tokens.Space.x2)
        let width = min(ceil(profileLabel.textWidth), room)
        profileLabel.isHidden = profileName == nil || room < Self.profileRoom
        let small = profileLabel.font ?? Tokens.Font.sidebarLabel()
        let lh = profileLabel.lineHeight
        let labelY = isFlipped ? baseline - (lh + small.ascender + small.descender) / 2 : baseline - (lh - small.ascender - small.descender) / 2
        profileLabel.frame = NSRect(x: bounds.width - SidebarRowView.inset + Label.inset - width, y: round(labelY), width: width, height: lh)
    }

    /// The least room worth showing a profile's name in: a few letters before it's cut short.
    static let profileRoom: CGFloat = 28

    /// The icon before a space's name: about the name's x-height and a little more, so the two read as one.
    static let iconSide: CGFloat = 20

    override func stateDidChange(animated: Bool) {
        // The name in light type and the space's own ink, quietly fuller under the pointer; its icon a step back.
        let ink = Brand.Theme.for(self).ink
        let color = isHovered ? ink : ink.withAlphaComponent(0.86)
        // The label measures by its own font, so it follows the style in use.
        if label.font != Self.nameFont { label.font = Self.nameFont; needsLayout = true }
        label.attributedStringValue = Self.isLarge ? Tokens.Font.voiceText(label.stringValue, color: color)
            : NSAttributedString(string: label.stringValue, attributes: [.font: Self.nameFont, .foregroundColor: color])
        // A symbol takes the name's own ink; an emoji keeps its colors.
        iconView.contentTintColor = ink.withAlphaComponent(0.86)
        profileLabel.textColor = Brand.Theme.for(self).quietInk
        chevron.image = Tokens.Symbol.image(isCollapsed ? "chevron.right" : "chevron.down", size: Tokens.TypeSize.body)
        // The chevron shows on hover, and stays while folded so you know something is tucked away.
        chevron.isHidden = !canCollapse || !(isHovered || isCollapsed)
        setAccessibilityLabel(isCollapsed ? String(localized: "\(label.stringValue), pinned tabs hidden", comment: "Accessibility label of the space's name above its pinned tabs, while they're folded away.") : label.stringValue)
        setAccessibilityHelp(isCollapsed ? String(localized: "Show pinned tabs", comment: "Accessibility help of the space's name above its pinned tabs, while they're folded away.") : String(localized: "Hide pinned tabs", comment: "Accessibility help of the space's name above its pinned tabs."))
        setAccessibilityCustomActions(canCollapse ? [
            NSAccessibilityCustomAction(name: isCollapsed ? String(localized: "Show Pinned Tabs", comment: "VoiceOver action on the space's name: unfolds its pinned tabs.")
                                                        : String(localized: "Hide Pinned Tabs", comment: "VoiceOver action on the space's name: folds its pinned tabs away.")) { [weak self] in
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
    private let label = Label(String(localized: "Tabs", comment: "The quiet label above today's tabs in the sidebar, below the pinned tabs."), font: Tokens.Font.sidebarLabel(), color: Tokens.Color.textTertiary)
    let clearButton = ClearTabsButton()
    /// The label and Clear in the space's quiet ink.
    func refreshInk() {
        label.textColor = Brand.Theme.for(self).quietInk
        clearButton.stateDidChange(animated: false)
    }
    var showsClear = false { didSet { if showsClear != oldValue { refreshClear() } } }
    var hasTabs = false { didSet { if hasTabs != oldValue { refreshClear() } } }
    /// Shown under the pointer, or while Tab has brought keyboard focus to it.
    private var clearShown: Bool { (showsClear || clearButton.hasKeyboardFocus) && hasTabs }
    /// When Clear last came into view. A click right as it appears was meant for whatever was under the pointer
    /// a moment before (New Tab, just below), so it counts only once Clear has been there a beat.
    private var clearShownAt = Date.distantPast
    var clearIsArmed: Bool { clearButton.hasKeyboardFocus || (clearShown && Date().timeIntervalSince(clearShownAt) > 0.35) }
    /// After a step, the next one waits a beat, so a double-click never runs two steps at once.
    func rearmClear() { clearShownAt = Date() }
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
        // The label sits low, nearer the tabs it names than the pinned tabs above, on the sidebar's left edge with
        // the icons and the space's name.
        let h = label.lineHeight
        let mid = bounds.height - Tokens.Space.x3
        label.frame = NSRect(x: SidebarRowView.inset - Label.inset, y: floor(mid - h / 2), width: label.inkWidth + Label.inset * 2, height: h)
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

/// Clear, on the line above the tabs: small, quiet text with a downward arrow (it clears what's below), in the same
/// quiet ink as "Tabs" until the pointer is on it, then in the rows' ink.
final class ClearTabsButton: InteractiveView {
    /// The tabs below get swept away, the way Arc says it: an arrow pointing down at them.
    private let arrow = NSImageView()
    private let label = Label(String(localized: "Clear", comment: "Button at the end of the Tabs label in the sidebar: closes tabs."), font: Tokens.Font.sidebarLabel(), color: Tokens.Color.textTertiary)
    private static let arrowSide: CGFloat = Tokens.Symbol.inline
    /// The capsule's room at each end: the arrow's own margin and the text's rounding make the two look the same.
    private static let pad: CGFloat = 6

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

    /// What a click does now, and its tooltip says so: the tabs you haven't been using, then every tab but the one
    /// you're on, then that one too.
    enum Step: Equatable { case unused(Int), others(Int), last(Int) }
    var step: Step = .others(0) {
        didSet {
            switch step {
            case .unused(let n):
                toolTip = String(localized: "Close \(n) tabs you haven’t been using", comment: "Tooltip of the sidebar's Clear button: closes the tabs you haven't looked at in a while, keeping the ones you're working with now.")
            case .others(let n):
                toolTip = String(localized: "Close the other \(n) tabs", comment: "Tooltip of the sidebar's Clear button: closes every tab but the one you're on.")
            case .last(let n):
                toolTip = n == 1 ? String(localized: "Close this tab too, leaving the space empty", comment: "Tooltip of the sidebar's Clear button when the only tab left is the one you're on.")
                                 : String(localized: "Close these tabs too, leaving the space empty", comment: "Tooltip of the sidebar's Clear button when the only tabs left are the split view you're on.")
            }
            setAccessibilityLabel(toolTip)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(Self.pad + Self.arrowSide + 3 + label.inkWidth + Self.pad) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A capsule, so its hover fill reads as one small button on the line.
        layer?.cornerRadius = bounds.height / 2
        arrow.frame = NSRect(x: Self.pad, y: (bounds.height - Self.arrowSide) / 2, width: Self.arrowSide, height: Self.arrowSide)
        let h = label.lineHeight
        label.frame = NSRect(x: arrow.frame.maxX + 3 - Label.inset, y: (bounds.height - h) / 2, width: label.inkWidth + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let active = isHovered || isPressed
        let theme = Brand.Theme.for(self)
        label.textColor = active ? theme.rowInk : theme.quietInk
        arrow.contentTintColor = label.textColor
        let fill: NSColor? = isPressed ? Tokens.Chrome.pressed : isHovered ? Tokens.Chrome.hover : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }
}

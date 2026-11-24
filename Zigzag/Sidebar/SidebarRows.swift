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
        drawsMenu = true
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        title.font = Tokens.Font.sidebarRow()
        // Long titles fade at the end (`Label.fadesTail`).
        title.fadesTail = true
        addSubview(icon)
        addSubview(title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Space reserved at the trailing edge for accessory buttons.
    var trailingAccessoryWidth: CGFloat { 0 }

    /// Whether `layout` fades the title; false when a subclass places and fades it later (tabs, under the close button).
    var fadesTitleInLayout: Bool { true }

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
        let titleHeight = title.lineHeight
        let trailing = trailingAccessoryWidth > 0 ? trailingAccessoryWidth + Self.buttonEdge : Self.inset - Label.inset
        // Center the caps on the icon, not the line box (which sits low).
        title.frame = NSRect(x: titleX, y: title.centeredY(in: bounds.height), width: max(0, bounds.width - titleX - trailing), height: titleHeight)
        if fadesTitleInLayout { title.fadeTail() }
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

    /// The views that fade: icon and title, or every part's on a split row.
    var fadingViews: [NSView] { [icon, title] }

    func applyFreshness(animated: Bool = false) {
        let visible = isAboutToClear ? 0.18 : isSelected || isHovered || isLifted || isMarked ? 1 : freshness
        for view in fadingViews { (animated ? view.animator() : view).alphaValue = visible }
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
    private var attentionToken: SignalToken?
    /// Question count when the dots last drew, so one for another row doesn't redraw every row.
    private var waitingQuestions = 0
    let closeButton = TabRowView.rowButton("xmark", toolTip: String(localized: "Close Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))
    /// The speaker right after the title of the page that's playing (or muted): this row's own, and in a split, its
    /// partner's after the partner's title. Clicking one mutes or unmutes that page.
    let audioButton = TabRowView.speakerButton()
    let partnerAudioButton = TabRowView.speakerButton()

    // Developer Mode (#141): each page of the row that's in it has the mode's chip on its icon's corner
    // (`FaviconView.developerBadge`), as a sleeping page has its ring, so the site you're building is told from the
    // one that's live at a glance without the row growing a second line or a frame. Pointing at the icon says so, with
    // the host; the hover card says so too.

    /// Which of the row's parts are in Developer Mode, in `half(at:)`'s order.
    private var developerParts: [Bool] {
        let pages: [Tab?] = isSplit ? [tab, partner] + extraPages : [tab]
        return pages.map { $0?.isDevelopment == true }
    }

    /// The parts of a row whose pages are `inMode` (one for a row of one page) that carry the chip, in the same order:
    /// each in Developer Mode, renaming or not, at rest, under the pointer and selected alike.
    nonisolated static func developerBadges(inMode: [Bool]) -> [Int] { inMode.indices.filter { inMode[$0] } }

    /// What pointing at a page in Developer Mode says: the mode, then the host with its port and without "www."
    /// ("localhost:3000"), the line Arc puts under the title.
    static func developerTip(for url: URL?) -> String {
        [DeveloperTool.modeName, developerHost(of: url)].compactMap { $0 }.joined(separator: "\n")
    }

    nonisolated static func developerHost(of url: URL?) -> String? {
        guard let url, let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        var name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if name.contains(":") { name = "[\(name)]" }
        return url.port.map { "\(name):\($0)" } ?? name
    }

    var showsDeveloperMode: Bool { !Self.developerBadges(inMode: developerParts).isEmpty }

    static func rowButton(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: Tokens.Sidebar.rowButton, symbolSize: Tokens.Sidebar.rowGlyph, toolTip: toolTip)
        button.radius = Tokens.Radius.small + 1
        return button
    }
    /// A page's speaker: a row button in the title's quieter ink, so it reads as part of the page, not a control column.
    static func speakerButton() -> IconButton {
        let button = rowButton("speaker.wave.2", toolTip: String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))
        button.tint = Tokens.Color.textSecondary
        showSpeaker(button, muted: false)
        return button
    }

    /// The speaker's glyph: the title's size and weight at the small symbol scale, so its ink is the caps' height.
    static func showSpeaker(_ button: IconButton, muted: Bool) {
        if SpeakerBadge.isBadge(button) { SpeakerBadge.show(button, muted: muted); return }
        let glyph = speakerGlyph(muted: muted)
        guard button.glyph !== glyph.image else { return }
        button.glyph = glyph.image
        button.glyphInk = glyph.ink
    }

    /// Playing and muted share one place: the speaker's body on the same pixels in both, set by the playing glyph's ink.
    private static func speakerGlyph(muted: Bool) -> (image: NSImage, ink: CGSize, size: CGSize) {
        let point = Tokens.Sidebar.rowText
        let key = "row speaker \(point)"
        if speakerGlyphs[key] == nil {
            let config = NSImage.SymbolConfiguration(pointSize: point, weight: .regular, scale: .small)
            let names = ["speaker.wave.2", "speaker.slash"], keys = names.map { "row speaker \($0) \(point)" }
            let images = names.map { name in
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
                image.isTemplate = true
                return image
            }
            let inks = Tokens.Symbol.sharedInkOffsets(of: images, keys: keys, reference: 0)
            let size = Tokens.Symbol.inkSize(of: images[0], key: keys[0])
            speakerGlyphs[key] = [(images[0], inks[0], size), (images[1], inks[1], size)]
        }
        return speakerGlyphs[key]![muted ? 1 : 0]
    }
    private static var speakerGlyphs: [String: [(image: NSImage, ink: CGSize, size: CGSize)]] = [:]

    /// A page's speaker as the badge on its icon's corner a favorite has (`SpeakerBadge`), or back to a row button.
    private static func showSpeaker(_ button: IconButton, badge: Bool, muted: Bool) {
        if badge {
            SpeakerBadge.style(button)
        } else if SpeakerBadge.isBadge(button) {
            SpeakerBadge.unstyle(button)
            button.setFrameSize(NSSize(width: Tokens.Sidebar.rowButton, height: Tokens.Sidebar.rowButton))
            button.radius = Tokens.Radius.small + 1
        }
        showSpeaker(button, muted: muted)
    }

    /// The ink size the speaker is placed by: the playing glyph's, in both states.
    private static func speakerInk(_ button: IconButton) -> CGSize { speakerGlyph(muted: false).size }
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
    private(set) var renamingPart = 0

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
        // The row's ink, so the name doesn't change color as you edit it.
        field.textColor = Brand.Theme.for(self).rowInk
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
        applyFreshness()
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
    /// A split or group fades as one; while one part is renamed, the others stay hidden.
    override var fadingViews: [NSView] { renameField == nil ? partViews.flatMap { $0 } : super.fadingViews }

    /// The pinned page's own name, shown before the mark while it's away: "Apple / MacBook Pro".
    var pinName: String? { didSet { pinLabel.stringValue = pinName ?? ""; needsLayout = true } }
    private lazy var pinLabel: Label = {
        let label = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textSecondary)
        label.fadesTail = true
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
    /// A pinned page none of whose pages is running (never opened, put to sleep, or not loaded yet since Zigzag
    /// reopened): no open edge and no unload button, the way a pinned page that was never opened looks (#205).
    private(set) var isUnloaded = false { didSet { if oldValue != isUnloaded { refreshTitleColor() }; showsOpenEdge = isBookmark && !isUnloaded } }

    /// Whether a page's icon wears the ring of a page that isn't running (#205). `loaded`: nil for no page. In the
    /// Tabs list every row is a tab, so the ring is what tells one that isn't running, asleep or not loaded yet
    /// since Zigzag reopened. Among pinned pages and favorites the open edge does (`showsOpenEdge(pinned:loaded:)`):
    /// one that isn't running looks like one never opened, never ringed while those beside it aren't.
    nonisolated static func ringsUnloaded(pinned: Bool, loaded: Bool?) -> Bool { !pinned && loaded == false }

    /// Whether a pinned page's row, or a favorite's tile, has the open edge: only while one of its pages is loaded.
    nonisolated static func showsOpenEdge(pinned: Bool, loaded: [Bool]) -> Bool { pinned && loaded.contains(true) }

    private func showsUnloaded(_ page: Tab?) -> Bool { Self.ringsUnloaded(pinned: isBookmark, loaded: page?.isLoaded) }

    private func refreshUnloaded() { isUnloaded = isBookmark && !Self.showsOpenEdge(pinned: true, loaded: pages.map(\.isLoaded)) }

    /// One of the row's other pages, after its own: its page while open, and for a pinned page its pinned name and
    /// icon, there whether or not the page is. Tab rows and pinned rows give the same parts.
    struct Part {
        var page: Tab?
        var name: String? = nil
        var icon: NSImage? = nil
    }
    /// The row's other pages in the group's order: a split's other half, or a tile group's other two or three.
    private(set) var parts: [Part] = []
    private var partTokens: [SignalToken] = []
    /// The second part's page.
    var partner: Tab? { parts.first?.page }
    /// Two to four pages in one row: a split or tile group, of tabs or of pinned pages.
    var isSplit: Bool { !parts.isEmpty }
    /// Which page you're working in, when split (0 = this row's own, 1 = its partner).
    var focusedHalf = 0 { didSet { if oldValue != focusedHalf { refreshTitleColor(); refreshAccessories() } } }
    /// The part whose page is zoomed over the rest of its split or group (`half(at:)`'s numbering), lit; nil for none.
    var zoomedPart: Int? { didSet { if oldValue != zoomedPart { needsLayout = true } } }
    /// The light under the zoomed part: the row's own pressed fill, inset as the split drop's half is.
    /// Made the first time a part of this row is zoomed.
    private var zoomMarkView: ColorView?

    /// Highlight the zoomed part, or on the selected icon-only split row, the focused page, matching the page area.
    private func layoutZoomMark() {
        guard let part = zoomedPart ?? (isSelected && !showsPartTitles ? focusedHalf : nil), isSplit else {
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
        let spatial = extraCount == 0 && partnerLeads ? 1 - part : part
        let spans = partSpans
        guard spans.indices.contains(spatial) else { zoomMark.isHidden = true; return }
        let inset = Tokens.Metric.dropInset
        let span = spans[spatial]
        // The row's own ends keep the row's inset; between parts, the middle of the gap.
        zoomMark.frame = NSRect(x: span.start + inset, y: inset, width: max(0, span.end - span.start - inset * 2), height: bounds.height - inset * 2)
        // The page you're in, the row's hover wash; one zoomed over the rest, its pressed fill.
        zoomMark.color = zoomedPart == nil ? Tokens.Color.hoverFill : Tokens.Color.pressedFill
        zoomMark.isHidden = false
    }
    /// The partner is on the left of the page, so it's on the left of the row too (a pinned page beside a tab).
    var partnerLeads = false { didSet { if oldValue != partnerLeads { needsLayout = true } } }
    private let partnerIcon = FaviconView()
    private let partnerTitle: Label = {
        let label = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
        label.fadesTail = true
        return label
    }()
    private let divider = ColorView(color: Tokens.Color.separator)
    /// A tile group's third and fourth parts' views (#160): each its own part of the row, as the partner's half is,
    /// with its icon, its title while there's room for it, and its speaker.
    private typealias ExtraViews = (icon: FaviconView, title: Label, divider: ColorView, audio: IconButton)
    /// Made the first time the row shows a group of more than two.
    private var extraViews: [ExtraViews]?
    private var extras: [ExtraViews] {
        if let extraViews { return extraViews }
        let made: [ExtraViews] = (0..<2).map { i in
            let icon = FaviconView(), title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
            title.fadesTail = true
            let divider = ColorView(color: Tokens.Color.separator)
            let audio = TabRowView.speakerButton()
            audio.onClick = { [weak self] _ in
                guard let self, self.extraPages.indices.contains(i), let page = self.extraPages[i] else { return }
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
    var pages: [Tab] { ([tab, partner] + extraPages).compactMap { $0 } }
    /// The third and fourth parts' pages, in order: nil for a pinned page that isn't open.
    var extraPages: [Tab?] { parts.dropFirst().map(\.page) }
    /// The third and fourth parts' names.
    private var extraTitles: [String] { parts.dropFirst().map(Self.name) }
    /// How many parts the row has after its own and its partner's.
    private var extraCount: Int { max(0, parts.count - 1) }
    /// A part's name: its pinned one, else its page's.
    private static func name(_ part: Part) -> String { part.name ?? part.page?.displayTitle ?? "" }
    /// How many parts the row is split into: one, two halves, or a tile group's three or four.
    private var segmentCount: Int { isSplit ? 2 + extraCount : 1 }

    /// A row of several pages, tabs or pinned, whose × closes one page (#404): the part pointed at, else the one you're in.
    var closesPart: Bool { isSplit && !isAway }
    /// The part under the pointer, in `half(at:)`'s numbering; nil while it's elsewhere.
    private var pointedPart: Int? { didSet { if oldValue != pointedPart { stateDidChange(animated: false); needsLayout = true } } }
    /// Whether the × sits in one part of the row, which it closes: the part under the pointer, or the one you're in.
    private var closesInPart: Bool { closesPart && isSplit }
    /// Whether a part has room for the × at its end beside its centered icon (always, with its title showing).
    private func closeFitsBesideIcon(part: Int) -> Bool {
        if showsPartTitles { return true }
        let spatial = extraCount == 0 && partnerLeads ? 1 - part : part
        let spans = partSpans
        guard spans.indices.contains(spatial) else { return true }
        let span = spans[spatial], side = Tokens.Sidebar.favicon, button = Tokens.Sidebar.rowButton
        return span.end - Self.buttonEdge - button >= (span.start + span.end + side) / 2 + Self.buttonGap
    }

    /// The part the × is in, lit with the row's hover wash; made the first time it shows.
    private var partWash: ColorView?

    /// Lights the part spanning `span` (nil: none), inset as the zoomed part's light is, unless that light is there.
    private func layoutPartWash(_ span: (start: CGFloat, end: CGFloat)?, lit: Bool) {
        guard let span, !lit, !closeButton.isHidden else { partWash?.isHidden = true; return }
        let wash = partWash ?? {
            let wash = ColorView(color: Tokens.Chrome.hover)
            wash.layer?.cornerRadius = Tokens.Sidebar.rowRadius - Tokens.Metric.dropInset
            wash.layer?.cornerCurve = .continuous
            addSubview(wash, positioned: .below, relativeTo: icon)
            partWash = wash
            return wash
        }()
        let inset = Tokens.Metric.dropInset
        wash.frame = NSRect(x: span.start + inset, y: inset, width: max(0, span.end - span.start - inset * 2), height: bounds.height - inset * 2)
        wash.isHidden = false
    }
    /// The part the × is on, in `half(at:)`'s numbering.
    var closePart: Int {
        guard closesPart, isSplit else { return 0 }
        if let voicedPart { return voicedPart }
        if let pointedPart, pointedPart < segmentCount { return pointedPart }
        if isSelected { return min(focusedHalf, segmentCount - 1) }
        return extraCount == 0 && partnerLeads ? 0 : segmentCount - 1
    }
    /// The page the × closes: one part's with `closesPart` (nil for a pinned part that isn't open), else the row's own.
    var closingPage: Tab? {
        guard closesPart else { return tab }
        let pages = [tab, partner] + extraPages
        return pages.indices.contains(closePart) ? pages[closePart] : nil
    }
    /// Whether the part's page has a × of its own: a tab always, a pinned page while it's loaded, as on its own row.
    private func partCloses(_ page: Tab?) -> Bool {
        guard let page else { return false }
        return page.bookmarkID == nil || page.isLoaded
    }
    #if DEBUG
    /// The debug bridge's pointer over one part of the row (`half(at:)`'s numbering).
    func debugPoint(atPart part: Int?) { pointedPart = part }
    #endif
    private var moveTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        moveTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        TouchReveal.pointerMoved(over: self)
        trackPointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        TouchReveal.pointerMoved(over: self)
        trackPointer(event)
    }

    // MARK: Touch

    /// Shown by a tap as hovering shows it, the × of a pinned tab or a split's part included (`TouchReveal`).
    private(set) var touchRevealed = false {
        didSet { if oldValue != touchRevealed { stateDidChange(animated: false) } }
    }

    /// A tap at `point` (own coordinates): the row's buttons show as if hovered, on the part tapped.
    func touchReveal(at point: NSPoint) {
        if closesPart, isSplit, bounds.contains(point) { pointedPart = half(at: point) }
        touchRevealed = true
        var area: NSView? = superview
        while let current = area, !(current is SidebarView) { area = current.superview }
        TouchReveal.reveal(self, keptWithin: area) { [weak self] in
            guard let self else { return }
            self.touchRevealed = false
            if !self.isHovered { self.pointedPart = nil }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointedPart = nil
    }

    private func trackPointer(_ event: NSEvent) {
        guard closesPart, isSplit else { pointedPart = nil; return }
        let point = convert(event.locationInWindow, from: nil)
        pointedPart = bounds.contains(point) ? half(at: point) : nil
    }

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
        if TouchGestures.isAvailable { addTouchWatch() }
    }

    private func addTouchWatch() {
        let watch = TouchWatch()
        watch.onDown = { [weak self] point in self?.touchDown(at: point) }
        watch.onTap = { [weak self] point in self?.touchTapped(at: point) }
        addGestureRecognizer(watch)
    }

    /// A finger landing near the × but off it (`closeTouchBox`): the click AppKit makes from it is the ×'s.
    private enum CloseTouch { case none, armed(NSPoint, TimeInterval), taken }
    private var closeTouch = CloseTouch.none
    /// The press the × took over from the row, until it lifts.
    private var closePress: NSEvent?

    /// The × is 20 points; a finger takes it anywhere in `TouchGestures.target` around it, within the row.
    var closeTouchBox: NSRect { TouchGestures.box(around: closeButton.frame).intersection(bounds) }

    /// A finger landed, in window coordinates.
    func touchDown(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let nearClose = !closeButton.isHidden && !closeButton.frame.contains(point) && closeTouchBox.contains(point)
        closeTouch = nearClose ? .armed(windowPoint, ProcessInfo.processInfo.systemUptime) : .none
    }

    /// A tap, in window coordinates, once AppKit's click from it has gone through.
    func touchTapped(at windowPoint: NSPoint) {
        TouchLog.note("row tap \(tab?.displayTitle.prefix(20) ?? "") close=\(closeTouch) selected=\(isSelected) seen by \(TouchLog.recognizers(from: self))")
        switch closeTouch {
        case .armed:
            // No click came from it: the tap is the ×'s all the same.
            closeTouch = .none
            let event = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
            if let event { closeButton.onClick?(event) }
        case .taken:
            closeTouch = .none
        case .none:
            touchReveal(at: convert(windowPoint, from: nil))
        }
    }

    /// Whether a mouse-down is the click AppKit made from a finger near the ×.
    private func takesCloseTouch(_ event: NSEvent) -> Bool {
        guard case .armed(let point, let time) = closeTouch, ProcessInfo.processInfo.systemUptime - time < 1,
              hypot(event.locationInWindow.x - point.x, event.locationInWindow.y - point.y) < TouchGestures.tapSlop else { return false }
        closeTouch = .taken
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let closes = takesCloseTouch(event)
        if TouchDoubleTap.isFromFinger(event.timestamp, landedAt: TouchPress.landedAt) {
            TouchLog.note("row press \(tab?.displayTitle.prefix(20) ?? "") clicks=\(event.clickCount) to×=\(closes)")
        }
        if closes { closePress = event; return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if closePress != nil { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press = closePress else { return super.mouseUp(with: event) }
        closePress = nil
        let moved = hypot(event.locationInWindow.x - press.locationInWindow.x, event.locationInWindow.y - press.locationInWindow.y)
        if moved < TouchGestures.tapSlop { closeButton.onClick?(event) }
    }

    /// The row's other pages after its own, in order (none: a row of one page). The only way a row becomes a split
    /// or tile group's row, in the tab list and among the pinned pages alike.
    func configure(parts new: [Part]) {
        let new = Array(new.prefix(3))
        let samePages = new.count == parts.count && zip(new, parts).allSatisfy { $0.page === $1.page }
        guard !samePages || zip(new, parts).contains(where: { $0.name != $1.name || $0.icon !== $1.icon }) else { return }
        parts = new
        if !samePages {
            partTokens = new.enumerated().compactMap { i, part in
                part.page?.changed.observe { [weak self] change in
                    // `.webView`: it went to sleep or woke, which its icon shows.
                    guard change == .title || change == .favicon || change == .loading || change == .url || change == .audio || change == .webView || change == .developer else { return }
                    if i == 0 { self?.refreshPartner() } else { self?.refreshExtras() }
                }
            }
        }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
        refreshExtras()
    }

    private func refreshExtras() {
        guard extraCount > 0 || extraViews != nil else { return }
        let pages = extraPages, titles = extraTitles
        for (i, views) in extras.enumerated() {
            let shown = i < extraCount
            let page = pages.indices.contains(i) ? pages[i] : nil
            let part = parts.indices.contains(i + 1) ? parts[i + 1] : nil
            views.icon.image = page?.displayIcon ?? part?.icon
            views.icon.isLoading = (page?.isLoading ?? false) && !(page?.isSuspended ?? true)
            views.icon.isUnloaded = showsUnloaded(page)
            views.title.stringValue = titles.indices.contains(i) ? titles[i] : ""
            Self.showSpeaker(views.audio, muted: page?.isMuted == true)
            views.audio.toolTip = page?.isMuted == true ? String(localized: "Unmute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.") : String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
            [views.icon, views.title, views.divider].forEach { $0.isHidden = !shown }
            if renameField != nil, renamingPart == i + 2 { views.title.isHidden = true }
        }
        refreshUnloaded()
        refreshAccessories()
        refreshAccessibilityLabel()
        refreshTitleColor()
        needsLayout = true
    }

    private func refreshPartner() {
        partnerTitle.stringValue = parts.first.map(Self.name) ?? ""
        partnerIcon.image = partner?.displayIcon ?? parts.first?.icon
        partnerIcon.isLoading = (partner?.isLoading ?? false) && !(partner?.isSuspended ?? true)
        partnerIcon.isUnloaded = showsUnloaded(partner)
        Self.showSpeaker(partnerAudioButton, muted: partner?.isMuted == true)
        partnerAudioButton.toolTip = partner?.isMuted == true ? String(localized: "Unmute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.") : String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
        refreshUnloaded()
        refreshAccessories()
        refreshAccessibilityLabel()
        refreshTitleColor()
        needsLayout = true
    }

    /// A split row reads out both of its pages.
    private func refreshAccessibilityLabel() {
        let names = [title.stringValue, partnerTitle.stringValue] + extraTitles
        setAccessibilityLabel(!isSplit ? title.stringValue : String(localized: "Split view: \(Words.list(names))", comment: "Accessibility label of a split view's row in the sidebar: its pages' titles, as a list (“Split view: Wikipedia, Example and Google”)."))
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
        let split = isSplit
        let development = showsDeveloperMode ? DeveloperTool.modeName : nil
        // What its ring shows: its page isn't running.
        let unloaded = showsUnloaded(tab) ? String(localized: "not loaded", comment: "Spoken by VoiceOver after a tab row's name: the tab's page isn't running (put to sleep, or not loaded yet since Zigzag reopened); it loads when you click it.") : nil
        let waiting = ([tab, partner] + extraPages).compactMap { $0 }.contains { PendingQuestions.hasPending(tabID: $0.id) }
            ? String(localized: "needs your answer", comment: "Spoken by VoiceOver after a tab row's name: a question is waiting for that page.")
            : nil
        let state = ([isSelected ? String(localized: "current tab", comment: "Spoken by VoiceOver after a tab row's name: it's the tab you're on.") : nil, unloaded, development, waiting, sound(tab, split ? title.stringValue : nil), sound(partner, partnerTitle.stringValue)]
            + zip(extraPages, extraTitles).map { sound($0, $1) })
            .compactMap { $0 }.joined(separator: String(localized: "accessibility.state-separator", defaultValue: ", ", comment: "Separates the states VoiceOver reads after a tab row's name, like “current tab, playing audio”."))
        setAccessibilityValue(state.isEmpty ? nil : state)
        setAccessibilitySelected(isSelected)
        refreshCloseActions()
    }

    /// The part VoiceOver's close action is for, while it runs.
    private var voicedPart: Int?

    /// VoiceOver closes each page of a split with its own action, as its part's × does.
    private func refreshCloseActions() {
        guard closesPart else { setAccessibilityCustomActions(nil); return }
        let pages = [tab, partner] + extraPages
        let names = partTitles.map(\.stringValue)
        let actions = pages.indices.compactMap { i -> NSAccessibilityCustomAction? in
            guard partCloses(pages[i]), names.indices.contains(i) else { return nil }
            let name = pages[i]?.bookmarkID != nil
                ? String(localized: "Unload \(names[i])", comment: "VoiceOver action on a split view's row in the sidebar: unloads one pinned page of it. The name is that page's title.")
                : String(localized: "Close \(names[i])", comment: "VoiceOver action on a split view's row in the sidebar: closes one page of it. The name is that page's title.")
            return NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                self.voicedPart = i
                defer { self.voicedPart = nil }
                self.onClose?()
                return true
            }
        }
        setAccessibilityCustomActions(actions)
    }

    /// Which page the point is over: 0 for this row's own, 1 for its partner, 2 and 3 for a tile group's others.
    func half(at point: NSPoint) -> Int {
        guard isSplit else { return 0 }
        let count = segmentCount
        // The part's frame, from hairline to hairline.
        let spatial = partEdges.count == count - 1 ? partEdges.filter { point.x >= $0 }.count
            : min(count - 1, max(0, Int(point.x / max(1, bounds.width / CGFloat(count)))))
        // In a split of two the partner's half can come first.
        return extraCount == 0 && partnerLeads ? 1 - spatial : spatial
    }

    /// Where a split or tile group part ends (its hairline).
    private var partEdges: [CGFloat] = []

    /// Each part's span across the row, in the row's order of parts (the partner's half first when it leads).
    private var partSpans: [(start: CGFloat, end: CGFloat)] {
        let edges = [0] + partEdges + [bounds.width]
        return (0..<(edges.count - 1)).map { (edges[$0], edges[$0 + 1]) }
    }

    /// The title labels of the row's parts, in `half(at:)`'s order: its own, the partner's, a group's others.
    private var partTitles: [Label] { [title, partnerTitle] + (extraViews ?? []).map(\.title) }

    /// The page the point is over.
    func page(at point: NSPoint) -> Tab? {
        let pages = [tab, partner] + extraPages
        let index = half(at: point)
        return pages.indices.contains(index) ? pages[index] ?? tab : tab
    }

    /// The open page of the part the point is over; nil for a pinned part that isn't open.
    func partPage(at point: NSPoint) -> Tab? {
        let pages = [tab, partner] + extraPages
        let index = half(at: point)
        return pages.indices.contains(index) ? pages[index] : nil
    }

    /// Splits a row of `count` pages into equal whole-point parts up to `end`, meeting at hairlines.
    static func splitParts(count: Int, end: CGFloat) -> [(start: CGFloat, end: CGFloat)] {
        guard count > 1 else { return [(0, end)] }
        let width = end / CGFloat(count)
        return (0..<count).map { i in (round(CGFloat(i) * width), i == count - 1 ? end : round(CGFloat(i + 1) * width)) }
    }

    /// Narrowest part that fits a title beside its icon: inset, icon, title gap, a few letters, inset.
    static func segmentMinWidth(for size: Tokens.Sidebar.Size = Tokens.Sidebar.size) -> CGFloat {
        inset * 2 + Tokens.Sidebar.favicon(for: size) + Tokens.Sidebar.iconGap + Tokens.Sidebar.splitTitleMin(for: size)
    }

    /// Whether a part this wide shows its title or just a centered icon.
    static func segmentShowsTitle(width: CGFloat, size: Tokens.Sidebar.Size = Tokens.Sidebar.size) -> Bool {
        width >= segmentMinWidth(for: size)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tab: Tab?) {
        guard tab !== self.tab || token == nil else { refresh(); return }
        self.tab = tab
        token = tab?.changed.observe { [weak self] change in self?.tabChanged(change) }
        // Only questions for this row's pages update its dots.
        if attentionToken == nil {
            attentionToken = PendingQuestions.changed.observe { [weak self] _ in
                guard let self, self.pendingForRow != self.waitingQuestions else { return }
                self.refresh()
            }
        }
        refresh()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .title, .url, .favicon, .loading, .audio, .themeColor, .webView, .activity, .developer: refresh()
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
    private var endSlot: CGFloat { showsClose ? Tokens.Sidebar.rowButton : showsNumber ? numberHint?.width ?? 0 : 0 }

    /// The close button (or a pinned tab's unload/back button) shows on hover over the title's faded end, so the title
    /// never shifts. The selected tab keeps it visible, so it reserves the room.
    private var closeOverlays: Bool { !isSplit && !(isSelected && !isBookmark) && !reservesClose && !showsNumber && renameField == nil }
    /// A nested-tabs chevron next to it stays put; the button's room is reserved, as on multi-page rows.
    private var reservesClose: Bool { !isSplit && showsNested }

    /// Faded after placement (`layoutTitleFade`).
    override var fadesTitleInLayout: Bool { false }

    override var trailingAccessoryWidth: CGFloat {
        let close = closeOverlays ? 0 : reservesClose ? max(endSlot, closeButton.frame.width) : endSlot
        let nested = showsNested ? Tokens.Sidebar.rowButton + (close > 0 ? Self.buttonGap : 0) : 0
        // The speaker follows the title (`placeSpeaker`), so it takes no room at the end.
        return close + nested
    }

    func refresh() {
        title.stringValue = fixedTitle ?? tab?.displayTitle ?? ""
        // A pinned page's saved icon until the page has its own; never a globe while one is loading.
        icon.image = tab?.displayIcon ?? (fixedTitle != nil || isAway ? bookmarkIcon : nil)
        icon.isLoading = (tab?.isLoading ?? false) && !(tab?.isSuspended ?? true)
        // Why it isn't running (asleep, and what that freed, or not loaded since Zigzag reopened) is in its hover card
        // (`TabPreviewView`), not a tooltip on top of it.
        icon.isUnloaded = showsUnloaded(tab)
        Self.showSpeaker(audioButton, muted: tab?.isMuted == true)
        audioButton.toolTip = tab?.isMuted == true ? String(localized: "Unmute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.") : String(localized: "Mute Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
        refreshUnloaded()
        refreshAccessibilityLabel()
        refreshTitleColor()
        refreshAccessories()
    }

    var bookmarkIcon: NSImage?

    private func refreshTitleColor() {
        // A pinned tab that isn't loaded reads the same as one that is: faded means old elsewhere in Zigzag.
        let theme = Brand.Theme.for(self)
        let ink = theme.rowInk
        // Fixed weight so selection never shifts text. In the selected split, the focused page's title uses the row's ink and
        // the others are dimmer, matching the page area.
        func inked(part: Int) -> NSColor { isSplit && isSelected && focusedHalf != part ? theme.quietInk : ink }
        title.textColor = inked(part: 0)
        partnerTitle.textColor = inked(part: 1)
        extraViews?.enumerated().forEach { $1.title.textColor = inked(part: $0 + 2) }
        dropHalf.color = Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropAlpha)
        dropHalf.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
    }

    private func refreshAccessories() {
        // A pinned tab you're on stays clean, as Arc's does: its button (unload, or back to its page) comes with the
        // pointer. A plain tab you're on keeps its close button in view.
        let hovering = isHovered || touchRevealed
        let pointing = closesInPart ? hovering && pointedPart != nil : hovering
        // A part too narrow for its icon and the × beside it keeps its icon until you point at it.
        let resting = isSelected && !isBookmark && (!closesInPart || closeFitsBesideIcon(part: closePart))
        // In a split, each part's × is that page's own: none on a pinned part that isn't loaded.
        let unloaded = closesInPart ? !partCloses(closingPage) : isBookmark && isUnloaded
        let showClose = (pointing || resting) && !isLifted && !unloaded && renameField == nil && number == nil
        if closesPart, closeButton.isHidden == showClose { needsLayout = true }
        closeButton.isHidden = !showClose
        let closesPinned = closesInPart ? closingPage?.bookmarkID != nil : isBookmark
        closeButton.toolTip = isAway ? String(localized: "Back to Pinned Page", comment: "Tooltip of a button on a tab's row in the sidebar. The pinned tab wandered off; this goes back to its page.")
            : closesPinned ? String(localized: "Unload Page", comment: "Tooltip of a button on a tab's row in the sidebar. Unloads a pinned tab's page; the pin stays.")
            : String(localized: "Close Tab", comment: "Tooltip of a button on a tab's row in the sidebar.")
        audioButton.isHidden = !showsAudio || renameField != nil
        refreshDeveloperMode()
        refreshAttention()
        partnerAudioButton.isHidden = !isSplit || !partnerShowsAudio || renameField != nil
        for (i, views) in (extraViews ?? []).enumerated() {
            let page = extraPages.indices.contains(i) ? extraPages[i] : nil
            views.audio.isHidden = page.map { !($0.isPlayingAudio || $0.isMuted) } ?? true || renameField != nil
        }
        if nestedTabs != nil || renameField != nil { nestedButton.isHidden = !showsNested }
        // Quiet at rest as a folder's is, clear under the pointer or while the tabs are folded away.
        if nestedTabs != nil { nestedButton.alphaValue = isHovered || nestedTabs == .collapsed ? 1 : 0.6 }
        needsLayout = true
    }

    /// Puts Developer Mode's chip on the icon of each page of the row in it, in the space's color, and takes it off
    /// those that left it.
    private func refreshDeveloperMode() {
        let badged = Set(Self.developerBadges(inMode: developerParts))
        let color = badged.isEmpty ? nil : Brand.Theme.for(self).badge
        let pages = [tab, partner] + extraPages
        let icons = [icon, partnerIcon] + (extraViews ?? []).map(\.icon)
        for (i, view) in icons.enumerated() {
            let on = badged.contains(i)
            view.developerBadge = on ? color : nil
            // Each page in it says so on its own icon, with its host.
            view.toolTip = on ? Self.developerTip(for: pages.indices.contains(i) ? pages[i]?.url : nil) : nil
        }
    }

    /// One accent dot on each page with a question that can't show yet (tab in back or window hidden), however many.
    private func refreshAttention() {
        let pages = [tab, partner] + extraPages
        let icons = [icon, partnerIcon] + (extraViews ?? []).map(\.icon)
        let accent = Brand.Theme.for(self).badge
        for (i, view) in icons.enumerated() {
            guard pages.indices.contains(i), let page = pages[i], waitsItself(page) else {
                view.attentionColor = nil
                continue
            }
            view.attentionColor = accent
        }
        waitingQuestions = pendingForRow
    }

    /// Waiting question count for this row's pages, shown or not; the dots follow it so other rows' questions don't redraw
    /// this one.
    private var pendingForRow: Int {
        pages.reduce(0) { $0 + PendingQuestions.count(tabID: $1.id) }
    }

    /// A question waits for `page` and nothing shows it (background tab or hidden window). The dot goes once the tab is in
    /// front.
    private func waitsItself(_ page: Tab) -> Bool {
        let front = (window?.windowController as? PromptHost)?.promptShows(page) ?? false
        return PendingQuestions.waits(tabID: page.id, isFront: front, windowVisible: window?.isVisible == true)
    }

    private func layoutRenameField() {
        guard let field = renameField else { return }
        let height = ceil(field.intrinsicContentSize.height)
        // On the title's line, so the name doesn't move as editing starts.
        let y = title.frame.midY - height / 2
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
        // Pointing at one part of a split, that part is lit (`partWash`), not the whole row.
        if closesInPart, pointedPart != nil, isHovered, !isSelected, !isMarked, !isPressed, !isLifted {
            layer?.set(backgroundColor: nil, animated: false)
        }
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
        if !isSplit, !audioButton.isHidden {
            // Never in the close button's place, shown or not, so the × comes and goes without moving it.
            let end = showsNested ? nestedButton.frame.minX : bounds.width - Self.buttonEdge - max(endSlot, closeButton.frame.width)
            placeSpeaker(audioButton, after: title, end: end - Self.buttonGap)
        }
        layoutRenameField()
        layoutTitleFade()
    }

    /// The title fades just before the close button while it shows (`closeOverlays`), and at its own end otherwise, with
    /// the same look.
    private func layoutTitleFade() {
        let covered = closeOverlays && !closeButton.isHidden && title.frame.maxX > closeButton.frame.minX
        // Start the fade a little before the button.
        if !isSplit { title.fadeTail(endingAt: covered ? closeButton.frame.minX - Self.buttonGap - title.frame.minX : nil) }
        if isAway { pinLabel.fadeTail() }
        // In a split, the last part's title fades before the close button (or ⌘ number).
        let closeOnPart = closesPart && isSplit && !closeButton.isHidden && partTitles.indices.contains(closePart) ? partTitles[closePart] : nil
        let closeAtEnd = closeOnPart == nil || closeOnPart === lastPartTitle
        let blocker: NSView? = !isSplit || !overlaysPartEnd ? nil : !closeButton.isHidden && closeAtEnd ? closeButton : showsNumber ? numberHint : nil
        for label in [partnerTitle] + (extraViews ?? []).map(\.title) + (isSplit ? [title] : []) {
            if label === closeOnPart, !closeAtEnd, label.frame.maxX > closeButton.frame.minX {
                label.fadeTail(endingAt: closeButton.frame.minX - Self.buttonGap - label.frame.minX)
            } else if label === lastPartTitle, let blocker, label.frame.maxX > blocker.frame.minX {
                label.fadeTail(endingAt: blocker.frame.minX - Self.buttonGap - label.frame.minX)
            } else {
                label.fadeTail()
            }
        }
    }

    private func layoutButtonsAndHalves() {
        let size = NSSize(width: Tokens.Sidebar.rowButton, height: Tokens.Sidebar.rowButton)
        let edge = Self.buttonEdge
        let y = (bounds.height - size.height) / 2
        closeButton.frame.origin = NSPoint(x: bounds.width - edge - size.width, y: y)
        if let hint = numberHint, showsNumber {
            let height = NumberHintView.height
            hint.frame = NSRect(x: bounds.width - edge - hint.width, y: (bounds.height - height) / 2, width: hint.width, height: height)
        }
        // A row of several pages keeps the close button's room whether or not it shows, so its parts never move as
        // the pointer comes and goes.
        let slot = isSplit || reservesClose ? max(endSlot, size.width) : endSlot
        var end = slot > 0 ? bounds.width - edge - slot - Self.buttonGap : bounds.width - edge
        if showsNested {
            nestedButton.frame = NSRect(x: end - size.width, y: y, width: size.width, height: size.height)
            end = nestedButton.frame.minX - Self.buttonGap
        }
        layoutDropHalf()
        defer { layoutZoomMark() }

        guard isSplit else {
            partEdges = []
            partWash?.isHidden = true
            // Restore the title hidden for an icon-only split, unless it's being renamed.
            title.isHidden = renameField != nil
            styleClose(chip: false)
            Self.showSpeaker(audioButton, badge: false, muted: tab?.isMuted == true)
            icon.speakerCut = nil
            return
        }
        // A split shows its pages in one row, equal parts in screen order with hairlines between: icon, faded title, and a
        // speaker while playing or muted. Parts too narrow for a few letters show a centered icon only.
        let pieces: [(icon: FaviconView, title: Label, audio: IconButton, page: Tab?)] = {
            let own = (icon, title, audioButton, tab), other = (partnerIcon, partnerTitle, partnerAudioButton, partner)
            let pages = extraPages
            let extras = (extraViews ?? []).prefix(extraCount).enumerated().map { i, views in
                (views.icon, views.title, views.audio, pages.indices.contains(i) ? pages[i] : nil)
            }
            return (extraCount == 0 && partnerLeads ? [other, own] : [own, other]) + extras
        }()
        let lines = [divider] + (extraViews ?? []).prefix(extraCount).map(\.divider)
        let count = pieces.count
        // Parts run to the row's end and the close button (or ⌘ number) covers the last part's faded title, like a tab, so
        // nothing shifts on hover or selection. Its room is reserved when it would cover too much (icon only, a speaker in
        // the last part, or the whole title), decided by width, not state.
        let kept = bounds.width - edge - max(endSlot, size.width) - Self.buttonGap
        let side = icon.frame.width
        var titles = Self.segmentShowsTitle(width: bounds.width / CGFloat(count))
        let lastStart = Self.splitParts(count: count, end: bounds.width).last?.start ?? 0
        let titleUnderClose = kept - (lastStart + Self.inset + side + Tokens.Sidebar.iconGap)
        // A × that comes in each part needs no room at the row's end: the parts run to it.
        let keepsRoom = !closesInPart && (!titles || !(pieces.last?.audio.isHidden ?? true) || titleUnderClose < Tokens.Sidebar.splitTitleMin())
        // Titles only where they'd show with the × at the row's end, so a part never shows a title the × covers.
        if keepsRoom || closesInPart { titles = Self.segmentShowsTitle(width: kept / CGFloat(count)) }
        let contentEnd = keepsRoom ? kept : bounds.width
        overlaysPartEnd = !keepsRoom
        showsPartTitles = titles
        lastPartTitle = pieces.last?.title
        let parts = Self.splitParts(count: count, end: contentEnd)
        partEdges = parts.dropFirst().map(\.start)
        // The part whose page the × closes, left to right; a row that closes all its pages keeps it at the row's end.
        let closeSpatial = closesPart ? (extraCount == 0 && partnerLeads ? 1 - closePart : closePart) : count - 1
        var washSpan: (start: CGFloat, end: CGFloat)?
        let iconY = icon.frame.minY
        let titleY = title.frame.minY, titleH = title.frame.height
        let renaming = renameField == nil ? nil : partTitles.indices.contains(renamingPart) ? partTitles[renamingPart] : nil
        var chipOrigin: NSPoint?
        for (i, part) in parts.enumerated() {
            let (icon, title, audio, page) = pieces[i]
            let last = i == count - 1
            // Clear of the × that comes on this part, so it never moves under the pointer.
            let speakerEnd = closesPart ? part.end - edge - size.width - Self.buttonGap : last ? contentEnd : part.end - Self.buttonEdge
            let titleX = part.start + Self.inset + side + Self.titleOffset
            // Where the speaker after the title would leave it too few letters, it's the icon's badge instead.
            let inline = titles && (audio.isHidden || speakerEnd - titleX - Label.inset - Tokens.Sidebar.inlineGlyphGap
                - Self.speakerInk(audio).width >= Tokens.Sidebar.splitTitleMin())
            Self.showSpeaker(audio, badge: !inline, muted: page?.isMuted == true)
            if titles {
                icon.frame = NSRect(x: part.start + Self.inset, y: iconY, width: side, height: side)
                // Same gap from the next hairline as the icon has from its own; the last title ends where a tab's does or at the
                // reserved close button room.
                let textEnd = !last ? part.end - Self.inset + Label.inset : keepsRoom ? contentEnd : bounds.width - Self.inset + Label.inset
                title.frame = NSRect(x: titleX, y: titleY, width: max(0, textEnd - titleX), height: titleH)
                if audio.isHidden {
                    icon.speakerCut = nil
                } else if inline {
                    placeSpeaker(audio, after: title, end: speakerEnd)
                    icon.speakerCut = nil
                } else {
                    SpeakerBadge.place(audio, on: icon)
                }
            } else {
                // Icons centered in their parts, like a segmented control, the speaker a badge on the icon's corner.
                let scale = window?.backingScaleFactor ?? 2
                icon.frame = NSRect(x: ((part.start + part.end - side) / 2 * scale).rounded() / scale, y: iconY, width: side, height: side)
                if audio.isHidden { icon.speakerCut = nil } else { SpeakerBadge.place(audio, on: icon) }
                title.frame = NSRect(x: icon.frame.maxX, y: titleY, width: 0, height: titleH)
            }
            title.isHidden = !titles || title === renaming
            icon.alphaValue = 1
            if closesInPart, i == closeSpatial {
                // At the part's own end, over its faded title or beside its icon; a part too narrow for both has a
                // favorite's small × in its top corner, its icon and speaker staying, the part's wash saying whose it is.
                let end = part.end - edge - size.width
                let fits = titles || end >= icon.frame.maxX + Self.buttonGap
                if !fits, !((isHovered || touchRevealed) && pointedPart != nil) { closeButton.isHidden = true }
                if fits {
                    closeButton.frame.origin.x = end
                } else {
                    let chip = Tokens.Sidebar.favoriteClose, inset = Tokens.Metric.dropInset + Self.chipInset
                    chipOrigin = NSPoint(x: part.end - inset - chip, y: isFlipped ? inset : bounds.height - inset - chip)
                }
                washSpan = (part.start, part.end)
            } else if i == closeSpatial, !last {
                // With titles, at the part's end over its faded title; icons only, in the icon's place.
                closeButton.frame.origin.x = titles ? part.end - edge - size.width : round(icon.frame.midX - size.width / 2)
                if !titles, !closeButton.isHidden { icon.alphaValue = 0 }
            }
            // The badge goes with its icon.
            audio.alphaValue = SpeakerBadge.isBadge(audio) ? icon.alphaValue : 1
            // Hairline between this part and the previous, inset from the row's ends.
            if i > 0, lines.indices.contains(i - 1) {
                let line = NSRect(x: part.start - Tokens.Metric.hairline / 2, y: Tokens.Space.x2, width: Tokens.Metric.hairline, height: bounds.height - Tokens.Space.x4)
                lines[i - 1].frame = backingAlignedRect(line, options: .alignAllEdgesNearest)
                lines[i - 1].isHidden = false
            }
        }
        // The light the zoomed part, or the selected icon-only row's page, already has (`layoutZoomMark`).
        let marked = zoomedPart ?? (isSelected && !titles ? focusedHalf : nil)
        let markedSpatial = marked.map { extraCount == 0 && partnerLeads ? 1 - $0 : $0 }
        layoutPartWash(washSpan, lit: markedSpatial == closeSpatial)
        // No hairline against the lit part's edges.
        if partWash?.isHidden == false {
            for j in [closeSpatial - 1, closeSpatial] where lines.indices.contains(j) { lines[j].isHidden = true }
        }
        // ⌘'s number at the row's end, over the last part's icon when there's no title to cover.
        if closesInPart, showsNumber, !titles, let last = pieces.last, let hint = numberHint, last.icon.frame.maxX > hint.frame.minX - Self.buttonGap {
            last.icon.alphaValue = 0
            last.audio.alphaValue = 0
        }
        styleClose(chip: chipOrigin != nil)
        if let chipOrigin { closeButton.frame.origin = chipOrigin }
    }

    /// From the part's wash to a favorite's × in its corner.
    private static let chipInset: CGFloat = 1.5
    private var closeIsChip = false

    /// The × as a row button, or as a favorite's small chip with a hairline (`FavoriteTile`).
    private func styleClose(chip: Bool) {
        if chip { Tokens.Motion.withoutAnimation { closeButton.layer?.borderColor = cgColor(Tokens.Color.controlEdge) } }
        guard chip != closeIsChip else { return }
        closeIsChip = chip
        let side = chip ? Tokens.Sidebar.favoriteClose : Tokens.Sidebar.rowButton
        closeButton.setFrameSize(NSSize(width: side, height: side))
        closeButton.symbolSize = chip ? Tokens.Sidebar.favoriteCloseGlyph : Tokens.Sidebar.rowGlyph
        closeButton.radius = chip ? side / 2 : Tokens.Radius.small + 1
        closeButton.tint = chip ? Tokens.Color.textSecondary : Tokens.Color.icon
        closeButton.showsFillAtRest = chip
        closeButton.wantsLayer = true
        Tokens.Motion.withoutAnimation { closeButton.layer?.borderWidth = chip ? Tokens.Metric.hairline : 0 }
    }

    /// A speaker right after its title's text, as browsers put it with the page, not with the close button: in the
    /// title's line as a symbol in text is, a word space after it, the button round it a full row button to press.
    /// A long title fades before it instead, so it never goes past `end`.
    private func placeSpeaker(_ speaker: IconButton, after title: Label, end: CGFloat) {
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let side = speaker.frame.width, ink = Self.speakerInk(speaker)
        let gap = Tokens.Sidebar.inlineGlyphGap
        let textStart = title.frame.minX + Label.inset
        let inkStart = min(textStart + title.inkWidth + gap, end - (side + ink.width) / 2)
        let x = pixel(max(textStart, inkStart) + ink.width / 2 - side / 2)
        let font = title.font ?? Tokens.Font.sidebarRow()
        let below = Label.capsBelowMiddle(of: font, lineHeight: title.frame.height)
        let capsMiddle = title.frame.midY + (isFlipped ? below : -below)
        // Titles are mostly lowercase, so the eye reads them between the x-height and the caps: the glyph's middle
        // goes halfway between those two middles, a little under the caps' own.
        let lower = Self.speakerDrop(capHeight: font.capHeight, xHeight: font.xHeight)
        let middle = capsMiddle + (isFlipped ? lower : -lower)
        speaker.frame.origin = NSPoint(x: x, y: pixel(middle - speaker.frame.height / 2))
        let textEnd = x + side / 2 - ink.width / 2 - gap
        title.frame.size.width = max(0, min(title.frame.width, textEnd + Label.inset - title.frame.minX))
    }

    /// How far under the caps' middle a symbol in a title's line has its middle: halfway to the x-height's middle.
    static func speakerDrop(capHeight: CGFloat, xHeight: CGFloat) -> CGFloat { max(0, capHeight - xHeight) / 4 }

    /// Whether the close button covers the last split part instead of reserving room.
    private var overlaysPartEnd = false
    /// Whether split parts show titles or icons only.
    private var showsPartTitles = true
    /// The last split part's title, whose fade the close button shortens.
    private weak var lastPartTitle: Label?
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

/// A pinned folder: chevron, folder icon and name. Click toggles, double-click renames, pinned pages drop in. Tab groups
/// (#209) use the same row.
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

    /// A tab group, not a folder; affects VoiceOver and rename text.
    private var isTabGroup = false

    func configure(name: String, open: Bool, count: Int, icon: String? = nil, tabGroup: Bool = false) {
        title.stringValue = name
        folderIcon.image = IconChoice.folder(icon, open: open, size: Tokens.Sidebar.favicon)
        isOpen = open
        isTabGroup = tabGroup
        setAccessibilityLabel(tabGroup ? String(localized: "\(name), group, \(count) tabs", comment: "Accessibility label of a group of tabs in the sidebar: its name, then how many tabs it holds.")
                              : String(localized: "\(name), folder, \(count) pinned", comment: "Accessibility label of a folder in the sidebar: its name, then how many pinned tabs it holds."))
        setAccessibilityValue(open ? 1 : 0)
        title.textColor = Brand.Theme.for(self).rowInk
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
            // On the title's line, so the name doesn't move as editing starts.
            field.frame = NSRect(x: title.frame.minX, y: title.frame.midY - height / 2, width: max(0, bounds.width - title.frame.minX - Self.inset), height: height)
        }
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        // The space's ink, as the pinned pages under it.
        title.textColor = Brand.Theme.for(self).rowInk
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
        let field = PlainTextField(font: title.font ?? Tokens.Font.body(), placeholder: isTabGroup ? String(localized: "Group name", comment: "Placeholder of the field that renames a group of tabs, in its sidebar row.")
                                   : String(localized: "Folder name", comment: "Placeholder of the field that renames a folder, in its sidebar row."))
        field.stringValue = title.stringValue
        // The title's own ink, so the name doesn't change color as you edit it.
        field.textColor = title.textColor
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
        drawsMenu = true
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
        // The name stands flush with the icons' edge, the way a heading does. Its first letter's own side bearing
        // sets its ink in from the box: pulled back so the ink, not the box, meets the icons' edge, at either size.
        // Low in its slot, near the pinned tabs it names, with the room above it.
        let pad = Tokens.Space.x1
        // Large, low in its slot; at row size, centered in its row like the rows below it.
        let y = !Self.isLarge ? label.centeredY(in: bounds.height) : isFlipped ? bounds.height - h - pad : pad
        // Icons and the chevron center on the lowercase letters' middle (the x-height), not the text box, so they sit
        // level with the name.
        let font = Self.nameFont
        let baseline = isFlipped ? y + (h + font.ascender + font.descender) / 2 : y + (h - font.ascender - font.descender) / 2
        let xMiddle = isFlipped ? baseline - font.xHeight / 2 : baseline + font.xHeight / 2
        let bearing = Self.inkBearing(of: name, font: font)
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
        // Cut short, the whole name is under the pointer (#189).
        removeAllToolTips()
        profileTip = nil
        if let profileName, !profileLabel.isHidden, width < ceil(profileLabel.textWidth) {
            profileTip = profileName as NSString
            addToolTip(profileLabel.frame, owner: profileTip!, userData: nil)
        }
    }
    /// How far in from its box the first letter's ink starts, so the name's ink, not its box, meets the icon column.
    static func inkBearing(of text: String, font: NSFont) -> CGFloat {
        guard let first = text.first else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(first), attributes: [.font: font]))
        return max(0, CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).minX)
    }
    /// What the cut profile name's tooltip says; a tooltip doesn't keep its owner.
    private var profileTip: NSString?

    /// The least room worth showing a profile's name in: a few letters before it's cut short.
    static let profileRoom: CGFloat = 28

    /// The icon before a space's name: about the name's x-height and a little more, so the two read as one.
    static var iconSide: CGFloat { Tokens.Sidebar.scaledEven(20) }

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

/// The "Tabs" label above today's tabs, with space above instead of a line. Clear sits at its end, as in Arc, shown only
/// on hover over the list when there are tabs to clear.
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
    /// Shown under the pointer, after a tap on the label's row, or while Tab has brought keyboard focus to it.
    private var clearShown: Bool { (showsClear || touchRevealed || clearButton.hasKeyboardFocus) && hasTabs }
    /// When Clear last came into view. A click right as it appears was meant for whatever was under the pointer
    /// a moment before (New Tab, just below), so it counts only once Clear has been there a beat.
    private var clearShownAt = Date.distantPast
    var clearIsArmed: Bool { clearButton.hasKeyboardFocus || (clearShown && Date().timeIntervalSince(clearShownAt) > 0.35) }
    /// After a step, the next one waits a beat, so a double-click never runs two steps at once.
    func rearmClear() { clearShownAt = Date() }
    /// With Full Keyboard Access on, Clear stays in the Tab order while there are tabs to clear, see-through until
    /// focus reaches it; otherwise it's hidden whenever it isn't shown.
    private var clearInTabOrder: Bool { NSApp.isFullKeyboardAccessEnabled && hasTabs }
    /// Hover or focus on Clear previews what it would close (true) or stops (false).
    var onPreview: ((Bool) -> Void)?
    var isPreviewingClear: Bool { clearButton.isHovered || clearButton.hasKeyboardFocus }
    private func previewChanged() { onPreview?(isPreviewingClear) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        clearButton.alphaValue = 0
        clearButton.isHidden = true
        clearButton.keyboardFocusChanged = { [weak self] _ in
            self?.refreshClear()
            self?.previewChanged()
        }
        clearButton.hoverChanged = { [weak self] _ in self?.previewChanged() }
        addSubview(clearButton)
        if TouchGestures.isAvailable { addTouchWatch() }
    }

    // MARK: Touch

    /// Shown by a tap as hovering the list shows it (`TouchReveal`).
    private(set) var touchRevealed = false { didSet { if touchRevealed != oldValue { refreshClear() } } }

    /// A tap on the row, once AppKit's click from it has gone through: Clear shows, as over the list.
    func touchTapped() {
        touchRevealed = true
        var area: NSView? = superview
        while let current = area, !(current is SidebarView) { area = current.superview }
        TouchReveal.reveal(self, keptWithin: area) { [weak self] in self?.touchRevealed = false }
    }

    private func addTouchWatch() {
        let watch = TouchWatch()
        watch.onTap = { [weak self] _ in self?.touchTapped() }
        addGestureRecognizer(watch)
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
            context.timingFunction = Tokens.Motion.easeOut
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
        // Center the caps on `mid`, Clear's capsule center.
        let capsY = mid - h / 2 - Label.capsBelowMiddle(of: label.font ?? Tokens.Font.sidebarLabel(), lineHeight: h)
        let scale = window?.backingScaleFactor ?? 2
        // Its ink, not its box, on the icon column, as the space's name is.
        let bearing = SpaceHeaderView.inkBearing(of: label.stringValue, font: label.font ?? Tokens.Font.sidebarLabel())
        label.frame = NSRect(x: SidebarRowView.inset - Label.inset - bearing, y: (capsY * scale).rounded() / scale, width: label.inkWidth + Label.inset * 2, height: h)
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
        step = Step(kind: .others, pages: 0)
        stateDidChange(animated: false)
    }

    /// What a click does now (also the tooltip): unused tabs, then all but the current one, then that too. On a favorite or
    /// pinned page, it's all of them. `pages` counts each page (a split's two included); `oneSplit` names a single split.
    struct Step: Equatable {
        enum Kind: Equatable { case unused, others, all, last }
        var kind: Kind
        var pages: Int
        var oneSplit = false
    }
    var step = Step(kind: .others, pages: 0) {
        didSet {
            toolTip = Self.tooltip(for: step)
            setAccessibilityLabel(toolTip)
        }
    }

    /// Clear's step for a list: `listed`, its tabs; `groups`, splits and tile groups by page; `current`, the current page,
    /// which may not be listed (favorite, pinned page).
    nonisolated static func step(kind: TabManager.ClearKind, closing: Set<UUID>, current: UUID?, listed: Set<UUID>, groups: [[UUID]]) -> Step {
        let yoursListed = current.map { id in listed.contains(id) || groups.contains { $0.contains(id) && !listed.isDisjoint(with: $0) } } ?? false
        let oneSplit = closing.count > 1 && groups.contains { Set($0) == closing }
        let shown: Step.Kind = switch kind {
        case .unused: .unused
        case .others: yoursListed ? .others : .all
        case .last: .last
        }
        return Step(kind: shown, pages: closing.count, oneSplit: oneSplit)
    }

    nonisolated static func tooltip(for step: Step) -> String {
        let n = step.pages
        if step.oneSplit {
            return switch step.kind {
            case .unused: String(localized: "Close the split view you haven’t used in a while", comment: "Tooltip of the sidebar's Clear button when what it closes is one split view you haven't looked at in a while.")
            case .others: String(localized: "Close the other split view", comment: "Tooltip of the sidebar's Clear button when the only other tabs are one split view.")
            case .all: String(localized: "Close the split view", comment: "Tooltip of the sidebar's Clear button while you're on a favorite or pinned page and the only tabs are one split view.")
            case .last: String(localized: "Close this split view, leaving the space empty", comment: "Tooltip of the sidebar's Clear button when the only tabs left are the split view you're on.")
            }
        }
        return switch step.kind {
        case .unused: String(localized: "Close \(n) tabs you haven’t used in a while", comment: "Tooltip of the sidebar's Clear button: closes the tabs you haven't looked at in a while, keeping the ones you're working with now.")
        case .others: String(localized: "Close the other \(n) tabs", comment: "Tooltip of the sidebar's Clear button: closes every tab but the one you're on.")
        case .all: String(localized: "Close all \(n) tabs", comment: "Tooltip of the sidebar's Clear button while you're on a favorite or pinned page, so none of the tabs is yours: closes every tab.")
        case .last: String(localized: "Close the last \(n) tabs, leaving the space empty", comment: "Tooltip of the sidebar's Clear button when the only tabs left are the one you're on (and the pages beside it in a split).")
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
        label.frame = NSRect(x: arrow.frame.maxX + 3 - Label.inset, y: label.centeredY(in: bounds.height), width: label.inkWidth + Label.inset * 2, height: h)
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

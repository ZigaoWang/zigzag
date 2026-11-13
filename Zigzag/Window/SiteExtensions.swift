import AppKit

/// Whether an extension works on the page Site Controls is about, as its tile shows it: dimmed when it doesn't, and
/// saying why under the pointer (#215).
enum SiteExtensionAccess: Equatable {
    /// It reads this site, or never needs to: a popup of its own works anywhere.
    case runs
    /// It wants this site and gets it from a click on its button ("When You Click It").
    case onClick
    /// It wants this site and hasn't been given it.
    case blocked
    /// Extensions are off on this site.
    case offHere

    static func of(offHere: Bool, hasAccess: Bool, wantsSite: Bool, clickAccess: Bool) -> SiteExtensionAccess {
        if offHere { return .offHere }
        if hasAccess || !wantsSite { return .runs }
        return clickAccess ? .onClick : .blocked
    }

    var isDimmed: Bool { self != .runs }

    /// What its tooltip adds under its name.
    var note: String? {
        switch self {
        case .runs: nil
        case .onClick: String(localized: "Runs on this site when you click it", comment: "Tooltip line under an extension's name in Site Controls: its site access is When You Click It, and it hasn't been clicked on this site yet.")
        case .blocked: String(localized: "Can’t read this site", comment: "Tooltip line under an extension's name in Site Controls: the extension wants this site but its site access doesn't include it.")
        case .offHere: String(localized: "Extensions are off on this site", comment: "Tooltip line under an extension's name in Site Controls: the Extensions switch is off for this site.")
        }
    }
}

/// How the Extensions section of Site Controls is laid out for a number of extensions and a width: what the folded
/// header's strip holds, whether the tiles carry names, and how many show before Show All (#215).
enum SiteExtensionsLayout {
    /// A strip icon's target in the folded header, and the room between two.
    static let stripSide = Tokens.Metric.compactIconButton
    static let stripGap: CGFloat = 0
    /// The most the strip ever holds, the "+N" included: a glance, not a second grid.
    static let stripSlots = 6
    /// The header's height: the strip's icons with a little room.
    static let headerHeight = Tokens.Space.x7Height
    /// The space between the icon-only tiles of the grid.
    static let gridGap = Tokens.Space.x2
    /// Rows of the grid shown before Show All.
    static let foldedRows = 2

    /// Open until you choose: a few extensions are easy to show whole, many fold to their strip.
    static func isOpen(count: Int, chosen: Bool?) -> Bool { chosen ?? (count <= 4) }

    /// The strip in the folded header, given the room after the header's name: how many icons, and how many more the
    /// "+N" counts. All of them when they fit; otherwise one slot goes to the "+N".
    static func strip(count: Int, room: CGFloat) -> (icons: Int, more: Int) {
        guard count > 0, room > 0 else { return (0, count) }
        let fit = min(stripSlots, Int(floor((room + stripGap) / (stripSide + stripGap))))
        guard fit > 0 else { return (0, count) }
        if count <= fit { return (count, 0) }
        let icons = max(0, fit - 1)
        return (icons, count - icons)
    }

    /// A name under each icon while they all fit on one row with room for it: one, two or three extensions.
    static func named(count: Int) -> Bool { count <= 3 }

    /// The grid's columns at a width: six in the sidebar's usual lane, fewer in a narrow one.
    static func columns(width: CGFloat) -> Int { width >= 260 ? 6 : width >= 200 ? 5 : 4 }

    /// How many tiles show, and whether Show All is offered: two rows' worth until you ask for all of them.
    static func shown(count: Int, columns: Int, showsAll: Bool) -> (shown: Int, offersAll: Bool) {
        let limit = columns * foldedRows
        guard count > limit else { return (count, false) }
        return (showsAll ? count : limit, true)
    }

    /// A named tile's width: half the row for one or two, so their names show whole, a third for three; they sit at
    /// the left with no empty grid around them.
    static func namedWidth(count: Int, width: CGFloat) -> CGFloat { floor(width / CGFloat(max(2, count))) }

    /// An icon-only tile's side.
    static func side(width: CGFloat, columns: Int) -> CGFloat { floor((width - gridGap * CGFloat(columns - 1)) / CGFloat(columns)) }

    /// The grid's height for `shown` tiles.
    static func gridHeight(shown: Int, named: Bool, width: CGFloat, columns: Int) -> CGFloat {
        guard shown > 0 else { return 0 }
        if named { return PanelTile.captionedHeight }
        let rows = (shown + columns - 1) / columns
        let side = side(width: width, columns: columns)
        return CGFloat(rows) * side + CGFloat(rows - 1) * gridGap
    }
}

/// The extensions on Site Controls' first page, in reach without another page (#215). A header names them with their
/// count and folds them away; folded, it still carries a strip of their icons, each one click from its popup. Open,
/// they're a grid of tiles (named when there are only a few), two rows of them until Show All, then Manage Extensions.
/// What it remembers (open or folded, all or two rows) is the same everywhere, once chosen.
final class SiteExtensionsSection: NSView {
    struct Item {
        let id: String
        /// The extension's name, under its tile and for VoiceOver.
        let name: String
        /// What its button says it does (Chrome's action title), for the tooltip.
        let label: String
        let icon: NSImage?
        let badge: String
        let needsAttention: Bool
        let access: SiteExtensionAccess
        /// What its toolbar button does: its popup, or its action.
        let run: (NSView) -> Void
        /// Its menu: settings, site access, pinning, turning off, removing.
        let menu: () -> NSMenu?
    }

    /// Whether the section is open, as chosen; nil until it is.
    static var chosenOpen: Bool? {
        get { UserDefaults.standard.object(forKey: "SiteControlsExtensionsOpen") as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: "SiteControlsExtensionsOpen") }
    }
    /// Show All, kept as chosen.
    static var showsAll: Bool {
        get { UserDefaults.standard.bool(forKey: "SiteControlsExtensionsShowAll") }
        set { UserDefaults.standard.set(newValue, forKey: "SiteControlsExtensionsShowAll") }
    }

    let items: [Item]
    /// On a new tab the section is the whole panel: always open, every tile, nothing to fold.
    private let isWhole: Bool
    private(set) var isOpen: Bool
    private(set) var showsAll: Bool
    /// Tells the panel its height changed, folding or showing fewer (false) or opening or showing more (true).
    var onResize: ((Bool) -> Void)?

    private let header = SectionHeader()
    private let getButton = IconButton(symbol: "plus", size: .compact, toolTip: SiteExtensionsSection.getTitle)
    private let profileLabel = Label("", font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
    private var stripTiles: [PanelTile] = []
    private let stripMore = StripMore()
    private(set) var tiles: [PanelTile] = []
    private var pins: [(id: String, tile: PanelTile, pin: HoverPin)] = []
    private let showAllRow: PanelLinkRow
    private let manageRow: PanelLinkRow
    /// With no extensions yet: one quiet way to the store.
    private let getRow: PanelLinkRow

    static let title = String(localized: "Extensions", comment: "Section label in Site Controls over your extensions, which folds them away; also the title of the panel on a new tab.")
    static let getTitle = String(localized: "Get Extensions", comment: "Tooltip of the + by the Extensions section in Site Controls, and the row there when you have none: opens the Chrome Web Store.")

    /// `pinState` and `togglePin` are the address's pins, offered on each tile's corner.
    init(items: [Item], isWhole: Bool, profile: String?, get: @escaping () -> Void, manage: @escaping () -> Void) {
        self.items = items
        self.isWhole = isWhole
        isOpen = isWhole || SiteExtensionsLayout.isOpen(count: items.count, chosen: Self.chosenOpen)
        showsAll = isWhole || Self.showsAll
        showAllRow = PanelLinkRow("") {}
        manageRow = PanelLinkRow(String(localized: "Manage Extensions", comment: "Row under the extensions in Site Controls: opens Settings › Extensions."), goes: true, run: manage)
        getRow = PanelLinkRow(Self.getTitle, goes: true, run: get)
        super.init(frame: .zero)
        // Opening, the tiles are uncovered as the section grows, like a drawer, rather than spilling past it.
        clipsToBounds = true
        header.title = Self.title
        header.count = items.isEmpty ? "" : "\(items.count)"
        header.isFoldable = !isWhole
        header.isOpen = isOpen
        // Folded, the strip and its "+N" say how many; open, the count does.
        header.showsCount = isOpen
        header.onClick = { [weak self] _ in self?.toggle() }
        getButton.onClick = { _ in get() }
        profileLabel.stringValue = profile ?? ""
        profileLabel.alignment = .right
        profileLabel.lineBreakMode = .byTruncatingTail
        profileLabel.isHidden = profile == nil
        stripMore.onClick = { [weak self] _ in self?.setOpen(true) }
        showAllRow.onClick = { [weak self] _ in self?.toggleShowAll() }
        [header, profileLabel, getButton, stripMore, showAllRow, manageRow, getRow].forEach { addSubview($0) }
        let named = SiteExtensionsLayout.named(count: items.count)
        for item in items {
            let tip = [item.needsAttention ? String(localized: "\(item.name): needs attention", comment: "Tooltip of an extension's button in the site panel when the extension asks for attention. The name is the extension's.") : item.label,
                       item.access.note].compactMap { $0 }.joined(separator: "\n")
            let value = [item.needsAttention ? String(localized: "Needs attention", comment: "VoiceOver value of an extension's button in the site panel when the extension asks for attention.") : item.badge.isEmpty ? nil : item.badge,
                         item.access.note].compactMap { $0 }.joined(separator: ", ")
            func make(caption: String?, small: Bool) -> PanelTile {
                let tile = PanelTile(image: item.icon, symbol: "puzzlepiece.extension", caption: caption)
                if small { tile.iconSide = Tokens.Space.x4 }
                tile.toolTip = tip
                tile.setAccessibilityLabel(item.name)
                tile.setAccessibilityValue(value)
                // Attention first: the badge takes its look from it.
                tile.isAttention = item.needsAttention
                tile.badge = item.needsAttention ? "!" : item.badge
                tile.isDimmed = item.access.isDimmed
                tile.onClick = { [weak tile] _ in if let tile { item.run(tile) } }
                tile.onRightClick = { _ in item.menu() }
                addSubview(tile)
                return tile
            }
            let tile = make(caption: named ? item.name : nil, small: false)
            tiles.append(tile)
            let pin = HoverPin()
            pins.append((item.id, tile, pin))
            stripTiles.append(make(caption: nil, small: true))
        }
        // Over its tile.
        for entry in pins { addSubview(entry.pin) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.title)
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: Pins

    /// The address's pins on each tile's corner, as Settings and the tile's menu have them.
    func wirePins(state: @escaping (String) -> HoverPin.State, toggle: @escaping (String) -> Void, title: @escaping (String) -> String?) {
        for entry in pins {
            let id = entry.id
            entry.pin.onClick = { _ in toggle(id) }
            let update: (Bool) -> Void = { [weak tile = entry.tile, weak pin = entry.pin] _ in
                guard let tile, let pin else { return }
                pin.isWanted = tile.isHovered || tile.hasKeyboardFocus || (pin.isShowing && pin.isHovered)
            }
            entry.tile.hoverChanged = update
            entry.tile.keyboardFocusChanged = update
            entry.pin.hoverChanged = update
        }
        pinState = state
        pinToggle = toggle
        pinTitle = title
        refreshPins()
    }
    private var pinState: ((String) -> HoverPin.State)?
    private var pinToggle: ((String) -> Void)?
    private var pinTitle: ((String) -> String?)?

    /// What each pin says now. Runs on every change, from here or another window, so the limit is always the truth.
    func refreshPins() {
        guard let pinState else { return }
        for entry in pins {
            entry.pin.state = pinState(entry.id)
            let id = entry.id
            if let name = pinTitle?(id), let toggle = pinToggle, entry.pin.state != .atLimit {
                entry.tile.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: name) {
                    MainActor.assumeIsolated { toggle(id) }
                    return true
                }])
            } else {
                entry.tile.setAccessibilityCustomActions(nil)
            }
        }
        needsLayout = true
    }

    // MARK: Folding

    func toggle() { setOpen(!isOpen) }

    func setOpen(_ open: Bool) {
        guard !isWhole, open != isOpen else { return }
        isOpen = open
        Self.chosenOpen = open
        header.isOpen = open
        header.showsCount = open
        apply(animated: true, opening: open)
        onResize?(open)
    }

    private func toggleShowAll() {
        showsAll.toggle()
        Self.showsAll = showsAll
        apply(animated: true, opening: showsAll)
        onResize?(showsAll)
    }

    /// The columns at the width last laid out, before the first layout the panel's usual one.
    private var columns: Int { SiteExtensionsLayout.columns(width: column) }

    /// Which views show for the state now; those that come or go fade, in step with the panel's drawer.
    private func apply(animated: Bool, opening: Bool = true) {
        let count = items.count
        appliedColumns = columns
        appliedRoom = stripRoom
        let layout = SiteExtensionsLayout.shown(count: count, columns: columns, showsAll: showsAll)
        let strip = SiteExtensionsLayout.strip(count: count, room: stripRoom)
        var wanted: [(NSView, Bool)] = [
            (header, count > 0),
            (getButton, count > 0 && isOpen),
            (profileLabel, count > 0 && isOpen && !profileLabel.stringValue.isEmpty),
            (stripMore, count > 0 && !isOpen && strip.more > 0),
            (showAllRow, isOpen && layout.offersAll && !isWhole),
            (manageRow, count > 0 ? isOpen : isWhole),
            (getRow, count == 0),
        ]
        for (i, tile) in tiles.enumerated() { wanted.append((tile, isOpen && i < layout.shown)) }
        for (i, tile) in stripTiles.enumerated() { wanted.append((tile, !isOpen && i < strip.icons)) }
        stripMore.text = "+\(strip.more)"
        showAllRow.titleText = showsAll ? String(localized: "Show Less", comment: "Row under the extensions in Site Controls once they all show: back to two rows of them.")
            : String(localized: "Show All (\(count))", comment: "Row under two rows of extensions in Site Controls: shows every one of them. The number is how many there are.")
        let fade = Tokens.Motion.Curve(duration: Self.drawer(opening: opening).duration)
        for (view, shows) in wanted { show(view, shows, animated: animated, fade: fade) }
        for entry in pins where entry.tile.isHidden { entry.pin.isWanted = false }
        needsLayout = true
    }

    /// What comes fades in, and what goes fades out, in the drawer's time; a fade is on the house ease-out.
    private func show(_ view: NSView, _ shows: Bool, animated: Bool, fade: Tokens.Motion.Curve) {
        guard animated, window != nil, !Tokens.Motion.isFromKey else {
            view.isHidden = !shows
            view.alphaValue = 1
            return
        }
        if shows {
            // Coming, or turned around while going: from wherever it is.
            guard view.isHidden || view.alphaValue < 1 else { return }
            if view.isHidden { view.alphaValue = 0 }
            view.isHidden = false
            Tokens.Motion.animate(fade) { view.animator().alphaValue = 1 }
        } else if !view.isHidden, view.alphaValue > 0 {
            Tokens.Motion.animate(fade, { view.animator().alphaValue = 0 }) { [weak view] in
                // Shown again meanwhile: it stays.
                guard let view, view.alphaValue < 0.01 else { return }
                view.isHidden = true
                view.alphaValue = 1
            }
        }
    }

    /// What the tiles shown were chosen for: a width that turns out other once laid out chooses again.
    private var appliedColumns = 0
    private var appliedRoom: CGFloat = 0

    /// The drawer role (DESIGN.md › Motion): coming out a touch slower than going back.
    static func drawer(opening: Bool) -> Tokens.Motion.Curve { Tokens.Motion.Role.drawer.curve(entering: opening) }

    // MARK: Layout

    /// The room after the header's name and count for the strip.
    private var stripRoom: CGFloat { column - header.textWidth - Tokens.Space.x2 }

    /// How tall it is for a text column `width`, for the state it's in.
    func height(for width: CGFloat) -> CGFloat {
        let count = items.count
        guard count > 0 else { return isWhole ? PanelLinkRow.height * 2 + PanelLinkRow.gap : PanelLinkRow.height }
        let columns = SiteExtensionsLayout.columns(width: width)
        var h = SiteExtensionsLayout.headerHeight
        guard isOpen else { return h }
        let named = SiteExtensionsLayout.named(count: count)
        let layout = SiteExtensionsLayout.shown(count: count, columns: columns, showsAll: showsAll)
        h += Tokens.Space.x2 + SiteExtensionsLayout.gridHeight(shown: layout.shown, named: named, width: width, columns: columns)
        h += Tokens.Space.x2
        if layout.offersAll && !isWhole { h += PanelLinkRow.height + PanelLinkRow.gap }
        h += PanelLinkRow.height
        return h
    }

    /// The room under the last row's words, which the panel's bottom margin takes back.
    var bottomSlack: CGFloat { isOpen || items.isEmpty ? manageRow.bottomSlack : 0 }
    /// Folded, the room under the header's words inside it.
    var foldedSlack: CGFloat { (SiteExtensionsLayout.headerHeight - Label.section("E").lineHeight) / 2 }

    /// The text column: the section reaches `PanelLinkRow.outset` past it on each side, for its rows' washes.
    private var column: CGFloat { (bounds.width > 0 ? bounds.width : SitePanel.width - Tokens.Space.x8 + PanelLinkRow.outset * 2) - PanelLinkRow.outset * 2 }

    override func layout() {
        super.layout()
        let o = PanelLinkRow.outset
        let width = column
        let count = items.count
        if appliedColumns != columns || abs(appliedRoom - stripRoom) > 0.5 { apply(animated: false) }
        func row(_ r: PanelLinkRow, _ y: CGFloat) { r.frame = NSRect(x: 0, y: y, width: bounds.width, height: PanelLinkRow.height) }
        guard count > 0 else {
            row(getRow, 0)
            row(manageRow, PanelLinkRow.height + PanelLinkRow.gap)
            return
        }
        let side = SiteExtensionsLayout.stripSide
        let h = SiteExtensionsLayout.headerHeight
        header.frame = NSRect(x: o, y: 0, width: width, height: h)
        // Trailing: the strip folded; the + (and whose they are) open. The +'s glyph ends on the text column.
        let glyphInset = (side - Tokens.Symbol.compactGlyph) / 2
        getButton.frame = NSRect(x: o + width - side + glyphInset, y: (h - side) / 2, width: side, height: side)
        let room = max(0, getButton.frame.minX - Tokens.Space.x1 - (o + header.textWidth + Tokens.Space.x2))
        profileLabel.frame = NSRect(x: getButton.frame.minX - Tokens.Space.x1 - room + Label.inset, y: (h - profileLabel.lineHeight) / 2, width: room, height: profileLabel.lineHeight)
        let strip = SiteExtensionsLayout.strip(count: count, room: stripRoom)
        let slots = strip.icons + (strip.more > 0 ? 1 : 0)
        var sx = o + width - CGFloat(slots) * side - CGFloat(max(0, slots - 1)) * SiteExtensionsLayout.stripGap
        for (i, tile) in stripTiles.enumerated() {
            let shown = i < strip.icons
            tile.frame = NSRect(x: shown ? sx : o + width - side, y: (h - side) / 2, width: side, height: side)
            if shown { sx += side + SiteExtensionsLayout.stripGap }
        }
        stripMore.frame = NSRect(x: o + width - side, y: (h - side) / 2, width: side, height: side)

        // Open: the grid, Show All, Manage.
        var y = h + Tokens.Space.x2
        let columns = SiteExtensionsLayout.columns(width: width)
        let named = SiteExtensionsLayout.named(count: count)
        let layout = SiteExtensionsLayout.shown(count: count, columns: columns, showsAll: showsAll)
        if named {
            let w = SiteExtensionsLayout.namedWidth(count: count, width: width)
            for (i, tile) in tiles.enumerated() {
                tile.frame = NSRect(x: o + CGFloat(i) * w, y: y, width: w, height: PanelTile.captionedHeight)
            }
        } else {
            let s = SiteExtensionsLayout.side(width: width, columns: columns)
            let gap = SiteExtensionsLayout.gridGap
            for (i, tile) in tiles.enumerated() {
                // Past what shows, a tile waits where it will appear, so Show All brings it in place.
                tile.frame = NSRect(x: o + CGFloat(i % columns) * (s + gap), y: y + CGFloat(i / columns) * (s + gap), width: s, height: s)
            }
        }
        y += SiteExtensionsLayout.gridHeight(shown: layout.shown, named: named, width: width, columns: columns) + Tokens.Space.x2
        if layout.offersAll && !isWhole {
            row(showAllRow, y)
            y += PanelLinkRow.height + PanelLinkRow.gap
        }
        row(manageRow, y)
        for entry in pins {
            entry.pin.frame = SitePanel.pinFrame(on: entry.tile.frame, left: !entry.tile.badge.isEmpty)
            if entry.tile.isHidden { entry.pin.isHidden = true }
        }
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["open": isOpen, "showsAll": showsAll, "count": items.count,
         "strip": stripTiles.filter { !$0.isHidden }.count, "more": stripMore.isHidden ? "" : stripMore.text,
         "tiles": tiles.filter { !$0.isHidden }.count, "dimmed": zip(items, tiles).filter { $1.isDimmed }.map(\.0.name),
         "showAll": showAllRow.isHidden ? "" : showAllRow.debugTitle]
    }

    /// sitext open|fold|all|less: the header, or Show All / Show Less, as a click would.
    func debugCommand(_ arg: String) {
        switch arg {
        case "open": setOpen(true)
        case "fold": setOpen(false)
        case "all": if !showsAll { toggleShowAll() }
        case "less": if showsAll { toggleShowAll() }
        default: break
        }
    }

    /// pinhover: the pointer on a tile, or its pin, as a real pointer would put it there.
    func debugHover(_ arg: String) {
        let f = arg.split(separator: " ").map(String.init)
        for entry in pins where entry.id != f.first {
            entry.pin.isHovered = false
            entry.tile.isHovered = false
        }
        guard let entry = pins.first(where: { $0.id == f.first }) else { return }
        if f.contains("limit") { entry.pin.state = .atLimit }
        entry.tile.isHovered = true
        if f.contains("pin") { entry.pin.isHovered = true }
    }
    #endif
}

/// The Extensions section's header: its name and count in the section labels' quiet voice, and a chevron that says
/// it folds, as Effects in the space editor does. The whole row is the control.
private final class SectionHeader: InteractiveView {
    private let label = Label.section("")
    private let countLabel = Label("", font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
    private let chevron = NSImageView()
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue) }
    }
    var count = "" {
        didSet {
            countLabel.stringValue = count
            setAccessibilityLabel(count.isEmpty ? label.stringValue : "\(label.stringValue), \(count)")
            needsLayout = true
        }
    }
    var showsCount = true { didSet { countLabel.isHidden = !showsCount; needsLayout = true } }
    private var shownCount: Bool { showsCount && !count.isEmpty }
    var isOpen = false { didSet { refresh() } }
    var isFoldable = true { didSet { chevron.isHidden = !isFoldable; isEnabled = isFoldable; refresh() } }

    /// Its name, count and chevron, and no more: what's after it is the strip's.
    var textWidth: CGFloat {
        label.inkWidth + (shownCount ? Tokens.Space.x1 + countLabel.inkWidth : 0) + (isFoldable ? Tokens.Space.x1 + Tokens.Space.x4 : 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.imageScaling = .scaleNone
        [label, countLabel, chevron].forEach { addSubview($0) }
        setAccessibilityRole(.disclosureTriangle)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let lh = label.lineHeight
        label.frame = NSRect(x: -Label.inset, y: (bounds.height - lh) / 2, width: label.inkWidth + Label.inset * 2, height: lh)
        var x = label.inkWidth
        if shownCount {
            x += Tokens.Space.x1
            countLabel.frame = NSRect(x: x - Label.inset, y: (bounds.height - lh) / 2, width: countLabel.inkWidth + Label.inset * 2, height: lh)
            x += countLabel.inkWidth
        }
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: x + Tokens.Space.x1, y: (bounds.height - side) / 2, width: side, height: side)
    }

    private func refresh() {
        chevron.image = Tokens.Symbol.image(isOpen ? "chevron.down" : "chevron.right", size: Tokens.Symbol.inline)
        setAccessibilityValue(isOpen ? 1 : 0)
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        // No wash: the words step up under the pointer, as the space editor's Effects does.
        let hot = isHovered && isFoldable
        label.textColor = hot ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
        countLabel.textColor = Tokens.Color.textTertiary
        chevron.contentTintColor = hot ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
    }
}

/// "+N" at the end of the folded strip: the rest of them, a click away.
private final class StripMore: InteractiveView {
    private let label = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            toolTip = String(localized: "Show All Extensions", comment: "Tooltip of the +N at the end of the folded Extensions strip in Site Controls: opens the section.")
            setAccessibilityLabel(toolTip)
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        label.alignment = .center
        addSubview(label)
        setAccessibilityRole(.button)
        pressScales = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let lh = label.lineHeight
        label.frame = NSRect(x: -Label.inset, y: (bounds.height - lh) / 2, width: bounds.width + Label.inset * 2, height: lh)
    }

    override func stateDidChange(animated: Bool) {
        let wash: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: wash.map { cgColor($0) }, animated: false)
        label.textColor = isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
    }
}

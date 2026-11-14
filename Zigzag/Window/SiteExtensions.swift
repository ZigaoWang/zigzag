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


/// How the Extensions section of Site Controls is laid out for a number of extensions and a text column: what the
/// folded header's strip holds, whether they're rows with their names or a grid of icons, and where each goes (#215).
/// Everything stands on the panel's text column, as its rows' words do: a row's icon starts on it, the grid's first
/// icon starts on it and its last column's icon ends on its right edge, and their hover washes reach
/// `PanelLinkRow.outset` past it on each side, as a row's does.
enum SiteExtensionsLayout {
    /// A strip icon's target in the folded header, and the room between two.
    static let stripSide = Tokens.Metric.compactIconButton
    static let stripGap: CGFloat = 0
    /// The most the strip ever holds, the "+N" included: a glance, not a second grid.
    static let stripSlots = 6
    /// The header's height: the strip's icons with a little room.
    static let headerHeight = Tokens.Space.x7Height
    /// Up to this many, each is a row with its name; more, a grid of icons.
    static let listLimit = 3
    /// An icon in the grid: the size of the actions' glyphs above it.
    static let iconSide = Tokens.Space.x5
    /// A grid tile: its icon with a row's outset on each side, so the icon's edge is where a row's words would start
    /// and the hover wash reaches as far past it as a row's.
    static let tileSide = iconSide + PanelLinkRow.outset * 2
    /// The least room between two tiles' washes, as between two rows: a hovered one never touches its neighbor.
    static let minGap = PanelLinkRow.gap
    /// The most room between two rows of tiles: a grid that's wide apart across stays together down.
    static let maxRowGap = Tokens.Space.x2

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

    /// Rows with their names while there are only a few, so each says what it is; past that, a grid of icons that
    /// name themselves under the pointer.
    static func listed(count: Int) -> Bool { count <= listLimit }

    /// The grid's columns across a text column `width`: as many tiles as fit across it and its outsets, `minGap` apart.
    static func columns(width: CGFloat) -> Int {
        max(1, Int(floor((width + PanelLinkRow.outset * 2 + minGap) / (tileSide + minGap))))
    }

    /// From one column's tile to the next: the room left over is shared between them, so the last column's icon ends
    /// on the text column's right edge as the first one's starts on its left.
    static func pitch(width: CGFloat, columns: Int) -> CGFloat {
        columns > 1 ? (width + PanelLinkRow.outset * 2 - tileSide) / CGFloat(columns - 1) : tileSide
    }

    /// Between two rows of tiles: the room between columns, up to `maxRowGap`.
    static func rowGap(width: CGFloat, columns: Int) -> CGFloat {
        min(maxRowGap, max(minGap, pitch(width: width, columns: columns) - tileSide))
    }

    /// Where tile `index` goes, in the section's terms: its left edge is the text column's less the outset.
    static func tileFrame(_ index: Int, width: CGFloat) -> NSRect {
        let columns = columns(width: width)
        let pitch = pitch(width: width, columns: columns)
        let row = index / columns, column = index % columns
        return NSRect(x: (CGFloat(column) * pitch).rounded(), y: CGFloat(row) * (tileSide + rowGap(width: width, columns: columns)),
                      width: tileSide, height: tileSide)
    }

    /// How tall the extensions themselves are: their rows, or the grid's.
    static func bodyHeight(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        if listed(count: count) { return CGFloat(count) * SiteExtensionRow.height + CGFloat(count - 1) * PanelLinkRow.gap }
        let columns = columns(width: width)
        let rows = (count + columns - 1) / columns
        return CGFloat(rows) * tileSide + CGFloat(rows - 1) * rowGap(width: width, columns: columns)
    }
}

/// The extensions on Site Controls' first page, in reach without another page (#215), under a header in the panel's
/// section-label voice that folds them away. Folded, the header still carries a strip of their icons, each one click
/// from its popup. Open, a few are rows with their names and many are a grid of icons, all of them, then Manage
/// Extensions. Whether it's open is remembered everywhere, once chosen.
final class SiteExtensionsSection: NSView {
    struct Item {
        let id: String
        /// The extension's name, on its row or in its tooltip, and for VoiceOver.
        let name: String
        /// What its button says it does (Chrome's action title).
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

    let items: [Item]
    /// On a new tab the section is the whole panel: always open, nothing to fold.
    private let isWhole: Bool
    private(set) var isOpen: Bool
    /// Tells the panel its height changed, folding (false) or opening (true).
    var onResize: ((Bool) -> Void)?

    private let header = SectionHeader()
    private let profileLabel = Label("", font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
    private var stripTiles: [PanelTile] = []
    private let stripMore = StripMore()
    /// Each extension's button while open: a row, or a tile of the grid.
    private(set) var buttons: [InteractiveView] = []
    private var pins: [(id: String, button: InteractiveView, pin: HoverPin)] = []
    private let manageRow: PanelLinkRow
    /// With no extensions yet: one quiet way to the store.
    private let getRow: PanelLinkRow

    static let title = String(localized: "Extensions", comment: "Section label in Site Controls over your extensions, which folds them away; also the title of the panel on a new tab.")
    static let getTitle = String(localized: "Get Extensions", comment: "Row in the Extensions section of Site Controls when you have none: opens the Chrome Web Store.")

    init(items: [Item], isWhole: Bool, profile: String?, get: @escaping () -> Void, manage: @escaping () -> Void) {
        self.items = items
        self.isWhole = isWhole
        isOpen = isWhole || SiteExtensionsLayout.isOpen(count: items.count, chosen: Self.chosenOpen)
        manageRow = PanelLinkRow(String(localized: "Manage Extensions", comment: "Row under the extensions in Site Controls: opens Settings › Extensions."), goes: true, run: manage)
        getRow = PanelLinkRow(Self.getTitle, goes: true, run: get)
        super.init(frame: .zero)
        // Opening, the extensions are uncovered as the section grows, like a drawer, rather than spilling past it.
        clipsToBounds = true
        header.title = Self.title
        header.count = items.count
        header.isFoldable = !isWhole
        header.isOpen = isOpen
        header.onClick = { [weak self] _ in self?.toggle() }
        profileLabel.stringValue = profile ?? ""
        profileLabel.alignment = .right
        profileLabel.lineBreakMode = .byTruncatingTail
        profileLabel.isHidden = profile == nil
        stripMore.onClick = { [weak self] _ in self?.setOpen(true) }
        [header, profileLabel, stripMore, manageRow, getRow].forEach { addSubview($0) }
        let listed = SiteExtensionsLayout.listed(count: items.count)
        for item in items {
            // Its name first, always: an icon alone doesn't say whose it is. Then why it's dimmed, when it is.
            let tip = [item.needsAttention ? String(localized: "\(item.name): needs attention", comment: "Tooltip of an extension's button in the site panel when the extension asks for attention. The name is the extension's.") : item.name,
                       item.access.note].compactMap { $0 }.joined(separator: "\n")
            let value = [item.needsAttention ? String(localized: "Needs attention", comment: "VoiceOver value of an extension's button in the site panel when the extension asks for attention.") : item.badge.isEmpty ? nil : item.badge,
                         item.access.note].compactMap { $0 }.joined(separator: ", ")
            func wire(_ view: InteractiveView) {
                view.toolTip = tip
                view.setAccessibilityLabel(item.name)
                view.setAccessibilityValue(value)
                view.onClick = { [weak view] _ in if let view { item.run(view) } }
                view.onRightClick = { _ in item.menu() }
                addSubview(view)
            }
            func tile(side: CGFloat) -> PanelTile {
                let tile = PanelTile(image: item.icon, symbol: "puzzlepiece.extension", caption: nil)
                tile.iconSide = side
                // Attention first: the badge takes its look from it.
                tile.isAttention = item.needsAttention
                tile.badge = item.needsAttention ? "!" : item.badge
                tile.isDimmed = item.access.isDimmed
                wire(tile)
                return tile
            }
            let button: InteractiveView
            if listed {
                let row = SiteExtensionRow(image: item.icon, name: item.name, badge: item.needsAttention ? "!" : item.badge, attention: item.needsAttention)
                row.isDimmed = item.access.isDimmed
                wire(row)
                button = row
            } else {
                button = tile(side: SiteExtensionsLayout.iconSide)
            }
            buttons.append(button)
            pins.append((item.id, button, HoverPin()))
            stripTiles.append(tile(side: Tokens.Space.x4))
        }
        // Over its button.
        for entry in pins { addSubview(entry.pin) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.title)
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: Pins

    /// The address's pins on each extension's button, as Settings and its menu have them.
    func wirePins(state: @escaping (String) -> HoverPin.State, toggle: @escaping (String) -> Void, title: @escaping (String) -> String?) {
        for entry in pins {
            let id = entry.id
            entry.pin.onClick = { _ in toggle(id) }
            let update: (Bool) -> Void = { [weak button = entry.button, weak pin = entry.pin] _ in
                guard let button, let pin else { return }
                pin.isWanted = button.isHovered || button.hasKeyboardFocus || (pin.isShowing && pin.isHovered)
            }
            entry.button.hoverChanged = update
            entry.button.keyboardFocusChanged = update
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
                entry.button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: name) {
                    MainActor.assumeIsolated { toggle(id) }
                    return true
                }])
            } else {
                entry.button.setAccessibilityCustomActions(nil)
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
        apply(animated: true, opening: open)
        onResize?(open)
    }

    /// Which views show for the state now; those that come or go fade, in step with the panel's drawer.
    private func apply(animated: Bool, opening: Bool = true) {
        let count = items.count
        appliedRoom = stripRoom
        let strip = SiteExtensionsLayout.strip(count: count, room: stripRoom)
        var wanted: [(NSView, Bool)] = [
            (header, count > 0),
            (profileLabel, count > 0 && isOpen && !profileLabel.stringValue.isEmpty),
            (stripMore, count > 0 && !isOpen && strip.more > 0),
            (manageRow, count > 0 ? isOpen : isWhole),
            (getRow, count == 0),
        ]
        for button in buttons { wanted.append((button, isOpen)) }
        for (i, tile) in stripTiles.enumerated() { wanted.append((tile, !isOpen && i < strip.icons)) }
        stripMore.text = "+\(strip.more)"
        let fade = Tokens.Motion.Curve(duration: Self.drawer(opening: opening).duration)
        for (view, shows) in wanted { show(view, shows, animated: animated, fade: fade) }
        for entry in pins where !isOpen { entry.pin.isWanted = false }
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

    /// The strip's room the views shown were chosen for: a width that turns out other once laid out chooses again.
    private var appliedRoom: CGFloat = 0

    /// The drawer role (DESIGN.md › Motion): coming out a touch slower than going back.
    static func drawer(opening: Bool) -> Tokens.Motion.Curve { Tokens.Motion.Role.drawer.curve(entering: opening) }

    // MARK: Layout

    /// The room after the header's name and chevron for the strip.
    private var stripRoom: CGFloat { column - header.textWidth - Tokens.Space.x2 }

    /// How tall it is for a text column `width`, for the state it's in.
    func height(for width: CGFloat) -> CGFloat {
        let count = items.count
        guard count > 0 else { return isWhole ? PanelLinkRow.height * 2 + PanelLinkRow.gap : PanelLinkRow.height }
        let h = SiteExtensionsLayout.headerHeight
        guard isOpen else { return h }
        return h + SiteExtensionsLayout.bodyHeight(count: count, width: width) + Tokens.Space.x2 + PanelLinkRow.height
    }

    /// The room under the last row's words, which the panel's bottom margin takes back.
    var bottomSlack: CGFloat { isOpen || items.isEmpty ? manageRow.bottomSlack : 0 }
    /// Folded, the room under the header's words inside it.
    var foldedSlack: CGFloat { (SiteExtensionsLayout.headerHeight - Label.section("E").lineHeight) / 2 }

    /// The text column: the section reaches `PanelLinkRow.outset` past it on each side, for its washes.
    private var column: CGFloat { (bounds.width > 0 ? bounds.width : SitePanel.width - Tokens.Space.x8 + PanelLinkRow.outset * 2) - PanelLinkRow.outset * 2 }

    override func layout() {
        super.layout()
        let o = PanelLinkRow.outset
        let width = column
        let count = items.count
        if abs(appliedRoom - stripRoom) > 0.5 { apply(animated: false) }
        func row(_ r: NSView, _ y: CGFloat) { r.frame = NSRect(x: 0, y: y, width: bounds.width, height: PanelLinkRow.height) }
        guard count > 0 else {
            row(getRow, 0)
            row(manageRow, PanelLinkRow.height + PanelLinkRow.gap)
            return
        }
        let side = SiteExtensionsLayout.stripSide
        let h = SiteExtensionsLayout.headerHeight
        header.frame = NSRect(x: o, y: 0, width: width, height: h)
        // Trailing, on the text column's end: the strip folded; whose they are, open.
        let room = max(0, width - header.textWidth - Tokens.Space.x2)
        profileLabel.frame = NSRect(x: o + width - room + Label.inset, y: (h - profileLabel.lineHeight) / 2, width: room, height: profileLabel.lineHeight)
        let strip = SiteExtensionsLayout.strip(count: count, room: stripRoom)
        let slots = strip.icons + (strip.more > 0 ? 1 : 0)
        var sx = o + width - CGFloat(slots) * side - CGFloat(max(0, slots - 1)) * SiteExtensionsLayout.stripGap
        for (i, tile) in stripTiles.enumerated() {
            let shown = i < strip.icons
            tile.frame = NSRect(x: shown ? sx : o + width - side, y: (h - side) / 2, width: side, height: side)
            if shown { sx += side + SiteExtensionsLayout.stripGap }
        }
        stripMore.frame = NSRect(x: o + width - side, y: (h - side) / 2, width: side, height: side)

        // Open: the extensions, then Manage.
        let top = h
        if SiteExtensionsLayout.listed(count: count) {
            for (i, button) in buttons.enumerated() {
                button.frame = NSRect(x: 0, y: top + CGFloat(i) * (SiteExtensionRow.height + PanelLinkRow.gap), width: bounds.width, height: SiteExtensionRow.height)
            }
        } else {
            for (i, button) in buttons.enumerated() {
                button.frame = SiteExtensionsLayout.tileFrame(i, width: width).offsetBy(dx: 0, dy: top)
            }
        }
        row(manageRow, top + SiteExtensionsLayout.bodyHeight(count: count, width: width) + Tokens.Space.x2)
        for entry in pins {
            if let row = entry.button as? SiteExtensionRow {
                entry.pin.frame = row.pinFrame.offsetBy(dx: row.frame.minX, dy: row.frame.minY)
            } else if let tile = entry.button as? PanelTile {
                entry.pin.frame = SitePanel.pinFrame(on: tile.frame, left: !tile.badge.isEmpty)
            }
            if entry.button.isHidden { entry.pin.isHidden = true }
        }
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["open": isOpen, "count": items.count, "listed": SiteExtensionsLayout.listed(count: items.count),
         "strip": stripTiles.filter { !$0.isHidden }.count, "more": stripMore.isHidden ? "" : stripMore.text,
         "shown": buttons.filter { !$0.isHidden }.count,
         "dimmed": zip(items, buttons).filter { ($1 as? PanelTile)?.isDimmed ?? ($1 as? SiteExtensionRow)?.isDimmed ?? false }.map(\.0.name)]
    }

    /// sitext open|fold: the header, as a click would.
    func debugCommand(_ arg: String) {
        switch arg {
        case "open": setOpen(true)
        case "fold": setOpen(false)
        default: break
        }
    }

    /// pinhover: the pointer on an extension, or its pin, as a real pointer would put it there.
    func debugHover(_ arg: String) {
        let f = arg.split(separator: " ").map(String.init)
        for entry in pins where entry.id != f.first {
            entry.pin.isHovered = false
            entry.button.isHovered = false
        }
        guard let entry = pins.first(where: { $0.id == f.first }) else { return }
        if f.contains("limit") { entry.pin.state = .atLimit }
        entry.button.isHovered = true
        if f.contains("pin") { entry.pin.isHovered = true }
    }
    #endif
}

/// One extension as a row, while there are only a few: its icon on the panel's text column, with its badge on the
/// icon's corner as the address draws it, and its name after it. The row is its button, with the panel's row washes;
/// its pin comes up at the trailing end, as a row's delete does. One that doesn't work on the site is faded, and says
/// why under the pointer.
final class SiteExtensionRow: InteractiveView {
    static let height = PanelLinkRow.height
    private let iconView = NSImageView()
    private let title: Label
    var isDimmed = false { didSet { stateDidChange(animated: false) } }

    init(image: NSImage?, name: String, badge: String, attention: Bool) {
        title = Label(name, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        title.lineBreakMode = .byTruncatingTail
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        iconView.image = image ?? Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.Symbol.row)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Tokens.Color.icon
        [iconView, title].forEach { addSubview($0) }
        if !badge.isEmpty {
            // The address's pill, hanging off the icon's corner as on a captioned tile.
            let view = BadgeView(text: badge, attention: attention)
            view.inset = PanelTile.iconBadgeInset
            iconView.addSubview(view)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    var debugName: String { title.stringValue }
    #endif

    /// Where its pin goes, in its own terms: the chip's edge on the text column's end, in the middle of the row.
    var pinFrame: NSRect {
        let side = Tokens.Sidebar.hoverPin, chip = Tokens.Sidebar.hoverPinChip
        let margin = (side - chip) / 2
        return NSRect(x: bounds.width - PanelLinkRow.outset - chip - margin, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func layout() {
        super.layout()
        let side = Tokens.Metric.favicon
        let x = PanelLinkRow.outset
        iconView.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
        let textX = x + side + Tokens.Space.x2
        // Short of the pin, so the name never runs under it.
        let right = pinFrame.minX - Tokens.Space.x1
        title.frame = NSRect(x: textX - Label.inset, y: (bounds.height - title.lineHeight) / 2, width: max(0, right - textX + Label.inset * 2), height: title.lineHeight)
        iconView.subviews.forEach { $0.needsLayout = true }
    }

    override func stateDidChange(animated: Bool) {
        applyRowStyle(animated: animated)
        let faded = !isEnabled || isDimmed
        iconView.alphaValue = faded ? Tokens.Opacity.disabled : 1
        title.alphaValue = faded ? Tokens.Opacity.disabled : 1
    }
}

/// The Extensions section's header: its name in the panel's section-label voice, and a chevron that says it folds,
/// as Effects in the space editor does. The whole row is the control, and the one way to show or hide them all.
private final class SectionHeader: InteractiveView {
    private let label = Label.section("")
    private let chevron = NSImageView()
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; refreshAccessibility() }
    }
    /// How many: for VoiceOver. On screen, the strip or the extensions themselves say it.
    var count = 0 { didSet { refreshAccessibility() } }
    var isOpen = false { didSet { refresh() } }
    var isFoldable = true { didSet { chevron.isHidden = !isFoldable; isEnabled = isFoldable; refresh() } }

    /// Its name and chevron, and no more: what's after it is the strip's.
    var textWidth: CGFloat { label.inkWidth + (isFoldable ? Tokens.Space.x1 + Tokens.Space.x4 : 0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.imageScaling = .scaleNone
        [label, chevron].forEach { addSubview($0) }
        setAccessibilityRole(.disclosureTriangle)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshAccessibility() {
        setAccessibilityLabel(count > 0 ? "\(label.stringValue), \(count)" : label.stringValue)
    }

    override func layout() {
        super.layout()
        let lh = label.lineHeight
        label.frame = NSRect(x: -Label.inset, y: (bounds.height - lh) / 2, width: label.inkWidth + Label.inset * 2, height: lh)
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: label.inkWidth + Tokens.Space.x1, y: (bounds.height - side) / 2, width: side, height: side)
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

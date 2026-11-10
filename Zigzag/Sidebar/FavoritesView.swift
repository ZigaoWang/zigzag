import AppKit

/// Favorites: a grid of icon tiles under the address, the same in every space.
final class FavoritesView: NSView {
    var onOpen: ((Bookmark) -> Void)?
    var onMenu: ((Bookmark) -> NSMenu?)?
    /// The × on an open favorite: unloads its page, the favorite stays.
    var onClose: ((Bookmark) -> Void)?
    private var tiles: [FavoriteTile] = []
    #if DEBUG
    func debugTiles() -> [(String, NSRect)] {
        guard let window else { return [] }
        return tiles.map { tile in
            ("fav:" + [tile.bookmark?.title, tile.partner?.title].compactMap { $0 }.joined(separator: "|"),
             tile.convert(tile.bounds, to: nil).flippedIn(window))
        }
    }
    #endif

    /// The first favorite: an empty tile in the empty grid shows where it will be.
    private let dropTile = FavoriteTile(bookmark: nil)
    /// Where a tab carried over the grid would go between tiles, as the tab list shows it with a line.
    private let dropBar = ColorView(color: Tokens.Color.accent)
    /// While a tab or pinned page is carried over the grid. As in the tab list, nothing moves: a bar shows where it
    /// would go, and the middle of a tile offers to open the two side by side as one favorite.
    var isDropTarget = false {
        didSet {
            guard oldValue != isDropTarget else { return }
            if !isDropTarget {
                dropIndex = nil
                showSplit(nil)
                dropBar.isHidden = true
            }
            dropTile.isHidden = !(isDropTarget && tiles.isEmpty)
            if tiles.isEmpty {
                onHeightChange?()
                relayout(gliding: false)
            }
        }
    }
    /// Where among the tiles it would land; nil: at the end.
    private(set) var dropIndex: Int?
    /// The favorite whose middle it's over, and on which side it would open.
    private(set) var splitTarget: (id: UUID, onRight: Bool)?

    /// Carried over the grid at this point (in window coordinates). `carrying`: what's carried, as one side of a
    /// split (nil: it can't open beside a favorite).
    func hoverDrop(at windowPoint: NSPoint, carrying: TabManager.SplitSide?) {
        aim(at: convert(windowPoint, from: nil), carried: carrying, moving: nil)
    }

    /// Where something carried over the grid would go, from a point in this view: beside a favorite as a split, or
    /// between two. `moving`: a favorite of this grid being moved, which stays where it is meanwhile.
    private func aim(at point: NSPoint, carried: TabManager.SplitSide?, moving: FavoriteTile?) {
        guard !tiles.isEmpty else { dropIndex = 0; return }
        // Most of a tile, away from its edges, is for a split.
        let middle = tiles.first { tile in
            guard tile !== moving, let carried, tile.frame.insetBy(dx: tile.frame.width * 0.2, dy: tile.frame.height * 0.2).contains(point) else { return false }
            return TabManager.canSplit(carried, onto: TabManager.SplitSide(kind: .favorite, inSplit: tile.partner != nil))
        }
        if let middle, let id = middle.bookmark?.id {
            showSplit((id, point.x > middle.frame.midX))
            dropBar.isHidden = true
            return
        }
        showSplit(nil)
        // The row of tiles at the pointer's height, and the slot in it by which tiles' middles it's past.
        let row = tiles.filter { point.y >= $0.frame.minY - Tokens.Space.x2 / 2 }.last.map { $0.frame.minY }
        let rowStart = tiles.firstIndex { $0.frame.minY == row } ?? 0
        dropIndex = rowStart + tiles[rowStart...].prefix { $0.frame.minY == row && $0.frame.midX < point.x }.count
        // Next to where the carried favorite already is, it wouldn't move: no bar.
        if let moving, let from = tiles.firstIndex(where: { $0 === moving }), dropIndex == from || dropIndex == from + 1 {
            dropBar.isHidden = true
            return
        }
        placeBar(at: dropIndex ?? tiles.count)
    }

    private func clearAim() {
        dropIndex = nil
        showSplit(nil)
        dropBar.isHidden = true
    }

    private func showSplit(_ target: (id: UUID, onRight: Bool)?) {
        splitTarget = target
        for tile in tiles { tile.splitSide = tile.bookmark?.id == target?.id ? (target?.onRight == true ? 1 : 0) : nil }
    }

    /// The bar in the gap before tile `index` (after the last one for the end), the height of its row.
    private func placeBar(at index: Int) {
        let gap = Tokens.Space.x2
        let x: CGFloat, row: NSRect
        if index < tiles.count {
            row = tiles[index].frame
            let previous = index > 0 ? tiles[index - 1].frame : nil
            x = previous.map { $0.minY == row.minY ? ($0.maxX + row.minX) / 2 : row.minX - gap / 2 } ?? row.minX - gap / 2
        } else {
            row = tiles.last?.frame ?? .zero
            x = row.maxX + gap / 2
        }
        let width: CGFloat = 2
        Tokens.Motion.withoutAnimation {
            dropBar.frame = NSRect(x: min(max(x - width / 2, 0), bounds.width - width), y: row.minY + 6, width: width, height: row.height - 12)
        }
        dropBar.isHidden = false
        addSubview(dropBar, positioned: .above, relativeTo: nil)
    }

    var onHeightChange: (() -> Void)?
    /// A tile is being carried: where the pointer is, in screen points. Returns true while it's over the tab list,
    /// where it would become a tab again.
    var onDragMove: ((Bookmark, NSPoint) -> Bool)?
    /// Dropped somewhere outside the grid: whether that did something, and the row it became, to land on.
    var onDrop: ((Bookmark, NSPoint) -> (handled: Bool, landing: NSView?))?
    /// The drag is over, dropped or called off with Esc (true).
    var onDragEnd: ((Bool) -> Void)?
    var onReorder: ((Bookmark, Int) -> Void)?
    /// A favorite dropped on another's middle: the two become one, side by side (`onRight`: the carried one right).
    var onJoin: ((Bookmark, UUID, Bool) -> Void)?

    static let tileHeight = Tokens.Sidebar.favoriteHeight

    /// How many favorites to a row, a setting: 0 for as many as fit (`Sidebar.favoriteMinWidth`), or 2, 3 or 4.
    static var perRow: Int {
        get { UserDefaults.standard.integer(forKey: "FavoritesPerRow") }
        set {
            UserDefaults.standard.set(newValue, forKey: "FavoritesPerRow")
            NotificationCenter.default.post(name: perRowChanged, object: nil)
        }
    }
    static let perRowChanged = Notification.Name("FavoritesPerRowChanged")
    static let perRowChoices = [0, 2, 3, 4]

    /// The columns a grid this wide has for this many favorites: the chosen count, or, on Automatic, rows that look
    /// whole. As few columns as fill every row, so tiles stay large; failing that, a last row of at least two, never
    /// one tile left on its own. Tiles may narrow from their comfortable width to their tightest for that: four at the
    /// usual width sit in one row rather than three and a lone one.
    static func columns(for width: CGFloat, count: Int) -> Int {
        if perRow > 0 { return perRow }
        let gap = Tokens.Sidebar.favoriteGap
        func fitting(_ tile: CGFloat) -> Int { min(max(Int((width + gap) / (tile + gap)), 2), Tokens.Sidebar.favoriteMaxColumns) }
        let roomy = fitting(Tokens.Sidebar.favoriteMinWidth), tight = max(roomy, fitting(Tokens.Sidebar.favoriteTightWidth))
        guard count > roomy else { return roomy }
        if let whole = (roomy...tight).first(where: { count % $0 == 0 }) { return whole }
        // Then fewer, larger columns; when every count leaves one over (13 does), the roomy one.
        return (roomy...tight).first { count % $0 != 1 } ?? (2..<roomy).reversed().first { count % $0 != 1 } ?? roomy
    }

    /// The setting changing: the tiles glide to their new rows and widths, and the sidebar makes room.
    private var perRowObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dropTile.isHidden = true
        dropTile.isPlaceholder = true
        addSubview(dropTile)
        dropBar.wantsLayer = true
        dropBar.layer?.cornerRadius = 1
        dropBar.isHidden = true
        addSubview(dropBar)
        perRowObserver = NotificationCenter.default.addObserver(forName: Self.perRowChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onHeightChange?()
                self.relayout(gliding: true)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var tileCount: Int { tiles.count + (isDropTarget && tiles.isEmpty ? 1 : 0) }

    /// How tall the grid is at its own width.
    var preferredHeight: CGFloat { preferredHeight(for: bounds.width) }

    /// How tall the grid is at a width: its rows of tiles and the gaps between them.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard tileCount > 0 else { return 0 }
        let columns = Self.columns(for: width, count: tileCount)
        let rows = (tileCount + columns - 1) / columns
        return CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Tokens.Sidebar.favoriteGap
    }

    /// One tile per favorite; a split favorite's two pages share one, each half opening its own page.
    func reload(favorites: [(Bookmark, partner: Bookmark?)], openIDs: Set<UUID>, selectedID: UUID?, tabs: [UUID: Tab] = [:]) {
        if tiles.map({ [$0.bookmark?.id, $0.partner?.id] }) != favorites.map({ [$0.0.id, $0.partner?.id] }) {
            // The tiles that stay are the same tiles, gliding to their new places; a new one fades in where it lands
            // and one that's gone fades out where it was.
            let animated = window != nil && !tiles.isEmpty && !Tokens.Motion.isFromKey
            var kept: [[UUID?]: FavoriteTile] = [:]
            for tile in tiles { kept[[tile.bookmark?.id, tile.partner?.id]] = tile }
            let wanted = Set(favorites.map { [$0.0.id, $0.partner?.id] as [UUID?] })
            for (key, tile) in kept where !wanted.contains(key) {
                kept[key] = nil
                guard animated else { tile.removeFromSuperview(); continue }
                Tokens.Motion.animate(Tokens.Motion.feedback, { tile.animator().alphaValue = 0 }, completion: { tile.removeFromSuperview() })
            }
            tiles = favorites.map { favorite, partner in
                if let tile = kept[[favorite.id, partner?.id]] { return tile }
                let tile = FavoriteTile(bookmark: favorite, partner: partner)
                // Each reads the tile's favorite when it happens, never the one it was made with.
                tile.onClick = { [weak self, weak tile] event in
                    guard let self, let tile, let favorite = tile.bookmark else { return }
                    let onRight = tile.convert(event.locationInWindow, from: nil).x > tile.bounds.midX
                    self.onOpen?(onRight ? tile.partner ?? favorite : favorite)
                }
                tile.onRightClick = { [weak self, weak tile] _ in tile?.bookmark.flatMap { self?.onMenu?($0) } }
                tile.onClose = { [weak self, weak tile] in if let favorite = tile?.bookmark { self?.onClose?(favorite) } }
                tile.onMiddleClick = tile.onClose
                tile.onDragStart = { [weak self, weak tile] event in
                    guard let self, let tile, let favorite = tile.bookmark else { return false }
                    self.drag(tile, favorite: favorite, event: event)
                    return true
                }
                addSubview(tile)
                if animated {
                    tile.alphaValue = 0
                    DispatchQueue.main.async { Tokens.Motion.animate(Tokens.Motion.feedback) { tile.animator().alphaValue = 1 } }
                }
                return tile
            }
            relayout(gliding: animated)
        }
        for (tile, favorite) in zip(tiles, favorites) { tile.update(favorite.0, partner: favorite.partner) }
        for tile in tiles {
            guard let id = tile.bookmark?.id else { continue }
            let ids = [id] + (tile.partner.map { [$0.id] } ?? [])
            tile.isSelected = selectedID.map(ids.contains) ?? false
            tile.isOpen = ids.contains(where: openIDs.contains)
            tile.track(tabs[id])
            tile.refreshIcon()
        }
    }

    /// While ⌘ is held: each tile's number, by its favorite (the left page's, for a split one). Empty: none.
    func showNumbers(_ numbers: [UUID: Int]) {
        for tile in tiles { tile.number = tile.bookmark.flatMap { numbers[$0.id] } }
    }

    /// The tile showing a favorite (either page of a split one).
    func tile(for bookmarkID: UUID) -> NSView? { tiles.first { $0.bookmark?.id == bookmarkID || $0.partner?.id == bookmarkID } }

    /// Picks the tile up, as a row in the tab list is: it stays in its place, faint, and a see-through copy follows
    /// the pointer. Over the grid a bar shows where it would go, and the middle of another favorite offers to open
    /// the two side by side as one. Off the grid (the tab list, a space's dot) it's handed on; over the tab list the
    /// copy turns into the row it would be there.
    private func drag(_ tile: FavoriteTile, favorite: Bookmark, event: NSEvent) {
        guard let window, let from = tiles.firstIndex(where: { $0 === tile }) else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let row = CarriedRow(favorite, icon: tile.iconImage, partner: tile.partner, partnerIcon: tile.partnerIconImage)
        let rowSize = NSSize(width: bounds.width, height: Tokens.Sidebar.rowHeight)
        // As a row it's held just past its icon, as if it had been picked up there.
        let rowGrab = NSPoint(x: Tokens.Sidebar.rowInset + Tokens.Sidebar.favicon + Tokens.Space.x1, y: rowSize.height / 2)
        let copy = CarriedCopy(of: tile, picture: CarriedCopy.picture(of: tile), grabbedAt: start, ground: Tokens.Color.panelBackground,
                               radius: Tokens.Sidebar.favoriteRadius, alternate: (row, rowSize, rowGrab, Tokens.Sidebar.rowRadius))
        tile.alphaValue = CarriedCopy.faint
        copy.lift()
        let carried = TabManager.SplitSide(kind: .favorite, inSplit: tile.partner != nil)
        var last = start
        var inside = true
        let released = CarriedCopy.track(in: window) { event in
            last = window.convertPoint(toScreen: event.locationInWindow)
            copy.follow(last)
            let local = self.convert(window.convertPoint(fromScreen: last), from: nil)
            inside = self.bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(local)
            if inside { self.aim(at: local, carried: carried, moving: tile) } else { self.clearAim() }
            copy.showsAlternate = self.onDragMove?(favorite, last) ?? false
        }
        let split = splitTarget, index = dropIndex
        clearAim()
        var landing: NSView? = tile
        if released == nil {
            copy.showsAlternate = false
        } else if inside {
            if let split {
                onJoin?(favorite, split.id, split.onRight)
            } else {
                // The bar counts the carried favorite where it is; past it, everything is one place earlier.
                var slot = index ?? from
                if slot > from { slot -= 1 }
                if slot != from { onReorder?(favorite, slot) }
            }
            copy.showsAlternate = false
            layoutSubtreeIfNeeded()
            landing = self.tile(for: favorite.id)
        } else if let dropped = onDrop?(favorite, last), dropped.handled {
            landing = dropped.landing
        } else {
            copy.showsAlternate = false
        }
        onDragEnd?(released == nil)
        tile.alphaValue = 1
        copy.land(on: landing)
    }

    /// While true, tiles already in place slide to their new places instead of jumping there.
    private var glides = false

    private func relayout(gliding: Bool) {
        glides = gliding && window != nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        glides = false
    }

    override func layout() {
        super.layout()
        var all = tiles
        if isDropTarget, tiles.isEmpty { all.append(dropTile) }
        let gap = Tokens.Sidebar.favoriteGap
        // As many columns as fit or were chosen, every tile one size, a shorter last row from the left. A lone
        // favorite is never wider than two would be: half the row, not a long bar around a small icon.
        let columns = max(2, min(Self.columns(for: bounds.width, count: all.count), all.count))
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        for (i, tile) in all.enumerated() {
            let row = i / columns, column = i % columns
            let frame = NSRect(x: (width + gap) * CGFloat(column), y: (Self.tileHeight + gap) * CGFloat(row),
                               width: width, height: Self.tileHeight).integral
            if glides, tile !== dropTile, tile.frame.width > 0, tile.frame.size == frame.size {
                Tokens.Motion.glide(tile, to: frame)
            } else if glides, tile !== dropTile, tile.frame.width > 0, !Tokens.Motion.reduceMotion {
                // A row gaining or losing a column: the tiles change width as they move, in the same stride.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Tokens.Motion.standard
                    context.timingFunction = Tokens.Motion.easeInOut
                    tile.animator().frame = frame
                }
            } else {
                tile.frame = frame
            }
        }
    }
}

/// A favorite: a soft gray tile with the site's icon, or a split's two icons side by side.
final class FavoriteTile: InteractiveView {
    /// The favorite as it is now: renamed or moved to another address, the same tile shows and opens the new one.
    private(set) var bookmark: Bookmark?
    /// A split favorite's right page, shown beside the left one in the same tile.
    private(set) var partner: Bookmark?
    private let icon = FaviconView()
    private let partnerIcon = FaviconView()
    /// While a tab is held over this tile's middle: the half it would open in, as a tab row shows it.
    private let dropHalf = ColorView()
    /// 0: would open on the left, 1: on the right, nil: not a split target.
    var splitSide: Int? {
        didSet {
            guard oldValue != splitSide else { return }
            needsLayout = true
            dropHalf.isHidden = splitSide == nil
        }
    }
    /// Its page is open in the background: a fine edge, so you can tell at a glance which are loaded.
    var isOpen = false { didSet { if oldValue != isOpen { stateDidChange(animated: false) } } }
    override var pressSinks: Bool { get { true } set {} }
    var iconImage: NSImage? { icon.image }
    var partnerIconImage: NSImage? { partnerIcon.image }
    var onClose: (() -> Void)?
    /// Shown under the pointer on every favorite that's open, the one you're on too, as a tab's is: a small ×
    /// tucked into the tile's top-right corner, clear of the icon even four to a row, and never past the tile's edge.
    private static let closeSide = Tokens.Sidebar.favoriteClose
    /// From the tile's top and right edges to the button: inside the tile's rounded corner, not on it.
    private static let closeInset = Tokens.Sidebar.favoriteCloseInset
    private lazy var closeButton: IconButton = {
        let button = IconButton(symbol: "xmark", size: Self.closeSide, symbolSize: Tokens.Sidebar.favoriteCloseGlyph, toolTip: String(localized: "Unload Page", comment: "Tooltip of a favorite's close button: unloads its page; the favorite stays."))
        button.tint = Tokens.Color.textSecondary
        button.wantsLayer = true
        button.radius = Self.closeSide / 2
        // A small solid chip with a hairline, so the mark reads cleanly on any icon or tile behind it.
        button.showsFillAtRest = true
        button.layer?.borderWidth = Tokens.Metric.hairline
        button.layer?.borderColor = cgColor(Tokens.Color.controlEdge)
        button.onClick = { [weak self] _ in self?.onClose?() }
        button.isHidden = true
        addSubview(button)
        return button
    }()
    /// While its page plays sound, or is muted: a speaker in the top-left corner, the chip the × is, as a tab's row
    /// has one beside its title. Clicking it mutes the page, or unmutes it.
    private lazy var audioButton: IconButton = {
        let button = IconButton(symbol: "speaker.wave.2", size: Self.closeSide, symbolSize: Tokens.Sidebar.favoriteCloseGlyph,
                                toolTip: String(localized: "Mute Tab", comment: "Tooltip of the speaker on a favorite whose page plays sound."))
        button.tint = Tokens.Color.textSecondary
        button.wantsLayer = true
        button.radius = Self.closeSide / 2
        button.showsFillAtRest = true
        button.layer?.borderWidth = Tokens.Metric.hairline
        button.layer?.borderColor = cgColor(Tokens.Color.controlEdge)
        button.onClick = { [weak self] _ in
            guard let tab = self?.tab else { return }
            tab.setMuted(!tab.isMuted)
        }
        button.isHidden = true
        addSubview(button)
        return button
    }()

    private func refreshAudio() {
        let shows = tab.map { $0.isPlayingAudio || $0.isMuted } ?? false
        guard shows || !audioButton.isHidden else { return }
        audioButton.isHidden = !shows
        let muted = tab?.isMuted == true
        audioButton.symbol = muted ? "speaker.slash" : "speaker.wave.2"
        audioButton.toolTip = muted ? String(localized: "Unmute Tab", comment: "Tooltip of the speaker on a favorite whose page is muted.")
            : String(localized: "Mute Tab", comment: "Tooltip of the speaker on a favorite whose page plays sound.")
        needsLayout = true
    }

    /// While ⌘ is held: the number that opens it with ⌘, in the corner its × uses (the × steps aside meanwhile).
    var number: Int? {
        didSet {
            guard oldValue != number else { return }
            if let number {
                let hint = numberHint ?? NumberHintView()
                if numberHint == nil { numberHint = hint; addSubview(hint) }
                hint.number = number
                layoutNumber()
                hint.show(true)
            } else {
                numberHint?.show(false)
            }
            stateDidChange(animated: false)
        }
    }
    private var numberHint: NumberHintView?
    private weak var tab: Tab?
    private var tabToken: SignalToken?
    /// An icon that arrives later (fetched, or saved by a visit) shows at once, not only after a relaunch.
    private var iconToken: SignalToken?
    var isPlaceholder = false { didSet { icon.isHidden = isPlaceholder; stateDidChange(animated: false) } }

    init(bookmark: Bookmark?, partner: Bookmark? = nil) {
        self.bookmark = bookmark
        self.partner = partner
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Sidebar.favoriteRadius
        layer?.cornerCurve = .continuous
        addSubview(icon)
        partnerIcon.isHidden = partner == nil
        addSubview(partnerIcon)
        dropHalf.wantsLayer = true
        dropHalf.layer?.cornerRadius = Tokens.Sidebar.favoriteRadius - Tokens.Metric.dropInset
        dropHalf.layer?.cornerCurve = .continuous
        dropHalf.layer?.borderWidth = Tokens.Metric.dropEdge
        dropHalf.isHidden = true
        addSubview(dropHalf, positioned: .below, relativeTo: icon)
        setAccessibilityRole(.button)
        describe()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The same favorite, changed (renamed, another address): its name and icon follow.
    func update(_ bookmark: Bookmark, partner: Bookmark?) {
        let changed = bookmark != self.bookmark || partner != self.partner
        self.bookmark = bookmark
        self.partner = partner
        if changed { describe() }
    }

    private func describe() {
        let name = Words.list([bookmark?.title, partner?.title].compactMap { $0 })
        toolTip = name
        setAccessibilityLabel(name)
        refreshIcon()
        // Only its own sites' icons arriving redraw it.
        let keys = Set([bookmark?.url, partner?.url].compactMap { FaviconStore.shared.iconKey(for: $0) })
        iconToken = FaviconStore.shared.updated.observe { [weak self] key in
            guard let self, keys.contains(key), self.tab?.favicon == nil || self.tab?.isLoading != true else { return }
            self.refreshIcon()
        }
    }

    /// Follows the favorite's page, so the tile shows the loading ribbon while it loads, like a tab does.
    func track(_ tab: Tab?) {
        guard tab !== self.tab else { return }
        self.tab = tab
        tabToken = tab?.changed.observe { [weak self] change in
            if change == .loading || change == .favicon { self?.refreshLoading() }
            if change == .audio || change == .webView { self?.refreshAudio() }
        }
        refreshLoading()
        refreshAudio()
    }

    private func refreshLoading() {
        icon.isLoading = (tab?.isLoading ?? false) && !(tab?.isSuspended ?? true)
        if let favicon = tab?.favicon, !(tab?.isLoading ?? false) { icon.image = favicon; needsLayout = true }
    }

    func refreshIcon() {
        guard let bookmark else { return }
        if let partner {
            if let image = FaviconStore.shared.cachedIcon(for: partner.url) { partnerIcon.image = image } else { FaviconStore.shared.prefetch(for: partner.url) }
        }
        if let image = FaviconStore.shared.cachedIcon(for: bookmark.url) {
            icon.image = image
            needsLayout = true
        } else {
            FaviconStore.shared.prefetch(for: bookmark.url)
        }
    }

    override func layout() {
        super.layout()
        refreshCardShadowPath()
        // Big enough to read at a glance when the site gives a sharp icon; a small one stays at a tab's 16pt rather
        // than being stretched and blurred.
        let inset = Tokens.Metric.dropInset
        dropHalf.frame = NSRect(x: splitSide == 1 ? bounds.midX : inset, y: inset, width: bounds.width / 2 - inset, height: bounds.height - inset * 2)
        dropHalf.color = Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropAlpha)
        dropHalf.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
        if partner != nil {
            // A split: both pages' icons side by side, at a tab's size. In the narrowest tiles they move closer, then
            // shrink, so the two always fit inside it.
            let room = bounds.width - inset * 2
            let gap = max(2, min(Tokens.Space.x1, room - Tokens.Sidebar.favicon * 2))
            let size = min(Tokens.Sidebar.favicon, floor((room - gap) / 2))
            let x = (bounds.width - size * 2 - gap) / 2, y = (bounds.height - size) / 2
            icon.frame = NSRect(x: x, y: y, width: size, height: size).integral
            partnerIcon.frame = NSRect(x: x + size + gap, y: y, width: size, height: size).integral
        } else {
            // Every favorite at one size: a site's own 32px icon is drawn up to it with the best filtering, only a
            // 16px one stays at a tab's size rather than blur.
            let size = icon.image.map { FaviconStore.sharpSide(of: $0) >= Self.iconSide } == true ? Self.iconSide : Tokens.Sidebar.favicon
            icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size).integral
        }
        let side = Self.closeSide, edge = Self.closeInset
        closeButton.frame = NSRect(x: bounds.width - side - edge, y: isFlipped ? edge : bounds.height - side - edge, width: side, height: side)
        if !audioButton.isHidden { audioButton.frame = NSRect(x: edge, y: isFlipped ? edge : bounds.height - side - edge, width: side, height: side) }
        layoutNumber()
    }

    /// The number tucked into the top-right corner, as far in as the ×: the digit alone, as the × is one mark, so it
    /// stays clear of the icon however narrow the tile.
    private func layoutNumber() {
        guard let hint = numberHint, number != nil else { return }
        let edge = Self.closeInset, height = NumberHintView.height
        hint.showsCommand = false
        hint.frame = NSRect(x: bounds.width - edge - hint.width, y: isFlipped ? edge : bounds.height - height - edge, width: hint.width, height: height)
    }

    override func stateDidChange(animated: Bool) {
        // VoiceOver says which favorite you're on and which are open, as it does for tab rows.
        setAccessibilityValue(isSelected ? String(localized: "current tab", comment: "Spoken by VoiceOver after a tab row's name: it's the tab you're on.") : isOpen ? String(localized: "open", comment: "Spoken by VoiceOver after a favorite's name: its page is loaded.") : nil)
        setAccessibilitySelected(isSelected)
        if isPlaceholder {
            // Where the first favorite will land: the drop target's look.
            layer?.backgroundColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropAlpha))
            layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
            layer?.borderWidth = Tokens.Metric.dropEdge
            return
        }
        closeButton.isHidden = !(isOpen && isHovered) || number != nil
        // A soft tile of the space's own color, a step lighter under the pointer; a fine edge while its page is open,
        // so you can tell which are loaded. The one you're on is the selected tab's card.
        let fill = isSelected ? (isHovered ? Tokens.Chrome.cardHover : Tokens.Chrome.card)
            : isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered, duration: Tokens.Motion.selection)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = isSelected || isOpen ? Tokens.Metric.hairline : 0
            layer?.borderColor = cgColor(isSelected ? Tokens.Chrome.cardEdge : Tokens.Chrome.openEdge)
            setCardShadow(isSelected)
        }
        setCardRim(isSelected)
    }

    private static let iconSide = Tokens.Sidebar.favoriteIcon
}

/// The row a carried favorite turns into over the tab list: its page, or a split's two pages side by side with a
/// hairline between, as the split's row will look there.
final class CarriedRow: NSView {
    private let left = SidebarRowView()
    private let right: SidebarRowView?
    private let divider = ColorView(color: Tokens.Color.separator)

    init(_ favorite: Bookmark, icon: NSImage?, partner: Bookmark?, partnerIcon: NSImage?) {
        right = partner.map { _ in SidebarRowView() }
        super.init(frame: .zero)
        left.title.stringValue = favorite.title
        left.icon.image = icon
        addSubview(left)
        if let right, let partner {
            right.title.stringValue = partner.title
            right.icon.image = partnerIcon
            addSubview(right)
            addSubview(divider)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let right else { left.frame = bounds; return }
        let half = floor(bounds.width / 2)
        left.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        right.frame = NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height)
        divider.frame = NSRect(x: half, y: Tokens.Space.x2, width: Tokens.Metric.hairline, height: bounds.height - Tokens.Space.x4)
    }
}

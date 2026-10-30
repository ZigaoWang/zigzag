import AppKit

/// Favorites: a grid of icon tiles under the address, the same in every space.
final class FavoritesView: NSView {
    var onOpen: ((Bookmark) -> Void)?
    var onMenu: ((Bookmark) -> NSMenu?)?
    /// The × on an open favorite: unloads its page, the favorite stays.
    var onClose: ((Bookmark) -> Void)?
    private var tiles: [FavoriteTile] = []
    /// While a tab is dragged over the grid: an empty tile shows where it would go.
    private let dropTile = FavoriteTile(bookmark: nil)
    var isDropTarget = false {
        didSet {
            guard oldValue != isDropTarget else { return }
            dropTile.isHidden = !isDropTarget
            onHeightChange?()
            needsLayout = true
        }
    }
    var onHeightChange: (() -> Void)?
    /// A tile is being carried: where the pointer is, in screen points.
    var onDragMove: ((Bookmark, NSPoint) -> Void)?
    /// Dropped somewhere outside the grid. Returns true if it was handled.
    var onDrop: ((Bookmark, NSPoint) -> Bool)?
    var onReorder: ((Bookmark, Int) -> Void)?

    static let tileHeight = Tokens.Space.x10 + Tokens.Space.x2
    static let maxColumns = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A tile's close badge sits over its corner and may reach past the grid's edge.
        clipsToBounds = false
        wantsLayer = true
        layer?.masksToBounds = false
        dropTile.isHidden = true
        dropTile.isPlaceholder = true
        addSubview(dropTile)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var tileCount: Int { tiles.count + (isDropTarget ? 1 : 0) }

    var preferredHeight: CGFloat {
        guard tileCount > 0 else { return 0 }
        let rows = (tileCount + Self.maxColumns - 1) / Self.maxColumns
        return CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Tokens.Space.x2
    }

    func reload(favorites: [Bookmark], openIDs: Set<UUID>, selectedID: UUID?, tabs: [UUID: Tab] = [:]) {
        if tiles.map(\.bookmark?.id) != favorites.map(\.id) {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = favorites.map { favorite in
                let tile = FavoriteTile(bookmark: favorite)
                tile.onClick = { [weak self] _ in self?.onOpen?(favorite) }
                tile.onRightClick = { [weak self] _ in self?.onMenu?(favorite) }
                tile.onClose = { [weak self] in self?.onClose?(favorite) }
                tile.onDragStart = { [weak self, weak tile] event in
                    guard let self, let tile else { return false }
                    self.drag(tile, favorite: favorite, event: event)
                    return true
                }
                addSubview(tile)
                return tile
            }
            needsLayout = true
        }
        for tile in tiles {
            guard let id = tile.bookmark?.id else { continue }
            tile.isSelected = id == selectedID
            tile.isOpen = openIDs.contains(id)
            tile.track(tabs[id])
            tile.refreshIcon()
        }
    }

    /// Which slot a point (in this view) falls in, for reordering.
    func index(at point: NSPoint) -> Int {
        // Before the first tile that's in a lower row, or in this row and right of the point.
        tiles.firstIndex { tile in
            let gap = Tokens.Space.x2
            let below = point.y < tile.frame.minY - gap
            let sameRow = point.y >= tile.frame.minY - gap && point.y < tile.frame.maxY + gap
            return below || (sameRow && point.x < tile.frame.midX)
        } ?? tiles.count
    }

    /// Lifts the tile into a see-through floating copy that follows the pointer anywhere.
    private func drag(_ tile: FavoriteTile, favorite: Bookmark, event: NSEvent) {
        guard let window else { return }
        let rect = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.6
        let image = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        if let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) {
            tile.cacheDisplay(in: tile.bounds, to: rep)
            let picture = NSImage(size: tile.bounds.size)
            picture.addRepresentation(rep)
            image.image = picture
        }
        panel.contentView = image
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let grab = NSPoint(x: start.x - rect.minX, y: start.y - rect.minY)
        panel.orderFront(nil)
        tile.alphaValue = 0.3

        var last = start
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            last = window.convertPoint(toScreen: event.locationInWindow)
            if event.type == .leftMouseUp { stop.pointee = true; return }
            panel.setFrameOrigin(NSPoint(x: last.x - grab.x, y: last.y - grab.y))
            self.onDragMove?(favorite, last)
        }
        panel.orderOut(nil)
        tile.alphaValue = 1

        let local = convert(window.convertPoint(fromScreen: last), from: nil)
        if bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(local) {
            let to = index(at: local)
            let from = tiles.firstIndex { $0 === tile } ?? 0
            if to != from && to != from + 1 { onReorder?(favorite, to > from ? to - 1 : to) }
            _ = onDrop?(favorite, NSPoint(x: -10_000, y: -10_000))
        } else {
            _ = onDrop?(favorite, last)
        }
    }

    override func layout() {
        super.layout()
        let all = tiles + (isDropTarget ? [dropTile] : [])
        let gap = Tokens.Space.x2
        // One tile size for all: a full row sets it (fewer favorites than that share the width), and a shorter row
        // after it starts at the left in tiles of the same size, like any grid.
        let columns = max(1, min(Self.maxColumns, all.count))
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        for (i, tile) in all.enumerated() {
            let row = i / columns, column = i % columns
            tile.frame = NSRect(x: (width + gap) * CGFloat(column), y: (Self.tileHeight + gap) * CGFloat(row),
                                width: width, height: Self.tileHeight).integral
        }
    }
}

final class FavoriteTile: InteractiveView {
    let bookmark: Bookmark?
    private let icon = FaviconView()
    var isOpen = false { didSet { if oldValue != isOpen { stateDidChange(animated: false) } } }
    var onClose: (() -> Void)?
    /// Shown on an open favorite under the pointer, in the corner, like a tab's close button. The disc behind it is
    /// its own view, so the button's hover fill sits on it and never replaces it.
    /// A small round badge in the tile's top-right corner, like an app's badge.
    private static let closeSide: CGFloat = 16
    private var badgeHovered = false
    private var badgeLinger: DispatchWorkItem?
    private lazy var closeDisc: ColorView = {
        let side = Self.closeSide
        let disc = ColorView(color: Self.badgeFill)
        disc.wantsLayer = true
        disc.layer?.cornerRadius = side / 2
        disc.layer?.borderWidth = Tokens.Metric.hairline
        disc.layer?.shadowOpacity = 1
        disc.layer?.shadowRadius = 1.5
        disc.layer?.shadowOffset = CGSize(width: 0, height: 1)
        disc.isHidden = true
        // The same close button a tab row has, on a disc of its own.
        let button = IconButton(symbol: "xmark", size: side, symbolSize: 9, toolTip: "Unload Page")
        button.wantsLayer = true
        button.layer?.cornerRadius = side / 2
        button.onClick = { [weak self] _ in self?.onClose?() }
        // Over the part that hangs past the tile, the tile no longer counts as hovered; the badge stays for its own.
        button.hoverChanged = { [weak self] hovering in
            self?.badgeHovered = hovering
            self?.stateDidChange(animated: false)
        }
        button.frame = NSRect(x: 0, y: 0, width: side, height: side)
        disc.addSubview(button)
        addSubview(disc)
        return disc
    }()
    private weak var tab: Tab?
    private var tabToken: SignalToken?
    /// An icon that arrives later (fetched, or saved by a visit) shows at once, not only after a relaunch.
    private var iconToken: SignalToken?
    var isPlaceholder = false { didSet { icon.isHidden = isPlaceholder; stateDidChange(animated: false) } }

    init(bookmark: Bookmark?) {
        self.bookmark = bookmark
        super.init(frame: .zero)
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
        addSubview(icon)
        toolTip = bookmark?.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(bookmark?.title)
        refreshIcon()
        iconToken = FaviconStore.shared.updated.observe { [weak self] _ in
            guard let self, self.tab?.favicon == nil || self.tab?.isLoading != true else { return }
            self.refreshIcon()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Follows the favorite's page, so the tile shows the loading ribbon while it loads, like a tab does.
    func track(_ tab: Tab?) {
        guard tab !== self.tab else { return }
        self.tab = tab
        tabToken = tab?.changed.observe { [weak self] change in
            if change == .loading || change == .favicon { self?.refreshLoading() }
        }
        refreshLoading()
    }

    private func refreshLoading() {
        icon.isLoading = (tab?.isLoading ?? false) && !(tab?.isSuspended ?? true)
        if let favicon = tab?.favicon, !(tab?.isLoading ?? false) { icon.image = favicon }
    }

    func refreshIcon() {
        guard let bookmark else { return }
        if let image = FaviconStore.shared.cachedIcon(for: bookmark.url) {
            icon.image = image
        } else {
            FaviconStore.shared.prefetch(for: bookmark.url)
        }
    }

    override func layout() {
        super.layout()
        let size = Tokens.Metric.favicon + 4
        icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        // The badge hangs over the edge; AppKit turns clipping back on for a rounded layer, so it's turned off here.
        clipsToBounds = false
        layer?.masksToBounds = false
        let side = Self.closeSide
        // Centered on the tile's corner, half over its edge, clear of the icon.
        closeDisc.frame = NSRect(x: bounds.width - side / 2 - 2, y: -side / 2 + 2, width: side, height: side)
    }


    /// The badge reaches past the tile's edge; that part still takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !closeDisc.isHidden, let superview {
            let local = convert(point, from: superview)
            if closeDisc.frame.contains(local) { return closeDisc.hitTest(local) ?? closeDisc }
        }
        return super.hitTest(point)
    }

    override func stateDidChange(animated: Bool) {
        if isPlaceholder {
            layer?.backgroundColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.12))
            layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
            layer?.borderWidth = 1.5
            return
        }
        // Shown while the pointer is on the tile or the badge; leaving the tile for the badge's outer half
        // passes through a moment where neither is hovered, so hiding waits a beat.
        let wanted = isOpen && (isHovered || badgeHovered)
        badgeLinger?.cancel()
        if wanted {
            // Its edge and shadow are resolved here, so they follow light and dark like the tile.
            closeDisc.layer?.borderColor = cgColor(Tokens.Color.panelEdge)
            closeDisc.layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            closeDisc.isHidden = false
        } else if !closeDisc.isHidden {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !(self.isOpen && (self.isHovered || self.badgeHovered)) else { return }
                self.closeDisc.isHidden = true
            }
            badgeLinger = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        // The badge reaches over the next tile: the hovered tile is drawn on top.
        if !closeDisc.isHidden, let superview, superview.subviews.last !== self {
            superview.addSubview(self, positioned: .above, relativeTo: nil)
        }
        // An open favorite shows its icon in full; one that isn't loaded is softly faded, with no mark to read.
        let iconAlpha: CGFloat = isOpen || isSelected || isHovered ? 1 : 0.5
        if icon.alphaValue != iconAlpha {
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.icon.animator().alphaValue = iconAlpha }
        }
        let fill: NSColor
        if isSelected {
            // The favorite you're on stands clearly apart from the resting tiles beside it.
            fill = isHovered ? Self.selectedHover : Self.selected
        } else if isPressed {
            fill = Tokens.Color.pressedFill
        } else if isHovered {
            fill = Tokens.Color.pressedFill
        } else {
            fill = Tokens.Color.fieldFill
        }
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        layer?.shadowOpacity = isSelected ? 1 : 0
        layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.borderWidth = isSelected ? Tokens.Metric.hairline : 0
        layer?.borderColor = cgColor(Tokens.Color.selectedEdge)
    }

    /// Light on dark and dark on light, so the badge reads on any tile.
    private static let badgeFill = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF), dark: Tokens.Color.hex(0x5C5C62))
    private static let selected = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: 0.95), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.2))
    private static let selectedHover = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: 1), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.24))
}

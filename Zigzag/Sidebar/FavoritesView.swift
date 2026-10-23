import AppKit

/// Favorites: a grid of icon tiles under the address, the same in every space.
final class FavoritesView: NSView {
    var onOpen: ((Bookmark) -> Void)?
    var onMenu: ((Bookmark) -> NSMenu?)?
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

    func reload(favorites: [Bookmark], openIDs: Set<UUID>, selectedID: UUID?) {
        if tiles.map(\.bookmark?.id) != favorites.map(\.id) {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = favorites.map { favorite in
                let tile = FavoriteTile(bookmark: favorite)
                tile.onClick = { [weak self] _ in self?.onOpen?(favorite) }
                tile.onRightClick = { [weak self] _ in self?.onMenu?(favorite) }
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
            tile.refreshIcon()
        }
    }

    /// Which slot a point (in this view) falls in, for reordering.
    func index(at point: NSPoint) -> Int {
        tiles.firstIndex { point.x < $0.frame.midX && point.y < $0.frame.maxY } ?? tiles.count
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
        for (i, tile) in all.enumerated() {
            let row = i / Self.maxColumns
            let rowStart = row * Self.maxColumns
            // Each row spreads its tiles across the full width, like Arc's.
            let inRow = min(Self.maxColumns, all.count - rowStart)
            let width = (bounds.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow)
            let column = i - rowStart
            tile.frame = NSRect(x: (width + gap) * CGFloat(column), y: (Self.tileHeight + gap) * CGFloat(row),
                                width: width, height: Self.tileHeight).integral
        }
    }
}

final class FavoriteTile: InteractiveView {
    let bookmark: Bookmark?
    private let icon = FaviconView()
    var isOpen = false
    var isPlaceholder = false { didSet { icon.isHidden = isPlaceholder; stateDidChange(animated: false) } }

    init(bookmark: Bookmark?) {
        self.bookmark = bookmark
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
        addSubview(icon)
        toolTip = bookmark?.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(bookmark?.title)
        refreshIcon()
    }

    required init?(coder: NSCoder) { fatalError() }

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
    }

    override func stateDidChange(animated: Bool) {
        if isPlaceholder {
            layer?.backgroundColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.12))
            layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
            layer?.borderWidth = 1.5
            return
        }
        let fill: NSColor
        if isSelected {
            fill = isHovered ? Tokens.Color.selectedHoverFill : Tokens.Color.selectedFill
        } else if isPressed {
            fill = Tokens.Color.pressedFill
        } else if isHovered {
            fill = Tokens.Color.pressedFill
        } else {
            fill = Tokens.Color.fieldFill
        }
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        layer?.shadowOpacity = isSelected ? 1 : 0
        layer?.shadowColor = cgColor(Tokens.Color.selectedEdge)
        layer?.shadowRadius = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
    }
}

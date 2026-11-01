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
            // The tiles after the opening slide over to make room for it, and back when it closes.
            relayout(gliding: true)
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
        wantsLayer = true
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

    /// The order while a tile is carried: the others make room where it would land, so you see the result before
    /// letting go. Nil when nothing is being dragged.
    private var liveOrder: [FavoriteTile]?

    /// The slot a point (in this view) is over, by the grid's own columns and rows, for `count` tiles.
    private func slot(at point: NSPoint, count: Int) -> Int {
        let gap = Tokens.Space.x2
        let columns = max(2, min(Self.maxColumns, count))
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let column = min(max(Int(point.x / (width + gap)), 0), columns - 1)
        let row = max(Int(point.y / (Self.tileHeight + gap)), 0)
        return min(row * columns + column, count - 1)
    }

    /// Picks the tile up: it follows the pointer, solid, and the others slide aside to open its new place. Let go
    /// over the grid and it settles there; anywhere else (the tab list, another window) it's handed on.
    private func drag(_ tile: FavoriteTile, favorite: Bookmark, event: NSEvent) {
        guard let window, let from = tiles.firstIndex(where: { $0 === tile }) else { return }
        let rect = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        let image = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        image.image = Self.picture(of: tile)
        panel.contentView = image
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let grab = NSPoint(x: start.x - rect.minX, y: start.y - rect.minY)
        panel.orderFront(nil)
        // Its place stays open (an empty slot) while it's carried.
        tile.alphaValue = 0
        liveOrder = tiles

        var last = start
        var target = from
        func arrange(_ to: Int) {
            guard to != target else { return }
            target = to
            var order = tiles.filter { $0 !== tile }
            order.insert(tile, at: to)
            liveOrder = order
            relayout(gliding: true)
        }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            last = window.convertPoint(toScreen: event.locationInWindow)
            if event.type == .leftMouseUp { stop.pointee = true; return }
            panel.setFrameOrigin(NSPoint(x: last.x - grab.x, y: last.y - grab.y))
            let local = self.convert(window.convertPoint(fromScreen: last), from: nil)
            // Over the grid the others make room where the carried tile's middle is, wherever it was picked up by;
            // off it, everything goes back to where it was.
            let center = self.convert(window.convertPoint(fromScreen: NSPoint(x: panel.frame.midX, y: panel.frame.midY)), from: nil)
            arrange(self.bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(local) ? self.slot(at: center, count: self.tiles.count) : from)
            self.onDragMove?(favorite, last)
        }

        let local = convert(window.convertPoint(fromScreen: last), from: nil)
        let inside = bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(local)
        func finish() {
            panel.orderOut(nil)
            tile.alphaValue = 1
            liveOrder = nil
        }
        guard inside else {
            arrange(from)
            finish()
            _ = onDrop?(favorite, last)
            return
        }
        // Settles into its new place, then the grid takes on that order for good.
        let landing = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.reduceMotion ? 0 : 0.18
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().setFrame(landing, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                finish()
                if target != from { self?.onReorder?(favorite, target) }
                _ = self?.onDrop?(favorite, NSPoint(x: -10_000, y: -10_000))
            }
        })
    }

    /// While true, tiles already in place slide to their new places instead of jumping there.
    private var glides = false

    private func relayout(gliding: Bool) {
        glides = gliding && window != nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        glides = false
    }

    /// The tile as it looks, from its layers, for the copy that follows the pointer.
    private static func picture(of tile: NSView) -> NSImage? {
        guard let layer = tile.layer else { return nil }
        let scale = tile.window?.backingScaleFactor ?? 2
        let size = tile.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        // Layers draw flipped against the bitmap.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        layer.render(in: cg)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    override func layout() {
        super.layout()
        let all = (liveOrder ?? tiles) + (isDropTarget ? [dropTile] : [])
        let gap = Tokens.Space.x2
        // Up to four columns, every tile one size, a shorter last row from the left. A lone favorite is never
        // wider than two would be: half the row, not a long bar around a small icon.
        let columns = max(2, min(Self.maxColumns, all.count))
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        for (i, tile) in all.enumerated() {
            let row = i / columns, column = i % columns
            let frame = NSRect(x: (width + gap) * CGFloat(column), y: (Self.tileHeight + gap) * CGFloat(row),
                               width: width, height: Self.tileHeight).integral
            if glides, tile !== dropTile, tile.frame.width > 0, tile.frame.size == frame.size {
                Tokens.Motion.glide(tile, to: frame)
            } else {
                tile.frame = frame
            }
        }
    }
}

final class FavoriteTile: InteractiveView {
    let bookmark: Bookmark?
    private let icon = FaviconView()
    var isOpen = false { didSet { if oldValue != isOpen { stateDidChange(animated: false) } } }
    var onClose: (() -> Void)?
    /// Shown under the pointer on every favorite that's open, the one you're on too, as a tab's is: a small ×
    /// tucked into the tile's top-right corner, clear of the icon even four to a row, and never past the tile's edge.
    private static let closeSide: CGFloat = 14
    private lazy var closeButton: IconButton = {
        let button = IconButton(symbol: "xmark", size: Self.closeSide, symbolSize: 7, toolTip: "Unload Page")
        button.tint = Tokens.Color.textSecondary
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.closeSide / 2
        button.onClick = { [weak self] _ in self?.onClose?() }
        button.isHidden = true
        addSubview(button)
        return button
    }()
    private weak var tab: Tab?
    private var tabToken: SignalToken?
    /// An icon that arrives later (fetched, or saved by a visit) shows at once, not only after a relaunch.
    private var iconToken: SignalToken?
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
        if let favicon = tab?.favicon, !(tab?.isLoading ?? false) { icon.image = favicon; needsLayout = true }
    }

    func refreshIcon() {
        guard let bookmark else { return }
        if let image = FaviconStore.shared.cachedIcon(for: bookmark.url) {
            icon.image = image
            needsLayout = true
        } else {
            FaviconStore.shared.prefetch(for: bookmark.url)
        }
    }

    override func layout() {
        super.layout()
        // Big enough to read at a glance when the site gives a sharp icon; a small one stays at a tab's 16pt rather
        // than being stretched and blurred.
        let size = icon.image.map { FaviconStore.sharpSide(of: $0) >= Self.iconSide } == true ? Self.iconSide : Tokens.Metric.favicon
        icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size).integral
        let side = Self.closeSide
        closeButton.frame = NSRect(x: bounds.width - side - 3, y: isFlipped ? 3 : bounds.height - side - 3, width: side, height: side)
    }

    override func stateDidChange(animated: Bool) {
        if isPlaceholder {
            layer?.backgroundColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.12))
            layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
            layer?.borderWidth = 1.5
            return
        }
        closeButton.isHidden = !(isOpen && isHovered)
        // Every favorite looks the same at rest: the one you're on is lit.
        icon.alphaValue = 1
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

    private static let iconSide: CGFloat = 22

    private static let selected = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: 0.95), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.2))
    private static let selectedHover = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: 1), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.24))
}

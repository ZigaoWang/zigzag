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
            if !isDropTarget { dropIndex = nil }
            onHeightChange?()
            // The tiles after the opening slide over to make room for it, and back when it closes.
            relayout(gliding: true)
        }
    }
    /// Where among the tiles a tab carried over the grid would land; nil: at the end.
    private(set) var dropIndex: Int?

    /// A tab carried over the grid at this point (in window coordinates): the empty tile opens in the slot under it.
    func hoverDrop(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let index = tiles.isEmpty ? 0 : slot(at: point, count: tiles.count + 1)
        guard index != dropIndex else { return }
        dropIndex = index
        relayout(gliding: true)
    }

    var onHeightChange: (() -> Void)?
    /// A tile is being carried: where the pointer is, in screen points. Returns true while it's over the tab list,
    /// where it would become a tab again.
    var onDragMove: ((Bookmark, NSPoint) -> Bool)?
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

    /// One tile per favorite; a split favorite's two pages share one, each half opening its own page.
    func reload(favorites: [(Bookmark, partner: Bookmark?)], openIDs: Set<UUID>, selectedID: UUID?, tabs: [UUID: Tab] = [:]) {
        if tiles.map({ [$0.bookmark?.id, $0.partner?.id] }) != favorites.map({ [$0.0.id, $0.partner?.id] }) {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = favorites.map { favorite, partner in
                let tile = FavoriteTile(bookmark: favorite, partner: partner)
                tile.onClick = { [weak self, weak tile] event in
                    guard let self, let tile else { return }
                    let onRight = tile.convert(event.locationInWindow, from: nil).x > tile.bounds.midX
                    self.onOpen?(onRight ? partner ?? favorite : favorite)
                }
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
            let ids = [id] + (tile.partner.map { [$0.id] } ?? [])
            tile.isSelected = selectedID.map(ids.contains) ?? false
            tile.isOpen = ids.contains(where: openIDs.contains)
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
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let grab = NSPoint(x: start.x - rect.minX, y: start.y - rect.minY)
        let carried = CarriedFavorite(tile: Self.picture(of: tile), tileSize: rect.size, grab: grab, favorite: favorite,
                                      icon: tile.iconImage, rowWidth: bounds.width, appearance: window.effectiveAppearance)
        carried.move(to: start)
        // See-through while it's carried, so the slots and rows under it show; solid again as it lands.
        carried.panel.alphaValue = SidebarListView.carriedOpacity
        carried.panel.orderFront(nil)
        let panel = carried.panel
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
            carried.move(to: last)
            let local = self.convert(window.convertPoint(fromScreen: last), from: nil)
            // Over the grid the others make room where the carried tile's middle is, wherever it was picked up by;
            // off it, everything goes back to where it was.
            let center = self.convert(window.convertPoint(fromScreen: carried.tileCenter), from: nil)
            arrange(self.bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(local) ? self.slot(at: center, count: self.tiles.count) : from)
            // Over the tab list it becomes the row it would be there; back over the grid, a tile again.
            carried.isRow = self.onDragMove?(favorite, last) ?? false
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
        carried.isRow = false
        let landing = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.reduceMotion ? 0 : 0.18
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().setFrame(carried.panelFrame(placingTileAt: landing), display: true)
            panel.animator().alphaValue = 1
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
        var all = liveOrder ?? tiles
        if isDropTarget { all.insert(dropTile, at: min(dropIndex ?? all.count, all.count)) }
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
    /// A split favorite's right page, shown beside the left one in the same tile.
    let partner: Bookmark?
    private let icon = FaviconView()
    private let partnerIcon = FaviconView()
    var isOpen = false { didSet { if oldValue != isOpen { stateDidChange(animated: false) } } }
    var iconImage: NSImage? { icon.image }
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

    init(bookmark: Bookmark?, partner: Bookmark? = nil) {
        self.bookmark = bookmark
        self.partner = partner
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
        addSubview(icon)
        partnerIcon.isHidden = partner == nil
        addSubview(partnerIcon)
        let name = [bookmark?.title, partner?.title].compactMap { $0 }.joined(separator: " and ")
        toolTip = name
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
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
        // Big enough to read at a glance when the site gives a sharp icon; a small one stays at a tab's 16pt rather
        // than being stretched and blurred.
        if partner != nil {
            // A split: both pages' icons side by side, at a tab's size, so two fit any tile.
            let size = Tokens.Metric.favicon, gap = Tokens.Space.x2
            let x = (bounds.width - size * 2 - gap) / 2, y = (bounds.height - size) / 2
            icon.frame = NSRect(x: x, y: y, width: size, height: size).integral
            partnerIcon.frame = NSRect(x: x + size + gap, y: y, width: size, height: size).integral
        } else {
            let size = icon.image.map { FaviconStore.sharpSide(of: $0) >= Self.iconSide } == true ? Self.iconSide : Tokens.Metric.favicon
            icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size).integral
        }
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
        // The one you're on is lit; one that's open in the background has a fine edge, so you can tell at a glance
        // which are loaded without anything fading or moving.
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
        layer?.borderWidth = isSelected ? Tokens.Metric.hairline : isOpen ? 1 : 0
        layer?.borderColor = cgColor(isSelected ? Tokens.Color.selectedEdge : Self.openEdge)
    }

    private static let openEdge = Tokens.Color.dynamic(light: Tokens.Color.hex(0x000000, alpha: 0.13), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.16))

    private static let iconSide: CGFloat = 22

    private static let selected = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: 0.95), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.2))
    private static let selectedHover = Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF, alpha: 1), dark: Tokens.Color.hex(0xFFFFFF, alpha: 0.24))
}

/// A favorite on its way somewhere: a floating copy that follows the pointer. Over the grid it's the tile; over the
/// tab list it turns into the row it would become there, and back again, so you see what a drop will do.
@MainActor
final class CarriedFavorite {
    let panel: NSPanel
    private let card = NSView()
    private let tileView = NSImageView()
    private let row = SidebarRowView()
    private let tileSize: NSSize
    private let rowSize: NSSize
    /// Where the pointer holds the tile, from its bottom-left corner.
    private let grab: NSPoint
    /// Where the pointer holds it as a row: just past its icon, as if it had been picked up there.
    private let rowGrab: NSPoint
    /// The panel is big enough for both shapes; the pointer stays at this spot in it.
    private let anchor: NSPoint
    private static let margin: CGFloat = 20

    init(tile: NSImage?, tileSize: NSSize, grab: NSPoint, favorite: Bookmark, icon: NSImage?, rowWidth: CGFloat, appearance: NSAppearance) {
        self.tileSize = tileSize
        self.grab = grab
        rowSize = NSSize(width: rowWidth, height: Tokens.Metric.rowHeight)
        let rowGrab = NSPoint(x: Tokens.Space.x2 + Tokens.Metric.favicon + Tokens.Space.x1, y: rowSize.height / 2)
        self.rowGrab = rowGrab
        let m = Self.margin
        anchor = NSPoint(x: m + max(grab.x, rowGrab.x), y: m + max(grab.y, rowGrab.y))
        let width = anchor.x + max(tileSize.width - grab.x, rowSize.width - rowGrab.x) + m
        let height = anchor.y + max(tileSize.height - grab.y, rowSize.height - rowGrab.y) + m
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        panel.contentView = content

        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.card
        card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.18
        card.layer?.shadowRadius = 8
        card.layer?.shadowOffset = CGSize(width: 0, height: -3)
        content.addSubview(card)
        tileView.image = tile
        tileView.imageScaling = .scaleNone
        tileView.autoresizingMask = [.width, .height]
        row.autoresizingMask = [.width, .height]
        row.title.stringValue = favorite.title
        row.icon.image = icon
        row.isLifted = true
        row.alphaValue = 0
        card.addSubview(row)
        card.addSubview(tileView)
        // Tiles and rows are see-through on the sidebar; lifted off it, the copy stands on solid ground.
        var ground = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance { ground = Tokens.Color.panelBackground.cgColor }
        card.layer?.backgroundColor = ground
        panel.appearance = appearance
        card.frame = tileFrame
        tileView.frame = card.bounds
        row.frame = card.bounds
        updateShadow()
    }

    private var tileFrame: NSRect { NSRect(x: anchor.x - grab.x, y: anchor.y - grab.y, width: tileSize.width, height: tileSize.height) }
    private var rowFrame: NSRect { NSRect(x: anchor.x - rowGrab.x, y: anchor.y - rowGrab.y, width: rowSize.width, height: rowSize.height) }

    var isRow = false {
        didSet {
            guard isRow != oldValue else { return }
            let target = isRow ? rowFrame : tileFrame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Tokens.Motion.reduceMotion ? 0 : 0.18
                context.timingFunction = Tokens.Motion.easeOut
                context.allowsImplicitAnimation = true
                card.animator().frame = target
                row.animator().alphaValue = isRow ? 1 : 0
                tileView.animator().alphaValue = isRow ? 0 : 1
                card.layer?.cornerRadius = isRow ? Tokens.Radius.row : Tokens.Radius.card
            }
            updateShadow(for: target)
        }
    }

    private func updateShadow(for frame: NSRect? = nil) {
        let size = (frame ?? card.frame).size
        let radius = isRow ? Tokens.Radius.row : Tokens.Radius.card
        card.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Keeps the pointer where it holds the copy.
    func move(to screenPoint: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - anchor.x, y: screenPoint.y - anchor.y))
    }

    /// The tile's middle on screen, for which slot it's over.
    var tileCenter: NSPoint { NSPoint(x: panel.frame.minX + tileFrame.midX, y: panel.frame.minY + tileFrame.midY) }

    /// Where the panel goes for the tile to sit at `rect` on screen.
    func panelFrame(placingTileAt rect: NSRect) -> NSRect {
        NSRect(x: rect.minX - tileFrame.minX, y: rect.minY - tileFrame.minY, width: panel.frame.width, height: panel.frame.height)
    }
}

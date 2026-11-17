import AppKit

/// Where the ⌘T bar sits in a browser window: its own place over the page by default, or wherever you dragged it.
/// A dragged place is kept as fractions of the window, so it holds at any window size; dragged back onto the
/// default (the guides snap it there), it's the default again, and follows any change to where that is.
/// Coordinates are the overlay's, top-down.
struct CommandBarPlacement {
    /// Where you put the bar, as fractions of the window: its middle across, its top down. Nil on an axis is the default.
    struct Position: Equatable {
        var centerX: CGFloat?
        var top: CGFloat?
        static let standard = Position()
        var isStandard: Bool { centerX == nil && top == nil }
    }

    /// Within this of a guide, the bar snaps onto it.
    static let snapDistance: CGFloat = 8
    /// A press moves the bar only once it has moved this far, so a click stays a click.
    static let dragThreshold: CGFloat = 3
    /// Room to breathe on both sides of the page by default.
    static let pageMargin = Tokens.Space.x8
    /// How close a dragged bar may come to the window's edges.
    static let edgeMargin = Tokens.Space.x2

    /// The whole window (the overlay's bounds).
    let bounds: NSRect
    /// The page beside the sidebar.
    let page: NSRect
    /// The bar's field and as many rows as a dragged bar always keeps room for.
    let minimumHeight: CGFloat

    init(bounds: NSRect, page: NSRect, minimumHeight: CGFloat) {
        self.bounds = bounds
        self.page = page
        self.minimumHeight = minimumHeight
    }

    var width: CGFloat { min(Tokens.Metric.commandBarWidth, page.width - Self.pageMargin * 2) }

    /// Centered on the whole window, not just the page beside the sidebar, but never tight against either edge of the page.
    var defaultX: CGFloat {
        min(max(page.minX + Self.pageMargin, floor(bounds.midX - width / 2)), page.maxX - width - Self.pageMargin)
    }

    var defaultTop: CGFloat { page.minY + max(Tokens.Space.x12, floor(page.height * 0.18)) }

    /// Where the guides run: the default bar's middle across, and its top.
    var guideX: CGFloat { defaultX + width / 2 }
    var guideY: CGFloat { defaultTop }

    /// The bar's top-left for a position, kept inside the window.
    func origin(for position: Position) -> NSPoint {
        let x = position.centerX.map { clampX(bounds.minX + $0 * bounds.width - width / 2) } ?? defaultX
        let top = position.top.map { clampTop(bounds.minY + $0 * bounds.height) } ?? defaultTop
        return NSPoint(x: x, y: top)
    }

    /// The lowest the bar's list may reach: the page's bottom by default, the window's once you've moved it down.
    func bottom(for position: Position) -> CGFloat { position.top == nil ? page.maxY : bounds.maxY }

    private func clampX(_ x: CGFloat) -> CGFloat {
        let low = bounds.minX + Self.edgeMargin, high = bounds.maxX - Self.edgeMargin - width
        return round(max(low, min(x, high)))
    }

    private func clampTop(_ top: CGFloat) -> CGFloat {
        let low = bounds.minY + Self.edgeMargin, high = bounds.maxY - Self.edgeMargin - minimumHeight
        return round(max(low, min(top, max(low, high))))
    }

    struct Drag: Equatable {
        var origin: NSPoint
        var position: Position
        var snappedX: Bool
        var snappedY: Bool
    }

    /// Where a bar dragged to `proposed` (its top-left) lands: inside the window, and onto a guide within reach.
    func drag(to proposed: NSPoint) -> Drag {
        var x = clampX(proposed.x), top = clampTop(proposed.y)
        let snappedX = abs(x + width / 2 - guideX) <= Self.snapDistance
        let snappedY = abs(top - guideY) <= Self.snapDistance
        if snappedX { x = defaultX }
        if snappedY { top = defaultTop }
        let position = Position(centerX: snappedX ? nil : (x + width / 2 - bounds.minX) / max(1, bounds.width),
                                top: snappedY ? nil : (top - bounds.minY) / max(1, bounds.height))
        return Drag(origin: NSPoint(x: x, y: top), position: position, snappedX: snappedX, snappedY: snappedY)
    }

    // MARK: Remembering it

    static let defaultsKey = "CommandBarPosition"

    static func load(from defaults: UserDefaults = .standard) -> Position {
        guard let saved = defaults.dictionary(forKey: defaultsKey) else { return .standard }
        func fraction(_ key: String) -> CGFloat? {
            guard let value = (saved[key] as? NSNumber)?.doubleValue, value.isFinite, (0...1).contains(value) else { return nil }
            return CGFloat(value)
        }
        return Position(centerX: fraction("x"), top: fraction("top"))
    }

    /// The default is kept as no setting at all, so a later change to the default reaches it.
    static func save(_ position: Position, to defaults: UserDefaults = .standard) {
        guard !position.isStandard else { defaults.removeObject(forKey: defaultsKey); return }
        var saved: [String: Double] = [:]
        if let x = position.centerX { saved["x"] = Double(x) }
        if let top = position.top { saved["top"] = Double(top) }
        defaults.set(saved, forKey: defaultsKey)
    }
}

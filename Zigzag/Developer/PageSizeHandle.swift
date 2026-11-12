import AppKit

/// A grip beside a page at a size of its own (#141), to drag it to another size: on its right edge for the width,
/// under it for the height, at its corner for both, as a responsive view in Chrome or Polypane has them. They lie on
/// the backdrop around the page, never over it, so the page keeps every click. The page stays in the middle of its
/// room, so a side moves half as far as the size changes: dragging takes the size with both sides, under the pointer.
final class PageSizeHandle: NSView {
    enum Edge: CaseIterable { case right, bottom, corner }

    let edge: Edge
    /// The size to give the page while it's dragged, and once it's let go.
    var onResize: ((CGSize) -> Void)?
    /// The page's size and the scale it's shown at when the drag starts (`PageCardView.pageScale`).
    var current: () -> (size: CGSize, scale: CGFloat)? = { nil }

    private var start: (point: NSPoint, size: CGSize, scale: CGFloat)?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel(Self.name(of: edge))
    }

    required init?(coder: NSCoder) { fatalError() }

    static func name(of edge: Edge) -> String {
        switch edge {
        case .right: String(localized: "Page width", comment: "VoiceOver name of the grip beside a page with a size of its own, among the developer tools: drag it to change the page's width.")
        case .bottom: String(localized: "Page height", comment: "VoiceOver name of the grip under a page with a size of its own, among the developer tools: drag it to change the page's height.")
        case .corner: String(localized: "Page size", comment: "VoiceOver name of the grip at the corner of a page with a size of its own, among the developer tools: drag it to change the page's width and height.")
        }
    }

    /// How far a grip reaches from the page, and how long the right and bottom ones are.
    static let depth: CGFloat = Tokens.Space.x3
    static let length: CGFloat = Tokens.Space.x10

    /// Where each grip goes beside `page`, in its superview's terms, which count up from the bottom (`flipped`
    /// false). None where it would leave `room`: a page as wide as its room has no width to drag out.
    static func frames(page: NSRect, room: NSRect, flipped: Bool = false) -> [Edge: NSRect] {
        var frames: [Edge: NSRect] = [:]
        let below = flipped ? page.maxY : page.minY - depth
        let fitsRight = page.maxX + depth <= room.maxX
        let fitsBelow = flipped ? page.maxY + depth <= room.maxY : page.minY - depth >= room.minY
        if fitsRight { frames[.right] = NSRect(x: page.maxX, y: round(page.midY - length / 2), width: depth, height: length) }
        if fitsBelow { frames[.bottom] = NSRect(x: round(page.midX - length / 2), y: below, width: length, height: depth) }
        if fitsRight, fitsBelow { frames[.corner] = NSRect(x: page.maxX, y: below, width: depth, height: depth) }
        return frames
    }

    /// The size a drag of `delta` (in window points, y up) from `size` gives, the page `scale` as large as itself:
    /// twice the move, since the page stays in the middle; whole points, within the sizes a page can be.
    static func resized(_ size: CGSize, edge: Edge, delta: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(scale, 0.01)
        var width = size.width, height = size.height
        if edge != .bottom { width += 2 * delta.width / scale }
        if edge != .right { height -= 2 * delta.height / scale }
        func clamp(_ value: CGFloat) -> CGFloat {
            CGFloat(min(PageSizes.limits.upperBound, max(PageSizes.limits.lowerBound, Int(value.rounded()))))
        }
        return CGSize(width: clamp(width), height: clamp(height))
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch edge {
        case .right: cursor = .resizeLeftRight
        case .bottom: cursor = .resizeUpDown
        case .corner: cursor = .frameResize(position: .bottomRight, directions: .all)
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { if start == nil { isHovered = false } }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let now = current() else { return }
        start = (event.locationInWindow, now.size, now.scale)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let delta = CGSize(width: event.locationInWindow.x - start.point.x, height: event.locationInWindow.y - start.point.y)
        onResize?(Self.resized(start.size, edge: edge, delta: delta, scale: start.scale))
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// A short rounded bar across the grip, in the quiet ink, stronger under the pointer or while dragged.
    override func draw(_ dirtyRect: NSRect) {
        let ink = (isHovered || start != nil ? Tokens.Color.textSecondary : Tokens.Color.textTertiary)
        ink.setFill()
        let bar: NSRect
        let thick: CGFloat = 4, inset = (Self.depth - thick) / 2
        switch edge {
        case .right: bar = NSRect(x: inset, y: Tokens.Space.x2, width: thick, height: bounds.height - Tokens.Space.x4)
        case .bottom: bar = NSRect(x: Tokens.Space.x2, y: inset, width: bounds.width - Tokens.Space.x4, height: thick)
        case .corner: bar = NSRect(x: inset, y: inset, width: thick, height: thick)
        }
        NSBezierPath(roundedRect: bar, xRadius: thick / 2, yRadius: thick / 2).fill()
    }
}

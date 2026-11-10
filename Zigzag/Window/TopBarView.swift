import AppKit

/// The bar above the page (Settings › Appearance › Address bar above the page), as in Arc's and Chrome's top-bar
/// layout: back, forward and reload, then the address. They're the sidebar's own views, moved here rather than made
/// again, so their actions, the panels and popups that come out of them, the command bar and their tooltips work as
/// they do in the sidebar. It lies on the window's frame as the sidebar does, its middle on the traffic lights' line,
/// and like the sidebar it moves the window and zooms it on a double-click.
final class TopBarView: NSView {
    /// Twice the traffic lights' center line: the lights, the sidebar's toggle and everything here sit on one line.
    static let height: CGFloat = Tokens.Sidebar.lightsCenter * 2

    /// The traffic lights' width while they sit at the bar's leading end (the sidebar hidden); 0 while they're
    /// elsewhere or in full screen's own title bar.
    var trafficLightsWidth: CGFloat = 0 { didSet { if trafficLightsWidth != oldValue { needsLayout = true } } }
    /// From the bar's trailing edge to the address's end, so the address ends where the page does.
    var trailingInset: CGFloat = Tokens.Sidebar.edge { didSet { if trailingInset != oldValue { needsLayout = true } } }

    /// The page's own color, over the page below it, as in Arc, so the bar and the page read as one card; nil lets the
    /// window's frame show through. Icons and text turn light or dark to match.
    var pageColor: NSColor? {
        didSet {
            guard pageColor != oldValue else { return }
            appearance = pageColor.map { NSAppearance(named: Tokens.Color.luminance(of: $0) < 0.5 ? .darkAqua : .aqua) } ?? nil
            needsDisplay = true
        }
    }
    /// Where the page's color goes (right above the page) and how round its top corners are.
    var pageSpan: NSRect = .zero { didSet { if pageSpan != oldValue { needsDisplay = true } } }
    var pageRadius: CGFloat = 0 { didSet { if pageRadius != oldValue { needsDisplay = true } } }

    private var buttons: [NSView] = []
    private weak var address: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let pageColor, !pageSpan.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        pageSpan.clip()
        pageColor.setFill()
        // Round at the top only: the shape runs a radius past the bottom, where the clip cuts it square.
        var shape = pageSpan
        shape.size.height += pageRadius
        NSBezierPath(roundedRect: shape, xRadius: pageRadius, yRadius: pageRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }

    /// Takes the sidebar's buttons and address, in order.
    func hold(buttons: [NSView], address: NSView) {
        self.buttons = buttons
        self.address = address
        (buttons + [address]).forEach(addSubview)
        needsLayout = true
    }

    struct Frames: Equatable {
        var buttons: [NSRect]
        var address: NSRect
    }

    /// The buttons a button apart from the leading end (after the traffic lights, the first glyph `Sidebar.lightsGap`
    /// after them, as the sidebar's toggle is), then the address to the trailing inset, all centered on the lights' line.
    static func frames(width: CGFloat, buttons: Int, trafficLightsWidth: CGFloat, trailingInset: CGFloat) -> Frames {
        let mid = height / 2, b = Tokens.Sidebar.button
        let glyph = Tokens.Symbol.inkSize("chevron.left", size: Tokens.Sidebar.glyph).width
        var x = trafficLightsWidth > 0
            ? round(Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Sidebar.lightsGap - (b - glyph) / 2) : Tokens.Sidebar.edge
        var rects: [NSRect] = []
        for _ in 0..<buttons {
            rects.append(NSRect(x: x, y: mid - b / 2, width: b, height: b))
            x += b
        }
        let start = x + Tokens.Space.x2, h = Tokens.Sidebar.addressHeight
        return Frames(buttons: rects, address: NSRect(x: start, y: round(mid - h / 2), width: max(0, width - trailingInset - start), height: h))
    }

    override func layout() {
        super.layout()
        let frames = Self.frames(width: bounds.width, buttons: buttons.count, trafficLightsWidth: trafficLightsWidth, trailingInset: trailingInset)
        for (button, frame) in zip(buttons, frames.buttons) where button.superview === self { button.frame = frame }
        if let address, address.superview === self { address.frame = frames.address }
    }
}

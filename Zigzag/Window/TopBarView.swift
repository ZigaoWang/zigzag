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
    /// From the bar's leading edge to its first button while the traffic lights aren't there: the page's left edge,
    /// plus the inset the address keeps from the page's right edge, so both ends match.
    var leadingInset: CGFloat = Tokens.Sidebar.edge { didSet { if leadingInset != oldValue { needsLayout = true } } }
    /// From the bar's trailing edge to the address's end, so the address ends where the page does.
    var trailingInset: CGFloat = Tokens.Sidebar.edge { didSet { if trailingInset != oldValue { needsLayout = true } } }

    /// The sidebar's toggle, first after the traffic lights while the sidebar is hidden: the sidebar's own is out of
    /// sight with it then. Shown, the sidebar keeps it in its own top row.
    let sidebarButton = SidebarView.chromeButton("sidebar.left", toolTip: String(localized: "Show Sidebar", comment: "Tooltip of the sidebar button while the sidebar is hidden."))
    var showsSidebarButton = false {
        didSet {
            guard showsSidebarButton != oldValue else { return }
            sidebarButton.isHidden = !showsSidebarButton
            needsLayout = true
        }
    }

    private var buttons: [NSView] = []
    private weak var address: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.toolbar)
        sidebarButton.isHidden = true
        addSubview(sidebarButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
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
        var sidebarButton: NSRect?
        var buttons: [NSRect]
        var address: NSRect
    }

    /// The sidebar's toggle when it's here, then the buttons, a button apart, then the address to the trailing inset,
    /// all centered on the lights' line. After the traffic lights the first glyph sits `Sidebar.lightsGap` after them,
    /// as the toggle's does in the sidebar's own top row; without them the first button starts `leadingInset` in.
    static func frames(width: CGFloat, buttons: Int, sidebarButton: Bool = false, trafficLightsWidth: CGFloat,
                       leadingInset: CGFloat = Tokens.Sidebar.edge, trailingInset: CGFloat) -> Frames {
        let mid = height / 2, b = Tokens.Sidebar.button
        let glyph = Tokens.Symbol.inkSize(sidebarButton ? "sidebar.left" : "chevron.left", size: Tokens.Sidebar.glyph).width
        var x = trafficLightsWidth > 0
            ? round(Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Sidebar.lightsGap - (b - glyph) / 2) : leadingInset
        func next() -> NSRect {
            defer { x += b }
            return NSRect(x: x, y: mid - b / 2, width: b, height: b)
        }
        let toggle = sidebarButton ? next() : nil
        let rects = (0..<buttons).map { _ in next() }
        let start = x + Tokens.Space.x2, h = Tokens.Sidebar.addressHeight
        return Frames(sidebarButton: toggle, buttons: rects,
                      address: NSRect(x: start, y: round(mid - h / 2), width: max(0, width - trailingInset - start), height: h))
    }

    /// Where the bar's controls start and end, from its own edges: the page's edges, pulled in by one inset on both
    /// ends, enough that the address never comes closer than `Sidebar.edge` to the window's edge. Framed, that's the
    /// page's edges themselves; borderless, the page meets the window, so they sit `Sidebar.edge` inside it.
    static func insets(bar: NSRect, page: NSRect, window: NSRect) -> (leading: CGFloat, trailing: CGFloat) {
        let inset = max(0, Tokens.Sidebar.edge - (window.maxX - page.maxX))
        return (page.minX - bar.minX + inset, bar.maxX - page.maxX + inset)
    }

    override func layout() {
        super.layout()
        let frames = Self.frames(width: bounds.width, buttons: buttons.count, sidebarButton: showsSidebarButton,
                                 trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset, trailingInset: trailingInset)
        if let toggle = frames.sidebarButton { sidebarButton.frame = toggle }
        for (button, frame) in zip(buttons, frames.buttons) where button.superview === self { button.frame = frame }
        if let address, address.superview === self { address.frame = frames.address }
    }
}

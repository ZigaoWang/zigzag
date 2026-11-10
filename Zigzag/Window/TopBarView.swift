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
    var showsSidebarButton = false { didSet { if showsSidebarButton != oldValue { refreshSidebarButton() } } }
    /// While the sidebar slides back in, its toggle stays here where the sidebar's own will land (this far from the
    /// window's left edge), still as the traffic lights, until the sidebar arrives with its own. Takes no room.
    var heldSidebarButtonX: CGFloat? { didSet { if heldSidebarButtonX != oldValue { refreshSidebarButton() } } }

    private func refreshSidebarButton() {
        sidebarButton.isHidden = !showsSidebarButton && heldSidebarButtonX == nil
        needsLayout = true
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

    /// Each control showing here and where it goes.
    private var places: [(view: NSView, frame: NSRect)] {
        let frames = Self.frames(width: bounds.width, buttons: buttons.count, sidebarButton: showsSidebarButton,
                                 trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset, trailingInset: trailingInset)
        var places: [(view: NSView, frame: NSRect)] = []
        if let toggle = frames.sidebarButton {
            places.append((sidebarButton, toggle))
        } else if let x = heldSidebarButtonX {
            let b = Tokens.Sidebar.button
            places.append((sidebarButton, NSRect(x: x - frame.minX, y: Self.height / 2 - b / 2, width: b, height: b)))
        }
        for (button, rect) in zip(buttons, frames.buttons) where button.superview === self { places.append((button, rect)) }
        if let address, address.superview === self { places.append((address, frames.address)) }
        return places
    }

    override func layout() {
        super.layout()
        guard !isSliding else { return }
        for place in places { place.view.frame = place.frame }
    }

    /// While the controls glide (`slideControls`), layout leaves them to it.
    private var isSliding = false

    /// Where each control showing is now, in the superview's terms: taken before the sidebar comes or goes.
    var controlPositions: [ObjectIdentifier: NSRect] {
        Dictionary(uniqueKeysWithValues: ([sidebarButton] + buttons + [address].compactMap { $0 })
            .filter { $0.superview === self && !$0.isHidden }
            .map { (ObjectIdentifier($0), $0.frame.offsetBy(dx: frame.minX, dy: frame.minY)) })
    }

    /// In an animation, with the bar where it stays for it: each control glides from where it was (`old`, from
    /// `controlPositions`) to its new place, so none jumps as the sidebar comes or goes. One that wasn't showing
    /// (the sidebar's toggle) appears where it goes, and stays put there as the traffic lights do.
    func slideControls(from old: [ObjectIdentifier: NSRect], curve: Tokens.Motion.Curve) {
        isSliding = true
        let places = places
        for place in places {
            let start = old[ObjectIdentifier(place.view)]?.offsetBy(dx: -frame.minX, dy: -frame.minY) ?? place.frame
            Tokens.Motion.withoutAnimation { place.view.frame = start }
        }
        // From the next turn of the run loop, once they're drawn where they start: an animation begun in the same one
        // starts from where they were last drawn instead, in the bar's old place.
        DispatchQueue.main.async {
            Tokens.Motion.animate(curve, evenFromKeyboard: true, moves: true) {
                for place in places { place.view.animator().frame = place.frame }
            }
        }
    }

    func endSlide() {
        isSliding = false
        needsLayout = true
    }
}

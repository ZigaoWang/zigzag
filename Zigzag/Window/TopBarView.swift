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
    /// From the bar's trailing edge to the address's end: where the page ends, or `Sidebar.edge` before it while the
    /// bar is the top of the page's card (`insets`).
    var trailingInset: CGFloat = Tokens.Sidebar.edge { didSet { if trailingInset != oldValue { needsLayout = true } } }

    /// The sidebar's toggle, first after the traffic lights while the sidebar is hidden: the sidebar's own is out of
    /// sight with it then. Shown, the sidebar keeps it in its own top row.
    let sidebarButton = SidebarView.chromeButton("sidebar.left", toolTip: String(localized: "Show Sidebar", comment: "Tooltip of the sidebar button while the sidebar is hidden."))
    var showsSidebarButton = false { didSet { if showsSidebarButton != oldValue { refreshSidebarButton() } } }
    /// While the sidebar slides back in, its toggle stays here where the sidebar's own will land (this place in the
    /// window), still as the traffic lights, until the sidebar arrives with its own. Takes no room.
    var heldSidebarButtonOrigin: NSPoint? { didSet { if heldSidebarButtonOrigin != oldValue { refreshSidebarButton() } } }

    private func refreshSidebarButton() {
        sidebarButton.isHidden = !showsSidebarButton && heldSidebarButtonOrigin == nil
        needsLayout = true
    }

    /// The page's own color under the bar (the page's card reaches up under it, `PageCardView.band`), nil while the
    /// window's frame shows through. Icons and text turn light or dark, whichever reads more clearly on it, and the
    /// fills turn the neutral washes a page's own controls use: the frame's white washes would vanish on a white page.
    var pageColor: NSColor? {
        didSet {
            guard pageColor != oldValue else { return }
            appearance = pageColor.flatMap { NSAppearance(named: Self.isDark($0) ? .darkAqua : .aqua) }
            refreshOnPage()
        }
    }

    private func refreshOnPage() {
        let onPage = pageColor != nil
        for case let button as IconButton in [sidebarButton] + buttons { button.isOnPage = onPage }
        (address as? AddressView)?.isOnPage = onPage
    }

    /// Whether a page's color takes light controls: white contrasts with it more than black (WCAG), so a mid gray
    /// keeps dark ones.
    static func isDark(_ color: NSColor) -> Bool { Brand.contrast(color, .white) > Brand.contrast(color, .black) }

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
        refreshOnPage()
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
        var x = leadX(sidebarButton: sidebarButton, trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset)
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

    /// Where the first control goes: its glyph `Sidebar.lightsGap` after the traffic lights, or `leadingInset` in.
    private static func leadX(sidebarButton: Bool, trafficLightsWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        let b = Tokens.Sidebar.button
        let glyph = Tokens.Symbol.inkSize(sidebarButton ? "sidebar.left" : "chevron.left", size: Tokens.Sidebar.glyph).width
        return trafficLightsWidth > 0 ? round(Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Sidebar.lightsGap - (b - glyph) / 2) : leadingInset
    }

    /// The inset the controls keep from the page's edges: none framed, `Sidebar.edge` where the page meets the
    /// window's edge, so nothing comes closer to it than that: its right edge, or its left one beside a sidebar on
    /// the right.
    static func edgeInset(page: NSRect, window: NSRect) -> CGFloat {
        max(0, Tokens.Sidebar.edge - min(window.maxX - page.maxX, page.minX - window.minX))
    }

    /// Where the bar's controls start and end, from its own edges: the page's edges, pulled in by one inset on both
    /// ends, enough that the address never comes closer than `Sidebar.edge` to the window's edge. Framed, that's the
    /// page's edges themselves; borderless, the page meets the window, so they sit `Sidebar.edge` inside it.
    /// `onCard`: the bar is the top of the page's card, in the page's color. The card's right edge is then an edge
    /// the address has to keep clear of too, framed as well: it ends `Sidebar.edge` before it. (The first button
    /// needs nothing more: its glyph sits that far inside its target.) On the plain bar, over Settings or a PDF,
    /// there's no such edge beside the address, and the frame's own inset is all the room it needs.
    static func insets(bar: NSRect, page: NSRect, window: NSRect, onCard: Bool = false) -> (leading: CGFloat, trailing: CGFloat) {
        let inset = edgeInset(page: page, window: window)
        return (page.minX - bar.minX + inset, bar.maxX - page.maxX + (onCard ? Tokens.Sidebar.edge : inset))
    }

    // MARK: Split view

    /// In split view, each pane's own strip (`PaneHeaderView`) is the bar over that pane, in place of the bar's own
    /// buttons and address, which would belong to neither page: one set of controls per page, in one row.
    private(set) var strips: [PaneHeaderView] = []
    /// Each strip's pane, its left and right edges in the bar's terms, in order with `strips`.
    private var stripPanes: [ClosedRange<CGFloat>] = []
    /// How far in from its pane's edges a strip keeps: the bar's own inset from the page's (`edgeInset`).
    var stripInset: CGFloat = 0 { didSet { if stripInset != oldValue { needsLayout = true } } }

    /// Takes the panes' strips into the row, over these panes (none: the row is the bar's own again). The bar's own
    /// controls are left as they are: the window fades them out or in (`ownControls`).
    func setStrips(_ strips: [PaneHeaderView], panes: [ClosedRange<CGFloat>]) {
        for strip in strips {
            if strip.superview !== self { addSubview(strip) }
            strip.isInBar = true
            strip.isHidden = false
        }
        if strips != self.strips || panes != stripPanes { needsLayout = true }
        self.strips = strips
        stripPanes = panes
    }

    /// The bar's own back, forward, reload and address, which step aside for the panes' strips.
    var ownControls: [NSView] { buttons + [address].compactMap { $0 } }

    struct Strip: Equatable {
        var frame: NSRect
        /// Its pane's middle, from the strip's leading edge: where its address centers.
        var addressCenter: CGFloat
    }

    /// Each pane's strip: the bar's height, over its pane, `inset` in from the pane's edges, and clear of the traffic
    /// lights and the sidebar's toggle at the row's leading end, so the first pane's back button is where the bar's
    /// own would be.
    static func stripFrames(panes: [ClosedRange<CGFloat>], sidebarButton: Bool = false, trafficLightsWidth: CGFloat,
                            leadingInset: CGFloat, inset: CGFloat) -> [Strip] {
        let start = leadX(sidebarButton: sidebarButton, trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset)
            + (sidebarButton ? Tokens.Sidebar.button : 0)
        return panes.map { pane in
            let minX = max(pane.lowerBound + inset, start), maxX = max(minX, pane.upperBound - inset)
            return Strip(frame: NSRect(x: minX, y: 0, width: maxX - minX, height: height),
                         addressCenter: (pane.lowerBound + pane.upperBound) / 2 - minX)
        }
    }

    /// How far below the bar's own top its row sits. While the sidebar slides, the bar is held over both where it was
    /// and where it's going; when those differ in height (the frame comes back with the sidebar in full screen), the
    /// row is where the bar will be, so the controls glide down or up with the page and nothing drops at the end.
    var rowTop: CGFloat = 0 { didSet { if rowTop != oldValue { needsLayout = true } } }

    /// Each control showing here and where it goes.
    private var places: [(view: NSView, frame: NSRect)] {
        let frames = Self.frames(width: bounds.width, buttons: buttons.count, sidebarButton: showsSidebarButton,
                                 trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset, trailingInset: trailingInset)
        var places: [(view: NSView, frame: NSRect)] = []
        if let toggle = frames.sidebarButton { places.append((sidebarButton, toggle)) }
        for (button, rect) in zip(buttons, frames.buttons) where button.superview === self { places.append((button, rect)) }
        if let address, address.superview === self { places.append((address, frames.address)) }
        for (strip, place) in zip(strips, stripPlaces) where strip.superview === self { places.append((strip, place.frame)) }
        places = places.map { ($0.view, $0.frame.offsetBy(dx: 0, dy: rowTop)) }
        // Held for the sidebar's own: where that one lands in the window, whatever the bar's row is doing.
        if frames.sidebarButton == nil, let origin = heldSidebarButtonOrigin {
            let b = Tokens.Sidebar.button
            places.append((sidebarButton, NSRect(x: origin.x - frame.minX, y: origin.y - frame.minY, width: b, height: b)))
        }
        return places
    }

    private var stripPlaces: [Strip] {
        Self.stripFrames(panes: stripPanes, sidebarButton: showsSidebarButton, trafficLightsWidth: trafficLightsWidth,
                         leadingInset: leadingInset, inset: stripInset)
    }

    private func centerStripAddresses() {
        for (strip, place) in zip(strips, stripPlaces) { strip.addressCenter = place.addressCenter }
    }

    override func layout() {
        super.layout()
        for place in places { place.view.frame = place.frame }
        centerStripAddresses()
    }

    /// Where each control showing is now, in the superview's terms: taken before the sidebar comes or goes.
    var controlPositions: [ObjectIdentifier: NSRect] {
        Dictionary(uniqueKeysWithValues: ([sidebarButton] + buttons + [address].compactMap { $0 } + (strips as [NSView]))
            .filter { $0.superview === self && !$0.isHidden }
            .map { (ObjectIdentifier($0), $0.frame.offsetBy(dx: frame.minX, dy: frame.minY)) })
    }

    /// With the bar where it stays for the slide: each control glides from where it was (`old`, from
    /// `controlPositions`) to its new place, so none jumps as the sidebar comes or goes. One that wasn't showing
    /// (the sidebar's toggle) appears where it goes, and stays put there as the traffic lights do.
    /// Each is in its new place at once and shown traveling there (`Motion.glide`), which says where it starts
    /// rather than leaving that to where it was last drawn: the bar has just moved under them, so that would be
    /// the wrong place, a sidebar's width off.
    func slideControls(from old: [ObjectIdentifier: NSRect], curve: Tokens.Motion.Curve) {
        centerStripAddresses()
        for place in places {
            let start = old[ObjectIdentifier(place.view)]?.offsetBy(dx: -frame.minX, dy: -frame.minY) ?? place.frame
            Tokens.Motion.withoutAnimation { place.view.frame = start }
            Tokens.Motion.glide(place.view, to: place.frame, duration: curve.duration, timing: curve.timing, resizes: true)
        }
    }
}

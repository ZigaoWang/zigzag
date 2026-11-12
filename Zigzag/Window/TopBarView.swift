import AppKit

/// The bar above the page (Settings › Appearance › Address bar above the page), as in Arc's and Chrome's top-bar
/// layout: back, forward and reload, then the address. They're the sidebar's own views, moved here rather than made
/// again, so their actions, the panels and popups that come out of them, the command bar and their tooltips work as
/// they do in the sidebar. It lies on the window's frame as the sidebar does, its middle on the traffic lights' line,
/// and like the sidebar it moves the window and zooms it on a double-click.
///
/// A page can bring tools of its own to the bar's trailing end (`accessory`), after the address. With the address
/// kept in the sidebar, the bar is there for them alone, and they sit at its trailing end all the same.
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
    /// sight with it then. Shown, the sidebar keeps it in its own top row. For a sidebar on the right it's last, at
    /// the bar's trailing end, the side the sidebar comes out of.
    let sidebarButton = SidebarView.chromeButton(SidebarView.toggleSymbol(onRight: false), toolTip: String(localized: "Show Sidebar", comment: "Tooltip of the sidebar button while the sidebar is hidden."))
    /// Whether the sidebar is on the window's right: the toggle sits at the bar's trailing end and its glyph mirrors.
    var sidebarOnRight = false {
        didSet {
            guard sidebarOnRight != oldValue else { return }
            sidebarButton.symbol = SidebarView.toggleSymbol(onRight: sidebarOnRight)
            needsLayout = true
        }
    }
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
            appearance = PageBar.inkAppearance(on: pageColor).flatMap(NSAppearance.init(named:))
            refreshOnPage()
        }
    }

    private func refreshOnPage() {
        let onPage = pageColor != nil
        for case let button as IconButton in [sidebarButton] + buttons { button.isOnPage = onPage }
        (address as? AddressView)?.isOnPage = onPage
        accessory?.isOnPage = onPage
    }

    /// The page's own tools, at the bar's trailing end after the address: as wide as they ask for in the room
    /// there is, which leaves the address `addressMinWidth` at least. The bar only gives them their place; whoever
    /// sets them owns what's in them.
    var accessory: TopBarAccessory? {
        didSet {
            guard accessory !== oldValue else { return }
            if oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let accessory { addSubview(accessory) }
            refreshOnPage()
            needsLayout = true
        }
    }
    /// The least the address keeps beside a page's tools, which give way first.
    static let addressMinWidth: CGFloat = 200

    private var buttons: [NSView] = []
    private weak var address: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.toolbar)
        sidebarButton.isHidden = true
        addSubview(sidebarButton)
        // Settings › Appearance › Sidebar size: the address held here takes its new height.
        sizeObserver = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }
    private var sizeObserver: NSObjectProtocol?

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }

    /// Takes the sidebar's buttons and address, in order.
    /// Back, forward and reload alone, after the traffic lights, while the bar is there for a page's tools and the
    /// address stays in the sidebar on the right: they're where the strip above the page has them there (#181), so
    /// nothing moves as you go between a development tab and any other.
    func hold(buttons: [NSView]) {
        self.buttons = buttons
        buttons.forEach(addSubview)
        refreshOnPage()
        needsLayout = true
    }

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
        /// The page's tools, when they take any room: the bar's whole height, ending where the address would.
        var accessory: NSRect?
    }

    /// The sidebar's toggle when it's here, then the buttons, a button apart, then the address to the trailing inset,
    /// all centered on the lights' line. After the traffic lights the first glyph sits `Sidebar.lightsGap` after them,
    /// as the toggle's does in the sidebar's own top row; without them the first button starts `leadingInset` in.
    /// `onRight`: the sidebar is on the right, so its toggle is at the bar's trailing end, where the sidebar's own
    /// lands (`trailingToggle`), with the address ending as far before it as it starts after the buttons.
    /// `accessory`: the width the page's tools take at the trailing end; the address ends a gap before them.
    static func frames(width: CGFloat, buttons: Int, sidebarButton: Bool = false, onRight: Bool = false, trafficLightsWidth: CGFloat,
                       leadingInset: CGFloat = Tokens.Sidebar.edge, trailingInset: CGFloat, accessory: CGFloat = 0) -> Frames {
        let mid = height / 2, b = Tokens.Sidebar.button
        let leads = sidebarButton && !onRight
        var x = leadX(sidebarButton: leads, trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset)
        func next() -> NSRect {
            defer { x += b }
            return NSRect(x: x, y: mid - b / 2, width: b, height: b)
        }
        let first = leads ? next() : nil
        let rects = (0..<buttons).map { _ in next() }
        let last = sidebarButton && onRight ? trailingToggle(width: width) : nil
        let start = x + Tokens.Space.x2, h = Tokens.Sidebar.addressHeight
        let end = min(width - trailingInset, last.map { $0.minX - Tokens.Space.x2 } ?? .infinity)
        let tools = accessory > 0 ? NSRect(x: max(start, end - accessory), y: 0, width: min(accessory, max(0, end - start)), height: height) : nil
        let addressEnd = tools.map { $0.minX - Tokens.Space.x2 } ?? end
        return Frames(sidebarButton: first ?? last, buttons: rects,
                      address: NSRect(x: start, y: round(mid - h / 2), width: max(0, addressEnd - start), height: h), accessory: tools)
    }

    /// The toggle at the bar's trailing end, for a sidebar on the right: `Sidebar.edge` in from the window's edge
    /// (the bar reaches it while the sidebar is hidden), where the sidebar's own sits in its top row
    /// (`SidebarView.topRowFrames`), so it stays put as the sidebar comes and goes, framed or not.
    private static func trailingToggle(width: CGFloat) -> NSRect {
        let b = Tokens.Sidebar.button
        return NSRect(x: width - Tokens.Sidebar.edge - b, y: height / 2 - b / 2, width: b, height: b)
    }

    /// Where the first control goes: its glyph `Sidebar.lightsGap` after the traffic lights, or `leadingInset` in.
    private static func leadX(sidebarButton: Bool, trafficLightsWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        let b = Tokens.Sidebar.button
        let glyph = Tokens.Symbol.inkSize(sidebarButton ? SidebarView.toggleSymbol(onRight: false) : "chevron.left", size: Tokens.Sidebar.glyph).width
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
    /// own would be. For a sidebar on the right the toggle is at the row's trailing end instead (`frames`), and the
    /// last strip ends where it starts.
    static func stripFrames(panes: [ClosedRange<CGFloat>], sidebarButton: Bool = false, onRight: Bool = false, width: CGFloat = 0,
                            trafficLightsWidth: CGFloat, leadingInset: CGFloat, inset: CGFloat) -> [Strip] {
        let leads = sidebarButton && !onRight
        let start = leadX(sidebarButton: leads, trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset)
            + (leads ? Tokens.Sidebar.button : 0)
        let end = sidebarButton && onRight ? trailingToggle(width: width).minX : .infinity
        return panes.map { pane in
            let minX = max(pane.lowerBound + inset, start), maxX = max(minX, min(pane.upperBound - inset, end))
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
        func frames(accessory: CGFloat) -> Frames {
            Self.frames(width: bounds.width, buttons: buttons.count, sidebarButton: showsSidebarButton, onRight: sidebarOnRight,
                        trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset, trailingInset: trailingInset, accessory: accessory)
        }
        // The page's tools take what they ask for of the room the address has, less what the address keeps while
        // it's here; with the panes' strips in the row (a split), there are none.
        var tools: CGFloat = 0
        if let accessory, strips.isEmpty {
            let holdsAddress = address?.superview === self
            tools = accessory.width(fitting: max(0, frames(accessory: 0).address.width - (holdsAddress ? Self.addressMinWidth + Tokens.Space.x2 : 0)))
        }
        accessory?.isHidden = tools <= 0
        let frames = frames(accessory: tools)
        var places: [(view: NSView, frame: NSRect)] = []
        if let accessory, let rect = frames.accessory { places.append((accessory, rect)) }
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
        Self.stripFrames(panes: stripPanes, sidebarButton: showsSidebarButton, onRight: sidebarOnRight, width: bounds.width,
                         trafficLightsWidth: trafficLightsWidth, leadingInset: leadingInset, inset: stripInset)
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
        Dictionary(uniqueKeysWithValues: ([sidebarButton] + buttons + [address, accessory].compactMap { $0 } + (strips as [NSView]))
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

/// A page's own tools in the bar above it (`TopBarView.accessory`).
protocol TopBarAccessory: NSView {
    /// The width they take when they have `room`: all of them, or as many as fit.
    func width(fitting room: CGFloat) -> CGFloat
    /// The bar is the top of the page's card, in the page's color: their fills are a page's, not the frame's.
    var isOnPage: Bool { get set }
}

/// The strip above the page beside a docked sidebar on the right, with the bar above the page off: the traffic lights
/// at its leading end, and back, forward and reload right after them, where the bar above the page has them, so the
/// lights sit in a toolbar rather than alone over an empty band (#181). The sidebar's own buttons, moved here while
/// the strip is there. Like the bar, it moves the window and zooms it on a double-click.
final class LightsStripView: NSView {
    private(set) var buttons: [IconButton] = []
    /// The traffic lights' width, for where the first button goes.
    var trafficLightsWidth: CGFloat = 0 { didSet { if trafficLightsWidth != oldValue { needsLayout = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the sidebar's back, forward and reload, in order.
    func hold(_ buttons: [IconButton]) {
        self.buttons = buttons
        for button in buttons {
            button.isOnPage = false
            addSubview(button)
        }
        needsLayout = true
    }

    /// Each button's place: as the bar above the page puts them after the lights, on the lights' line.
    static func buttonFrames(count: Int, trafficLightsWidth: CGFloat) -> [NSRect] {
        TopBarView.frames(width: 0, buttons: count, trafficLightsWidth: trafficLightsWidth, trailingInset: 0).buttons
    }

    override func layout() {
        super.layout()
        let frames = Self.buttonFrames(count: buttons.count, trafficLightsWidth: trafficLightsWidth)
        for (button, frame) in zip(buttons, frames) where button.superview === self { button.frame = frame }
    }
}

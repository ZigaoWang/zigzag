import AppKit

/// The slim strip on top of each pane in split view, on the page card's own surface: back, forward and reload at the
/// leading end, the page's address centered in a quiet pill, and the split's own buttons at the trailing end. A
/// hairline under it keeps it apart from the page. The pane you're not in dims it (`PageCardView`).
///
/// Everything in it belongs to its own pane's page (`show(_:)`), never the selected tab: its buttons act on that page,
/// and its address and loading state are that page's.
final class PaneHeaderView: NSView {
    let back = PaneHeaderView.button("chevron.left", toolTip: String(localized: "Back", comment: "Tooltip of a button in the strip on top of each page of a split view: goes back."))
    let forward = PaneHeaderView.button("chevron.right", toolTip: String(localized: "Forward", comment: "Tooltip of a button in the strip on top of each page of a split view: goes forward."))
    let reload = PaneHeaderView.button("arrow.clockwise", toolTip: String(localized: "Reload", comment: "Tooltip of a button in the strip on top of each page of a split view: reloads the page."))
    let orientation = PaneHeaderView.button("rectangle.split.1x2", toolTip: String(localized: "Stack Vertically", comment: "Tooltip of a button in the strip on top of each page of a split view: stacks the two pages one above the other."))
    let swap = PaneHeaderView.button("arrow.left.arrow.right", toolTip: String(localized: "Swap Sides", comment: "Tooltip of a button in the strip on top of each page of a split view: swaps the two pages."))
    /// Enlarges this pane over the others for a moment, and puts it back (#160).
    let zoom = PaneHeaderView.button("arrow.up.left.and.arrow.down.right", toolTip: PaneHeaderView.zoomTitle(false))
    /// This pane is the one enlarged over the others: its zoom button puts it back.
    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            zoom.symbol = isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            zoom.toolTip = Self.zoomTitle(isZoomed)
        }
    }

    /// Zoom Pane, or Return Pane while it's zoomed: the button's, the menu bar's and ⋯'s name for it.
    static func zoomTitle(_ zoomed: Bool) -> String {
        zoomed ? String(localized: "Return Pane", comment: "Tooltip and menu item: puts the enlarged page of a split view back in its place among the others.")
               : String(localized: "Zoom Pane", comment: "Tooltip and menu item: enlarges one page of a split view over the others for a moment, without changing where it is.")
    }
    let close = PaneHeaderView.button("rectangle.split.2x1.slash", toolTip: String(localized: "Separate Tabs", comment: "Tooltip of a button in the strip on top of each page of a split view: ends the split view, keeping both tabs."))
    /// Closes this pane's page; the other one fills the window, as closing either half from the sidebar does.
    let closeTab = PaneHeaderView.button("xmark", toolTip: String(localized: "Close Tab", comment: "Tooltip of a button in the strip on top of each page of a split view: closes that page's tab, leaving the other page."))
    /// Where the split's own buttons go when the pane is too narrow for them beside its address.
    let more = PaneHeaderView.button("ellipsis", toolTip: String(localized: "More", comment: "Tooltip of a button in the strip on top of each page of a narrow split view: opens a menu with the split's buttons that don't fit."))
    /// The page's address: click it to edit it, as the sidebar's address does for the page you're in.
    let address = PaneAddressView()
    private let line = ColorView(color: Tokens.Color.separator)
    /// Keeps the window still under the strip on the page, in the title bar's band too (`TitleBandGuard`).
    let windowGuard = TitleBandGuard()
    private(set) weak var tab: Tab?
    private var token: SignalToken?
    static let height = Tokens.Pane.height
    static let siteControlsTitle = String(localized: "Site Controls", comment: "Name of the button by the address that opens the site panel: its tooltip and VoiceOver name.")
    /// Clicked the address: edit this pane's page's address (the window focuses the pane first).
    var onEditAddress: ((Tab) -> Void)?
    /// Site Controls asked for, from the button at the address's end or ⋯: for this pane's page, under this view (#160).
    var onSiteControls: ((Tab, NSView) -> Void)?
    /// A split of two has swap and the layout; a tile group's pages keep the places they were dropped in (#160).
    var arrangesSplit = true { didSet { if arrangesSplit != oldValue { needsLayout = true } } }
    /// Up in the bar above the page (`TopBarView.strips`) instead of on the pane's card: the bar's height, on the
    /// window's frame, no hairline, and like the bar it moves the window and zooms it on a double-click.
    var isInBar = false {
        didSet {
            guard isInBar != oldValue else { return }
            line.isHidden = isInBar
            windowGuard.isHidden = isInBar
            refreshInk()
            needsLayout = true
        }
    }
    /// In the bar, where the address centers, from the strip's leading edge: over the middle of its pane, which can
    /// start under the traffic lights. Nil centers it on the strip.
    var addressCenter: CGFloat? { didSet { if addressCenter != oldValue { needsLayout = true } } }

    static func button(_ symbol: String, toolTip: String) -> IconButton {
        IconButton(symbol: symbol, size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph, toolTip: toolTip)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [windowGuard, back, forward, reload, address, zoom, swap, orientation, close, more, closeTab, line].forEach { addSubview($0) }
        more.onClick = { [weak self] _ in self?.showMore() }
        back.onClick = { [weak self] _ in self?.tab?.goBack() }
        forward.onClick = { [weak self] _ in self?.tab?.goForward() }
        reload.onClick = { [weak self] _ in
            guard let tab = self?.tab else { return }
            tab.isLoading ? tab.stopLoading() : tab.reload()
        }
        address.onClick = { [weak self] _ in
            guard let self, let tab = self.tab else { return }
            self.onEditAddress?(tab)
        }
        address.drop.onDrop = { [weak self] url in
            guard let tab = self?.tab else { return false }
            tab.load(url)
            return true
        }
        address.siteControls.onClick = { [weak self] _ in self?.openSiteControls() }
        address.siteControls.onRightClick = { [weak self] _ in self?.openSiteControls(); return nil }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Site Controls for this pane's page: under the address, or under ⋯ while the address has no room for its button.
    private func openSiteControls() {
        guard let tab else { return }
        onSiteControls?(tab, address.isHidden ? more : address)
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { isInBar }

    /// Pressed on the strip (not its buttons or address) and moved past `dragThreshold`: the pane is picked up, to be
    /// put somewhere else in its group (#160). Called with the press and the move that got past it.
    var onDrag: ((Tab, _ press: NSEvent, _ moved: NSEvent) -> Void)?
    /// How far the pointer goes before a press is a drag, so a click stays a click.
    static let dragThreshold: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        // Up in the bar, the strip is the bar's: it moves the window, as the rest of the bar does.
        if isInBar { window?.titleBarMouseDown(event); return }
        guard let window, let tab, let onDrag else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        var moved: NSEvent?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { next, stop in
            guard let next else { return }
            if next.type == .leftMouseUp { stop.pointee = true; return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= Self.dragThreshold {
                moved = next
                stop.pointee = true
            }
        }
        if let moved { onDrag(tab, event, moved) }
    }

    // MARK: Ink

    /// The color under the strip, its pane's page color on the card (nil: the card's plain ground). Its icons and text
    /// turn light or dark, whichever reads more clearly on it, as the bar above the page does (`TopBarView.pageColor`):
    /// on a dark page they'd be dark on dark otherwise.
    var ground: NSColor? {
        didSet {
            guard ground != oldValue else { return }
            refreshInk()
        }
    }

    private func refreshInk() {
        // Up in the bar, the bar's own appearance is the strip's.
        appearance = isInBar ? nil : PageBar.inkAppearance(on: ground).flatMap(NSAppearance.init(named:))
        let onPage = !isInBar && ground != nil
        [back, forward, reload, zoom, swap, orientation, close, more, closeTab, address.siteControls].forEach { $0.isOnPage = onPage }
    }

    func setVertical(_ vertical: Bool) {
        orientation.symbol = vertical ? "rectangle.split.2x1" : "rectangle.split.1x2"
        orientation.toolTip = vertical ? String(localized: "Side by Side", comment: "Tooltip of a button in the strip on top of each page of a split view: lays the two pages side by side.")
                                     : String(localized: "Stack Vertically", comment: "Tooltip of a button in the strip on top of each page of a split view: stacks the two pages one above the other.")
        swap.symbol = vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right"
        swap.toolTip = vertical ? String(localized: "Swap Top and Bottom", comment: "Tooltip of a button in the strip on top of each page of a split view: swaps the two stacked pages.")
                              : String(localized: "Swap Sides", comment: "Tooltip of a button in the strip on top of each page of a split view: swaps the two pages.")
        // The whole split's, not this page's: with its shortcut, as the window's own buttons say theirs.
        close.toolTip = Shortcuts.tooltip(String(localized: "Separate Tabs", comment: "Tooltip of a button in the strip on top of each page of a split view: ends the split view, keeping both tabs."),
                                          for: #selector(BrowserWindowController.closeSplitView(_:)))
    }

    func show(_ tab: Tab?) {
        if tab !== self.tab || token == nil {
            self.tab = tab
            token = tab?.changed.observe { [weak self, weak tab] change in
                // Only this pane's own page: a change from a page the header no longer shows is old news.
                guard let self, let tab, tab === self.tab else { return }
                if change == .url || change == .navigation || change == .loading { self.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        back.isEnabled = tab?.canGoBackOrReturn ?? false
        forward.isEnabled = tab?.canGoForward ?? false
        let loading = tab?.isLoading ?? false
        reload.symbol = loading ? "xmark" : "arrow.clockwise"
        reload.toolTip = loading ? String(localized: "Stop", comment: "Tooltip of a button in the strip on top of each page of a split view: stops the page loading.") : String(localized: "Reload", comment: "Tooltip of a button in the strip on top of each page of a split view: reloads the page.")
        address.text = tab?.url.map(CommandRanker.displayURL) ?? ""
        needsLayout = true
    }

    /// What the strip shows at a width, most first: its buttons give way one step at a time so the address keeps
    /// `Pane.addressMinWidth` and the close button is never cut. Swap and the layout go into ⋯ first, then Separate,
    /// then Forward, then Reload; Back and close stay.
    enum Fit: Int, CaseIterable, Comparable {
        case all, splitInMore, separateInMore, noForward, noReload
        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
        var showsForward: Bool { self < .noForward }
        var showsReload: Bool { self < .noReload }
        var showsSplitButtons: Bool { self == .all }
        var showsSeparate: Bool { self < .separateInMore }
        var showsMore: Bool { self > .all }
        /// Buttons at the leading end, and at the trailing end before the close button.
        var leading: Int { 1 + (showsForward ? 1 : 0) + (showsReload ? 1 : 0) }
        /// Zoom, swap and the layout go together.
        var trailing: Int { (showsSplitButtons ? 3 : 0) + (showsSeparate ? 1 : 0) + (showsMore ? 1 : 0) }
    }

    /// The first fit, most buttons first, that leaves the address its room. Zoom, swap and the layout stay out only
    /// while the address shows whole, up to twice `Pane.addressMinWidth`; the rest give way only to keep it that
    /// minimum. Too narrow for any, the fewest buttons.
    /// Without swap and the layout (`arrangesSplit` off), they take no room in any fit; zoom does.
    static func fit(width: CGFloat, edge: CGFloat, address: CGFloat, splitButtons: Bool = true) -> Fit {
        let b = Tokens.Pane.button, gap = Tokens.Space.x2
        for fit in Fit.allCases {
            let need = min(address, Tokens.Pane.addressMinWidth * (fit == .all ? 2 : 1))
            let lo = edge + CGFloat(fit.leading) * b + gap
            let trailing = fit.trailing - (!splitButtons && fit.showsSplitButtons ? 2 : 0)
            let hi = width - edge - b - gap - CGFloat(trailing) * b - gap
            if hi - lo >= need { return fit }
        }
        return .noReload
    }

    private var currentFit = Fit.all

    /// The buttons the strip has no room for, in its own menu under ⋯.
    private func showMore() {
        if let open = MenuPanel.current, open.anchor === more { open.close(); return }
        func item(_ button: IconButton, title: String? = nil) -> MenuPanel.Entry {
            .item(.init(title: title ?? button.toolTip ?? "", symbol: button.symbol, isEnabled: button.isEnabled) { [weak button] in
                if let button, let event = NSApp.currentEvent { button.onClick?(event) }
            })
        }
        var entries: [MenuPanel.Entry] = []
        // The address too narrow for its own button: Site Controls comes here, first, as it's about the page.
        if !address.showsSiteControls, tab != nil {
            entries.append(.item(.init(title: Self.siteControlsTitle, symbol: address.siteControls.symbol) { [weak self] in self?.openSiteControls() }))
            entries.append(.separator)
        }
        if !currentFit.showsForward { entries.append(item(forward)) }
        if !currentFit.showsReload { entries.append(item(reload)) }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(item(zoom))
        if arrangesSplit { entries += [item(swap), item(orientation)] }
        if !currentFit.showsSeparate {
            entries.append(item(close, title: String(localized: "Separate Tabs", comment: "Tooltip of a button in the strip on top of each page of a split view: ends the split view, keeping both tabs.")))
        }
        more.isSelected = true
        MenuPanel.show(entries, from: more) { [weak self] in self?.more.isSelected = false }
    }

    override func layout() {
        super.layout()
        let b = Tokens.Pane.button
        // In the bar, the buttons start and end at the strip's edges (the bar sets them where its own would be), on its
        // middle line, the traffic lights' line.
        let edge = isInBar ? 0 : floor((bounds.height - Tokens.Metric.hairline - b) / 2)
        let y = isInBar ? round((bounds.height - b) / 2) : edge
        let fit = Self.fit(width: bounds.width, edge: edge, address: address.text.isEmpty ? 0 : address.fittingWidth, splitButtons: arrangesSplit)
        currentFit = fit
        forward.isHidden = !fit.showsForward
        reload.isHidden = !fit.showsReload
        swap.isHidden = !fit.showsSplitButtons || !arrangesSplit
        orientation.isHidden = !fit.showsSplitButtons || !arrangesSplit
        zoom.isHidden = !fit.showsSplitButtons
        close.isHidden = !fit.showsSeparate
        more.isHidden = !fit.showsMore
        var x = edge
        for button in [back, forward, reload] where !button.isHidden {
            button.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b
        }
        closeTab.frame = NSRect(x: bounds.width - edge - b, y: y, width: b, height: b)
        // A little room between the split's own buttons and the one that closes the page, so it isn't hit by mistake.
        var trailing = closeTab.frame.minX - Tokens.Space.x2
        for button in [more, close, orientation, swap, zoom] where !button.isHidden {
            button.frame = NSRect(x: trailing - b, y: y, width: b, height: b)
            trailing -= b
        }
        [back, forward, reload, zoom, swap, orientation, close, more, closeTab].forEach { $0.radius = Tokens.Radius.control }
        // The address pill is centered over its pane, as wide as its text, within the room the buttons leave, and
        // nudged clear of them where centering would cut it.
        let h = Tokens.Pane.addressHeight
        let center = addressCenter ?? bounds.midX
        let lo = x + Tokens.Space.x2, hi = trailing - Tokens.Space.x2
        let pillWidth = max(0, min(hi - lo, address.fittingWidth))
        let pillX = min(max(center - pillWidth / 2, lo), hi - pillWidth)
        address.frame = NSRect(x: round(pillX), y: y + (b - h) / 2, width: pillWidth, height: h)
        address.isHidden = address.text.isEmpty || pillWidth < PaneAddressView.padding * 3
        line.frame = NSRect(x: 0, y: bounds.height - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
        windowGuard.frame = bounds
    }
}

/// Laid under a view in the band where a title bar would be, keeps a press there from moving the window. With
/// `.fullSizeContentView` the window server itself starts moving the window on a press in that band, before the app
/// sees it, everywhere but the parts AppKit marks as taken. It marks only controls (`NSControl`s) whose
/// `mouseDownCanMoveWindow` is false; a plain view's own false counts below the band but not in it. This control
/// marks its frame, and takes no clicks itself: they go to the view it lies under. Hidden, it marks nothing.
final class TitleBandGuard: NSControl {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    /// Out of the key view loop. Not by refusing first responder: AppKit then leaves the control out of the region.
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A pane's address: the page's address in a small field, a faint fill and a 1px edge. A click edits it.
final class PaneAddressView: InteractiveView {

    // MARK: Dropping a link or words (#182)

    /// Where a link, an address or words dropped on the field go (`AddressDrop`).
    private(set) lazy var drop = AddressDrop(self)
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drop.entered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { drop.exited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop.perform(sender) }
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textSecondary)
    static let padding = Tokens.Space.x2 + 2
    /// Site Controls for this pane's page, at the field's end as in the sidebar's address (#160).
    let siteControls = IconButton(symbol: "slider.horizontal.3", size: PaneAddressView.buttonSide, symbolSize: Tokens.Pane.glyph - 1,
                                  toolTip: PaneHeaderView.siteControlsTitle)
    static let buttonSide = Tokens.Pane.addressHeight - buttonInset * 2
    static let buttonInset: CGFloat = 2
    /// What the field keeps for its button: the button, its inset from the end, less the padding it stands in.
    static var buttonRoom: CGFloat { buttonSide + buttonInset * 2 - padding + Tokens.Space.x1 }
    /// The least of a cut address the field shows beside its button; any narrower and the button goes into the
    /// strip's ⋯, leaving the address its room.
    static let minTextWithButton: CGFloat = 56

    /// Whether the button shows at a width: beside the whole address, or beside enough of a cut one to read.
    static func showsButton(width: CGFloat, fitting: CGFloat, hasText: Bool) -> Bool {
        hasText && (width >= fitting - 0.5 || width >= padding * 2 + buttonRoom + minTextWithButton)
    }
    var showsSiteControls: Bool { !isHidden && !siteControls.isHidden }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue.isEmpty ? String(localized: "Address", comment: "VoiceOver name of the address in a split view page's strip, while it has none.") : newValue)
            needsLayout = true
        }
    }

    /// As wide as the whole address and the padding, with the few points a middle-truncating field keeps in hand
    /// before it cuts (centered, so they never show).
    var fittingWidth: CGFloat {
        let cell = label.cell.map { ceil($0.cellSize.width) - Label.inset * 2 } ?? 0
        return max(cell, label.inkWidth) + Self.padding * 2 + Self.slack + Self.buttonRoom
    }
    private static let slack: CGFloat = Tokens.Space.x2

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        addSubview(label)
        siteControls.radius = Tokens.Radius.control - Self.buttonInset
        siteControls.pressOutset = NSEdgeInsets(top: Self.buttonInset, left: 1, bottom: Self.buttonInset, right: Self.buttonInset)
        addSubview(siteControls)
        _ = drop
        setAccessibilityRole(.button)
        setAccessibilityHelp(String(localized: "Edit this page’s address", comment: "VoiceOver hint of the address in a split view page's strip."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        let button = Self.showsButton(width: bounds.width, fitting: fittingWidth, hasText: !text.isEmpty)
        siteControls.isHidden = !button
        let side = Self.buttonSide
        siteControls.frame = NSRect(x: bounds.width - Self.buttonInset - side, y: (bounds.height - side) / 2, width: side, height: side)
        label.frame = NSRect(x: Self.padding - Label.inset, y: (bounds.height - h) / 2,
                             width: max(0, bounds.width - Self.padding * 2 - (button ? Self.buttonRoom : 0) + Label.inset * 2), height: h)
    }

    override func stateDidChange(animated: Bool) {
        // The sidebar address's look, smaller: a faint fill and a 1px edge, a step deeper under the pointer.
        let fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.chromeHover : Tokens.Color.chromeFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = Tokens.Metric.hairline
            layer?.borderColor = cgColor(Tokens.Color.chromeEdge)
        }
    }
}

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
    let close = PaneHeaderView.button("rectangle.split.2x1.slash", toolTip: String(localized: "Separate Tabs", comment: "Tooltip of a button in the strip on top of each page of a split view: ends the split view, keeping both tabs."))
    /// Closes this pane's page; the other one fills the window, as closing either half from the sidebar does.
    let closeTab = PaneHeaderView.button("xmark", toolTip: String(localized: "Close Tab", comment: "Tooltip of a button in the strip on top of each page of a split view: closes that page's tab, leaving the other page."))
    /// The page's address: click it to edit it, as the sidebar's address does for the page you're in.
    let address = PaneAddressView()
    private let line = ColorView(color: Tokens.Color.separator)
    private(set) weak var tab: Tab?
    private var token: SignalToken?
    static let height = Tokens.Pane.height
    /// Clicked the address: edit this pane's page's address (the window focuses the pane first).
    var onEditAddress: ((Tab) -> Void)?

    static func button(_ symbol: String, toolTip: String) -> IconButton {
        IconButton(symbol: symbol, size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph, toolTip: toolTip)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [back, forward, reload, address, swap, orientation, close, closeTab, line].forEach { addSubview($0) }
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setVertical(_ vertical: Bool) {
        orientation.symbol = vertical ? "rectangle.split.2x1" : "rectangle.split.1x2"
        orientation.toolTip = vertical ? String(localized: "Side by Side", comment: "Tooltip of a button in the strip on top of each page of a split view: lays the two pages side by side.")
                                     : String(localized: "Stack Vertically", comment: "Tooltip of a button in the strip on top of each page of a split view: stacks the two pages one above the other.")
        swap.symbol = vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right"
        swap.toolTip = vertical ? String(localized: "Swap Top and Bottom", comment: "Tooltip of a button in the strip on top of each page of a split view: swaps the two stacked pages.")
                              : String(localized: "Swap Sides", comment: "Tooltip of a button in the strip on top of each page of a split view: swaps the two pages.")
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

    override func layout() {
        super.layout()
        let b = Tokens.Pane.button
        let edge = floor((bounds.height - Tokens.Metric.hairline - b) / 2)
        let y = edge
        var x = edge
        for button in [back, forward, reload] {
            button.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b
        }
        closeTab.frame = NSRect(x: bounds.width - edge - b, y: y, width: b, height: b)
        // A little room between the split's own buttons and the one that closes the page, so it isn't hit by mistake.
        close.frame = NSRect(x: closeTab.frame.minX - Tokens.Space.x2 - b, y: y, width: b, height: b)
        orientation.frame = NSRect(x: close.frame.minX - b, y: y, width: b, height: b)
        swap.frame = NSRect(x: orientation.frame.minX - b, y: y, width: b, height: b)
        [back, forward, reload, swap, orientation, close, closeTab].forEach { $0.radius = Tokens.Radius.control }
        // The address pill is centered on the pane, and as wide as its text, within the room the buttons leave.
        let room = max(0, min(bounds.midX - x, swap.frame.minX - bounds.midX) - Tokens.Space.x2) * 2
        let pillWidth = min(room, address.fittingWidth)
        let h = Tokens.Pane.addressHeight
        address.frame = NSRect(x: round(bounds.midX - pillWidth / 2), y: y + (b - h) / 2, width: pillWidth, height: h)
        address.isHidden = address.text.isEmpty || pillWidth < PaneAddressView.padding * 3
        line.frame = NSRect(x: 0, y: bounds.height - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
    }
}

/// A pane's address: the page's address in a small field, a faint fill and a 1px edge. A click edits it.
final class PaneAddressView: InteractiveView {
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textSecondary)
    static let padding = Tokens.Space.x2 + 2

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
        return max(cell, label.inkWidth) + Self.padding * 2 + Self.slack
    }
    private static let slack: CGFloat = Tokens.Space.x2

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        addSubview(label)
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
        label.frame = NSRect(x: Self.padding - Label.inset, y: (bounds.height - h) / 2,
                             width: max(0, bounds.width - Self.padding * 2 + Label.inset * 2), height: h)
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

import AppKit

/// The slim strip on top of each pane in split view, on the page card's own surface: back, forward and reload at the
/// leading end, the page's address centered in a quiet pill, and the split's own buttons at the trailing end. A
/// hairline under it keeps it apart from the page. The pane you're not in dims it (`PageCardView`).
final class PaneHeaderView: NSView {
    let back = IconButton(symbol: "chevron.left", size: Tokens.Metric.paneButton, toolTip: "Back")
    let forward = IconButton(symbol: "chevron.right", size: Tokens.Metric.paneButton, toolTip: "Forward")
    let reload = IconButton(symbol: "arrow.clockwise", size: Tokens.Metric.paneButton, toolTip: "Reload")
    let orientation = IconButton(symbol: "rectangle.split.1x2", size: Tokens.Metric.paneButton, toolTip: "Stack Vertically")
    let swap = IconButton(symbol: "arrow.left.arrow.right", size: Tokens.Metric.paneButton, symbolSize: Tokens.TypeSize.small, toolTip: "Swap Sides")
    let close = IconButton(symbol: "rectangle.split.2x1.slash", size: Tokens.Metric.paneButton, toolTip: "Separate Tabs")
    private let addressPill = ColorView(color: Tokens.Color.addressFill)
    private let address = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let line = ColorView(color: Tokens.Color.separator)
    private weak var tab: Tab?
    private var token: SignalToken?
    static let height = Tokens.Metric.paneHeaderHeight

    override init(frame: NSRect) {
        super.init(frame: frame)
        address.lineBreakMode = .byTruncatingMiddle
        address.alignment = .center
        addressPill.wantsLayer = true
        addressPill.layer?.cornerCurve = .continuous
        [back, forward, reload, addressPill, address, swap, orientation, close, line].forEach { addSubview($0) }
        back.onClick = { [weak self] _ in self?.tab?.goBack() }
        forward.onClick = { [weak self] _ in self?.tab?.goForward() }
        reload.onClick = { [weak self] _ in
            guard let tab = self?.tab else { return }
            tab.isLoading ? tab.stopLoading() : tab.reload()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setVertical(_ vertical: Bool) {
        orientation.symbol = vertical ? "rectangle.split.2x1" : "rectangle.split.1x2"
        orientation.toolTip = vertical ? "Side by Side" : "Stack Vertically"
        swap.symbol = vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right"
        swap.toolTip = vertical ? "Swap Top and Bottom" : "Swap Sides"
    }

    func show(_ tab: Tab?) {
        self.tab = tab
        token = tab?.changed.observe { [weak self] change in
            if change == .url || change == .navigation || change == .loading { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        back.isEnabled = tab?.canGoBackOrReturn ?? false
        forward.isEnabled = tab?.canGoForward ?? false
        reload.symbol = (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise"
        reload.toolTip = (tab?.isLoading ?? false) ? "Stop" : "Reload"
        address.stringValue = tab?.url.map(CommandRanker.displayURL) ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = Tokens.Metric.paneButton
        let edge = (bounds.height - Tokens.Metric.hairline - b) / 2
        let y = edge
        var x = edge
        for button in [back, forward, reload] {
            button.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b
        }
        close.frame = NSRect(x: bounds.width - edge - b, y: y, width: b, height: b)
        orientation.frame = NSRect(x: close.frame.minX - b, y: y, width: b, height: b)
        swap.frame = NSRect(x: orientation.frame.minX - b, y: y, width: b, height: b)
        [back, forward, reload, swap, orientation, close].forEach { $0.radius = Tokens.Radius.control }
        // The address pill is centered on the pane, and as wide as its text, within the room the buttons leave.
        let room = max(0, min(bounds.midX - x, swap.frame.minX - bounds.midX) - Tokens.Space.x2) * 2
        let padding = Tokens.Space.x3
        let pillWidth = min(room, address.inkWidth + padding * 2)
        let pill = NSRect(x: round(bounds.midX - pillWidth / 2), y: y, width: pillWidth, height: b)
        addressPill.frame = pill
        addressPill.layer?.cornerRadius = b / 2
        addressPill.isHidden = address.stringValue.isEmpty || pillWidth < padding * 3
        let h = address.lineHeight
        address.frame = NSRect(x: pill.minX + padding - Label.inset, y: pill.midY - h / 2,
                               width: max(0, pill.width - padding * 2 + Label.inset * 2), height: h)
        line.frame = NSRect(x: 0, y: bounds.height - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
    }
}

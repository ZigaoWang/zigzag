import AppKit

/// The slim strip on top of each pane in split view: its own back, forward and reload,
/// the page's address, and a button to take the pane out of the split.
final class PaneHeaderView: NSView {
    let back = IconButton(symbol: "chevron.left", size: Tokens.Space.x6, toolTip: "Back")
    let forward = IconButton(symbol: "chevron.right", size: Tokens.Space.x6, toolTip: "Forward")
    let reload = IconButton(symbol: "arrow.clockwise", size: Tokens.Space.x6, toolTip: "Reload")
    let orientation = IconButton(symbol: "rectangle.split.1x2", size: Tokens.Space.x6, toolTip: "Stack Vertically")
    let close = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Close Split View")
    private let address = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let line = ColorView(color: Tokens.Color.separator)
    private weak var tab: Tab?
    private var token: SignalToken?
    static let height = Tokens.Space.x8 + Tokens.Space.x1

    override init(frame: NSRect) {
        super.init(frame: frame)
        address.lineBreakMode = .byTruncatingMiddle
        [back, forward, reload, address, orientation, close, line].forEach { addSubview($0) }
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
    }

    func show(_ tab: Tab?) {
        self.tab = tab
        token = tab?.changed.observe { [weak self] change in
            if change == .url || change == .navigation || change == .loading { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        back.isEnabled = tab?.canGoBack ?? false
        forward.isEnabled = tab?.canGoForward ?? false
        reload.symbol = (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise"
        address.stringValue = tab?.url.map(CommandRanker.displayURL) ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = Tokens.Space.x6
        let y = (bounds.height - b) / 2
        var x = Tokens.Space.x2
        for button in [back, forward, reload] {
            button.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b
        }
        close.frame = NSRect(x: bounds.width - Tokens.Space.x2 - b, y: y, width: b, height: b)
        orientation.frame = NSRect(x: close.frame.minX - b, y: y, width: b, height: b)
        let h = address.lineHeight
        let textX = x + Tokens.Space.x2
        address.frame = NSRect(x: textX, y: (bounds.height - h) / 2, width: max(0, orientation.frame.minX - textX - Tokens.Space.x2), height: h)
        line.frame = NSRect(x: 0, y: bounds.height - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
    }
}

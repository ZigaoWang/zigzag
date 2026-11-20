import AppKit

/// The peek's compact browser chrome: back, forward, address, reload, extensions and Expand.
struct EdgePeekToolbarState {
    let address: String
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
}

final class EdgePeekToolbar: NSView {
    let backButton = IconButton(symbol: "chevron.left", size: .compact, toolTip: String(localized: "Back", comment: "Tooltip of the peek's Back button."))
    let forwardButton = IconButton(symbol: "chevron.right", size: .compact, toolTip: String(localized: "Forward", comment: "Tooltip of the peek's Forward button."))
    let addressField = NSTextField()
    let reloadButton = IconButton(symbol: "arrow.clockwise", size: .compact, toolTip: String(localized: "Reload", comment: "Tooltip of the peek's Reload button."))
    let extensionsButton = IconButton(symbol: "puzzlepiece.extension", size: .compact, toolTip: String(localized: "Extensions", comment: "Tooltip of the peek's Extensions button."))
    let expandButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: .compact, toolTip: String(localized: "Expand to Browser", comment: "Tooltip of the button that turns the peek into the browser window."))

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onAddress: ((String) -> Void)?
    var onExtensions: ((IconButton) -> Void)?
    var onExpand: (() -> Void)?

    private let addressBackground = ColorView(color: NSColor.labelColor.withAlphaComponent(0.07))

    override init(frame: NSRect) {
        super.init(frame: frame)
        addressBackground.layer?.cornerRadius = Tokens.Radius.field
        addressBackground.layer?.cornerCurve = .continuous
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.font = .systemFont(ofSize: Tokens.Pane.addressText)
        addressField.textColor = Tokens.Color.textPrimary
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        [backButton, forwardButton, addressBackground, reloadButton, extensionsButton, expandButton].forEach(addSubview)
        addressBackground.addSubview(addressField)
        backButton.onClick = { [weak self] _ in guard self?.backButton.isEnabled == true else { return }; self?.onBack?() }
        forwardButton.onClick = { [weak self] _ in guard self?.forwardButton.isEnabled == true else { return }; self?.onForward?() }
        reloadButton.onClick = { [weak self] _ in self?.onReload?() }
        extensionsButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.onExtensions?(self.extensionsButton)
        }
        expandButton.onClick = { [weak self] _ in self?.onExpand?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(state: EdgePeekToolbarState) {
        if addressField.currentEditor() == nil { addressField.stringValue = state.address }
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        reloadButton.isLoading = state.isLoading
    }

    func focusAddress() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressSubmitted() {
        onAddress?(addressField.stringValue)
    }

    override func layout() {
        super.layout()
        let button = Tokens.Pane.button
        let y = (bounds.height - button) / 2
        var x = Tokens.Space.x2
        backButton.frame = NSRect(x: x, y: y, width: button, height: button)
        x = backButton.frame.maxX + Tokens.Space.x1
        forwardButton.frame = NSRect(x: x, y: y, width: button, height: button)
        x = forwardButton.frame.maxX + Tokens.Space.x2
        let right = bounds.width - Tokens.Space.x2
        expandButton.frame = NSRect(x: right - button, y: y, width: button, height: button)
        extensionsButton.frame = NSRect(x: expandButton.frame.minX - button - Tokens.Space.x1, y: y, width: button, height: button)
        reloadButton.frame = NSRect(x: extensionsButton.frame.minX - button - Tokens.Space.x1, y: y, width: button, height: button)
        let addressRight = reloadButton.frame.minX - Tokens.Space.x2
        let addressHeight = Tokens.Pane.addressHeight
        addressBackground.frame = NSRect(x: x, y: (bounds.height - addressHeight) / 2,
                                         width: max(0, addressRight - x), height: addressHeight)
        addressField.frame = addressBackground.bounds.insetBy(dx: Tokens.Space.x2, dy: 0)
    }
}

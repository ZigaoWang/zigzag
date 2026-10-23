import AppKit

/// Shown once, in the empty page of a brand-new install, when Arc is on the Mac.
final class WelcomeView: NSView {
    private let title = Label("Coming from Arc?", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let body: NSTextField
    private let importButton = PrimaryButton(title: "Import from Arc")
    private let skipButton = TextButton(title: "Not Now", font: Tokens.Font.body(.medium))
    var onImport: (() -> Void)?
    var onSkip: (() -> Void)?

    override init(frame: NSRect) {
        body = NSTextField(wrappingLabelWithString: "Bring over your spaces, pinned tabs and history in one step. Arc stays exactly as it is.")
        super.init(frame: frame)
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textSecondary
        body.alignment = .center
        body.isSelectable = false
        title.alignment = .center
        [title, body, importButton, skipButton].forEach { addSubview($0) }
        importButton.onClick = { [weak self] _ in self?.onImport?() }
        skipButton.onClick = { [weak self] _ in self?.onSkip?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width: CGFloat = 320
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: width, height: 200)).height)
        let buttonHeight = Tokens.Space.x8
        let total = title.lineHeight + Tokens.Space.x2 + bodyHeight + Tokens.Space.x6 + buttonHeight + Tokens.Space.x2 + buttonHeight
        var y = round((bounds.height - total) / 2)
        let x = round((bounds.width - width) / 2)
        title.frame = NSRect(x: x, y: y, width: width, height: title.lineHeight)
        y = title.frame.maxY + Tokens.Space.x2
        body.frame = NSRect(x: x, y: y, width: width, height: bodyHeight)
        y = body.frame.maxY + Tokens.Space.x6
        let iw = importButton.fittingWidth
        importButton.frame = NSRect(x: round(bounds.midX - iw / 2), y: y, width: iw, height: buttonHeight)
        y = importButton.frame.maxY + Tokens.Space.x2
        let sw = skipButton.fittingWidth
        skipButton.frame = NSRect(x: round(bounds.midX - sw / 2), y: y, width: sw, height: buttonHeight)
    }
}

/// The one filled button style: the main action on a screen.
final class PrimaryButton: InteractiveView {
    private let label: Label

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.semibold), color: .white)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { label.textWidth + Tokens.Space.x8 }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: Tokens.Space.x4, y: (bounds.height - h) / 2, width: bounds.width - Tokens.Space.x8, height: h)
        label.alignment = .center
    }

    override func stateDidChange(animated: Bool) {
        let base = Tokens.Color.accent
        let color = !isEnabled ? base.withAlphaComponent(Tokens.Opacity.disabled) : isPressed ? (base.shadow(withLevel: 0.15) ?? base) : isHovered ? (base.highlight(withLevel: 0.08) ?? base) : base
        layer?.set(backgroundColor: cgColor(color), animated: false)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}

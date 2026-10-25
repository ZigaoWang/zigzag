import AppKit

/// The one place an extension asks for something: before it's added, and when an update wants more access.
/// It floats over the top of the page like the other panels. Return confirms, Escape cancels.
@available(macOS 15.4, *)
final class ExtensionSheet: FloatingPanelView {
    struct Content {
        var icon: NSImage?
        var title: String
        var subtitle: String
        var heading: String
        var report: ExtensionReport
        var confirm: String
        var cancel: String
    }

    private static weak var current: ExtensionSheet?

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let headingLabel: Label
    private var rows: [(NSImageView, NSTextField)] = []
    private let limitsBox = ColorView(color: Tokens.Color.fieldFill)
    private let limitsIcon = NSImageView()
    private let limitsText = NSTextField(wrappingLabelWithString: "")
    private let confirmButton: PrimaryButton
    private let cancelButton: TextButton
    private var monitor: Any?
    private var onConfirm: () -> Void = {}
    private var onCancel: () -> Void = {}

    static let width: CGFloat = 360

    private init(_ content: Content) {
        // Both wrap: an extension's name, or an update's sentence, can be longer than one line.
        titleLabel = NSTextField(wrappingLabelWithString: content.title)
        titleLabel.font = Tokens.Font.body(.semibold)
        titleLabel.textColor = Tokens.Color.textPrimary
        titleLabel.maximumNumberOfLines = 2
        titleLabel.isSelectable = false
        subtitleLabel = NSTextField(wrappingLabelWithString: content.subtitle)
        subtitleLabel.font = Tokens.Font.small()
        subtitleLabel.textColor = Tokens.Color.textSecondary
        subtitleLabel.isSelectable = false
        headingLabel = Label(content.heading, font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
        confirmButton = PrimaryButton(title: content.confirm)
        cancelButton = TextButton(title: content.cancel, font: Tokens.Font.body(.medium))
        super.init(frame: .zero)
        iconView.image = content.icon ?? Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.TypeSize.large)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        [iconView, titleLabel, subtitleLabel].forEach { addSubview($0) }
        if !content.report.abilities.isEmpty { addSubview(headingLabel) }
        for line in content.report.abilities {
            let symbol = NSImageView(image: Tokens.Symbol.image(line.symbol))
            symbol.contentTintColor = Tokens.Color.icon
            let text = NSTextField(wrappingLabelWithString: line.text)
            text.font = Tokens.Font.body()
            text.textColor = Tokens.Color.textPrimary
            text.isSelectable = false
            addSubview(symbol)
            addSubview(text)
            rows.append((symbol, text))
        }
        if !content.report.limits.isEmpty {
            limitsBox.wantsLayer = true
            limitsBox.layer?.cornerRadius = Tokens.Radius.row
            limitsBox.layer?.cornerCurve = .continuous
            limitsIcon.image = Tokens.Symbol.image("exclamationmark.triangle", size: Tokens.TypeSize.small)
            limitsIcon.contentTintColor = Tokens.Color.textSecondary
            // One sentence: the names run on in lower case ("…: side panel, notifications.").
            let names = content.report.limits.map { $0.prefix(1).lowercased() + $0.dropFirst() }
            limitsText.stringValue = "Won’t work in Zigzag: " + ListFormatter.localizedString(byJoining: names) + "."
            limitsText.font = Tokens.Font.small()
            limitsText.textColor = Tokens.Color.textSecondary
            limitsText.isSelectable = false
            addSubview(limitsBox)
            limitsBox.addSubview(limitsIcon)
            limitsBox.addSubview(limitsText)
        }
        addSubview(cancelButton)
        addSubview(confirmButton)
        confirmButton.onClick = { [weak self] _ in self?.finish(confirmed: true) }
        cancelButton.onClick = { [weak self] _ in self?.finish(confirmed: false) }
        frame.size = NSSize(width: Self.width, height: layoutContent(dryRun: true))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the sheet over the page of a window, replacing any other one.
    static func present(_ content: Content, in controller: BrowserWindowController,
                        onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}) {
        current?.finish(confirmed: false)
        let sheet = ExtensionSheet(content)
        sheet.onConfirm = onConfirm
        sheet.onCancel = onCancel
        let card = controller.root.cardFrame
        sheet.frame.origin = NSPoint(x: round(card.midX - width / 2), y: card.minY + Tokens.Space.x6)
        controller.root.overlay.addSubview(sheet)
        sheet.needsLayout = true
        sheet.present()
        current = sheet
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, event.window === sheet.window else { return event }
            switch event.keyCode {
            case 36, 76: sheet.finish(confirmed: true); return nil   // Return, Enter
            case 53: sheet.finish(confirmed: false); return nil      // Escape
            default: return event
            }
        }
    }

    #if DEBUG
    static func debugCancel() { current?.finish(confirmed: false) }
    #endif

    private func finish(confirmed: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.current === self { Self.current = nil }
        dismiss(always: true)
        confirmed ? onConfirm() : onCancel()
        onConfirm = {}
        onCancel = {}
    }

    override func layout() {
        super.layout()
        _ = layoutContent(dryRun: false)
    }

    /// Lays everything out top to bottom and returns the height it needs.
    private func layoutContent(dryRun: Bool) -> CGFloat {
        let pad = Tokens.Space.x4
        let inner = Self.width - pad * 2
        func place(_ view: NSView, _ rect: NSRect) { if !dryRun { view.frame = rect } }
        var y = pad
        let iconSize = Tokens.Space.x10
        place(iconView, NSRect(x: pad, y: y, width: iconSize, height: iconSize))
        let textX = pad + iconSize + Tokens.Space.x3
        let textWidth = Self.width - textX - pad
        let titleHeight = ceil(titleLabel.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
        let subtitleHeight = ceil(subtitleLabel.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
        let textHeight = titleHeight + 2 + subtitleHeight
        let textY = y + max(0, (iconSize - textHeight) / 2)
        place(titleLabel, NSRect(x: textX, y: textY, width: textWidth, height: titleHeight))
        place(subtitleLabel, NSRect(x: textX, y: textY + titleHeight + 2, width: textWidth, height: subtitleHeight))
        y += max(iconSize, textHeight) + Tokens.Space.x4
        if !rows.isEmpty {
            place(headingLabel, NSRect(x: pad, y: y, width: inner, height: headingLabel.lineHeight))
            y += headingLabel.lineHeight + Tokens.Space.x2
            for (symbol, text) in rows {
                let textWidth = inner - Tokens.Space.x6
                text.preferredMaxLayoutWidth = textWidth
                let h = ceil(text.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
                // The symbol sits on the first line, however many lines the text takes.
                let firstLine = ceil(text.font?.boundingRectForFont.height ?? Tokens.Space.x4)
                place(symbol, NSRect(x: pad, y: y, width: Tokens.Space.x4, height: min(firstLine, h)))
                place(text, NSRect(x: pad + Tokens.Space.x6, y: y, width: textWidth, height: h))
                y += h + Tokens.Space.x2
            }
            y += Tokens.Space.x1
        }
        if limitsBox.superview != nil {
            let boxPad = Tokens.Space.x3
            let textWidth = inner - boxPad * 2 - Tokens.Space.x5
            limitsText.preferredMaxLayoutWidth = textWidth
            let h = ceil(limitsText.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
            let boxHeight = h + boxPad * 2
            place(limitsBox, NSRect(x: pad, y: y, width: inner, height: boxHeight))
            let firstLine = ceil(limitsText.font?.boundingRectForFont.height ?? Tokens.Space.x4)
            place(limitsIcon, NSRect(x: boxPad, y: boxPad, width: Tokens.Space.x4, height: min(firstLine, h)))
            place(limitsText, NSRect(x: boxPad + Tokens.Space.x5, y: boxPad, width: textWidth, height: h))
            y += boxHeight + Tokens.Space.x4
        } else {
            y += Tokens.Space.x2
        }
        let buttonHeight = Tokens.Space.x8
        let confirmWidth = confirmButton.fittingWidth
        place(confirmButton, NSRect(x: Self.width - pad - confirmWidth, y: y, width: confirmWidth, height: buttonHeight))
        let cancelWidth = cancelButton.fittingWidth
        place(cancelButton, NSRect(x: Self.width - pad - confirmWidth - Tokens.Space.x2 - cancelWidth, y: y, width: cancelWidth, height: buttonHeight))
        y += buttonHeight + pad
        return y
    }
}

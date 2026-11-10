import AppKit
import WebKit

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
        /// Where it's going, when there's a choice (which profile an extension is added to): a label, the places,
        /// and the one chosen to begin with.
        var destination: Destination?
    }

    struct Destination {
        var label: String
        var options: [DropdownButton.Option]
        var selected: Int
    }

    private let destinationLabel = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let destinationButton = DropdownButton()
    /// The place chosen, when the sheet offered a choice.
    var destinationIndex: Int { destinationButton.selectedIndex }

    private static weak var current: ExtensionSheet?
    /// Whether one is up, so an extension's own question never takes the place of one you're answering.
    static var isShowing: Bool { current != nil }

    private let header: DialogHeader
    private let headingLabel: Label
    private var rows: [(NSImageView, NSTextField)] = []
    private let limitsBox = ColorView(color: Tokens.Color.fieldFill)
    private let limitsIcon = NSImageView()
    private let limitsText = NSTextField(wrappingLabelWithString: "")
    private let buttons = DialogButtons()
    private let confirmButton: PillButton
    private let cancelButton: PillButton
    private var monitor: Any?
    private var onConfirm: () -> Void = {}
    private var onCancel: () -> Void = {}

    static let width: CGFloat = Tokens.Dialog.width

    private init(_ content: Content) {
        // The title wraps: an extension's name, or an update's sentence, can be longer than one line.
        header = DialogHeader(title: content.title, subtitle: content.subtitle)
        headingLabel = Label(content.heading, font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
        confirmButton = PillButton(title: content.confirm, style: .prominent)
        cancelButton = PillButton(title: content.cancel, style: .plain)
        super.init(frame: .zero)
        if let icon = content.icon {
            header.setImage(icon)
        } else {
            header.setSymbol("puzzlepiece.extension", tint: Tokens.Color.icon)
        }
        addSubview(header)
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
            limitsIcon.image = Tokens.Symbol.image("exclamationmark.triangle", size: Tokens.Symbol.inline)
            limitsIcon.contentTintColor = Tokens.Color.textSecondary
            // One sentence: the names run on in lower case ("…: side panel, notifications.").
            let names = content.report.limits.map { $0.prefix(1).lowercased() + $0.dropFirst() }
            let list = Words.list(names)
            limitsText.stringValue = String(localized: "Won’t work in Zigzag: \(list).",
                                            comment: "In the extension install sheet. The placeholder lists features the extension uses that Zigzag lacks, like “side panel and notifications”.")
            limitsText.font = Tokens.Font.small()
            limitsText.textColor = Tokens.Color.textSecondary
            limitsText.isSelectable = false
            addSubview(limitsBox)
            limitsBox.addSubview(limitsIcon)
            limitsBox.addSubview(limitsText)
        }
        if let destination = content.destination {
            destinationLabel.stringValue = destination.label
            destinationButton.options = destination.options
            destinationButton.selectedIndex = destination.selected
            addSubview(destinationLabel)
            addSubview(destinationButton)
        }
        addSubview(buttons)
        buttons.trailing = [cancelButton, confirmButton]
        confirmButton.onClick = { [weak self] _ in self?.finish(confirmed: true) }
        cancelButton.onClick = { [weak self] _ in self?.finish(confirmed: false) }
        frame.size = NSSize(width: Self.width, height: layoutContent(dryRun: true))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the sheet over the page of a window, replacing any other one.
    @discardableResult
    static func present(_ content: Content, in controller: BrowserWindowController,
                        onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}) -> ExtensionSheet {
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
            guard let sheet, let window = sheet.window, event.window === window else { return event }
            // Its menu of places, while open, has the keys.
            if MenuPanel.current != nil { return event }
            // Return goes to whatever you're typing in (a page's field, a word being composed), never to "Add".
            var view = window.firstResponder as? NSView
            while let current = view, !(current is WKWebView) { view = current.superview }
            let typing = window.firstResponder is NSTextView || view != nil
            switch event.keyCode {
            case 36 where !typing, 76 where !typing: sheet.finish(confirmed: true); return nil   // Return, Enter
            case 53: sheet.finish(confirmed: false); return nil      // Escape
            default: return event
            }
        }
        return sheet
    }

    #if DEBUG
    static func debugCancel() { current?.finish(confirmed: false) }
    static func debugConfirm() { current?.finish(confirmed: true) }
    static func debugChoose(destination index: Int) { current?.destinationButton.selectedIndex = index }
    #endif

    private func finish(confirmed: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Self.current === self { Self.current = nil }
        dismiss()
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
        let pad = Tokens.Dialog.padding
        let inner = Self.width - pad * 2
        func place(_ view: NSView, _ rect: NSRect) { if !dryRun { view.frame = rect } }
        var y = pad
        let headerHeight = header.height(for: inner)
        place(header, NSRect(x: pad, y: y, width: inner, height: headerHeight))
        y += headerHeight + Tokens.Dialog.gap
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
        if destinationButton.superview != nil {
            let h = Tokens.Page.controlHeight
            let menuWidth = min(destinationButton.intrinsicContentSize.width, inner - destinationLabel.textWidth - Tokens.Space.x3)
            place(destinationLabel, NSRect(x: pad - Label.inset, y: y + round((h - destinationLabel.lineHeight) / 2), width: inner - menuWidth, height: destinationLabel.lineHeight))
            place(destinationButton, NSRect(x: pad + inner - menuWidth, y: y, width: menuWidth, height: h))
            y += h + Tokens.Space.x4
        }
        place(buttons, NSRect(x: pad, y: y, width: inner, height: DialogButtons.height))
        y += DialogButtons.height + pad
        return y
    }
}

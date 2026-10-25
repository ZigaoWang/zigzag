import AppKit

/// A website's alert, confirm, prompt or sign-in, drawn as Zigzag's own sheet over the window: who's asking, what
/// they say, their fields, and Zigzag buttons. From a page's second dialog on, it offers to block the rest, so a
/// page stuck showing dialogs can't take the window hostage.
final class PageDialogSheet: NSView {
    struct Field {
        let placeholder: String
        var value: String = ""
        var secure = false
    }

    enum Result {
        case confirmed([String])
        case cancelled
        /// Don't show this page's dialogs any more (until it loads something new).
        case blocked
    }

    private let panel = FloatingPanelView()
    private let titleLabel: Label
    private let body: NSTextField
    private var inputs: [FilledField] = []
    private let confirm: PrimaryButton
    private let cancel = TextButton.form("Cancel")
    private let block = TextButton(title: "Block Dialogs", font: Tokens.Font.body(.medium))
    private var monitor: Any?
    private var completion: (Result) -> Void
    private let width: CGFloat = 380
    private let pad = Tokens.Space.x5

    private init(title: String, message: String, fields: [Field], confirmTitle: String, showsCancel: Bool, offersBlock: Bool,
                 completion: @escaping (Result) -> Void) {
        titleLabel = Label(title, font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        body = NSTextField(wrappingLabelWithString: message)
        confirm = PrimaryButton(title: confirmTitle)
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textPrimary
        body.isSelectable = true
        body.maximumNumberOfLines = 12
        addSubview(panel)
        [titleLabel, body, confirm].forEach { panel.addSubview($0) }
        for field in fields {
            let input = FilledField(placeholder: field.placeholder, secure: field.secure)
            input.stringValue = field.value
            panel.addSubview(input)
            inputs.append(input)
        }
        if showsCancel { panel.addSubview(cancel) }
        if offersBlock {
            block.textColor = Tokens.Color.textSecondary
            block.toolTip = "Don’t let this page show more dialogs"
            panel.addSubview(block)
        }
        confirm.onClick = { [weak self] _ in self?.finish(.confirmed(self?.inputs.map(\.stringValue) ?? [])) }
        cancel.onClick = { [weak self] _ in self?.finish(.cancelled) }
        block.onClick = { [weak self] _ in self?.finish(.blocked) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @MainActor
    static func ask(in window: NSWindow, title: String, message: String, fields: [Field] = [], confirmTitle: String = "OK",
                    showsCancel: Bool, offersBlock: Bool) async -> Result {
        guard let host = window.contentView else { return .cancelled }
        return await withCheckedContinuation { continuation in
            let sheet = PageDialogSheet(title: title, message: message, fields: fields, confirmTitle: confirmTitle,
                                        showsCancel: showsCancel, offersBlock: offersBlock) { continuation.resume(returning: $0) }
            sheet.frame = host.bounds
            sheet.autoresizingMask = [.width, .height]
            host.addSubview(sheet)
            sheet.layer?.backgroundColor = sheet.cgColor(Tokens.Color.scrim)
            sheet.panel.present(always: true)
            if let first = sheet.inputs.first { window.makeFirstResponder(first.field) }
            // Return answers (the page asked, and is waiting); Escape cancels.
            sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
                guard let sheet, event.window === window else { return event }
                switch event.keyCode {
                case 36, 76: sheet.finish(.confirmed(sheet.inputs.map(\.stringValue))); return nil
                case 53: sheet.finish(sheet.cancel.superview == nil ? .confirmed([]) : .cancelled); return nil
                default: return event
                }
            }
        }
    }

    private func finish(_ result: Result) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let completion = self.completion
        self.completion = { _ in }
        removeFromSuperview()
        completion(result)
    }

    /// Its window closed with it up: the page hears "cancel" rather than waiting forever.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, monitor != nil { finish(.cancelled) }
    }

    // Clicks on the backdrop don't reach the page underneath.
    override func mouseDown(with event: NSEvent) {}

    private var bodyHeight: CGFloat { ceil(body.sizeThatFits(NSSize(width: width - pad * 2, height: 600)).height) }
    private let fieldHeight: CGFloat = 36

    override func layout() {
        super.layout()
        let fields = CGFloat(inputs.count) * (fieldHeight + Tokens.Space.x2)
        let height = pad + titleLabel.lineHeight + Tokens.Space.x2 + bodyHeight + Tokens.Space.x4 + fields + Tokens.Space.x2 + Tokens.Space.x8 + pad
        panel.frame = NSRect(x: round((bounds.width - width) / 2), y: round((bounds.height - height) / 2.4), width: width, height: height)
    }

    private func layoutPanel() {
        let inner = panel.bounds.width - pad * 2
        titleLabel.frame = NSRect(x: pad, y: pad, width: inner, height: titleLabel.lineHeight)
        body.frame = NSRect(x: pad, y: titleLabel.frame.maxY + Tokens.Space.x2, width: inner, height: bodyHeight)
        var y = body.frame.maxY + Tokens.Space.x4
        for input in inputs {
            input.frame = NSRect(x: pad, y: y, width: inner, height: fieldHeight)
            y += fieldHeight + Tokens.Space.x2
        }
        y += inputs.isEmpty ? 0 : Tokens.Space.x2
        let h = Tokens.Space.x8
        let cw = max(confirm.fittingWidth, 80)
        confirm.frame = NSRect(x: panel.bounds.width - pad - cw, y: y, width: cw, height: h)
        let xw = cancel.fittingWidth + Tokens.Space.x2
        cancel.frame = NSRect(x: confirm.frame.minX - Tokens.Space.x2 - xw, y: y, width: xw, height: h)
        block.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: block.fittingWidth, height: h)
    }
}

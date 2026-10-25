import AppKit

/// A confirmation drawn over a window's content: a dimmed backdrop and a small panel with what will happen and
/// two buttons. Return confirms, Escape cancels. Used where a choice needs a pause, like exporting passwords.
/// It can offer a second way forward too (`choose`), drawn as a quiet button beside the main one.
final class ConfirmSheet: NSView {
    enum Choice { case confirm, alternate, cancel }

    private let panel = FloatingPanelView()
    private let titleLabel: Label
    private let body: NSTextField
    private let confirm: PrimaryButton
    private let cancel = TextButton(title: "Cancel", font: Tokens.Font.body(.medium))
    private let alternate: TextButton?
    private var monitor: Any?
    private var completion: (Choice) -> Void

    private init(title: String, message: String, confirmTitle: String, alternateTitle: String? = nil, destructive: Bool, completion: @escaping (Choice) -> Void) {
        titleLabel = Label(title, font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
        body = NSTextField(wrappingLabelWithString: message)
        confirm = PrimaryButton(title: confirmTitle)
        confirm.isDestructive = destructive
        alternate = alternateTitle.map(TextButton.form)
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textSecondary
        body.isSelectable = false
        addSubview(panel)
        [titleLabel, body, cancel, confirm].forEach { panel.addSubview($0) }
        if let alternate { panel.addSubview(alternate) }
        confirm.onClick = { [weak self] _ in self?.finish(.confirm) }
        alternate?.onClick = { [weak self] _ in self?.finish(.alternate) }
        cancel.onClick = { [weak self] _ in self?.finish(.cancel) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static func show(in host: NSView, title: String, message: String, confirmTitle: String, destructive: Bool = false, completion: @escaping (Bool) -> Void) {
        present(ConfirmSheet(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive) { completion($0 == .confirm) }, in: host)
    }

    /// Two ways forward and Cancel: Return picks `confirmTitle`, Escape cancels.
    static func choose(in host: NSView, title: String, message: String, confirmTitle: String, alternateTitle: String, completion: @escaping (Choice) -> Void) {
        present(ConfirmSheet(title: title, message: message, confirmTitle: confirmTitle, alternateTitle: alternateTitle, destructive: false, completion: completion), in: host)
    }

    private static func present(_ sheet: ConfirmSheet, in host: NSView) {
        sheet.frame = host.bounds
        sheet.autoresizingMask = [.width, .height]
        host.addSubview(sheet)
        sheet.updateBackdrop()
        sheet.alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.feedback, { sheet.animator().alphaValue = 1 })
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, event.window === host.window else { return event }
            switch event.keyCode {
            case 36, 76: sheet.finish(.confirm); return nil
            case 53: sheet.finish(.cancel); return nil
            default: return event
            }
        }
    }

    /// Something that didn't work, said plainly, with one button to acknowledge it.
    static func notice(in host: NSView, title: String, message: String) {
        show(in: host, title: title, message: message, confirmTitle: "OK") { _ in }
        (host.subviews.last as? ConfirmSheet)?.cancel.isHidden = true
    }

    #if DEBUG
    func debugCancel() { finish(.cancel) }
    #endif

    private func finish(_ choice: Choice) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let completion = self.completion
        self.completion = { _ in }
        Tokens.Motion.animate(Tokens.Motion.feedback, { self.animator().alphaValue = 0 }, completion: { self.removeFromSuperview() })
        completion(choice)
    }

    // Clicks on the backdrop don't reach the window underneath.
    override func mouseDown(with event: NSEvent) {}

    private func updateBackdrop() {
        layer?.backgroundColor = cgColor(Tokens.Color.scrim)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackdrop()
    }

    private let width: CGFloat = 360

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x5
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: width - pad * 2, height: 400)).height)
        let height = pad + titleLabel.lineHeight + Tokens.Space.x2 + bodyHeight + Tokens.Space.x5 + Tokens.Space.x8 + pad
        panel.frame = NSRect(x: round((bounds.width - width) / 2), y: round((bounds.height - height) / 2.4), width: width, height: height)
    }

    private func layoutPanel() {
        let pad = Tokens.Space.x5
        let inner = panel.bounds.width - pad * 2
        titleLabel.frame = NSRect(x: pad, y: pad, width: inner, height: titleLabel.lineHeight)
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: inner, height: 400)).height)
        body.frame = NSRect(x: pad, y: titleLabel.frame.maxY + Tokens.Space.x2, width: inner, height: bodyHeight)
        let y = body.frame.maxY + Tokens.Space.x5
        let cw = max(confirm.fittingWidth, 88)
        confirm.frame = NSRect(x: panel.bounds.width - pad - cw, y: y, width: cw, height: Tokens.Space.x8)
        var trailing = confirm.frame.minX
        if let alternate {
            let aw = alternate.fittingWidth + Tokens.Space.x2
            alternate.frame = NSRect(x: trailing - Tokens.Space.x2 - aw, y: y, width: aw, height: Tokens.Space.x8)
            trailing = alternate.frame.minX
        }
        let xw = cancel.fittingWidth
        cancel.frame = NSRect(x: trailing - Tokens.Space.x2 - xw, y: y, width: xw, height: Tokens.Space.x8)
    }
}

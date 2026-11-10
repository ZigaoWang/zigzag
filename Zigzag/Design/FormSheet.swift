import AppKit

/// A small form drawn over a window's content, as ConfirmSheet is: a dimmed backdrop and a panel with a heading, a
/// few things to fill in or choose, and two buttons. For what needs more than yes or no: naming a new profile, or
/// typing a name to show you mean to delete it.
///
/// Return confirms once the form can be confirmed, unless that's destructive: then, as in ConfirmSheet, it takes a
/// click, so a Return meant for the field can't throw anything away. Escape cancels. While it's up it has the
/// keyboard: typing goes to its fields, and shortcuts like ⌘W don't reach the page or window behind it.
final class FormSheet: NSView, NSTextFieldDelegate {
    /// One line of the form: a control with its label before it, or, with no label, something as wide as the form
    /// (a field, a line of text).
    struct Row {
        var label: String?
        var view: NSView
        var height: CGFloat = Tokens.Metric.controlHeight

        /// A quiet line of words, wrapped to the form's width.
        static func note(_ text: String) -> Row {
            let field = NSTextField.dialogText(text, font: Tokens.Font.detail())
            return Row(label: nil, view: field, height: 0)
        }
    }

    private let panel = FloatingPanelView()
    private let header: DialogHeader
    private let body: NSTextField?
    private var rows: [Row]
    private var labels: [Label?] = []
    private let buttons = DialogButtons()
    private let confirm: PillButton
    private let cancel = PillButton(title: String(localized: "Cancel", comment: "Button in a sheet that asks before doing something."), style: .plain)
    private let isDestructive: Bool
    private let canConfirm: () -> Bool
    private var completion: (Bool) -> Void
    private var monitor: Any?
    private weak var previousResponder: NSResponder?

    private init(title: String, symbol: String?, message: String?, rows: [Row], confirmTitle: String, destructive: Bool,
                 canConfirm: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        header = DialogHeader(title: title)
        body = message.map { .dialogText($0) }
        self.rows = rows
        confirm = PillButton(title: confirmTitle, style: .prominent)
        confirm.isDestructive = destructive
        isDestructive = destructive
        self.canConfirm = canConfirm
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        if let symbol { header.setSymbol(symbol, tint: destructive ? Tokens.Color.destructive : Tokens.Color.icon) }
        addSubview(panel)
        panel.addSubview(header)
        if let body { panel.addSubview(body) }
        for row in rows {
            let label = row.label.map { Label($0, font: Tokens.Font.body(), color: Tokens.Color.textPrimary) }
            labels.append(label)
            if let label { panel.addSubview(label) }
            panel.addSubview(row.view)
            // Typing in any of its fields can change whether it may be confirmed.
            (row.view as? FilledField)?.field.delegate = self
        }
        panel.addSubview(buttons)
        buttons.trailing = [cancel, confirm]
        confirm.onClick = { [weak self] _ in self?.finish(true) }
        cancel.onClick = { [weak self] _ in self?.finish(false) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(title)
        revalidate()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Shows the form over `host`. `canConfirm` is asked whenever something in it changes (call `revalidate` after
    /// changing a control that isn't a field). `completion` hears true for the main button, false for Cancel.
    @discardableResult
    static func show(in host: NSView, title: String, symbol: String? = nil, message: String? = nil, rows: [Row], confirmTitle: String,
                     destructive: Bool = false, canConfirm: @escaping () -> Bool = { true }, completion: @escaping (Bool) -> Void) -> FormSheet {
        let sheet = FormSheet(title: title, symbol: symbol, message: message, rows: rows, confirmTitle: confirmTitle, destructive: destructive,
                              canConfirm: canConfirm, completion: completion)
        sheet.frame = host.bounds
        sheet.autoresizingMask = [.width, .height]
        host.addSubview(sheet)
        sheet.updateBackdrop()
        sheet.alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.entering, evenFromKeyboard: true, { sheet.animator().alphaValue = 1 })
        sheet.layoutSubtreeIfNeeded()
        sheet.panel.growsFrom = Tokens.Motion.sheetOrigin
        sheet.panel.present(arrival: .pop)
        if let window = host.window {
            sheet.previousResponder = window.firstResponder
            // Straight into its first field, when it has one.
            let first = rows.lazy.compactMap { $0.view as? FilledField }.first
            window.makeFirstResponder(first?.field ?? sheet)
            first?.field.currentEditor()?.selectAll(nil)
        }
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, let window = sheet.window, event.window === window else { return event }
            return sheet.handle(event, in: window)
        }
        return sheet
    }

    /// The main button follows what's been filled in.
    func revalidate() { confirm.isEnabled = canConfirm() }

    func controlTextDidChange(_ obj: Notification) { revalidate() }

    /// What a key does while a form is up.
    enum KeyAction: Equatable {
        case confirm, cancel
        /// On to whatever has the keyboard: a field being typed in, or a button Tab reached.
        case pass
        /// Nothing: it goes no further.
        case swallow
    }

    /// Escape cancels. Return confirms a form that can be confirmed, never a destructive one. Typing and editing keys
    /// (⌘A, ⌘C, ⌘V, ⌘X, ⌘Z) go to the field; any other shortcut stops here, except ⌘Q, which asks about quitting itself.
    static func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?, destructive: Bool, canConfirm: Bool,
                          composing: Bool) -> KeyAction {
        // Mid-word in a Chinese or Japanese input method, Return and Escape belong to it.
        if composing { return .pass }
        let mods = modifiers.intersection([.command, .option, .control])
        if mods.contains(.command) {
            guard mods == .command, let key = characters?.lowercased() else { return .swallow }
            return ["a", "c", "v", "x", "z", "q"].contains(key) ? .pass : .swallow
        }
        switch keyCode {
        case 53: return .cancel
        case 36, 76: return mods.isEmpty && canConfirm && !destructive ? .confirm : .swallow
        default: return .pass
        }
    }

    private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        // A dropdown's menu, open over the form, has the keys while it's up.
        if MenuPanel.current != nil { return event }
        let composing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch Self.keyAction(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers,
                              destructive: isDestructive, canConfirm: canConfirm(), composing: composing) {
        case .confirm: finish(true)
        case .cancel: finish(false)
        case .pass: return event
        case .swallow: break
        }
        return nil
    }

    #if DEBUG
    /// Answers the form as its buttons would, for scripted checks. Confirming one that can't be confirmed does nothing.
    func debugAnswer(_ confirmed: Bool) {
        if confirmed, !canConfirm() { return }
        finish(confirmed)
    }
    #endif

    private func finish(_ confirmed: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        giveBackKeyboard()
        let completion = self.completion
        self.completion = { _ in }
        panel.dismiss()
        Tokens.Motion.animate(Tokens.Motion.leaving, evenFromKeyboard: true, { self.animator().alphaValue = 0 }, completion: { self.removeFromSuperview() })
        completion(confirmed)
    }

    private func giveBackKeyboard() {
        guard let window, let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) else { return }
        var previous = previousResponder as? NSView
        if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSView }
        if let view = previous, view.window === window, !view.isDescendant(of: self) {
            window.makeFirstResponder(view)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    /// Taken away without an answer (its host went): the key monitor goes with it.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            giveBackKeyboard()
        }
        super.viewWillMove(toSuperview: newSuperview)
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

    // MARK: Layout

    private var width: CGFloat { min(Tokens.Dialog.width, bounds.width - Tokens.Space.x6 * 2) }
    private let rowGap = Tokens.Space.x3

    private func height(of row: Row, width: CGFloat) -> CGFloat {
        if row.height > 0 { return row.height }
        return (row.view as? NSTextField)?.wrappedHeight(width) ?? Tokens.Metric.controlHeight
    }

    private func height(for width: CGFloat) -> CGFloat {
        let pad = Tokens.Dialog.padding, inner = width - pad * 2
        var height = pad + header.height(for: inner)
        if let body { height += Tokens.Space.x2 + body.wrappedHeight(inner) }
        height += Tokens.Dialog.gap
        for row in rows { height += self.height(of: row, width: inner) + rowGap }
        return height - rowGap + Tokens.Dialog.gap + DialogButtons.height + pad
    }

    override func layout() {
        super.layout()
        let height = height(for: width)
        panel.frame = NSRect(x: round((bounds.width - width) / 2), y: round((bounds.height - height) / 2.4), width: width, height: height)
    }

    private func layoutPanel() {
        let pad = Tokens.Dialog.padding
        let inner = panel.bounds.width - pad * 2
        header.frame = NSRect(x: pad, y: pad, width: inner, height: header.height(for: inner))
        var y = header.frame.maxY
        if let body {
            body.frame = NSRect(x: pad, y: y + Tokens.Space.x2, width: inner, height: body.wrappedHeight(inner))
            y = body.frame.maxY
        }
        y += Tokens.Dialog.gap
        // Labels share a column, so the controls after them line up.
        let labelWidth = labels.compactMap { $0?.intrinsicContentSize.width }.max().map { ceil($0) + Tokens.Space.x3 } ?? 0
        for (row, label) in zip(rows, labels) {
            let height = self.height(of: row, width: inner)
            if let label {
                let lh = ceil(label.intrinsicContentSize.height)
                label.frame = NSRect(x: pad, y: y + round((height - lh) / 2), width: labelWidth, height: lh)
                // A control keeps its own width at the row's end, as Settings' rows do; anything else fills the row.
                let fitting = (row.view as? DropdownButton)?.intrinsicContentSize.width
                let width = min(fitting ?? inner - labelWidth, inner - labelWidth)
                row.view.frame = NSRect(x: pad + inner - width, y: y, width: width, height: height)
            } else {
                row.view.frame = NSRect(x: pad, y: y, width: inner, height: height)
            }
            y += height + rowGap
        }
        buttons.frame = NSRect(x: pad, y: panel.bounds.height - pad - DialogButtons.height, width: inner, height: DialogButtons.height)
    }
}

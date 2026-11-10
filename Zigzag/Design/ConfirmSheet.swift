import AppKit

/// A confirmation drawn over a window's content: a dimmed backdrop and a small panel with what will happen and
/// two buttons. Return confirms, Escape cancels. Used where a choice needs a pause, like exporting passwords.
/// It can offer a second way forward too (`choose`), drawn as a quiet button beside the main one.
/// A destructive one (deleting, clearing) never goes ahead on Return: it takes a click, or Tab to the button and
/// Space, so a Return meant for something else can't throw anything away. While it's up it has the keyboard: typing
/// and shortcuts like ⌘W don't reach the page or window behind it.
final class ConfirmSheet: NSView {
    enum Choice { case confirm, alternate, cancel }

    private let panel = FloatingPanelView()
    private let header: DialogHeader
    private let body: NSTextField
    private let buttons = DialogButtons()
    private let confirm: PillButton
    private let cancel = PillButton(title: String(localized: "Cancel", comment: "Button in a sheet that asks before doing something."), style: .plain)
    private let alternate: PillButton?
    private var monitor: Any?
    private let isDestructive: Bool
    /// Where the keyboard was, given back when the sheet goes.
    private weak var previousResponder: NSResponder?
    private var completion: (Choice) -> Void

    private init(title: String, message: String, confirmTitle: String, alternateTitle: String? = nil, destructive: Bool, completion: @escaping (Choice) -> Void) {
        header = DialogHeader(title: title)
        body = .dialogText(message)
        confirm = PillButton(title: confirmTitle, style: .prominent)
        confirm.isDestructive = destructive
        isDestructive = destructive
        alternate = alternateTitle.map { PillButton(title: $0, style: .plain) }
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        [header, body, buttons].forEach { panel.addSubview($0) }
        buttons.trailing = [cancel, alternate, confirm].compactMap { $0 }
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
        // A question that interrupts you always eases in and out, even when a key brought it: unlike a menu you call
        // up many times a day, it should never just snap onto the window.
        Tokens.Motion.animate(Tokens.Motion.entering, evenFromKeyboard: true, { sheet.animator().alphaValue = 1 })
        sheet.layoutSubtreeIfNeeded()
        sheet.panel.growsFrom = Tokens.Motion.sheetOrigin
        sheet.panel.present(arrival: .pop)
        // The keyboard comes to the sheet, so typing doesn't go on into the page or field behind it.
        if let window = host.window {
            sheet.previousResponder = window.firstResponder
            window.makeFirstResponder(sheet)
        }
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, let window = sheet.window, event.window === window else { return event }
            return sheet.handle(event, in: window)
        }
    }

    /// What a key does while a sheet is up.
    enum KeyAction: Equatable {
        case confirm, cancel
        /// Tab or Shift-Tab: to the sheet's next (or previous) button.
        case moveFocus(backward: Bool)
        /// To the button Tab reached, which presses it.
        case press
        /// Nothing: no key gets past the sheet to the page or window behind it.
        case swallow
        /// On to the app as usual (⌘Q, which asks about quitting itself).
        case pass
    }

    /// Return and Escape answer, Tab moves between its buttons, Space presses the one with the focus ring. A
    /// destructive sheet never confirms on Return: its button takes a click, or Tab to it and Space. `focused` is the
    /// button Tab reached, if any: `confirmFocused` says whether it's the main one.
    static func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?, destructive: Bool,
                          buttonFocused: Bool, confirmFocused: Bool) -> KeyAction {
        let mods = modifiers.intersection([.command, .option, .control])
        if mods == .command, characters?.lowercased() == "q" { return .pass }
        switch keyCode {
        case 53:
            return .cancel
        case 48:
            return mods.isEmpty ? .moveFocus(backward: modifiers.contains(.shift)) : .swallow
        case 49:
            return mods.isEmpty && buttonFocused ? .press : .swallow
        case 36, 76:
            guard mods.isEmpty else { return .swallow }
            if buttonFocused { return destructive && confirmFocused ? .swallow : .press }
            return destructive ? .swallow : .confirm
        default:
            return .swallow
        }
    }

    /// Every key while it's up goes through here; ⌘W and other shortcuts don't reach the page behind it.
    private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        let focused = (window.firstResponder as? InteractiveView).flatMap { $0.isDescendant(of: panel) && $0.hasKeyboardFocus ? $0 : nil }
        switch Self.keyAction(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers,
                              destructive: isDestructive, buttonFocused: focused != nil, confirmFocused: focused === confirm) {
        case .confirm: finish(.confirm)
        case .cancel: finish(.cancel)
        case .moveFocus(let backward): moveFocus(backward: backward, in: window)
        case .press, .pass: return event
        case .swallow: break
        }
        return nil
    }

    /// Tab and Shift-Tab go round the sheet's own buttons, never out to the page behind. With Full Keyboard Access
    /// off, buttons don't take focus, so there's nowhere to go.
    private func moveFocus(backward: Bool, in window: NSWindow) {
        let stops = ([cancel, alternate, confirm] as [InteractiveView?]).compactMap { $0 }.filter(\.canBecomeKeyView)
        guard !stops.isEmpty else { return }
        let current = stops.firstIndex { $0 === window.firstResponder }
        let next: Int
        if let current {
            next = (current + (backward ? stops.count - 1 : 1)) % stops.count
        } else {
            next = backward ? stops.count - 1 : 0
        }
        window.makeFirstResponder(stops[next])
    }

    override var acceptsFirstResponder: Bool { true }

    /// Removing an extension deletes its data too, and can't be undone, so it asks first, from Settings and from the
    /// extension's own menu alike.
    static func removeExtension(id: String, name: String?, from profile: Profile, in host: NSView) {
        let title = name.map { name in String(localized: "Remove \(name)?", comment: "Title of the sheet that asks before removing an extension. The placeholder is the extension's name.") }
            ?? String(localized: "Remove this extension?", comment: "Title of the sheet that asks before removing an extension without a name.")
        show(in: host, title: title,
             message: String(localized: "Its settings and data on this Mac are deleted too. You can add it again from the Chrome Web Store.", comment: "Message of the sheet that asks before removing an extension."),
             confirmTitle: String(localized: "Remove", comment: "Button of the sheet that asks before removing an extension."), destructive: true) { confirmed in
            if confirmed { ExtensionStore.uninstall(id, from: profile) }
        }
    }

    /// Something that didn't work, said plainly, with one button to acknowledge it.
    static func notice(in host: NSView, title: String, message: String) {
        show(in: host, title: title, message: message, confirmTitle: String(localized: "OK", comment: "Button of a sheet that says something didn't work.")) { _ in }
        (host.subviews.last as? ConfirmSheet)?.cancel.isHidden = true
    }

    #if DEBUG
    func debugCancel() { finish(.cancel) }
    func debugConfirm() { finish(.confirm) }
    #endif

    private func finish(_ choice: Choice) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        giveBackKeyboard()
        let completion = self.completion
        self.completion = { _ in }
        panel.dismiss()
        Tokens.Motion.animate(Tokens.Motion.leaving, evenFromKeyboard: true, { self.animator().alphaValue = 0 }, completion: { self.removeFromSuperview() })
        completion(choice)
    }

    /// The keyboard goes back where it was, if that's still in the window.
    private func giveBackKeyboard() {
        guard let window, let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) else { return }
        var previous = previousResponder as? NSView
        // Typing in a field was in its field editor, which isn't the field's for long: the field itself takes it back.
        if let editor = previous as? NSTextView, editor.isFieldEditor { previous = editor.delegate as? NSView }
        if let view = previous, view.window === window, !view.isDescendant(of: self) {
            window.makeFirstResponder(view)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    /// Taken away without an answer (its host went, or ⌘Q a second time took it down): the key monitor goes with it,
    /// rather than eating keys for a sheet no one can see. Whoever took it away answers for it.
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

    /// The dialog's width: the shared one, narrower only in a small window.
    private var width: CGFloat { min(Tokens.Dialog.width, bounds.width - Tokens.Space.x6 * 2) }

    private func height(for width: CGFloat) -> CGFloat {
        let pad = Tokens.Dialog.padding, inner = width - pad * 2
        return pad + header.height(for: inner) + Tokens.Space.x2 + body.wrappedHeight(inner) + Tokens.Dialog.gap + Tokens.Space.x1
            + DialogButtons.height + pad
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
        body.frame = NSRect(x: pad, y: header.frame.maxY + Tokens.Space.x2, width: inner, height: body.wrappedHeight(inner))
        buttons.frame = NSRect(x: pad, y: panel.bounds.height - pad - DialogButtons.height, width: inner, height: DialogButtons.height)
    }
}

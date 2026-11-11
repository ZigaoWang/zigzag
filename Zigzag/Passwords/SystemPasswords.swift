import AppKit
import WebKit

/// "Passwords…" in the password menu: the Mac's own list of passwords, from the Passwords app and the password
/// manager apps that fill across the Mac (1Password, Dashlane, Bitwarden and the like), as Orion offers it.
///
/// macOS has no way for a browser to ask it for a website's password, so this goes the one way there is: a pair of
/// native fields marked username and password, laid over the page's field all but transparent, is focused and asked
/// for passwords, as Edit › AutoFill › Passwords… does in any app. You pick a login in the system's list (it asks
/// for Touch ID), macOS fills the two fields, and they're read, emptied and taken away at once. The login goes into
/// the page through the same checks as one of yours; it's never saved, logged or kept.
@MainActor
final class SystemPasswordPicker: NSObject, NSTextFieldDelegate {
    static let shared = SystemPasswordPicker()

    enum Outcome {
        /// What macOS filled. Either may be empty: a login can come back with only a password.
        case filled(username: SecretString, password: SecretString)
        case cancelled(Reason)
    }

    enum Reason: Equatable {
        /// Closed, or a click went somewhere else.
        case dismissed
        /// Left open too long.
        case timedOut
        /// Something typed into the fields: that's never a login from the list.
        case typed
        /// The system's list couldn't be opened.
        case unavailable
        /// Another request took its place, or the page went away.
        case replaced
    }

    /// How long the list may stay open before the fields go away by themselves.
    static let timeout: TimeInterval = 60

    /// The command Edit › AutoFill › Passwords… sends to the focused text field. AppKit has no public call for it;
    /// it's only ever sent where the field answers to it.
    static let passwordsCommand = NSSelectorFromString("_handleInsertFromPasswordsCommand:")

    /// Asks AppKit to open the list for the focused field. Only an app in front can.
    static func askSystem(_ field: NSTextField) -> Bool {
        debugLog("syspasswords ask active=\(NSApp.isActive) key=\(field.window?.isKeyWindow ?? false) responder=\(field.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        guard NSApp.isActive, let responder = field.window?.firstResponder, responder.responds(to: passwordsCommand) else { return false }
        return NSApp.sendAction(passwordsCommand, to: responder, from: nil)
    }

    /// Holds the fields over the page's field. Clicks go through to the page underneath.
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let anchor = Anchor()
    let usernameField = NSTextField()
    let passwordField = NSSecureTextField()
    private var completion: ((Outcome) -> Void)?
    private weak var restoreTo: NSResponder?
    private var observers: [NSObjectProtocol] = []
    /// Bumped when a request ends, so nothing scheduled for it acts on the next one.
    private var session = 0
    /// Bumped on every change to the fields; the last one reads them.
    private var changes = 0
    private var settling = false
    /// The system's list took the front (Zigzag stopped being the active app), so coming back means it closed.
    private(set) var opened = false
    private let timeout: TimeInterval
    private let openCheck: TimeInterval?

    /// `openCheck`: how soon the list must have taken the front, or the fields go away (nil never checks).
    init(timeout: TimeInterval = SystemPasswordPicker.timeout, openCheck: TimeInterval? = 2) {
        self.timeout = timeout
        self.openCheck = openCheck
        super.init()
        usernameField.contentType = .username
        passwordField.contentType = .password
        for field in [usernameField, passwordField] {
            field.delegate = self
            field.focusRingType = .none
            // Nearly invisible: AppKit offers AutoFill only to a field that's on screen, but nobody should see it.
            field.alphaValue = 0.02
            field.setAccessibilityElement(false)
            anchor.addSubview(field)
        }
    }

    var isPresented: Bool { completion != nil }

    /// Lays the fields over `rect` in `overlay`, focuses the password field and asks for the list. `completion` is
    /// called once, on the main thread, with what came back; by then the fields are empty and gone, and the focus is
    /// back on `responder`.
    func present(over rect: NSRect, in overlay: NSView, restoringFocusTo responder: NSResponder?,
                 ask: @MainActor (NSTextField) -> Bool = SystemPasswordPicker.askSystem, completion: @escaping (Outcome) -> Void) {
        if isPresented { finish(.cancelled(.replaced)) }
        self.completion = completion
        restoreTo = responder
        opened = false
        anchor.frame = rect.height < 16 ? rect.insetBy(dx: 0, dy: (rect.height - 16) / 2) : rect
        // The password field on top, where the list points; the username field under it, so AutoFill sees the pair.
        usernameField.frame = anchor.bounds
        passwordField.frame = anchor.bounds
        usernameField.font = .systemFont(ofSize: max(9, min(anchor.bounds.height * 0.5, 15)))
        passwordField.font = usernameField.font
        overlay.addSubview(anchor)
        debugLog("syspasswords present")
        guard let window = overlay.window, window.makeFirstResponder(passwordField) else { finish(.cancelled(.unavailable)); return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.opened = true }
            },
            // Back in front: the list closed. A login picked in it has arrived by now or just after.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.after(0.5) { $0.giveUpIfEmpty(.dismissed) } }
            },
        ]
        after(timeout) { $0.finish(.cancelled(.timedOut)) }
        guard ask(passwordField) else { finish(.cancelled(.unavailable)); return }
        if let openCheck { after(openCheck) { if !$0.opened { $0.giveUpIfEmpty(.unavailable) } } }
    }

    /// Takes the fields away with nothing filled.
    func cancel() {
        finish(.cancelled(.replaced))
    }

    private func after(_ delay: TimeInterval, _ body: @escaping (SystemPasswordPicker) -> Void) {
        let session = session
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isPresented, self.session == session else { return }
            body(self)
        }
    }

    private func giveUpIfEmpty(_ reason: Reason) {
        guard isPresented, !settling, usernameField.stringValue.isEmpty, passwordField.stringValue.isEmpty else { return }
        finish(.cancelled(reason))
    }

    // MARK: Filling

    func controlTextDidChange(_ notification: Notification) {
        guard isPresented else { return }
        // Keys pressed here aren't a login from the list (the fields can't be seen): hand the focus back.
        if Self.isTyping(NSApp.currentEvent) { finish(.cancelled(.typed)); return }
        // AutoFill fills the two fields one after the other: read them once both have had their turn.
        changes += 1
        settling = true
        let change = changes
        after(0.25) { picker in if picker.changes == change { picker.collect() } }
    }

    /// A key being pressed right now. (The last event Zigzag had can be the Return that chose Passwords… in the
    /// menu, long before the list filled anything.)
    static func isTyping(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.2
    }

    /// For tests: what AutoFill's filling of the fields looks like from here.
    func fieldsDidChange() { controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: passwordField)) }

    private func collect() {
        settling = false
        let username = SecretString(usernameField.stringValue), password = SecretString(passwordField.stringValue)
        guard !username.isEmpty || !password.isEmpty else { return }
        finish(.filled(username: username, password: password))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Focus moved on (a click on the page): give up, unless a fill is on its way.
        after(0.3) { $0.giveUpIfEmpty(.dismissed) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
             #selector(NSResponder.insertNewline(_:)):
            finish(.cancelled(.dismissed))
            return true
        default: return false
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        session += 1
        settling = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        let window = anchor.window
        let focused = window.map { Self.owns($0.firstResponder, [usernameField, passwordField]) } ?? false
        // Emptied before anything else, the field editor's copy too.
        for field in [usernameField, passwordField] {
            field.abortEditing()
            field.stringValue = ""
        }
        anchor.removeFromSuperview()
        if focused, let window { window.makeFirstResponder(restoreTo.flatMap { ($0 as? NSView)?.window === window ? $0 : nil }) }
        switch outcome {
        case .filled: debugLog("syspasswords filled")
        case .cancelled(let reason): debugLog("syspasswords cancelled \(reason)")
        }
        completion(outcome)
    }

    /// Whether `responder` is one of `fields`, or the field editor working in one.
    private static func owns(_ responder: NSResponder?, _ fields: [NSTextField]) -> Bool {
        guard let responder else { return false }
        if let view = responder as? NSTextField, fields.contains(where: { $0 === view }) { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let delegate = editor.delegate as? NSTextField {
            return fields.contains { $0 === delegate }
        }
        return false
    }
}

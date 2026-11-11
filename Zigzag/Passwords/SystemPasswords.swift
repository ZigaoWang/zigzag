import AppKit
import WebKit

/// "Passwords…" in the password menu: the Mac's own list of passwords, from the Passwords app and the password
/// manager apps that fill across the Mac (1Password, Dashlane, Bitwarden and the like), as Orion offers it.
///
/// On macOS 27 Passwords… opens the Mac's AutoFill panel on the page's field itself (`SystemAutoFillPanel`); this is
/// what's left before that, or when the panel can't be asked for. Here macOS has no way for a browser to ask it for a
/// website's password, so this goes the one way there is: a pair of
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
    private var clickMonitor: Any?
    /// The system's list took the front (Zigzag stopped being the active app), so coming back means it closed.
    private(set) var opened = false
    private let timeout: TimeInterval
    private let openCheck: TimeInterval?

    /// `openCheck`: how soon the list must have taken the front, or the fields go away (nil, the default, never
    /// checks: the Mac can show its list inside Zigzag's own window, where Zigzag never stops being the active app).
    init(timeout: TimeInterval = SystemPasswordPicker.timeout, openCheck: TimeInterval? = nil) {
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
        // A click in the window anywhere but the fields: you've moved on, so the fields go (a fill already on its
        // way still lands). Clicks in the Mac's own list are in its window, not this one.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPresented, let window = self.anchor.window, event.window === window else { return }
                let point = self.anchor.convert(event.locationInWindow, from: nil)
                if !self.anchor.bounds.contains(point) { self.after(0.3) { $0.giveUpIfEmpty(.dismissed) } }
            }
            return event
        }
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
        // The Mac's list taking the focus ends editing too, as it opens: that alone mustn't take the fields away.
        // A click elsewhere in the window does (`clickMonitor`), and Escape, Tab, Return and the timeout.
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
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
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

/// macOS 27 and later: the Mac's own AutoFill panel, opened on the page's field itself, as the page's right-click
/// AutoFill › Passwords… does. Pointed at the web field, macOS knows the page's site, so the panel puts that site's
/// logins first ("Suggested") and fills the one you pick straight into the field.
///
/// The menu item sends `_handleInsertFromPasswordsCommand:` up the responder chain; WKWebView doesn't answer it, so
/// NSApplication does, presenting the panel for the text input in focus (AppKit's NSAutoFillHeuristicController).
/// Zigzag sends the same command, to NSApplication, with the page's field focused.
@MainActor
enum SystemAutoFillPanel {
    static var command: Selector { SystemPasswordPicker.passwordsCommand }

    /// The panel can be asked for here. Off before macOS 27, where only the fields laid over the page work.
    static var isAvailable: Bool {
        guard #available(macOS 27, *) else { return false }
        return NSApp.responds(to: command)
    }

    /// Puts the cursor back in the field the menu was for, without bringing Zigzag's menu up again.
    static let focuser = """
    if (location.origin !== expectedOrigin) return false;
    const el = window.__zigzagField && window.__zigzagField.deref();
    if (!el || !el.isConnected || el.disabled || el.readOnly) return false;
    window.__zigzagFilling = true;
    try { if (document.activeElement !== el) el.focus({ preventScroll: true }); }
    finally { setTimeout(() => { window.__zigzagFilling = false; }, 0); }
    return document.activeElement === el;
    """

    /// Opens the panel at the field in `frame` of `webView`, if it's still `origin`'s page, in the tab in front, with
    /// its window key. False when it couldn't be asked for (nothing was shown).
    static func open(in webView: WKWebView, frame: WKFrameInfo?, origin: Origin, inFront: @MainActor (WKWebView) -> Bool) async -> Bool {
        guard isAvailable, NSApp.isActive, let window = webView.window, window.isKeyWindow,
              Origin(webView.url) == origin, inFront(webView) else {
            debugLog("sysautofill not asked active=\(NSApp.isActive) key=\(webView.window?.isKeyWindow ?? false) front=\(inFront(webView))")
            return false
        }
        if window.firstResponder !== webView, !window.makeFirstResponder(webView) { return false }
        let focused = try? await webView.callAsyncJavaScript(focuser, arguments: ["expectedOrigin": origin.description], in: frame, contentWorld: .defaultClient) as? Bool
        guard focused == true else { debugLog("sysautofill no field"); return false }
        // WebKit tells AppKit about the focused field a moment after the page has it.
        try? await Task.sleep(for: .milliseconds(120))
        guard NSApp.isActive, window.isKeyWindow, window.firstResponder === webView, Origin(webView.url) == origin, inFront(webView) else { return false }
        let sent = NSApp.sendAction(command, to: NSApp, from: nil)
        debugLog("sysautofill sent=\(sent)")
        return sent
    }
}

/// macOS 27 and later: sign-in fields show Safari's key icon. A click on it opens the Mac's AutoFill panel on the
/// field (`Autofill.keyIconClicked`); a click anywhere else in the field opens Zigzag's password menu.
@available(macOS 27, *)
enum AutofillKeyIcon {
    static let messageName = "zigzagAutofillKey"

    /// A world of Zigzag's own where fields can be given the icon; pages can't.
    static let world: WKContentWorld = {
        let configuration = WKContentWorld.Configuration()
        configuration.autofillScriptingEnabled = true
        return WKContentWorld(configuration: configuration)
    }()

    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.addScriptMessageHandler(Asker.shared, contentWorld: world, name: messageName)
    }

    /// Answers the page script's one question: does Zigzag fill passwords in this page's profile?
    final class Asker: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Asker { webView in
            guard let webView = webView as? BrowserWebView else { return false }
            return Autofill.isOn(in: Profiles.shared.profile(ofPage: webView))
        }
        private let isOn: (WKWebView?) -> Bool
        init(isOn: @escaping (WKWebView?) -> Bool) { self.isOn = isOn }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard message.frameInfo.isMainFrame else { return (false, nil) }
            return (isOn(message.webView), nil)
        }
    }

    /// Marks the sign-in fields, now and as the page adds them.
    static let source = """
    (() => {
      if (window.__zigzagKeyIcons) return;
      window.__zigzagKeyIcons = true;
      \(Autofill.signInCheck)
      const marked = new WeakSet();
      const mark = () => {
        for (const el of document.querySelectorAll('input')) {
          const wanted = signIn(el);
          if (wanted && el.autofillButtonType === 'none') { el.autofillButtonType = 'credentials'; marked.add(el); }
          else if (!wanted && marked.has(el)) { el.autofillButtonType = 'none'; marked.delete(el); }
        }
      };
      let queued = false;
      const later = () => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; mark(); }, 250);
      };
      window.webkit.messageHandlers.\(messageName).postMessage('on').then((on) => {
        if (on !== true) return;
        mark();
        new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true, attributes: true,
          attributeFilter: ['type', 'autocomplete', 'disabled', 'readonly', 'name', 'id'] });
      }).catch(() => {});
    })();
    """
}

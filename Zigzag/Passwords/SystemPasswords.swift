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
    private var reshowGuard: NSObjectProtocol?
    /// The window was on screen when the fields went in, so it being gone by the ask means it closed or was hidden.
    private var shownInVisibleWindow = false
    /// The system's list took the front (Zigzag stopped being the active app), so coming back means it closed.
    private(set) var opened = false
    private let timeout: TimeInterval
    private let openCheck: TimeInterval?
    private let settle: TimeInterval
    private let dismissSystem: @MainActor () -> Void

    /// How long AppKit's AutoFill takes to catch up with a newly focused field. Asked sooner, its own update for
    /// the field closes the list a moment after it opens (#378).
    static let settle: TimeInterval = 0.35

    /// `openCheck`: how soon the list must have taken the front, or the fields go away (nil, the default, never
    /// checks: the Mac can show its list inside Zigzag's own window, where Zigzag never stops being the active app).
    /// `settle`: how long the password field is focused before the list is asked for (0 asks at once).
    /// `dismissSystem`: closes whatever AutoFill still shows for the fields as they go.
    init(timeout: TimeInterval = SystemPasswordPicker.timeout, openCheck: TimeInterval? = nil, settle: TimeInterval = SystemPasswordPicker.settle,
         dismissSystem: @escaping @MainActor () -> Void = SystemPasswordPicker.dismissSystemAutoFill) {
        self.timeout = timeout
        self.openCheck = openCheck
        self.settle = settle
        self.dismissSystem = dismissSystem
        super.init()
        // The password field is marked only as the list is asked for: focused while marked, AppKit puts its own
        // Passwords… suggestion under it first (#378).
        usernameField.contentType = .username
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
                 ask: @escaping @MainActor (NSTextField) -> Bool = SystemPasswordPicker.askSystem, completion: @escaping (Outcome) -> Void) {
        if isPresented { finish(.cancelled(.replaced)) }
        endReshowGuard()
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
        shownInVisibleWindow = window.isVisible
        let center = NotificationCenter.default
        observers = [
            // The window closing takes the fields with it: nothing is asked of a closed window.
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(.cancelled(.dismissed)) }
            },
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
                // The second click of a double-click is the first one's (`Autofill` keeps it off the page).
                guard let self, self.isPresented, let window = self.anchor.window, event.window === window, event.clickCount < 2 else { return }
                let point = self.anchor.convert(event.locationInWindow, from: nil)
                guard !self.anchor.bounds.contains(point) else { return }
                // Closed before the page takes the click, so AppKit never moves it to the page's field.
                self.dismissSystem()
                self.after(0.3) { $0.giveUpIfEmpty(.dismissed) }
            }
            return event
        }
        after(timeout) { $0.finish(.cancelled(.timedOut)) }
        guard settle > 0 else { askNow(ask); return }
        after(settle) { $0.askNow(ask) }
    }

    private func askNow(_ ask: @MainActor (NSTextField) -> Bool) {
        // The focus moved on while AutoFill caught up, or the window closed or went away: you've moved on.
        guard let overlay = anchor.superview, let window = anchor.window, !shownInVisibleWindow || window.isVisible,
              Self.owns(window.firstResponder, [passwordField]) else { finish(.cancelled(.dismissed)); return }
        // The list points at the field; a field off its page would put it in a corner of the screen.
        guard Self.anchorIsValid(anchor.frame, in: overlay.bounds), passwordField.currentEditor() != nil else { finish(.cancelled(.unavailable)); return }
        passwordField.contentType = .password
        guard ask(passwordField) else { finish(.cancelled(.unavailable)); return }
        if let openCheck { after(openCheck) { if !$0.opened { $0.giveUpIfEmpty(.unavailable) } } }
    }

    /// Whether the list can point at `rect`: a real field, its middle inside the page.
    static func anchorIsValid(_ rect: NSRect, in bounds: NSRect) -> Bool {
        rect.width >= 1 && rect.height >= 1 && bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    /// AppKit's AutoFill panel and suggestion outlive the fields they were opened for, and come back each time the
    /// window becomes key, so they're closed with the fields. Private, so only where AppKit has it.
    static func dismissSystemAutoFill() {
        let shared = NSSelectorFromString("sharedInstance"), dismiss = NSSelectorFromString("_dismissAutoFill")
        guard let type = NSClassFromString("NSAutoFillHeuristicController") as? NSObject.Type, type.responds(to: shared),
              let controller = type.perform(shared)?.takeUnretainedValue() as? NSObject, controller.responds(to: dismiss) else { return }
        controller.perform(dismiss)
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
        passwordField.contentType = nil
        // Focus handed back while the fields are still in the window, so AppKit sees them let go of it.
        if focused, let window { window.makeFirstResponder(restoreTo.flatMap { ($0 as? NSView)?.window === window ? $0 : nil }) }
        dismissSystem()
        anchor.removeFromSuperview()
        if let window { guardReshow(in: window) }
        switch outcome {
        case .filled: debugLog("syspasswords filled")
        case .cancelled(let reason): debugLog("syspasswords cancelled \(reason)")
        }
        completion(outcome)
    }

    /// AppKit brings its list back the next time the window is key, for whatever has the focus by then, with no
    /// field to point at: at the screen's corner (#378). For a moment after the fields go, it's closed again.
    private func guardReshow(in window: NSWindow) {
        endReshowGuard()
        let dismiss = dismissSystem
        reshowGuard = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { dismiss() } }
        }
        let session = session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reshowGuardTime) { [weak self] in
            guard let self, self.session == session, !self.isPresented else { return }
            self.endReshowGuard()
        }
    }

    static let reshowGuardTime: TimeInterval = 1.5

    private func endReshowGuard() {
        if let reshowGuard { NotificationCenter.default.removeObserver(reshowGuard) }
        reshowGuard = nil
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

/// What closes the Mac's Passwords list opened for a page, as Safari's closes: the page scrolling or going
/// somewhere else, its window moving, resizing, hiding or closing. Switching tabs closes it from `TabManager`.
@MainActor
final class SystemPanelWatch {
    enum Trigger: Equatable {
        case scrolled, navigated, windowMoved, windowResized, windowHidden, windowClosed, timedOut
    }

    private(set) weak var webView: WKWebView?
    private weak var window: NSWindow?
    private var onEnd: ((Trigger) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var keyValueObservers: [NSKeyValueObservation] = []
    private var scrollMonitor: Any?

    var isWatching: Bool { onEnd != nil }

    init(webView: WKWebView, window: NSWindow, timeout: TimeInterval = SystemPasswordPicker.timeout, onEnd: @escaping (Trigger) -> Void) {
        self.webView = webView
        self.window = window
        self.onEnd = onEnd
        let center = NotificationCenter.default
        let triggers: [(Notification.Name, Trigger)] = [
            (NSWindow.willMoveNotification, .windowMoved), (NSWindow.didMoveNotification, .windowMoved),
            (NSWindow.willStartLiveResizeNotification, .windowResized), (NSWindow.didResizeNotification, .windowResized),
            (NSWindow.willEnterFullScreenNotification, .windowResized), (NSWindow.willExitFullScreenNotification, .windowResized),
            (NSWindow.willMiniaturizeNotification, .windowHidden), (NSWindow.willCloseNotification, .windowClosed),
        ]
        observers = triggers.map { name, trigger in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(trigger) }
            }
        }
        observers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.windowHidden) }
        })
        keyValueObservers = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.end(.navigated) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { if change.newValue == true { self?.end(.navigated) } }
            },
        ]
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(in: event.window) }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.timedOut) }
    }

    /// A scroll in the page's window: the field moves out from under the list.
    func scrolled(in eventWindow: NSWindow?) {
        guard let window, eventWindow === window else { return }
        end(.scrolled)
    }

    /// Calls `onEnd` once, then stops watching.
    func end(_ trigger: Trigger) {
        guard let onEnd else { return }
        stop()
        debugLog("syspasswords closed by \(trigger)")
        onEnd(trigger)
    }

    /// Stops watching without calling `onEnd`.
    func stop() {
        onEnd = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        keyValueObservers.forEach { $0.invalidate() }
        keyValueObservers = []
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
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

    /// Show the key only where Zigzag fills passwords and the system panel can open. Not with a password-manager
    /// extension on (Bitwarden and 1Password draw their own icon there), nor with Fill passwords off, as in Chrome
    /// (#236).
    static func shows(fills: Bool, managerOn: Bool, panelAvailable: Bool) -> Bool {
        panelAvailable && fills && !managerOn
    }

    /// `shows` for a page, in its profile.
    @MainActor static func shows(in webView: WKWebView?) -> Bool {
        guard let webView = webView as? BrowserWebView else { return false }
        let profile = Profiles.shared.profile(ofPage: webView)
        return shows(fills: Autofill.isOn(in: profile), managerOn: PasswordManagers.active(in: profile) != nil,
                     panelAvailable: SystemAutoFillPanel.isAvailable)
    }

    /// Answers the page script's question: show the key? (`shows`)
    final class Asker: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Asker { webView in AutofillKeyIcon.shows(in: webView) }
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

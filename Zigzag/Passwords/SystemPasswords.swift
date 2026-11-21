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
final class SystemPasswordPicker: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
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
    static func askSystem(_ field: NSView) -> Bool {
        debugLog("syspasswords ask active=\(NSApp.isActive) key=\(field.window?.isKeyWindow ?? false) responder=\(field.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        let responds = field.window?.firstResponder?.responds(to: passwordsCommand) ?? false
        guard NSApp.isActive, let responder = field.window?.firstResponder, responder.responds(to: passwordsCommand) else {
            PasswordsLog.write("ask-system", ["active": .flag(NSApp.isActive), "responds": .flag(responds), "sent": .flag(false)])
            return false
        }
        let sent = NSApp.sendAction(passwordsCommand, to: responder, from: nil)
        PasswordsLog.write("ask-system", ["active": .flag(true), "responds": .flag(true), "sent": .flag(sent)])
        return sent
    }

    /// Holds the fields over the page's field. Clicks go through to the page underneath.
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let anchor = Anchor()
    let usernameField = NSTextField()
    /// A text view of its own rather than a secure text field. AppKit pairs the username field with the password
    /// one around whatever has the focus, and works the pair out again each time the window becomes key, as it does
    /// around the list. A secure field's focus is its field editor, which isn't one of the window's fields, so the
    /// pair was lost and only the password came back (#378).
    let passwordView = SecretTextView(frame: .zero)
    private var storageObserver: NSObjectProtocol?
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
    /// System uptime at `present`, for the log's timings.
    private var presentedAt: TimeInterval = 0
    private var elapsed: PasswordsLog.Fact { .seconds(ProcessInfo.processInfo.systemUptime - presentedAt) }
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
        usernameField.contentType = .username
        usernameField.delegate = self
        usernameField.focusRingType = .none
        // AppKit puts its own Passwords… suggestion only under a focused text field, never a text view, so this one
        // can be marked from the start (#378).
        passwordView.contentType = .password
        passwordView.delegate = self
        passwordView.isRichText = false
        passwordView.importsGraphics = false
        passwordView.allowsUndo = false
        passwordView.isContinuousSpellCheckingEnabled = false
        passwordView.isGrammarCheckingEnabled = false
        // Autocorrection is left on: with it off, AutoFill skips the field.
        passwordView.isAutomaticTextCompletionEnabled = false
        passwordView.isAutomaticTextReplacementEnabled = false
        passwordView.isAutomaticQuoteSubstitutionEnabled = false
        passwordView.isAutomaticDashSubstitutionEnabled = false
        passwordView.isAutomaticLinkDetectionEnabled = false
        passwordView.isAutomaticDataDetectionEnabled = false
        passwordView.smartInsertDeleteEnabled = false
        passwordView.inlinePredictionType = .no
        passwordView.writingToolsBehavior = .none
        passwordView.usesFindBar = false
        passwordView.drawsBackground = false
        passwordView.textColor = .clear
        passwordView.insertionPointColor = .clear
        passwordView.textContainerInset = .zero
        passwordView.isVerticallyResizable = false
        passwordView.isHorizontallyResizable = false
        for view in [usernameField, passwordView] as [NSView] {
            // Nearly invisible: AppKit offers AutoFill only to a field that's on screen, but nobody should see it.
            view.alphaValue = 0.02
            view.setAccessibilityElement(false)
            anchor.addSubview(view)
        }
        // AutoFill sets the text view's text without a word to its delegate.
        storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: passwordView.textStorage,
                                                                 queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                // Read once the storage is done editing, never inside its edit.
                guard let self, self.isPresented else { return }
                self.after(0) { $0.fieldsChanged(in: $0.passwordView) }
            }
        }
    }

    var isPresented: Bool { completion != nil }

    /// Lays the fields over `rect` in `overlay`, focuses the password field and asks for the list. `completion` is
    /// called once, on the main thread, with what came back; by then the fields are empty and gone, and the focus is
    /// back on `responder`.
    func present(over rect: NSRect, in overlay: NSView, restoringFocusTo responder: NSResponder?,
                 ask: @escaping @MainActor (NSView) -> Bool = SystemPasswordPicker.askSystem, completion: @escaping (Outcome) -> Void) {
        if isPresented { finish(.cancelled(.replaced)) }
        presentedAt = ProcessInfo.processInfo.systemUptime
        PasswordsLog.write("present", ["session": .number(session), "active": .flag(NSApp.isActive), "key": .flag(overlay.window?.isKeyWindow ?? false),
                                       "responder": .type(overlay.window?.firstResponder), "reshowGuard": .flag(reshowGuard != nil)])
        endReshowGuard()
        // Whatever AppKit still has open from before is closed first, so every request starts clean (#378).
        dismissSystem()
        self.completion = completion
        restoreTo = responder
        opened = false
        anchor.frame = rect.height < 16 ? rect.insetBy(dx: 0, dy: (rect.height - 16) / 2) : rect
        // The password field on top, where the list points; the username field under it, so AutoFill sees the pair.
        usernameField.frame = anchor.bounds
        passwordView.frame = anchor.bounds
        usernameField.font = .systemFont(ofSize: max(9, min(anchor.bounds.height * 0.5, 15)))
        passwordView.font = usernameField.font
        overlay.addSubview(anchor)
        debugLog("syspasswords present")
        let focused = overlay.window?.makeFirstResponder(passwordView) ?? false
        PasswordsLog.write("focus", ["window": .flag(overlay.window != nil), "took": .flag(focused), "responder": .type(overlay.window?.firstResponder),
                                     "anchor": .size(anchor.frame.size), "overlay": .size(overlay.bounds.size)])
        guard let window = overlay.window, focused else { finish(.cancelled(.unavailable)); return }
        shownInVisibleWindow = window.isVisible
        let center = NotificationCenter.default
        observers = [
            // The window closing takes the fields with it: nothing is asked of a closed window.
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(.cancelled(.dismissed)) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.apple.") ?? false
                    PasswordsLog.write("app-resigned", ["after": self.elapsed, "frontIsApple": .flag(front)])
                    self.opened = true
                }
            },
            // Back in front: the list closed. A login picked in it has arrived by now or just after.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    PasswordsLog.write("app-active", ["after": self.elapsed, "key": .flag(self.anchor.window?.isKeyWindow ?? false),
                                                      "responder": .type(self.anchor.window?.firstResponder)])
                    self.after(0.5) { $0.giveUpIfEmpty(.dismissed) }
                }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    PasswordsLog.write("window-key", ["after": self.elapsed, "responder": .type(self.anchor.window?.firstResponder)])
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    PasswordsLog.write("window-resigned-key", ["after": self.elapsed, "keyWindow": .type(NSApp.keyWindow)])
                }
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
                PasswordsLog.write("click-away", ["after": self.elapsed])
                self.dismissSystem()
                self.after(0.3) { $0.giveUpIfEmpty(.dismissed) }
            }
            return event
        }
        after(timeout) { $0.finish(.cancelled(.timedOut)) }
        guard settle > 0 else { askNow(ask); return }
        after(settle) { $0.askNow(ask) }
    }

    private func askNow(_ ask: @MainActor (NSView) -> Bool) {
        PasswordsLog.write("settled", ["after": elapsed, "active": .flag(NSApp.isActive), "key": .flag(anchor.window?.isKeyWindow ?? false),
                                       "visible": .flag(anchor.window?.isVisible ?? false), "focused": .flag(anchor.window?.firstResponder === passwordView),
                                       "responder": .type(anchor.window?.firstResponder)])
        // The focus moved on while AutoFill caught up, or the window closed or went away: you've moved on.
        guard let overlay = anchor.superview, let window = anchor.window, !shownInVisibleWindow || window.isVisible,
              window.firstResponder === passwordView else { finish(.cancelled(.dismissed)); return }
        // The list points at the field; a field off its page would put it in a corner of the screen.
        guard Self.anchorIsValid(anchor.frame, in: overlay.bounds) else { finish(.cancelled(.unavailable)); return }
        Self.pairForAutoFill(passwordView)
        let asked = ask(passwordView)
        PasswordsLog.write("asked", ["sent": .flag(asked), "active": .flag(NSApp.isActive), "key": .flag(window.isKeyWindow),
                                     "responder": .type(window.firstResponder)])
        // The panel may take the focus a moment later.
        after(0.3) { [weak window] in
            PasswordsLog.write("after-ask", ["after": $0.elapsed, "active": .flag(NSApp.isActive), "key": .flag(window?.isKeyWindow ?? false),
                                             "responder": .type(window?.firstResponder)])
        }
        guard asked else { finish(.cancelled(.unavailable)); return }
        if let openCheck { after(openCheck) { if !$0.opened { $0.giveUpIfEmpty(.unavailable) } } }
    }

    /// Whether the list can point at `rect`: a real field, its middle inside the page.
    static func anchorIsValid(_ rect: NSRect, in bounds: NSRect) -> Bool {
        rect.width >= 1 && rect.height >= 1 && bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    /// AppKit's AutoFill panel and suggestion outlive the fields they were opened for, and come back each time the
    /// window becomes key, so they're closed with the fields. Private, so only where AppKit has it.
    static func dismissSystemAutoFill() {
        let shared = NSSelectorFromString("sharedInstance")
        guard let type = NSClassFromString("NSAutoFillHeuristicController") as? NSObject.Type, type.responds(to: shared),
              let controller = type.perform(shared)?.takeUnretainedValue() as? NSObject else {
            PasswordsLog.writeIfStarted("dismiss", ["controller": .flag(false)])
            return
        }
        let answered = dismissSelectors.filter { controller.responds(to: $0) }
        for selector in answered { controller.perform(selector) }
        PasswordsLog.writeIfStarted("dismiss", ["controller": .flag(true), "sent": .selectors(answered)])
    }

    /// The part of AppKit's AutoFill that pairs a password field with its username field, where AppKit has it.
    static var autoFillDetection: NSObject? {
        let shared = NSSelectorFromString("sharedInstance"), create = NSSelectorFromString("_createTargetDetectionControllerIfNecessary")
        guard let type = NSClassFromString("NSAutoFillHeuristicController") as? NSObject.Type, type.responds(to: shared),
              let controller = type.perform(shared)?.takeUnretainedValue() as? NSObject, controller.isKind(of: type), controller.responds(to: create),
              let ivar = class_getInstanceVariable(type, "_targetDetectionController"),
              // Read only while it holds an object, as it does on the macOS versions this was written for.
              ivar_getTypeEncoding(ivar).map({ String(cString: $0).hasPrefix("@") }) == true else { return nil }
        controller.perform(create)
        return object_getIvar(controller, ivar) as? NSObject
    }

    /// AppKit pairs the fields only when a text field takes the focus, never a text view, and fills by the last pair (#378).
    static func pairForAutoFill(_ view: NSView) {
        let mode = NSSelectorFromString("autoFillModeForResponder:")
        let detection = autoFillDetection
        guard let detection, detection.responds(to: mode) else { logPairing(detection: detection, mode: mode, result: nil); return }
        typealias Mode = @convention(c) (NSObject, Selector, NSView) -> UInt
        let result = unsafeBitCast(detection.method(for: mode), to: Mode.self)(detection, mode, view)
        logPairing(detection: detection, mode: mode, result: result)
    }

    /// What of AppKit's pairing calls this Mac has, looked up without calling any of them.
    private static func logPairing(detection: NSObject?, mode: Selector, result: UInt?) {
        let type: AnyClass? = NSClassFromString("NSAutoFillHeuristicController")
        let ivar = type.flatMap { class_getInstanceVariable($0, "_targetDetectionController") }
        let encoding = ivar.flatMap { ivar_getTypeEncoding($0) }.map { String(String(cString: $0).prefix(1)) } ?? "none"
        let create = NSSelectorFromString("_createTargetDetectionControllerIfNecessary")
        var found: [Selector] = []
        if type?.instancesRespond(to: create) == true { found.append(create) }
        if detection?.responds(to: mode) == true { found.append(mode) }
        PasswordsLog.write("pair", ["class": .flag(type != nil), "shared": .flag((type as? NSObject.Type)?.responds(to: NSSelectorFromString("sharedInstance")) ?? false),
                                    "ivar": .flag(ivar != nil), "ivarObject": .flag(encoding == "@"), "detection": .type(detection),
                                    "found": .selectors(found), "mode": .number(result.map { Int(truncatingIfNeeded: $0) } ?? -1)])
    }

    /// The suggestion under a field, then the Passwords panel. AppKit closes the panel itself only for a field that
    /// lets go of the focus in a key window, and the window isn't key while the panel is in front (#378).
    static let dismissSelectors = [NSSelectorFromString("_dismissAutoFill"), NSSelectorFromString("_hideAutoFillPanel")]

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
        guard isPresented, !settling, usernameField.stringValue.isEmpty, passwordView.string.isEmpty else { return }
        finish(.cancelled(reason))
    }

    // MARK: Filling

    func controlTextDidChange(_ notification: Notification) { fieldsChanged(in: usernameField) }

    private func fieldsChanged(in field: NSView?) {
        guard isPresented else { return }
        let typing = Self.isTyping(NSApp.currentEvent)
        PasswordsLog.write("changed", ["field": .type(field), "after": elapsed, "username": .text(usernameField.stringValue),
                                       "password": .text(passwordView.string), "typing": .flag(typing)])
        // Keys pressed here aren't a login from the list (the fields can't be seen): hand the focus back.
        if typing { finish(.cancelled(.typed)); return }
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
    func fieldsDidChange() { fieldsChanged(in: nil) }

    private func collect() {
        settling = false
        let username = SecretString(usernameField.stringValue), password = SecretString(passwordView.string)
        PasswordsLog.write("collect", ["after": elapsed, "username": .flag(!username.isEmpty), "password": .flag(!password.isEmpty)])
        guard !username.isEmpty || !password.isEmpty else { return }
        finish(.filled(username: username, password: password))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // The Mac's list taking the focus ends editing too, as it opens: that alone mustn't take the fields away.
        // A click elsewhere in the window does (`clickMonitor`), and Escape, Tab, Return and the timeout.
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool { endsRequest(selector) }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool { endsRequest(selector) }

    /// Autocorrection stays on for AutoFill, which only pairs a field that has it, but nothing it finds is kept or
    /// put in: no spelling, correction or replacement ever touches a password.
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult], orthography: NSOrthography,
                  wordCount: Int) -> [NSTextCheckingResult] {
        guard view === passwordView else { return results }
        return Self.keptChecks(results)
    }

    /// What of a check of the password view is kept: nothing that would change or remember its text.
    nonisolated static func keptChecks(_ results: [NSTextCheckingResult]) -> [NSTextCheckingResult] {
        let changes: NSTextCheckingResult.CheckingType = [.spelling, .grammar, .correction, .replacement, .quote, .dash, .link, .date, .address, .phoneNumber, .transitInformation]
        return results.filter { changes.intersection($0.resultType).isEmpty }
    }

    /// Escape, Tab and Return take the fields away.
    private func endsRequest(_ selector: Selector) -> Bool {
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
        let focused = window.map { $0.firstResponder === passwordView || Self.owns($0.firstResponder, [usernameField]) } ?? false
        // Emptied before anything else, the field editor's copy too.
        usernameField.abortEditing()
        usernameField.stringValue = ""
        passwordView.string = ""
        // Whatever the spell checker kept for this view (words it was told to ignore) goes with the password.
        NSSpellChecker.shared.closeSpellDocument(withTag: passwordView.spellCheckerDocumentTag)
        // Focus handed back while the fields are still in the window, so AppKit sees them let go of it.
        if focused, let window { window.makeFirstResponder(restoreTo.flatMap { ($0 as? NSView)?.window === window ? $0 : nil }) }
        dismissSystem()
        anchor.removeFromSuperview()
        if let window { guardReshow(in: window) }
        switch outcome {
        case .filled(let username, let password):
            debugLog("syspasswords filled")
            PasswordsLog.write("finish", ["outcome": .reason(nil), "after": elapsed, "username": .flag(!username.isEmpty), "password": .flag(!password.isEmpty),
                                          "opened": .flag(opened), "focusBack": .flag(focused)])
        case .cancelled(let reason):
            debugLog("syspasswords cancelled \(reason)")
            PasswordsLog.write("finish", ["outcome": .reason(reason), "after": elapsed, "opened": .flag(opened), "focusBack": .flag(focused)])
        }
        completion(outcome)
    }

    /// AppKit brings its list back the next time the window is key, for whatever has the focus by then, with no
    /// field to point at: at the screen's corner (#378). For a moment after the fields go, it's closed again.
    private func guardReshow(in window: NSWindow) {
        endReshowGuard()
        let dismiss = dismissSystem
        reshowGuard = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                PasswordsLog.write("reshow-guard")
                dismiss()
            } }
        }
        let session = session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reshowGuardTime) { [weak self] in
            guard let self, self.session == session, !self.isPresented else { return }
            PasswordsLog.write("reshow-guard-ended")
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
            MainActor.assumeIsolated { self?.scrolled(in: event.window, phase: event.phase, momentumPhase: event.momentumPhase) }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.timedOut) }
    }

    /// A scroll in the page's window: the field moves out from under the list.
    func scrolled(in eventWindow: NSWindow?, phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = []) {
        guard let window, eventWindow === window, Self.isUserScroll(phase: phase, momentumPhase: momentumPhase) else { return }
        end(.scrolled)
    }

    /// Whether a scroll event is fingers or a wheel moving now: not the glide after a swipe, not fingers resting or
    /// lifting, which a scroll from before the list opened still sends.
    nonisolated static func isUserScroll(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Bool {
        guard momentumPhase.isEmpty else { return false }
        return phase.isEmpty || phase.contains(.began) || phase.contains(.changed)
    }

    /// Calls `onEnd` once, then stops watching.
    func end(_ trigger: Trigger) {
        guard let onEnd else { return }
        stop()
        debugLog("syspasswords closed by \(trigger)")
        PasswordsLog.writeIfStarted("watch-ended", ["by": .trigger(trigger)])
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

/// The password half of `SystemPasswordPicker`: a text view, so AppKit pairs it with the username field, that never
/// gives its text away while it holds a password. Nothing copies, cuts, drags or hands it to a service, Select All does
/// nothing, and accessibility reads it as empty, as a secure field reads.
final class SecretTextView: NSTextView {
    override func copy(_ sender: Any?) {}
    override func cut(_ sender: Any?) {}
    override func selectAll(_ sender: Any?) {}
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.withheld.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// The edits that would hand the text on.
    static let withheld: Set<Selector> = [#selector(copy(_:)), #selector(cut(_:)), #selector(selectAll(_:)), NSSelectorFromString("orderFrontSharingServicePicker:")]

    override func accessibilityValue() -> String? { "" }
    override func accessibilityNumberOfCharacters() -> Int { 0 }
    override func accessibilitySelectedText() -> String? { nil }
    override func accessibilityString(for range: NSRange) -> String? { nil }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? { nil }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .secureTextField }
}

/// The Mac's Passwords list, step by step, in every build, for finding out why it misbehaves on a Mac nobody here
/// has (#378). Only what happened and yes-or-no facts: never a username, password, page or anything typed.
enum PasswordsLog {
    /// One fact in a line. None of these can carry a field's text.
    nonisolated enum Fact {
        case flag(Bool)
        /// Written as set or empty, never the text.
        case text(String)
        /// The object's class name.
        case type(Any?)
        case selectors([Selector])
        case number(Int)
        case seconds(TimeInterval)
        case size(NSSize)
        /// nil for a fill.
        case reason(SystemPasswordPicker.Reason?)
        case trigger(SystemPanelWatch.Trigger)

        var rendered: String {
            switch self {
            case .flag(let on): on ? "yes" : "no"
            case .text(let text): text.isEmpty ? "empty" : "set"
            case .type(let object): object.map { String(describing: Swift.type(of: $0)) } ?? "none"
            case .selectors(let selectors): selectors.isEmpty ? "none" : selectors.map(NSStringFromSelector).joined(separator: ",")
            case .number(let n): String(n)
            case .seconds(let seconds): String(format: "%.2fs", seconds)
            case .size(let size): "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            case .reason(let reason): reason.map { String(describing: $0) } ?? "filled"
            case .trigger(let trigger): String(describing: trigger)
            }
        }
    }

    /// The file's folder; none while tests run.
    nonisolated static let folder: URL? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Library/Logs/Zigzag Dev" : "Library/Logs/Zigzag"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }()
    nonisolated static let fileName = "passwords.log"
    nonisolated static let oldFileName = "passwords.old.log"
    /// Past this size the file is set aside as the old one and starts over.
    nonisolated static let limit = 200_000

    nonisolated private static let queue = DispatchQueue(label: "app.zigzag.passwords-log", qos: .utility)
    nonisolated(unsafe) private static var collapser = Collapser()
    /// Set by the first line, so nothing is written until the list is used.
    @MainActor private(set) static var started = false

    /// "event key=value …".
    nonisolated static func line(_ event: StaticString, _ facts: KeyValuePairs<StaticString, Fact>) -> String {
        ([String(describing: event)] + facts.map { "\($0.key)=\($0.value.rendered)" }).joined(separator: " ")
    }

    @MainActor static func write(_ event: StaticString, _ facts: KeyValuePairs<StaticString, Fact> = [:]) {
        guard let folder else { return }
        var lines = [ExtensionLog.entry(line(event, facts))]
        if !started {
            started = true
            let info = Bundle.main.infoDictionary
            lines.insert("launch \(ProcessInfo.processInfo.operatingSystemVersionString) Zigzag \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))", at: 0)
        }
        let now = Date(), taken = lines
        queue.async {
            let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            let out = taken.flatMap { collapser.take($0) }.map { "\(stamp) \($0)" }
            guard !out.isEmpty else { return }
            append(out, to: folder, limit: limit)
        }
    }

    /// Only once the list has been used this launch.
    @MainActor static func writeIfStarted(_ event: StaticString, _ facts: KeyValuePairs<StaticString, Fact> = [:]) {
        if started { write(event, facts) }
    }

    /// The same line again and again is written once, then how many more times it came.
    nonisolated struct Collapser {
        private var last: String?
        private var repeats = 0

        mutating func take(_ line: String) -> [String] {
            if line == last { repeats += 1; return [] }
            defer { last = line; repeats = 0 }
            return repeats > 0 ? ["  same \(repeats) more time\(repeats == 1 ? "" : "s")", line] : [line]
        }
    }

    /// Adds `lines` to the file in `folder`, first setting it aside once it would pass `limit`.
    nonisolated static func append(_ lines: [String], to folder: URL, limit: Int) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName), old = folder.appendingPathComponent(oldFileName)
        let text = Data(lines.map { $0 + "\n" }.joined().utf8)
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0, size + text.count > limit {
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if manager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: text)
            try? handle.close()
        } else {
            try? text.write(to: url)
        }
    }

    /// The last lines, for Help › Report a Problem.
    nonisolated static func recent(_ count: Int) -> [String] {
        guard let folder, let text = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(count).map(String.init)
    }
}

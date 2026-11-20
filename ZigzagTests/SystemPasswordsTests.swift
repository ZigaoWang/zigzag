import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Passwords… in the password menu: the Mac's own list (the Passwords app and password manager apps), reached
/// through native fields laid over the page's field. The system's list itself can't be opened here; everything
/// around it can (#57).
@MainActor
struct SystemPasswordsTests {
    // MARK: The menu's rows

    private func login(_ site: String, _ username: String) -> Credential {
        Credential(id: UUID(), origin: Origin(URL(string: site))!, username: username, title: "", notes: "", otpAuth: "",
                   created: Date(), modified: Date(), lastUsed: nil)
    }

    private func names(_ items: [AutofillMenu.Item]) -> [String] {
        items.map { item in
            switch item {
            case .login(let login): login.username
            case .generate: "strong"
            case .note: "note"
            case .elsewhere: "elsewhere"
            case .systemPasswords: "system"
            case .missing: "missing"
            default: "other"
            }
        }
    }

    @Test func passwordsComesLastOnEverySignIn() throws {
        let here = try #require(Origin(URL(string: "https://www.example.com")))
        let mine = login("https://www.example.com", "sam"), mail = login("https://mail.example.com", "mail")
        #expect(names(Autofill.menuItems([mine], on: here)) == ["sam", "system"])
        #expect(names(Autofill.menuItems([mine, mail], on: here)) == ["sam", "elsewhere", "system"])
        // Nothing saved for the site: it's the one thing on offer.
        #expect(names(Autofill.menuItems([], on: here)) == ["system"])
        #expect(names(Autofill.menuItems([mine], on: here, newPassword: true)) == ["strong", "sam", "system"])
        // A private window has it too: nothing it fills is ever saved.
        #expect(names(Autofill.menuItems([mine], on: here, isPrivate: true)) == ["sam", "system"])
        #expect(names(Autofill.menuItems([mine], on: here, newPassword: true, isPrivate: true)) == ["note", "sam", "system"])
        #expect(names(Autofill.menuItems([mine], on: here, systemPasswords: false)) == ["sam"])
    }

    @Test func aFullMenuKeepsRoomForPasswords() throws {
        let here = try #require(Origin(URL(string: "https://www.example.com")))
        let many = (0..<12).map { login("https://www.example.com", "user\($0)") }
        let items = names(Autofill.menuItems(many + [login("https://mail.example.com", "mail")], on: here, newPassword: true))
        #expect(items.count == AutofillMenu.maxRows)
        #expect(items.first == "strong")
        #expect(items.suffix(2) == ["elsewhere", "system"])
        let plain = names(Autofill.menuItems(many, on: here))
        #expect(plain.count == AutofillMenu.maxRows)
        #expect(plain.last == "system")
    }

    @Test func thePasswordsRowTakesAClick() throws {
        let menu = AutofillMenu(items: [.systemPasswords], origin: try #require(Origin(URL(string: "https://example.com"))))
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let rows = all(menu).compactMap { $0 as? InteractiveView }.filter { $0.accessibilityRole() == .menuItem }
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { $0.isEnabled })
        #expect(rows.first?.accessibilityLabel() == String(localized: "Passwords…", comment: "A row at the bottom of the fill-password menu: opens the Mac’s own list of passwords to pick one from, as Edit › AutoFill › Passwords… does in other apps."))
    }

    // MARK: Filling what came back

    @Test func onlyTheSiteItWasAskedForGetsIt() throws {
        let asked = try #require(Origin(URL(string: "https://example.com")))
        #expect(Autofill.systemFillAllowed(asked: asked, now: URL(string: "https://example.com/login?next=1"), inFront: true))
        #expect(!Autofill.systemFillAllowed(asked: asked, now: URL(string: "https://example.com/login"), inFront: false))
        #expect(!Autofill.systemFillAllowed(asked: asked, now: URL(string: "https://evil.example/login"), inFront: true))
        #expect(!Autofill.systemFillAllowed(asked: asked, now: URL(string: "https://sub.example.com/login"), inFront: true))
        #expect(!Autofill.systemFillAllowed(asked: asked, now: URL(string: "http://example.com/login"), inFront: true))
        #expect(!Autofill.systemFillAllowed(asked: asked, now: URL(string: "https://example.com:8443/login"), inFront: true))
        #expect(!Autofill.systemFillAllowed(asked: asked, now: nil, inFront: true))
    }

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private final class Heard: NSObject, WKScriptMessageHandler {
        var kinds: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let kind = (message.body as? [String: Any])?["kind"] as? String else { return }
            kinds.append(kind)
        }
    }

    private func page(_ html: String, configure: (WKWebViewConfiguration) -> Void = { _ in }) async -> (WKWebView, NSWindow, Loading) {
        let configuration = WKWebViewConfiguration()
        configure(configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, window, loading)
    }

    private func value(_ id: String, in webView: WKWebView) async -> String? {
        try? await webView.evaluateJavaScript("document.getElementById('\(id)').value") as? String
    }

    private let form = "<form><input id='u' name='username' autocomplete='username'><input id='p' type='password'></form>"

    private func fill(_ webView: WKWebView, username: String, password: String, origin: String = "https://example.com") async throws -> [String: Any]? {
        _ = try await webView.evaluateJavaScript("document.getElementById('p').focus()")
        return try await webView.callAsyncJavaScript(Autofill.filler, arguments: ["username": username, "password": password, "expectedOrigin": origin, "mark": false],
                                                     in: nil, contentWorld: .defaultClient) as? [String: Any]
    }

    @Test func aLoginFromTheListFillsButIsNeverOfferedForSaving() async throws {
        let (webView, _, _) = await page(form)
        let result = try await fill(webView, username: "sam@example.com", password: "fake-pass")
        #expect(result?["username"] as? Bool == true && result?["password"] as? Bool == true)
        #expect(await value("u", in: webView) == "sam@example.com")
        #expect(await value("p", in: webView) == "fake-pass")
        // Not marked as Zigzag's own fill: the save prompt only ever offers what you typed or Zigzag filled.
        let marked = try await webView.callAsyncJavaScript("return !!(window.__zigzagFilled && window.__zigzagFilled.has(document.getElementById('p')))",
                                                           arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(marked == false)
    }

    @Test func anotherSiteGetsNothing() async throws {
        let (webView, _, _) = await page(form)
        let result = try await fill(webView, username: "sam", password: "fake-pass", origin: "https://other.example")
        #expect(result?["moved"] as? Bool == true)
        #expect(await value("u", in: webView) == "")
        #expect(await value("p", in: webView) == "")
    }

    @Test func onlyAPasswordLeavesTheUsernameAlone() async throws {
        let (webView, _, _) = await page(form)
        _ = try await webView.evaluateJavaScript("document.getElementById('u').value = 'typed'")
        let result = try await fill(webView, username: "", password: "fake-pass")
        #expect(result?["password"] as? Bool == true)
        #expect(result?["usernameEmpty"] as? Bool == false)
        #expect(await value("u", in: webView) == "typed")
        // An empty username field says so, for the toast.
        let (empty, _, _) = await page(form)
        let second = try await fill(empty, username: "", password: "fake-pass")
        #expect(second?["usernameEmpty"] as? Bool == true)
        // And only a username never empties a password that's there.
        _ = try await empty.evaluateJavaScript("document.getElementById('p').value = 'kept'")
        let third = try await fill(empty, username: "sam", password: "")
        #expect(third?["password"] as? Bool == false)
        #expect(await value("p", in: empty) == "kept")
    }

    // MARK: The fields over the page

    /// A window with a page stand-in to hand the focus back to, and an overlay for the fields.
    private final class Stand: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func host() -> (NSWindow, NSView, Stand) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let stand = Stand(frame: content.bounds)
        let overlay = NSView(frame: content.bounds)
        content.addSubview(stand)
        content.addSubview(overlay)
        window.contentView = content
        window.makeFirstResponder(stand)
        return (window, overlay, stand)
    }

    private func wait(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    @Test func theFieldsGoOverThePageFieldAndAway() async throws {
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {})
        var asked = false
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 40, y: 60, width: 280, height: 32), in: overlay, restoringFocusTo: stand, ask: { field in
            asked = field === picker.passwordField
            return true
        }) { outcome = $0 }
        #expect(asked)
        #expect(picker.isPresented)
        #expect(picker.anchor.superview === overlay)
        #expect(picker.anchor.frame == NSRect(x: 40, y: 60, width: 280, height: 32))
        #expect(picker.passwordField.contentType == .password && picker.usernameField.contentType == .username)
        // Focused, so AutoFill has a field, but never in the way of a click on the page.
        #expect(picker.passwordField.currentEditor() != nil)
        #expect(picker.anchor.hitTest(NSPoint(x: 50, y: 70)) == nil)
        picker.cancel()
        guard case .cancelled(.replaced) = outcome else { Issue.record("expected a cancel, got \(String(describing: outcome))"); return }
        #expect(!picker.isPresented)
        #expect(picker.anchor.superview == nil)
        #expect(window.firstResponder === stand)
    }

    @Test func whatAutoFillPutsInIsReadThenEmptied() async throws {
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {})
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        picker.usernameField.stringValue = "sam@example.com"
        picker.passwordField.stringValue = "fake-pass"
        picker.fieldsDidChange()
        #expect(outcome == nil)  // read once both fields have had their turn
        try await wait(0.5)
        guard case .filled(let username, let password) = outcome else { Issue.record("expected a fill"); return }
        #expect(username.withUnsafeString { $0 } == "sam@example.com")
        #expect(password.withUnsafeString { $0 } == "fake-pass")
        // Nothing left behind in the native fields, and they're gone.
        #expect(picker.usernameField.stringValue.isEmpty && picker.passwordField.stringValue.isEmpty)
        #expect(picker.anchor.superview == nil)
        #expect(window.firstResponder === stand)
        // Printing it never shows it.
        #expect("\(password)" == "<redacted>")
    }

    @Test func onlyAPasswordStillComesBack() async throws {
        let (_, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {})
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        picker.passwordField.stringValue = "fake-pass"
        picker.fieldsDidChange()
        try await wait(0.5)
        guard case .filled(let username, let password) = outcome else { Issue.record("expected a fill"); return }
        #expect(username.isEmpty)
        #expect(!password.isEmpty)
    }

    @Test func itGivesUpAfterAWhile() async throws {
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(timeout: 0.2, openCheck: nil, settle: 0, dismissSystem: {})
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        try await wait(0.5)
        guard case .cancelled(.timedOut) = outcome else { Issue.record("expected a timeout, got \(String(describing: outcome))"); return }
        #expect(picker.anchor.superview == nil)
        #expect(window.firstResponder === stand)
    }

    @Test func aListThatNeverOpensTakesTheFieldsAway() async throws {
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: 0.2, settle: 0, dismissSystem: {})
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in false }) { outcome = $0 }
        guard case .cancelled(.unavailable) = outcome else { Issue.record("expected unavailable"); return }
        #expect(picker.anchor.superview == nil)
        #expect(window.firstResponder === stand)
        // Asked, but the list never took the front.
        let quiet = SystemPasswordPicker(openCheck: 0.2, settle: 0, dismissSystem: {})
        var second: SystemPasswordPicker.Outcome?
        quiet.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { second = $0 }
        try await wait(0.5)
        guard case .cancelled(.unavailable) = second else { Issue.record("expected unavailable, got \(String(describing: second))"); return }
        #expect(quiet.anchor.superview == nil)
    }

    @Test func theListTakingTheFocusDoesNotCloseIt() async throws {
        // The Mac's list can open inside Zigzag's window and take the focus from the fields as it does: that ended
        // the request at once, so the list flashed and went (reported after 0.8.1).
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(settle: 0, dismissSystem: {})
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        window.makeFirstResponder(nil)
        try await wait(0.6)
        #expect(outcome == nil)
        #expect(picker.isPresented)
        picker.cancel()
        #expect(picker.anchor.superview == nil)
    }

    @Test func escapeOrTabCancels() async throws {
        let (window, overlay, stand) = host()
        for command in [#selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:))] {
            let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {})
            var outcome: SystemPasswordPicker.Outcome?
            picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
            let editor = try #require(picker.passwordField.currentEditor() as? NSTextView)
            #expect(picker.control(picker.passwordField, textView: editor, doCommandBy: command))
            guard case .cancelled(.dismissed) = outcome else { Issue.record("expected dismissed for \(command)"); continue }
            #expect(picker.anchor.superview == nil)
            #expect(window.firstResponder === stand)
        }
    }

    @Test func aSecondRequestReplacesTheFirst() async throws {
        let (_, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {})
        var first: SystemPasswordPicker.Outcome?
        var second: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { first = $0 }
        picker.present(over: NSRect(x: 0, y: 40, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { second = $0 }
        guard case .cancelled(.replaced) = first else { Issue.record("expected the first replaced"); return }
        #expect(second == nil)
        #expect(picker.anchor.superview === overlay)
        picker.cancel()
    }

    @Test func theListIsAskedForOnceAutoFillHasCaughtUp() async throws {
        // Asked the moment the field was focused, AppKit's own update for the field closed the list a frame
        // after it opened (#378).
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0.2, dismissSystem: {})
        var asked = 0
        var focusedWhenAsked = false
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { field in
            asked += 1
            focusedWhenAsked = field.currentEditor() != nil
            return true
        }) { outcome = $0 }
        #expect(asked == 0)
        #expect(picker.passwordField.currentEditor() != nil)
        try await wait(0.4)
        #expect(asked == 1)
        #expect(focusedWhenAsked)
        #expect(outcome == nil)
        picker.cancel()
        #expect(window.firstResponder === stand)
    }

    @Test func focusMovingOnBeforeTheAskAsksNothing() async throws {
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0.2, dismissSystem: {})
        var asked = false
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in asked = true; return true }) { outcome = $0 }
        window.makeFirstResponder(stand)
        try await wait(0.4)
        #expect(!asked)
        guard case .cancelled(.dismissed) = outcome else { Issue.record("expected dismissed, got \(String(describing: outcome))"); return }
        #expect(picker.anchor.superview == nil)
    }

    @Test func aWindowClosedBeforeTheAskAsksNothing() async throws {
        // Closed during the wait for AutoFill, the window is never asked for its list (#378).
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0.2, dismissSystem: {})
        var asked = false
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in asked = true; return true }) { outcome = $0 }
        window.close()
        try await wait(0.4)
        #expect(!asked)
        guard case .cancelled(.dismissed) = outcome else { Issue.record("expected dismissed, got \(String(describing: outcome))"); return }
        #expect(!picker.isPresented)
    }

    @Test func theMacsListClosesWithTheFields() async throws {
        // Left behind, it stayed over the page and came back each time the window became key (#378).
        let (window, overlay, stand) = host()
        var dismissed = 0
        let tracked = SystemPasswordPicker(timeout: 0.6, openCheck: nil, settle: 0, dismissSystem: { dismissed += 1 })
        var outcome: SystemPasswordPicker.Outcome?
        let rect = NSRect(x: 0, y: 0, width: 200, height: 30)
        // Taken away by hand.
        tracked.present(over: rect, in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        tracked.cancel()
        #expect(dismissed == 1)
        // Escape.
        tracked.present(over: rect, in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        let editor = try #require(tracked.passwordField.currentEditor() as? NSTextView)
        #expect(tracked.control(tracked.passwordField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(dismissed == 2)
        // A login picked.
        tracked.present(over: rect, in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        tracked.passwordField.stringValue = "fake-pass"
        tracked.fieldsDidChange()
        try await wait(0.4)
        guard case .filled = outcome else { Issue.record("expected a fill, got \(String(describing: outcome))"); return }
        #expect(dismissed == 3)
        // Left open.
        tracked.present(over: rect, in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        try await wait(1)
        guard case .cancelled(.timedOut) = outcome else { Issue.record("expected a timeout, got \(String(describing: outcome))"); return }
        #expect(dismissed == 4)
        #expect(window.firstResponder === stand)
    }

    @Test func focusGoesBackBeforeTheFieldsLeaveTheWindow() async throws {
        // AppKit closes its AutoFill for a field that gives up the focus; a field already gone never does.
        let (window, overlay, stand) = host()
        var firstResponderOnDismiss: NSResponder?
        var inWindowOnDismiss = false
        var picker: SystemPasswordPicker!
        picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {
            firstResponderOnDismiss = window.firstResponder
            inWindowOnDismiss = picker.anchor.superview != nil
        })
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { _ in }
        picker.cancel()
        #expect(firstResponderOnDismiss === stand)
        #expect(inWindowOnDismiss)
    }

    @Test func thePasswordFieldIsMarkedOnlyAsTheListIsAskedFor() async throws {
        // Focused while marked, AppKit put its own Passwords… suggestion under it before the list opened (#378).
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0.2, dismissSystem: {})
        var markedWhenAsked: NSTextContentType?
        var asked = 0
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { field in
            asked += 1
            markedWhenAsked = field.contentType
            return true
        }) { outcome = $0 }
        #expect(picker.passwordField.currentEditor() != nil)
        #expect(picker.passwordField.contentType == nil)
        try await wait(0.4)
        #expect(asked == 1, "outcome \(String(describing: outcome))")
        #expect(markedWhenAsked == .password, "marked \(String(describing: markedWhenAsked?.rawValue))")
        picker.cancel()
        #expect(picker.passwordField.contentType == nil)
        #expect(picker.usernameField.contentType == .username)
        #expect(window.firstResponder === stand)
    }

    @Test func aFieldOffThePageAsksNothing() async throws {
        // The list points at the field: without one on the page, it opened at the screen's corner (#378).
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)
        #expect(SystemPasswordPicker.anchorIsValid(NSRect(x: 40, y: 60, width: 280, height: 32), in: bounds))
        #expect(!SystemPasswordPicker.anchorIsValid(NSRect(x: 40, y: 900, width: 280, height: 32), in: bounds))
        #expect(!SystemPasswordPicker.anchorIsValid(NSRect(x: -400, y: 60, width: 280, height: 32), in: bounds))
        #expect(!SystemPasswordPicker.anchorIsValid(.zero, in: bounds))
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: {})
        var asked = false
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 40, y: 900, width: 280, height: 32), in: overlay, restoringFocusTo: stand, ask: { _ in asked = true; return true }) { outcome = $0 }
        #expect(!asked)
        guard case .cancelled(.unavailable) = outcome else { Issue.record("expected unavailable, got \(String(describing: outcome))"); return }
        #expect(window.firstResponder === stand)
    }

    @Test func theMacsListIsClosedAgainWhenTheWindowIsNextKey() async throws {
        // AppKit brings it back for whatever has the focus, with no field to point at (#378).
        let (window, overlay, stand) = host()
        var dismissed = 0
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: { dismissed += 1 })
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { _ in }
        picker.cancel()
        #expect(dismissed == 1)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await wait(0.1)
        #expect(dismissed == 2)
        // Opened again: the new list is left alone.
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { _ in }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await wait(0.1)
        #expect(dismissed == 2)
        picker.cancel()
        #expect(dismissed == 3)
        // And only for a moment.
        try await wait(SystemPasswordPicker.reshowGuardTime + 0.3)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await wait(0.1)
        #expect(dismissed == 3)
    }

    @Test func theListClosesWhenTheWindowMovesOrResizes() async throws {
        let (webView, window, _) = await page(form)
        let triggers: [(Notification.Name, SystemPanelWatch.Trigger)] = [
            (NSWindow.willMoveNotification, .windowMoved), (NSWindow.didResizeNotification, .windowResized),
            (NSWindow.willStartLiveResizeNotification, .windowResized), (NSWindow.willEnterFullScreenNotification, .windowResized),
            (NSWindow.willMiniaturizeNotification, .windowHidden), (NSWindow.willCloseNotification, .windowClosed),
        ]
        for (name, expected) in triggers {
            var ends: [SystemPanelWatch.Trigger] = []
            let watch = SystemPanelWatch(webView: webView, window: window) { ends.append($0) }
            NotificationCenter.default.post(name: name, object: window)
            NotificationCenter.default.post(name: name, object: window)
            #expect(ends == [expected])
            #expect(!watch.isWatching)
        }
        // Another window moving is nothing to it.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        var ends: [SystemPanelWatch.Trigger] = []
        let watch = SystemPanelWatch(webView: webView, window: window) { ends.append($0) }
        NotificationCenter.default.post(name: NSWindow.willMoveNotification, object: other)
        watch.scrolled(in: other)
        #expect(ends.isEmpty && watch.isWatching)
        watch.stop()
    }

    @Test func theListClosesWhenThePageScrolls() async throws {
        let (webView, window, _) = await page(form)
        var ends: [SystemPanelWatch.Trigger] = []
        let watch = SystemPanelWatch(webView: webView, window: window) { ends.append($0) }
        watch.scrolled(in: window)
        watch.scrolled(in: window)
        #expect(ends == [.scrolled])
        #expect(!watch.isWatching)
    }

    @Test func theListClosesWhenThePageGoesElsewhere() async throws {
        let (webView, window, loading) = await page(form)
        var ends: [SystemPanelWatch.Trigger] = []
        let watch = SystemPanelWatch(webView: webView, window: window) { ends.append($0) }
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<p>next</p>", baseURL: URL(string: "https://example.com/next"))
        }
        #expect(ends == [.navigated])
        #expect(!watch.isWatching)
        // A page that changes only its address (a history step in a web app) counts too.
        var steps: [SystemPanelWatch.Trigger] = []
        let again = SystemPanelWatch(webView: webView, window: window) { steps.append($0) }
        _ = try await webView.evaluateJavaScript("history.pushState({}, '', '/elsewhere'); 1")
        try await wait(0.2)
        #expect(steps == [.navigated])
        #expect(!again.isWatching)
    }

    @Test func stoppingTheWatchCallsNothing() async throws {
        let (webView, window, _) = await page(form)
        var ends: [SystemPanelWatch.Trigger] = []
        let watch = SystemPanelWatch(webView: webView, window: window, timeout: 0.2) { ends.append($0) }
        watch.stop()
        NotificationCenter.default.post(name: NSWindow.willMoveNotification, object: window)
        try await wait(0.4)
        #expect(ends.isEmpty)
        // Left alone, it gives up with the list.
        let timed = SystemPanelWatch(webView: webView, window: window, timeout: 0.2) { ends.append($0) }
        try await wait(0.4)
        #expect(ends == [.timedOut])
        #expect(!timed.isWatching)
    }

    @Test func theSecondClickOfADoubleClickIsTheFirstOnes() {
        // The menu is gone by the second click, which landed on the page under it, in the next field (#378).
        #expect(Autofill.isSecondClick(clickCount: 2, sameWindow: true, after: 0.1, interval: 0.5))
        #expect(Autofill.isSecondClick(clickCount: 2, sameWindow: true, after: -0.01, interval: 0.5))
        #expect(!Autofill.isSecondClick(clickCount: 1, sameWindow: true, after: 0.1, interval: 0.5))
        #expect(!Autofill.isSecondClick(clickCount: 2, sameWindow: false, after: 0.1, interval: 0.5))
        #expect(!Autofill.isSecondClick(clickCount: 2, sameWindow: true, after: 0.6, interval: 0.5))
    }

    @Test func passwordsTakesAClickAtOnce() throws {
        // The other rows fill the page, so they still wait out a click aimed elsewhere; Passwords… fills nothing
        // until you pick in the Mac's list (#378).
        #expect(AutofillMenu.takesClick(on: .systemPasswords, shownFor: 0))
        #expect(!AutofillMenu.takesClick(on: .generate, shownFor: 0.1))
        #expect(AutofillMenu.takesClick(on: .generate, shownFor: 0.6))
        let menu = AutofillMenu(items: [.generate, .systemPasswords], origin: try #require(Origin(URL(string: "https://example.com"))))
        menu.frame = NSRect(x: 0, y: 0, width: 300, height: menu.contentHeight)
        menu.layoutSubtreeIfNeeded()
        let stand = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        stand.addSubview(menu)
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let rows = all(menu).compactMap { $0 as? InteractiveView }.filter { $0.accessibilityRole() == .menuItem }
        try #require(rows.count == 2)
        #expect(rows.allSatisfy { $0.frame.height > 0 })
        func center(_ row: NSView) -> NSPoint { row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: stand) }
        #expect(menu.hitTest(center(rows[0])) === menu)
        #expect(menu.hitTest(center(rows[1])) === rows[1])
    }

    @Test func appKitHasTheCallThatClosesItsAutoFill() throws {
        let type = try #require(NSClassFromString("NSAutoFillHeuristicController") as? NSObject.Type)
        #expect(type.responds(to: NSSelectorFromString("sharedInstance")))
        #expect(type.instancesRespond(to: NSSelectorFromString("_dismissAutoFill")))
        // With nothing showing, it does nothing.
        SystemPasswordPicker.dismissSystemAutoFill()
    }

    @Test func itOpensAgainEveryTime() async throws {
        let (window, overlay, stand) = host()
        var dismissed = 0
        let picker = SystemPasswordPicker(openCheck: nil, settle: 0, dismissSystem: { dismissed += 1 })
        for round in 1...5 {
            var asked = false
            var outcome: SystemPasswordPicker.Outcome?
            picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { field in
                asked = field.currentEditor() != nil
                return true
            }) { outcome = $0 }
            #expect(asked)
            #expect(picker.isPresented)
            let editor = try #require(picker.passwordField.currentEditor() as? NSTextView)
            _ = picker.control(picker.passwordField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            guard case .cancelled(.dismissed) = outcome else { Issue.record("round \(round): expected dismissed"); return }
            #expect(dismissed == round)
            #expect(!picker.isPresented)
            #expect(window.firstResponder === stand)
        }
    }

    @Test func typingIsNeverTakenForAFill() throws {
        let now = ProcessInfo.processInfo.systemUptime
        func key(at time: TimeInterval) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
                             characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        }
        #expect(SystemPasswordPicker.isTyping(key(at: now)))
        // The Return that chose Passwords… in the menu, seconds before the list filled anything.
        #expect(!SystemPasswordPicker.isTyping(key(at: now - 5)))
        #expect(!SystemPasswordPicker.isTyping(nil))
    }

    // MARK: macOS 27: the key icon

    @Test func signInFieldsGetTheKeyIcon() async throws {
        guard #available(macOS 27, *) else { return }
        let html = """
        <form><input id='u' name='username' autocomplete='username'><input id='p' type='password'>
        <input id='q' type='search' name='q'><input id='n' type='password' autocomplete='new-password'></form>
        """
        func icons(_ on: Bool) async throws -> [String] {
            let (webView, _, _) = await page(html) { configuration in
                configuration.userContentController.addUserScript(AutofillKeyIcon.script)
                configuration.userContentController.addScriptMessageHandler(AutofillKeyIcon.Asker { _ in on }, contentWorld: AutofillKeyIcon.world, name: AutofillKeyIcon.messageName)
            }
            try await wait(0.3)
            let types = try await webView.callAsyncJavaScript("return ['u', 'p', 'q', 'n'].map((id) => document.getElementById(id).autofillButtonType)",
                                                              arguments: [:], in: nil, contentWorld: AutofillKeyIcon.world) as? [String]
            return types ?? []
        }
        #expect(try await icons(true) == ["credentials", "credentials", "none", "none"])
        // Off when Zigzag doesn't fill passwords in the profile.
        #expect(try await icons(false) == ["none", "none", "none", "none"])
    }

    @Test func theKeyIconIsOnlyZigzagsWhenItFills() {
        guard #available(macOS 27, *) else { return }
        #expect(AutofillKeyIcon.shows(fills: true, managerOn: false, panelAvailable: true))
        // Fill passwords off: no key icon, even with the system panel (#236).
        #expect(!AutofillKeyIcon.shows(fills: false, managerOn: false, panelAvailable: true))
        // Password manager extensions draw their own icon in the field.
        #expect(!AutofillKeyIcon.shows(fills: true, managerOn: true, panelAvailable: true))
        #expect(!AutofillKeyIcon.shows(fills: false, managerOn: true, panelAvailable: true))
        #expect(!AutofillKeyIcon.shows(fills: true, managerOn: false, panelAvailable: false))
        // Not in a browser tab (extension or test web view): never.
        #expect(!AutofillKeyIcon.shows(in: WKWebView()))
    }

    @Test func theKeyIconFollowsFillPasswords() async throws {
        guard #available(macOS 27, *) else { return }
        let profile = Profiles.shared.profile(ofPage: nil)
        let key = ProfileKey.fillsPasswords.name(in: profile.id)
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        let webView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let managerOn = PasswordManagers.active(in: profile) != nil
        Autofill.setOn(false, in: profile)
        #expect(!AutofillKeyIcon.shows(in: webView))
        Autofill.setOn(true, in: profile)
        #expect(AutofillKeyIcon.shows(in: webView) == (SystemAutoFillPanel.isAvailable && !managerOn))
    }

    @Test func aClickOnTheKeyIconOpensTheMenu() async throws {
        guard #available(macOS 27, *) else { return }
        let heard = Heard()
        let (webView, window, _) = await page(form) { configuration in
            configuration.userContentController.addUserScript(Autofill.script)
            configuration.userContentController.add(heard, contentWorld: .defaultClient, name: Autofill.messageName)
            configuration.userContentController.addUserScript(AutofillKeyIcon.script)
            configuration.userContentController.addScriptMessageHandler(AutofillKeyIcon.Asker { _ in true }, contentWorld: AutofillKeyIcon.world, name: AutofillKeyIcon.messageName)
        }
        try await wait(0.3)
        let rect = try #require(try await webView.callAsyncJavaScript("const r = document.getElementById('p').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]",
                                                                      arguments: [:], in: nil, contentWorld: .page) as? [Double])
        // The icon sits at the field's right end.
        window.makeFirstResponder(webView)
        let point = webView.convert(NSPoint(x: rect[0] + rect[2] - 10, y: webView.isFlipped ? rect[1] + rect[3] / 2 : webView.bounds.height - rect[1] - rect[3] / 2), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        try await wait(0.3)
        _ = try await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil, contentWorld: .defaultClient)
        #expect(heard.kinds.contains("focus"))
    }

    // MARK: macOS 27: the Mac's AutoFill panel on the page's field

    private final class KeyIconClicks: NSObject, WKUIDelegate {
        var count = 0
        @objc(_webView:didClickAutoFillButtonWithUserInfo:)
        func webView(_ webView: WKWebView, didClickAutoFillButtonWithUserInfo userInfo: Any?) { count += 1 }
    }

    @Test func aClickOnTheKeyIconReachesTheDelegate() async throws {
        guard #available(macOS 27, *) else { return }
        let clicks = KeyIconClicks()
        let (webView, window, _) = await page(form) { configuration in
            configuration.userContentController.addUserScript(AutofillKeyIcon.script)
            configuration.userContentController.addScriptMessageHandler(AutofillKeyIcon.Asker { _ in true }, contentWorld: AutofillKeyIcon.world, name: AutofillKeyIcon.messageName)
        }
        webView.uiDelegate = clicks
        try await wait(0.3)
        let rect = try #require(try await webView.callAsyncJavaScript("const r = document.getElementById('p').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]",
                                                                      arguments: [:], in: nil, contentWorld: .page) as? [Double])
        window.makeFirstResponder(webView)
        let point = webView.convert(NSPoint(x: rect[0] + rect[2] - 10, y: webView.isFlipped ? rect[1] + rect[3] / 2 : webView.bounds.height - rect[1] - rect[3] / 2), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        try await wait(0.3)
        _ = try await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil, contentWorld: .page)
        #expect(clicks.count == 1)
        // A page clicking its own field doesn't.
        _ = try await webView.evaluateJavaScript("document.getElementById('p').click()")
        try await wait(0.2)
        #expect(clicks.count == 1)
    }

    @Test func thePanelIsAskedForOnTheFieldTheMenuWasFor() async throws {
        let (webView, _, _) = await page(form) { configuration in
            configuration.userContentController.addUserScript(Autofill.script)
        }
        // The watcher keeps the field it reported; the cursor has gone elsewhere since.
        _ = try await webView.callAsyncJavaScript("window.__zigzagField = new WeakRef(document.getElementById('p')); document.getElementById('u').focus()",
                                                  arguments: [:], in: nil, contentWorld: .defaultClient)
        let elsewhere = try await webView.callAsyncJavaScript(SystemAutoFillPanel.focuser, arguments: ["expectedOrigin": "https://other.example"], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(elsewhere == false)
        let focused = try await webView.callAsyncJavaScript(SystemAutoFillPanel.focuser, arguments: ["expectedOrigin": "https://example.com"], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(focused == true)
        #expect(try await webView.evaluateJavaScript("document.activeElement.id") as? String == "p")
        // The page can't see or set the field it's kept by.
        #expect(try await webView.evaluateJavaScript("typeof window.__zigzagField") as? String == "undefined")
    }

    @Test func aFieldsRightClickMenuHasAutoFill() {
        let mainMenu = NSMenu(), edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), autoFill = NSMenuItem(title: "AutoFill", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        autoFill.submenu = NSMenu(title: "AutoFill")
        for (title, command) in [("Contact…", "_handleInsertFromContactsCommand:"), ("Passwords…", "_handleInsertFromPasswordsCommand:"), ("Credit Card…", "_handleInsertFromCreditCardsCommand:")] {
            autoFill.submenu?.addItem(NSMenuItem(title: title, action: NSSelectorFromString(command), keyEquivalent: ""))
        }
        edit.submenu?.addItem(autoFill)
        mainMenu.addItem(edit)
        func webMenu(_ identifiers: [String]) -> NSMenu {
            let menu = NSMenu()
            for identifier in identifiers {
                if identifier == "-" { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
                menu.addItem(item)
            }
            return menu
        }
        func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

        let field = webMenu(["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste", "-", "WKMenuItemIdentifierInspectElement"])
        BrowserWebView.addAutoFill(to: field, from: mainMenu)
        #expect(titles(field) == ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste", "-", "AutoFill", "-", "WKMenuItemIdentifierInspectElement"])
        #expect(field.items[4].submenu?.items.map(\.title) == ["Contact…", "Passwords…", "Credit Card…"])
        #expect(field.items[4].submenu?.items[1].action == SystemAutoFillPanel.command)
        // The menu bar keeps its own.
        #expect(autoFill.submenu?.items.count == 3)
        // Once only.
        BrowserWebView.addAutoFill(to: field, from: mainMenu)
        #expect(titles(field).filter { $0 == "AutoFill" }.count == 1)
        // Not on a page's menu away from a field.
        let page = webMenu(["WKMenuItemIdentifierReload", "-", "WKMenuItemIdentifierInspectElement"])
        BrowserWebView.addAutoFill(to: page, from: mainMenu)
        #expect(titles(page) == ["WKMenuItemIdentifierReload", "-", "WKMenuItemIdentifierInspectElement"])
    }

    @Test func onlyAClickJustMadeOpensThePanel() {
        #expect(Autofill.justClicked(99.6, now: 100))
        #expect(!Autofill.justClicked(95, now: 100))
        #expect(!Autofill.justClicked(-.infinity, now: 100))
        #expect(!Autofill.justClicked(101, now: 100))
    }
}

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
        let picker = SystemPasswordPicker(openCheck: nil)
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
        let picker = SystemPasswordPicker(openCheck: nil)
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
        let picker = SystemPasswordPicker(openCheck: nil)
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
        let picker = SystemPasswordPicker(timeout: 0.2, openCheck: nil)
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { outcome = $0 }
        try await wait(0.5)
        guard case .cancelled(.timedOut) = outcome else { Issue.record("expected a timeout, got \(String(describing: outcome))"); return }
        #expect(picker.anchor.superview == nil)
        #expect(window.firstResponder === stand)
    }

    @Test func aListThatNeverOpensTakesTheFieldsAway() async throws {
        let (window, overlay, stand) = host()
        let picker = SystemPasswordPicker(openCheck: 0.2)
        var outcome: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in false }) { outcome = $0 }
        guard case .cancelled(.unavailable) = outcome else { Issue.record("expected unavailable"); return }
        #expect(picker.anchor.superview == nil)
        #expect(window.firstResponder === stand)
        // Asked, but the list never took the front.
        let quiet = SystemPasswordPicker(openCheck: 0.2)
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
        let picker = SystemPasswordPicker()
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
            let picker = SystemPasswordPicker(openCheck: nil)
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
        let picker = SystemPasswordPicker(openCheck: nil)
        var first: SystemPasswordPicker.Outcome?
        var second: SystemPasswordPicker.Outcome?
        picker.present(over: NSRect(x: 0, y: 0, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { first = $0 }
        picker.present(over: NSRect(x: 0, y: 40, width: 200, height: 30), in: overlay, restoringFocusTo: stand, ask: { _ in true }) { second = $0 }
        guard case .cancelled(.replaced) = first else { Issue.record("expected the first replaced"); return }
        #expect(second == nil)
        #expect(picker.anchor.superview === overlay)
        picker.cancel()
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

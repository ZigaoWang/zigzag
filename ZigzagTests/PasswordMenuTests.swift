import AppKit
import Testing
import WebKit
@testable import Zigzag

/// The password menu opens for a click on a sign-in field however the page dressed it up, fills what you pick, and
/// on a field for a new password offers a strong one with your saved logins under it (#68).
@MainActor
struct PasswordMenuTests {
    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// What the password watcher tells Zigzag, by kind.
    private final class Heard: NSObject, WKScriptMessageHandler {
        var kinds: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let kind = (message.body as? [String: Any])?["kind"] as? String else { return }
            kinds.append(kind)
        }
    }

    /// A made-up page on https://example.com with the password watcher, in a window that's never shown.
    private func page(_ html: String) async -> (WKWebView, NSWindow, Heard, Loading) {
        let heard = Heard()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(Autofill.script)
        configuration.userContentController.add(heard, contentWorld: .defaultClient, name: Autofill.messageName)
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
        return (webView, window, heard, loading)
    }

    /// A person's click at a point on the page (CSS pixels from its top left), as the window hands it to the page.
    private func click(_ webView: WKWebView, x: Double, y: Double) async throws {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let point = webView.convert(NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(300))
        // Anything the watcher posted arrives before this.
        _ = try await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private func spot(_ selector: String, in webView: WKWebView, dx: Double? = nil, dy: Double? = nil) async throws -> (Double, Double) {
        let r = try #require(try await webView.callAsyncJavaScript("const r = document.querySelector(s).getBoundingClientRect(); return [r.left, r.top, r.width, r.height]",
                                                                   arguments: ["s": selector], in: nil, contentWorld: .page) as? [Double])
        return (r[0] + (dx ?? r[2] / 2), r[1] + (dy ?? r[3] / 2))
    }

    private func active(_ webView: WKWebView) async -> String? {
        try? await webView.evaluateJavaScript("document.activeElement && document.activeElement.id") as? String
    }

    /// Whether the click got through to the page: the cursor is in the field, as the page puts it there.
    private func clicksReach(_ webView: WKWebView, _ id: String) async -> Bool {
        await active(webView) == id
    }

    // An old-style placeholder: a span over the field that focuses it, gone once you type. Clicking it is clicking
    // the field; before, the menu came only once a typed character took the placeholder away.
    private let overlay = """
    <style>.f{position:relative;width:300px;margin:12px 0}.f input{width:100%;box-sizing:border-box;padding:10px}.ph{position:absolute;inset:0;padding:10px}</style>
    <form><div class="f"><input id="u" name="account"><span class="ph" id="uph">Phone or email</span></div>
    <div class="f"><input id="p" type="password" name="password"><span class="ph" id="pph">Password</span></div></form>
    <script>for (const [ph, f] of [[uph, u], [pph, p]]) { ph.addEventListener('click', () => f.focus()); f.addEventListener('input', () => { ph.style.display = f.value ? 'none' : ''; }); }</script>
    """

    @Test func aClickOnAPlaceholderOverTheFieldOpensTheMenu() async throws {
        let (webView, window, heard, _) = await page(overlay)
        _ = window
        let (x, y) = try await spot("#uph", in: webView)
        try await click(webView, x: x, y: y)
        #expect(await clicksReach(webView, "u"))
        #expect(heard.kinds.contains("focus"))
    }

    @Test func aClickOnTheBoxAroundTheFieldOpensTheMenu() async throws {
        // A field with an icon in its box, as many sign-ins have: the page focuses the field for a click on the box.
        let (webView, window, heard, _) = await page("""
        <div id="box" style="display:flex;width:320px;padding:6px 12px;border:1px solid #999"><span style="width:20px">@</span>
        <input id="u" name="username" style="flex:1;border:0"></div><input id="p" type="password">
        <script>box.addEventListener('mousedown', (e) => { if (e.target !== u) { e.preventDefault(); u.focus(); } });</script>
        """)
        _ = window
        let (x, y) = try await spot("#box", in: webView, dx: 10)
        try await click(webView, x: x, y: y)
        #expect(await clicksReach(webView, "u"))
        #expect(heard.kinds.contains("focus"))
    }

    @Test func aPageThatTakesPressesItselfStillGetsTheMenu() async throws {
        // A page that stops the mouse events (a tap library) and puts the cursor in the field itself.
        let (webView, window, heard, _) = await page("""
        <form><input id="u" name="email" autocomplete="username"><input id="p" type="password"></form>
        <script>document.addEventListener('pointerdown', (e) => { if (e.target.tagName === 'INPUT') { e.preventDefault(); const t = e.target; setTimeout(() => t.focus(), 0); } });</script>
        """)
        _ = window
        let (x, y) = try await spot("#u", in: webView)
        try await click(webView, x: x, y: y)
        #expect(await clicksReach(webView, "u"))
        #expect(heard.kinds.contains("focus"))
    }

    @Test func aClickOnTheFieldTheCursorIsAlreadyInOpensTheMenu() async throws {
        let (webView, window, heard, _) = await page("""
        <form><input id="u" name="email" autocomplete="username" autofocus><input id="p" type="password"></form>
        <script>u.focus()</script>
        """)
        _ = window
        #expect(!heard.kinds.contains("focus"))
        let (x, y) = try await spot("#u", in: webView)
        try await click(webView, x: x, y: y)
        #expect(await clicksReach(webView, "u"))
        #expect(heard.kinds.filter { $0 == "focus" }.count == 1)
    }

    @Test func aClickElsewhereStillNeverOpensTheMenu() async throws {
        // The page moves the cursor into the sign-in field on a click on its button: not a click on the field.
        let (webView, window, heard, _) = await page("""
        <button id="b" style="width:300px;height:60px">Go</button>
        <form style="margin-top:200px"><input id="u" name="email" autocomplete="username"><input id="p" type="password"></form>
        <script>b.addEventListener('mousedown', () => setTimeout(() => u.focus(), 10));</script>
        """)
        _ = window
        let (x, y) = try await spot("#b", in: webView)
        try await click(webView, x: x, y: y)
        #expect(await clicksReach(webView, "u"))
        #expect(!heard.kinds.contains("focus"))
    }

    // MARK: Filling

    private func fill(_ webView: WKWebView, focusing id: String) async throws -> [String: Any]? {
        _ = try await webView.evaluateJavaScript("document.getElementById('\(id)').focus()")
        return try await webView.callAsyncJavaScript(Autofill.filler, arguments: ["username": "sam@example.com", "password": "fake-pass",
                                                                                 "expectedOrigin": "https://example.com"],
                                                     in: nil, contentWorld: .defaultClient) as? [String: Any]
    }

    private func value(_ id: String, in webView: WKWebView) async -> String? {
        try? await webView.evaluateJavaScript("document.getElementById('\(id)').value") as? String
    }

    @Test func aPasswordFillsUnderItsPlaceholder() async throws {
        let (webView, _, _, _) = await page(overlay)
        let result = try await fill(webView, focusing: "u")
        #expect(await value("u", in: webView) == "sam@example.com")
        // Before, the placeholder over it hid it from the filler, and choosing the login seemed to do nothing.
        #expect(await value("p", in: webView) == "fake-pass")
        #expect(result?["password"] as? Bool == true)
    }

    @Test func aFieldCoveredBySomethingElseStaysEmpty() async throws {
        // Something bigger than the field over it, or something you could press: it's not the field you see.
        let (webView, _, _, _) = await page("""
        <form><input id="u" name="email" autocomplete="username">
        <div style="position:relative"><input id="p" type="password"><div style="position:absolute;left:-20px;top:-20px;width:400px;height:80px;background:white"></div></div></form>
        """)
        let result = try await fill(webView, focusing: "u")
        #expect(await value("p", in: webView) == "")
        #expect(result?["password"] as? Bool == false)
    }

    @Test func aSavedLoginPickedInANewPasswordFieldFillsIt() async throws {
        // A sign-in Zigzag took for a sign-up (two password boxes on the page): the login you chose goes in.
        let (webView, _, _, _) = await page("""
        <input id="u" placeholder="Username"><input id="p" type="password"><input id="p2" type="password">
        """)
        let result = try await fill(webView, focusing: "p")
        #expect(await value("p", in: webView) == "fake-pass")
        #expect(await value("p2", in: webView) == "")
        #expect(result?["password"] as? Bool == true)
    }

    @Test func aChangeOfPasswordStillFillsTheCurrentOne() async throws {
        let (webView, _, _, _) = await page("""
        <form><input id="u" autocomplete="username"><input id="old" type="password" autocomplete="current-password">
        <input id="new" type="password" autocomplete="new-password"><input id="again" type="password" autocomplete="new-password"></form>
        """)
        _ = try await fill(webView, focusing: "new")
        #expect(await value("old", in: webView) == "fake-pass")
        #expect(await value("new", in: webView) == "")
    }

    @Test func aPageThatMovedOnSaysSo() async throws {
        let (webView, _, _, _) = await page("<input id='p' type='password'>")
        _ = try await webView.evaluateJavaScript("document.getElementById('p').focus()")
        let result = try await webView.callAsyncJavaScript(Autofill.filler, arguments: ["username": "", "password": "fake-pass", "expectedOrigin": "https://other.example"],
                                                           in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(result?["moved"] as? Bool == true)
        #expect(await value("p", in: webView) == "")
    }

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
            case .elsewhere(let logins): "elsewhere: " + logins.map(\.username).joined(separator: ",")
            default: "other"
            }
        }
    }

    @Test func aNewPasswordFieldOffersAStrongOneAndYourLogins() throws {
        let here = try #require(Origin(URL(string: "https://www.example.com")))
        let mine = login("https://www.example.com", "sam"), mail = login("https://mail.example.com", "mail")
        #expect(names(Autofill.menuItems([mine, mail], on: here, newPassword: true, systemPasswords: false)) == ["strong", "sam", "elsewhere: mail"])
        #expect(names(Autofill.menuItems([], on: here, newPassword: true, systemPasswords: false)) == ["strong"])
        // A private window keeps no new password: a row says so, and the logins are still there.
        #expect(names(Autofill.menuItems([mine], on: here, newPassword: true, isPrivate: true, systemPasswords: false)) == ["note", "sam"])
        // A sign-in field: logins only.
        #expect(names(Autofill.menuItems([mine], on: here, systemPasswords: false)) == ["sam"])
        // Never more rows than the menu lists, the strong password and the other parts of the site kept.
        let many = (0..<12).map { login("https://www.example.com", "user\($0)") }
        let items = names(Autofill.menuItems(many + [mail], on: here, newPassword: true, systemPasswords: false))
        #expect(items.count == AutofillMenu.maxRows)
        #expect(items.first == "strong")
        #expect(items.last == "elsewhere: mail")
    }

    @Test func theNoteRowTakesNoClick() throws {
        let menu = AutofillMenu(items: [.note(.privateWindow)], origin: try #require(Origin(URL(string: "https://example.com"))))
        var picked = false
        menu.onPick = { _ in picked = true }
        #expect(menu.subviews.compactMap { $0 as? InteractiveView }.allSatisfy { !$0.isEnabled })
        #expect(!picked)
    }
}

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
        var focuses: [[String: Any]] = []
        var moves: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            kinds.append(kind)
            if kind == "focus" { focuses.append(body) }
            if kind == "move" { moves.append(body) }
        }
    }

    /// A made-up page on https://example.com with the password watcher, in a window that's never shown.
    /// `drawn`: the window drawn off screen, so the page gets its frames and layout callbacks.
    private func page(_ html: String, drawn: Bool = false) async -> (WKWebView, NSWindow, Heard, Loading) {
        let heard = Heard()
        let configuration = WKWebViewConfiguration()
        if drawn { configuration.preferences.inactiveSchedulingPolicy = .none }
        configuration.userContentController.addUserScript(Autofill.script)
        configuration.userContentController.add(heard, contentWorld: .defaultClient, name: Autofill.messageName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window.contentView = webView
        if drawn { drawOffscreen(webView, window) }
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

    /// A down-arrow key press sent through the window.
    private func pressDown(_ webView: WKWebView) async throws {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let arrow = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                                      isARepeat: false, keyCode: 125))
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    /// Down arrow in a page-focused field opens the menu marked page-chosen; a click marks it user-chosen.
    @Test func theMenuKnowsWhoChoseTheField() async throws {
        let (webView, window, heard, _) = await page("""
        <form><input id="u" name="email" autocomplete="username"><input id="p" type="password"></form>
        <script>u.focus()</script>
        """)
        _ = window
        try await pressDown(webView)
        #expect(heard.focuses.count == 1)
        #expect(heard.focuses.first?["byUser"] as? Bool == false)
        let (x, y) = try await spot("#p", in: webView)
        try await click(webView, x: x, y: y)
        #expect(heard.focuses.last?["byUser"] as? Bool == true)
    }

    /// A page-focused field far out of view gets no menu from the down arrow.
    @Test func aFieldOffThePageYouSeeGetsNoMenu() async throws {
        let (webView, window, heard, _) = await page("""
        <form style="position:absolute;top:250vh"><input id="u" name="email" autocomplete="username"><input id="p" type="password"></form>
        <script>u.focus({ preventScroll: true })</script>
        """)
        _ = window
        #expect(try await webView.evaluateJavaScript("window.scrollY") as? Double == 0)
        try await pressDown(webView)
        #expect(await active(webView) == "u")
        #expect(heard.focuses.isEmpty)
    }

    // MARK: The menu on screen

    private func drawOffscreen(_ webView: WKWebView, _ window: NSWindow) {
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: SetBool.self)(webView, occlusion, false)
        }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
    }

    private func y(of rect: Any?) -> Double? { (rect as? [String: Any])?["y"] as? Double }

    /// Before, the menu stayed where it opened when the page zoomed or the field moved, covering the field, and a click
    /// meant for the field picked a login (#378).
    @Test func theMenuFollowsAFieldThatMoves() async throws {
        let (webView, window, heard, _) = await page("""
        <form><input id="u" name="email" autocomplete="username"><input id="p" type="password"></form>
        """, drawn: true)
        defer { window.orderOut(nil) }
        let (x, y) = try await spot("#u", in: webView)
        try await click(webView, x: x, y: y)
        let opened = try #require(self.y(of: heard.focuses.last?["rect"]))
        // No menu up: nothing is followed.
        _ = try await webView.evaluateJavaScript("document.body.style.paddingTop = '40px'")
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.moves.isEmpty)
        _ = try await webView.evaluateJavaScript("document.body.style.paddingTop = ''")
        try await Task.sleep(for: .milliseconds(300))
        // The menu up: the page's layout moving the field down reports where it is now.
        // Set where Zigzag sets it, in the watcher's own world.
        _ = try await webView.callAsyncJavaScript("window.__zigzagSuggesting = true", arguments: [:], in: nil, contentWorld: .defaultClient)
        _ = try await webView.evaluateJavaScript("document.body.style.paddingTop = '120px'")
        try await Task.sleep(for: .milliseconds(400))
        _ = try await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil, contentWorld: .defaultClient)
        let moved = try #require(self.y(of: heard.moves.last?["rect"]))
        #expect(abs(moved - opened - 120) < 1)
        // So does the page zooming.
        let count = heard.moves.count
        webView.pageZoom = 1.5
        try await Task.sleep(for: .milliseconds(500))
        _ = try await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil, contentWorld: .defaultClient)
        #expect(heard.moves.count > count)
    }

    /// Pinched in, the page's CSS pixels are bigger on screen: the menu still goes under the field (#378).
    @Test func aPinchedPageStillPutsTheMenuUnderItsField() {
        let css = NSRect(x: 40, y: 90, width: 320, height: 30)
        #expect(Autofill.fieldRect(css: css, viewportOffset: .zero, pageZoom: 1, magnification: 1) == css)
        #expect(Autofill.fieldRect(css: css, viewportOffset: .zero, pageZoom: 1, magnification: 1.5) == NSRect(x: 60, y: 135, width: 480, height: 45))
        #expect(Autofill.fieldRect(css: css, viewportOffset: .zero, pageZoom: 1.25, magnification: 1) == NSRect(x: 50, y: 112.5, width: 400, height: 37.5))
        // Panned across a pinched page: counted from the part in view.
        #expect(Autofill.fieldRect(css: css, viewportOffset: NSPoint(x: 20, y: 10), pageZoom: 1, magnification: 2) == NSRect(x: 40, y: 160, width: 640, height: 60))
    }

    @Test func theMenuStaysInsideTheWindow() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        // Far below or to the side of the window.
        for field in [NSRect(x: 40, y: 1500, width: 300, height: 30), NSRect(x: -900, y: -400, width: 300, height: 30), NSRect(x: 2000, y: 300, width: 300, height: 30)] {
            let frame = Autofill.menuFrame(under: field, in: bounds, height: 200)
            #expect(bounds.contains(frame))
        }
        // A normal field: right under it.
        let field = NSRect(x: 40, y: 100, width: 300, height: 30)
        let frame = Autofill.menuFrame(under: field, in: bounds, height: 200)
        #expect(frame.minY == field.maxY + Tokens.Space.x1 && frame.minX == field.minX)
    }

    @Test func onlyAFieldYouCanSeeIsInView() {
        let viewport = NSSize(width: 800, height: 600)
        #expect(Autofill.isInView(NSRect(x: 40, y: 100, width: 300, height: 30), viewport: viewport))
        #expect(!Autofill.isInView(NSRect(x: 40, y: 1500, width: 300, height: 30), viewport: viewport))
        #expect(!Autofill.isInView(NSRect(x: -400, y: 100, width: 300, height: 30), viewport: viewport))
        #expect(!Autofill.isInView(NSRect(x: 40, y: 100, width: 0, height: 0), viewport: viewport))
    }

    /// Keys wait the same half second as clicks; Return fills only for a field you chose, or with the menu visible.
    @Test func keysWaitAndReturnNeedsYou() {
        #expect(!AutofillMenu.takesInput(shownFor: 0.1))
        #expect(!AutofillMenu.takesInput(shownFor: 0.5))
        #expect(AutofillMenu.takesInput(shownFor: 0.6))
        // Only Return waits; arrows move immediately.
        #expect(!AutofillMenu.takesKey("Enter", shownFor: 0.1) && AutofillMenu.takesKey("Enter", shownFor: 0.6))
        #expect(AutofillMenu.takesKey("ArrowDown", shownFor: 0.1) && AutofillMenu.takesKey("ArrowUp", shownFor: 0.1))
        #expect(Autofill.enterMayFill(focusedByUser: true, menuOnScreen: false))
        #expect(Autofill.enterMayFill(focusedByUser: false, menuOnScreen: true))
        #expect(!Autofill.enterMayFill(focusedByUser: false, menuOnScreen: false))
    }

    /// A menu in an offscreen window isn't visible.
    @Test func aMenuInAHiddenWindowIsNotOnScreen() throws {
        let menu = AutofillMenu(items: [.generate], origin: try #require(Origin(URL(string: "https://example.com"))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(menu)
        menu.frame = NSRect(x: 10, y: 10, width: 300, height: menu.contentHeight)
        #expect(!menu.isOnScreen)
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

    /// The field scrolled out of view: nothing is filled.
    @Test func aFieldScrolledAwayIsNotFilled() async throws {
        let (webView, _, _, _) = await page("""
        <form style="position:absolute;top:250vh"><input id="u" autocomplete="username"><input id="p" type="password"></form>
        """)
        _ = try await webView.evaluateJavaScript("document.getElementById('p').focus({ preventScroll: true })")
        let result = try await webView.callAsyncJavaScript(Autofill.filler, arguments: ["username": "sam@example.com", "password": "fake-pass",
                                                                                       "expectedOrigin": "https://example.com"],
                                                           in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(result?["password"] as? Bool == false)
        #expect(await value("p", in: webView) == "")
        #expect(await value("u", in: webView) == "")
    }

    private func fillStrong(_ webView: WKWebView, origin: String = "https://example.com") async throws -> [String: Any]? {
        try await webView.callAsyncJavaScript(Autofill.generatedFiller, arguments: ["candidates": ["Strong-1-abc", "Strong-2-def"], "expectedOrigin": origin],
                                              in: nil, contentWorld: .defaultClient) as? [String: Any]
    }

    /// A strong password fills only on the site it was offered for.
    @Test func aStrongPasswordChecksTheSite() async throws {
        let (webView, _, _, _) = await page("<form><input id='n' type='password' autocomplete='new-password'></form>")
        _ = try await webView.evaluateJavaScript("document.getElementById('n').focus()")
        let moved = try await fillStrong(webView, origin: "https://other.example")
        #expect(moved?["moved"] as? Bool == true)
        #expect(await value("n", in: webView) == "")
        let filled = try await fillStrong(webView)
        #expect(filled?["index"] as? Int == 0)
        #expect(await value("n", in: webView) == "Strong-1-abc")
    }

    /// Another strong password in the same form is a retry; in another form it isn't.
    @Test func aStrongPasswordKnowsItsForm() async throws {
        let (webView, _, _, _) = await page("""
        <form id="a"><input id="n1" type="password" autocomplete="new-password"></form>
        <form id="b"><input id="n2" type="password" autocomplete="new-password"></form>
        """)
        _ = try await webView.evaluateJavaScript("document.getElementById('n1').focus()")
        #expect(try await fillStrong(webView)?["sameForm"] as? Bool == false)
        #expect(try await fillStrong(webView)?["sameForm"] as? Bool == true)
        _ = try await webView.evaluateJavaScript("document.getElementById('n2').focus()")
        #expect(try await fillStrong(webView)?["sameForm"] as? Bool == false)
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

    /// One highlight glides between rows, as in every drawn menu: the arrow keys put it on a row, the pointer takes it
    /// to another, and no row lights on its own.
    @Test func oneHighlightGlidesBetweenRows() throws {
        let origin = try #require(Origin(URL(string: "https://example.com")))
        let menu = AutofillMenu(items: [.login(login("https://example.com", "sam")), .login(login("https://example.com", "alex")), .systemPasswords], origin: origin)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(menu)
        menu.frame = NSRect(x: 20, y: 20, width: 320, height: menu.contentHeight)
        menu.layoutSubtreeIfNeeded()
        #expect(!menu.debugHighlight.shown)
        menu.move(1)
        #expect(menu.debugHighlight.shown)
        #expect(menu.debugHighlight.frame == menu.debugRowFrame(0))
        menu.debugHover(1, true)
        #expect(menu.debugHighlight.frame == menu.debugRowFrame(1))
        #expect(menu.debugHighlight.gliding == !Tokens.Motion.reduceMotion)
        // Off the row it chose, nothing is chosen, as in MenuPanel.
        menu.debugHover(1, false)
        #expect(!menu.debugHighlight.shown)
        #expect(!menu.debugRowsFilled)
        _ = window
    }

    /// With the pointer resting on a row, the arrow keys move the highlight on from it, and Return fills the row lit.
    @Test func theKeysTakeTheHighlightFromThePointer() throws {
        let origin = try #require(Origin(URL(string: "https://example.com")))
        let menu = AutofillMenu(items: [.login(login("https://example.com", "sam")), .login(login("https://example.com", "alex")), .systemPasswords], origin: origin)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(menu)
        menu.frame = NSRect(x: 20, y: 20, width: 320, height: menu.contentHeight)
        menu.layoutSubtreeIfNeeded()
        menu.debugHover(0, true)
        guard case .login(let first)? = menu.selected else { Issue.record("no row chosen"); return }
        #expect(first.username == "sam")
        menu.move(1)
        #expect(menu.debugHighlight.frame == menu.debugRowFrame(1))
        guard case .login(let next)? = menu.selected else { Issue.record("no row chosen"); return }
        #expect(next.username == "alex")
        // The pointer leaving the row it no longer lights keeps the keys' choice.
        menu.debugHover(0, false)
        #expect(menu.debugHighlight.frame == menu.debugRowFrame(1))
        _ = window
    }
}

import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// wait_for and press_key: their arguments, the page watching for a condition, and real key events in a real page.
@MainActor
struct MCPWaitAndKeysTests {
    // MARK: Arguments

    private func parse(_ name: String, _ arguments: [String: JSON]) -> Result<MCPCommand, MCPArgumentError> { MCPCommand.parse(name, arguments) }

    private func error(_ name: String, _ arguments: [String: JSON] = [:]) -> String? {
        if case .failure(let error) = parse(name, arguments) { return error.message }
        return nil
    }

    private func key(_ key: String, _ modifiers: [String] = []) throws -> MCPKeyPress { try MCPKeyPress.parse(key, modifiers: modifiers).get() }

    @Test func readsWaitForArguments() throws {
        #expect(try parse("wait_for", ["text": "Saved"]).get() == .waitFor(nil, .text("Saved"), timeoutMs: MCPTools.waitDefault))
        #expect(try parse("wait_for", ["id": 3, "text_gone": "Loading", "timeout_ms": 1000]).get() == .waitFor(3, .textGone("Loading"), timeoutMs: 1000))
        #expect(try parse("wait_for", ["selector": ".done"]).get() == .waitFor(nil, .selector(".done"), timeoutMs: MCPTools.waitDefault))
        #expect(try parse("wait_for", ["selector_gone": "#spinner"]).get() == .waitFor(nil, .selectorGone("#spinner"), timeoutMs: MCPTools.waitDefault))
        #expect(try parse("wait_for", ["load": true, "timeout_ms": 999_999]).get() == .waitFor(nil, .load, timeoutMs: MCPTools.waitMax))
        #expect(try parse("wait_for", ["text": "x", "timeout_ms": 1]).get() == .waitFor(nil, .text("x"), timeoutMs: MCPTools.waitMin))
        #expect(error("wait_for")?.contains("one of") == true)
        #expect(error("wait_for", ["text": "a", "selector": "b"])?.contains("one of") == true)
        #expect(error("wait_for", ["load": false]) != nil)
        #expect(error("wait_for", ["text": "  "]) != nil)
        #expect(error("wait_for", ["text": "a", "timeout_ms": "soon"]) != nil)
        #expect(error("wait_for", ["script": "1"]) != nil)
    }

    @Test func readsKeys() throws {
        let enter = try key("Enter")
        #expect(enter.key == "Enter" && enter.keyCode == 36 && enter.characters == "\r" && enter.modifiers.isEmpty && enter.mayNavigate)
        #expect(try key("return").key == "Enter")
        #expect(try key("esc").keyCode == 53)
        let back = try key("Shift+Tab")
        #expect(back.key == "Tab" && back.modifiers == [.shift] && back.characters == "\u{19}" && back.name == "Shift+Tab")
        #expect(try key("Tab", ["shift"]) == back)
        let down = try key("ArrowDown")
        #expect(down.keyCode == 125 && down.modifierFlags.contains(.function) && !down.editsText)
        #expect(try key("Delete").keyCode == 117 && (try key("Backspace")).keyCode == 51)
        #expect(try key("Delete").editsText && (try key("Backspace")).editsText)
        #expect(try key("PageDown").keyCode == 121 && (try key("Home")).keyCode == 115)
        let space = try key("Space")
        #expect(space.key == " " && space.keyCode == 49 && space.name == "Space" && space.editsText)
        let combo = try key("a", ["meta", "cmd", "alt"])
        #expect(combo.key == "a" && combo.modifiers == [.alt, .meta] && combo.keyCode == 0 && combo.modifierFlags.contains(.command) && combo.name == "Alt+Meta+a")
        #expect(try key("Ctrl+Shift+K") == (try key("k", ["ctrl", "shift"])))
        #expect(try key("k", ["ctrl"]).characters == "\u{0b}")
        let capital = try key("A")
        #expect(capital.modifiers == [.shift] && capital.characters == "A")
        #expect(try key("+").key == "+" && (try key("Meta++")).key == "+" && (try key("Meta++")).modifiers == [.meta])
        for bad in ["F13", "Hyper+a", "ab", "\t", "\n", "Shift+"] {
            #expect((try? MCPKeyPress.parse(bad, modifiers: []).get()) == nil, "\(bad)")
        }
        #expect((try? MCPKeyPress.parse("a", modifiers: ["super"]).get()) == nil)
        #expect(try parse("press_key", ["key": "Enter", "selector": "#q"]).get() == .pressKey(nil, enter, selector: "#q"))
        #expect(try parse("press_key", ["id": 2, "key": "Tab", "modifiers": ["shift"]]).get() == .pressKey(2, back, selector: nil))
        #expect(error("press_key") != nil)
        #expect(error("press_key", ["key": "Enter", "modifiers": "shift"]) != nil)
        #expect(error("press_key", ["key": "Enter", "modifiers": [1]]) != nil)
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String, in window: NSWindow? = nil) async -> (WKWebView, Loading) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window?.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, loading)
    }

    private func value(_ script: String, in webView: WKWebView) async throws -> String? {
        try await webView.evaluateJavaScript(script) as? String
    }

    // MARK: wait_for

    @Test func waitsForTextThatComesLater() async throws {
        let (webView, loading) = await page("<p>Loading…</p><script>setTimeout(() => { document.querySelector('p').textContent = 'All  done'; }, 400)</script>")
        _ = loading
        guard case .matched(let object, let elapsed) = await MCPWait(.text("all done"), in: webView, timeout: 5).run() else {
            Issue.record("didn't match"); return
        }
        #expect(object["matched"] as? String == "text")
        #expect(elapsed >= 250 && elapsed < 4000)
        // Gone: the old text has left the page by now.
        guard case .matched = await MCPWait(.textGone("Loading"), in: webView, timeout: 1).run() else { Issue.record("text_gone didn't match"); return }
        #expect(MCPWait.count == 0)
    }

    @Test func timesOutNamingTheCondition() async {
        let (webView, loading) = await page("<p>Nothing here</p>")
        _ = loading
        let start = Date()
        guard case .failed(let message) = await MCPWait(.text("Never"), in: webView, timeout: 0.3).run() else { Issue.record("matched"); return }
        #expect(message.contains("Timed out after 300 ms") && message.contains("“Never”"))
        #expect(Date().timeIntervalSince(start) < 2)
        guard case .failed(let selector) = await MCPWait(.selector("#nope"), in: webView, timeout: 0.2).run() else { Issue.record("matched"); return }
        #expect(selector.contains("#nope"))
        guard case .failed(let invalid) = await MCPWait(.selector("[[["), in: webView, timeout: 1).run() else { Issue.record("matched"); return }
        #expect(invalid.contains("Invalid CSS selector"))
        #expect(MCPWait.count == 0)
    }

    /// An element that's there but hidden isn't waited for until it shows, and selector_gone waits until it's hidden again.
    @Test func waitsForAnElementToShow() async throws {
        let html = """
        <style>.hidden { display: none }</style>
        <div id="toast" class="hidden">Saved</div>
        <script>
        setTimeout(() => document.querySelector('#toast').classList.remove('hidden'), 400);
        setTimeout(() => document.querySelector('#toast').style.visibility = 'hidden', 900);
        </script>
        """
        let (webView, loading) = await page(html)
        _ = loading
        let started = Date()
        guard case .matched(let object, _) = await MCPWait(.selector("#toast"), in: webView, timeout: 5).run() else { Issue.record("didn't show"); return }
        #expect(Date().timeIntervalSince(started) > 0.25)
        #expect((object["element"] as? [String: Any])?["selector"] as? String == "#toast")
        guard case .matched = await MCPWait(.selectorGone("#toast"), in: webView, timeout: 5).run() else { Issue.record("didn't go"); return }
        guard case .matched = await MCPWait(.load, in: webView, timeout: 1).run() else { Issue.record("not loaded"); return }
    }

    @Test func navigatingAwayEndsTheWait() async throws {
        let (webView, loading) = await page("<p>First page</p>")
        let wait = Task { await MCPWait(.text("never on this page"), in: webView, timeout: 10).run() }
        try await Task.sleep(nanoseconds: 300_000_000)
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<p>Second page</p>", baseURL: URL(string: "https://example.org/"))
        }
        guard case .failed(let message) = await wait.value else { Issue.record("matched"); return }
        #expect(message.contains("another page") || message.contains("left the page"))
        #expect(MCPWait.count == 0)
    }

    /// Stop ends every wait at once, and a wait whose tab went (`ended`) ends with why.
    @Test func stopEndsEveryWait() async throws {
        let (webView, loading) = await page("<p>Page</p>")
        _ = loading
        let first = Task { await MCPWait(.text("never"), in: webView, timeout: 10).run() }
        let second = Task { await MCPWait(.selector("#never"), in: webView, timeout: 10).run() }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(MCPWait.count == 2)
        MCPWait.cancelAll(MCPWait.stoppedMessage)
        for task in [first, second] {
            guard case .failed(let message) = await task.value else { Issue.record("matched"); continue }
            #expect(message == MCPWait.stoppedMessage)
        }
        final class Flag { var on = false }
        let closed = Flag()
        let third = Task { await MCPWait(.text("never"), in: webView, timeout: 10) { closed.on ? "The tab was closed." : nil }.run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        closed.on = true
        guard case .failed(let message) = await third.value else { Issue.record("matched"); return }
        #expect(message == "The tab was closed.")
        // The page stopped watching too.
        try await Task.sleep(nanoseconds: 200_000_000)
        let left = try await webView.callAsyncJavaScript("return globalThis.__zigzagWaits ? globalThis.__zigzagWaits.size : 0", contentWorld: MCPPageScript.world) as? Int
        #expect(left == 0)
    }

    // MARK: press_key

    private static let form = """
    <title>Form</title>
    <form onsubmit="event.preventDefault(); document.title = 'sent ' + document.querySelector('#a').value">
      <input id="a" value="hi"><input id="b"><input id="pw" type="password"><button>Send</button>
    </form>
    <script>
    window.log = [];
    document.addEventListener('keydown', (e) => log.push(e.key + ':' + e.isTrusted + ':' + e.metaKey + e.altKey + e.ctrlKey + e.shiftKey));
    </script>
    """

    private func target(_ selector: String?, in webView: WKWebView) async throws -> [String: Any] {
        try await MCPPageScript.run("keyTarget", selector.map { ["selector": $0] } ?? [:], in: webView).get()
    }

    @Test func enterSubmitsTheForm() async throws {
        let (webView, loading) = await page(Self.form)
        _ = loading
        let focused = try await target("#a", in: webView)
        #expect((focused["focused"] as? [String: Any])?["selector"] as? String == "#a")
        _ = await MCPKeyDelivery.press(try key("Enter"), in: webView)
        #expect(try await value("document.title", in: webView) == "sent hi")
        #expect(try await value("log.join(',')", in: webView) == "Enter:true:falsefalsefalsefalse")
    }

    @Test func escapeReachesTheListener() async throws {
        let (webView, loading) = await page(Self.form + "<script>document.addEventListener('keydown', (e) => { if (e.key === 'Escape') document.title = 'closed'; })</script>")
        _ = loading
        _ = try await target("#b", in: webView)
        _ = await MCPKeyDelivery.press(try key("Escape"), in: webView)
        #expect(try await value("document.title", in: webView) == "closed")
    }

    @Test func tabMovesTheFocus() async throws {
        let (webView, loading) = await page(Self.form)
        _ = loading
        _ = try await target("#a", in: webView)
        let after = await MCPKeyDelivery.press(try key("Tab"), in: webView)
        #expect(after["selector"] == "#b")
        #expect(try await value("document.activeElement.id", in: webView) == "b")
        _ = await MCPKeyDelivery.press(try key("Shift+Tab"), in: webView)
        #expect(try await value("document.activeElement.id", in: webView) == "a")
        // A character types, as the keyboard would: Tab selected what's in the field, so it's replaced.
        _ = await MCPKeyDelivery.press(try key("!"), in: webView)
        #expect(try await value("document.querySelector('#a').value", in: webView) == "!")
        // The password field is told apart, so press_key can refuse to type in it.
        let secret = try await target("#pw", in: webView)
        #expect(secret["secret"] as? Bool == true)
    }

    /// A password field in a shadow root, or in a frame of the page's own origin, is still told apart.
    @Test func secretFieldsInShadowRootsAndFrames() async throws {
        let html = """
        <div id="host"></div>
        <iframe id="same" srcdoc="<input id='inner' type='password' value='x'>"></iframe>
        <iframe id="other" sandbox="allow-scripts" srcdoc="<input id='far'>"></iframe>
        <script>
        const root = document.querySelector('#host').attachShadow({ mode: 'open' });
        root.innerHTML = '<input id="spw" type="password" value="x"><input id="plain">';
        </script>
        """
        let (webView, loading) = await page(html)
        _ = loading
        _ = try await value("document.querySelector('#host').shadowRoot.querySelector('#spw').focus(), 'ok'", in: webView)
        #expect(try await target(nil, in: webView)["secret"] as? Bool == true)
        _ = try await value("document.querySelector('#host').shadowRoot.querySelector('#plain').focus(), 'ok'", in: webView)
        #expect(try await target(nil, in: webView)["secret"] as? Bool == false)
        // Waited for, as a srcdoc frame may load after the page.
        for _ in 0..<50 {
            let ready = try await value("String(!!(document.querySelector('#same').contentDocument && document.querySelector('#same').contentDocument.querySelector('#inner')))", in: webView)
            if ready == "true" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await value("document.querySelector('#same').contentDocument.querySelector('#inner').focus(), 'ok'", in: webView)
        let framed = try await target(nil, in: webView)
        #expect(framed["secret"] as? Bool == true)
        #expect(framed["inFrame"] as? Bool == false)
        // Another origin's frame can't be looked into: it stays the frame, and press_key refuses what acts in it.
        _ = try await value("document.querySelector('#other').focus(), 'ok'", in: webView)
        #expect(try await target(nil, in: webView)["inFrame"] as? Bool == true)
        for name in ["Enter", "Tab", "Space"] { #expect(try key(name).reachesFrame, "\(name)") }
        for name in ["ArrowDown", "Escape", "PageDown", "a"] { #expect(try !key(name).reachesFrame, "\(name)") }
    }

    /// ⌘⌥⌃J is one of Zigzag's menu items here: pressed in the page, the page gets it, and the menu never does.
    @Test func aModifierComboNeverReachesTheMenus() async throws {
        final class Target: NSObject {
            var fired = 0
            @objc func fire(_ sender: Any?) { fired += 1 }
        }
        let receiver = Target()
        let menu = NSApp.mainMenu ?? NSMenu()
        let hadMenu = NSApp.mainMenu != nil
        if !hadMenu { NSApp.mainMenu = menu }
        let holder = NSMenuItem(title: "Test", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Test")
        let item = NSMenuItem(title: "Test Shortcut", action: #selector(Target.fire(_:)), keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.command, .option, .control]
        item.target = receiver
        submenu.addItem(item)
        holder.submenu = submenu
        menu.addItem(holder)
        defer {
            menu.removeItem(holder)
            if !hadMenu { NSApp.mainMenu = nil }
        }
        let press = try key("j", ["meta", "alt", "ctrl"])
        // The menu answers this key when it comes from the keyboard.
        let probe = try #require(MCPKeyDelivery.events(for: press, window: nil).first)
        #expect(menu.performKeyEquivalent(with: probe))
        #expect(receiver.fired == 1)

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let (webView, loading) = await page(Self.form, in: window)
        _ = loading
        _ = try await target("#b", in: webView)
        let stoppedBefore = MCPKeyDelivery.stopped
        _ = await MCPKeyDelivery.press(press, in: webView)
        // WebKit hands back the key the page didn't take a moment after.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(try await value("log.join(',')", in: webView) == "j:true:truetruetruefalse")
        #expect(receiver.fired == 1)
        #expect(MCPKeyDelivery.stopped > stoppedBefore)
        #expect(try await value("document.querySelector('#b').value", in: webView) == "")
    }

    // MARK: Through the endpoint

    /// With a session, as every app has after initialize: both tools are listed, and their arguments are checked
    /// before anything reaches a tab.
    @Test func listedAndCheckedInASession() async throws {
        let token = "k" + String(repeating: "y", count: 42)
        let endpoint = MCPEndpoint(token: token, runner: MCPBrowserRunner(), serverVersion: "1.0")
        func post(_ body: JSON, session: String? = nil) -> HTTPRequest {
            var headers = ["host": "127.0.0.1:39217", "content-type": "application/json", "authorization": "Bearer \(token)"]
            if let session { headers["mcp-session-id"] = session; headers["mcp-protocol-version"] = "2025-06-18" }
            return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body.data)
        }
        let initialize: JSON = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Test App", "version": "1"]]]
        let session = try #require(await endpoint.handle(post(initialize)).header("Mcp-Session-Id"))
        let list = JSON.parse(await endpoint.handle(post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: session)).body)
        let names = list?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("wait_for") && names.contains("press_key"))
        let call: JSON = ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "wait_for", "arguments": ["text": "a", "load": true]]]
        let answer = JSON.parse(await endpoint.handle(post(call, session: session)).body)
        #expect(answer?["result"]?["isError"] == true)
        #expect(answer?["result"]?["content"]?.array?.first?["text"]?.string?.contains("one of") == true)
        let badKey: JSON = ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "press_key", "arguments": ["key": "Hyper+F99"]]]
        let refused = JSON.parse(await endpoint.handle(post(badKey, session: session)).body)
        #expect(refused?["result"]?["isError"] == true)
    }
}

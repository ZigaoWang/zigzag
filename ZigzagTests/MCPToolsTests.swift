import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The MCP tools: what each takes, where they may act, and what the page script does in a real page.
@MainActor
struct MCPToolsTests {
    // MARK: Arguments

    private func parse(_ name: String, _ arguments: [String: JSON] = [:]) -> Result<MCPCommand, MCPArgumentError> { MCPCommand.parse(name, arguments) }

    private func error(_ name: String, _ arguments: [String: JSON] = [:]) -> String? {
        if case .failure(let error) = parse(name, arguments) { return error.message }
        return nil
    }

    @Test func everyToolHasASchemaAndAName() {
        #expect(MCPTools.names == ["list_tabs", "open_tab", "activate_tab", "close_tab", "navigate", "go_back", "go_forward", "reload",
                                   "read_page", "get_links", "screenshot", "click", "type", "scroll"])
        for tool in MCPTools.definitions {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.string?.isEmpty == false)
        }
        // Nothing that runs an app's own code in a page.
        #expect(!MCPTools.names.contains { $0.contains("eval") || $0.contains("script") || $0.contains("javascript") })
    }

    @Test func readsArguments() throws {
        #expect(try parse("list_tabs").get() == .listTabs)
        #expect(try parse("open_tab", ["url": "https://example.com"]).get() == .openTab(URL(string: "https://example.com")!, background: false))
        #expect(try parse("open_tab", ["url": "example.com/a", "background": true]).get() == .openTab(URL(string: "https://example.com/a")!, background: true))
        #expect(try parse("activate_tab", ["id": 3]).get() == .activate(3))
        #expect(try parse("close_tab", ["id": "4"]).get() == .close(4))
        #expect(try parse("navigate", ["url": "http://localhost:8000/x"]).get() == .navigate(nil, URL(string: "http://localhost:8000/x")!))
        #expect(try parse("go_back", ["id": 2]).get() == .goBack(2))
        #expect(try parse("read_page").get() == .read(nil, maxChars: MCPTools.readDefault))
        #expect(try parse("read_page", ["max_chars": 10_000_000]).get() == .read(nil, maxChars: MCPTools.readMax))
        #expect(try parse("get_links", ["max": 5]).get() == .links(nil, max: 5))
        #expect(try parse("click", ["text": "Sign up"]).get() == .click(nil, selector: nil, text: "Sign up"))
        #expect(try parse("type", ["selector": "#q", "text": ""]).get() == .type(nil, selector: "#q", text: "", clear: true, submit: false))
        #expect(try parse("scroll", ["dy": 400.5]).get() == .scroll(nil, dy: 400.5, selector: nil))
    }

    @Test func refusesBadArguments() {
        #expect(error("open_tab") != nil)
        #expect(error("activate_tab") != nil)
        #expect(error("activate_tab", ["id": 0]) != nil)
        #expect(error("activate_tab", ["id": 1.5]) != nil)
        #expect(error("close_tab", ["id": "abc"]) != nil)
        #expect(error("click") != nil)
        #expect(error("click", ["selector": "a", "text": "b"]) != nil)
        #expect(error("click", ["selector": "  "]) != nil)
        #expect(error("type", ["selector": "#q"]) != nil)
        #expect(error("type", ["selector": "#q", "text": 5]) != nil)
        #expect(error("scroll") != nil)
        #expect(error("scroll", ["dy": "down"]) != nil)
        #expect(error("open_tab", ["url": "https://example.com", "background": "yes"]) != nil)
        #expect(error("list_tabs", ["script": "alert(1)"])?.contains("doesn't take") == true)
        #expect(error("read_page", ["evaluate": "1"]) != nil)
        #expect(error("nope") != nil)
        for address in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/hosts", "zigzag://settings", "zigzag:settings",
                        "webkit-extension://abc/page.html", "chrome-extension://abc/x.html", "about:blank", "https://", "", "hello world",
                        "https://user:pass@example.com", "localhost"] {
            #expect(error("navigate", ["url": .string(address)]) != nil, "\(address)")
        }
    }

    // MARK: Where tools may act

    @Test func onlyWebsitesInEverydayWindows() {
        let site = URL(string: "https://example.com")!
        #expect(MCPSafety.refusal(url: site, isPrivate: false) == nil)
        #expect(MCPSafety.refusal(url: site, isPrivate: true) == .privateWindow)
        #expect(MCPSafety.refusal(url: site, isPrivate: false, stopped: true) == .stopped)
        #expect(MCPSafety.refusal(url: SettingsPage.url, isPrivate: false) == .ownPage)
        #expect(MCPSafety.refusal(url: URL(string: "zigzag://history"), isPrivate: false) == .ownPage)
        #expect(MCPSafety.refusal(url: URL(string: "webkit-extension://abc/popup.html"), isPrivate: false) == .extensionPage)
        #expect(MCPSafety.refusal(url: URL(string: "file:///Users/me/notes.html"), isPrivate: false) == .notAWebPage)
        #expect(MCPSafety.refusal(url: nil, isPrivate: false) == .emptyTab)
        // An empty tab can still be sent somewhere.
        #expect(MCPSafety.refusal(url: nil, isPrivate: false, needsPage: false) == nil)
        #expect(MCPSafety.refusal(url: nil, isPrivate: true, needsPage: false) == .privateWindow)
        for refusal in [MCPSafety.Refusal.privateWindow, .ownPage, .extensionPage, .notAWebPage, .emptyTab, .stopped] {
            #expect(!MCPSafety.message(refusal).isEmpty)
        }
    }

    @Test func passwordsAreSecrets() {
        #expect(MCPSafety.isPasswordField(type: "password", autocomplete: nil))
        #expect(MCPSafety.isPasswordField(type: "PASSWORD", autocomplete: nil))
        #expect(MCPSafety.isPasswordField(type: "text", autocomplete: "current-password"))
        #expect(MCPSafety.isPasswordField(type: "text", autocomplete: "new-password"))
        #expect(!MCPSafety.isPasswordField(type: "email", autocomplete: "username"))
        #expect(MCPSafety.hidesValue(type: "text", autocomplete: "cc-number"))
        #expect(MCPSafety.hidesValue(type: "text", autocomplete: "one-time-code"))
        #expect(MCPSafety.hidesValue(type: "hidden", autocomplete: nil))
        #expect(!MCPSafety.hidesValue(type: "search", autocomplete: "off"))
    }

    @Test func theBarNamesTheApp() {
        #expect(AgentControl.line(for: "Inspector").contains("Inspector"))
        #expect(AgentControl.line(for: nil) == AgentControl.line(for: "  "))
        #expect(!AgentControl.line(for: nil).isEmpty)
        #expect(AgentControl.line(for: String(repeating: "a", count: 200)).count < 120)
    }

    /// Stop lets the tab go, keeps it out of reach and disconnects every app, not only the one on that tab; turning
    /// the setting off forgets it all.
    @Test func stopKeepsTheTabOutOfReach() {
        let control = AgentControl()
        var disconnected: [MCPClient] = []
        control.onStop = { disconnected.append($0) }
        let app = MCPClient(key: "s1", name: "Inspector"), other = MCPClient(key: "s2", name: "Other")
        let first = Tab(url: URL(string: "https://example.com"), spaceID: UUID()), second = Tab(url: URL(string: "https://example.org"), spaceID: UUID())
        let third = Tab(url: URL(string: "https://example.net"), spaceID: UUID())
        control.touch(first, by: app)
        control.touch(second, by: app)
        control.touch(third, by: other)
        control.stop(first.id)
        #expect(disconnected == [app])
        #expect(control.isStopped(first.id) && !control.isStopped(second.id))
        #expect(control.inUse.isEmpty)
        control.touch(third, by: other)
        control.release(other)
        #expect(control.inUse.isEmpty)
        control.touch(second, by: app, now: Date(timeIntervalSinceNow: -AgentControl.quietAfter - 1))
        control.forgetQuiet()
        #expect(control.inUse.isEmpty)
        control.reset()
        #expect(!control.isStopped(first.id))
    }

    // MARK: The page script, in a real page

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String) async -> (WKWebView, Loading) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, loading)
    }

    private static let form = """
    <title>Sign in</title>
    <h1>Welcome back</h1>
    <p>Please sign in.</p>
    <a href="/help">Help</a> <a href="https://other.example/x">Other site</a> <a href="javascript:void 0">Nothing</a>
    <form onsubmit="event.preventDefault(); document.title = 'sent ' + document.querySelector('#user').value">
      <label for="user">Email</label><input id="user" name="user" value="me@example.com">
      <input id="pw" type="password" value="hunter2-secret">
      <input id="pw2" type="text" autocomplete="current-password" value="also-secret">
      <input id="card" autocomplete="cc-number" value="4111111111111111">
      <select id="size"><option>Small</option><option>Large</option></select>
      <button id="go" type="submit">Sign in</button>
    </form>
    <div id="out"></div>
    <button onclick="document.querySelector('#out').textContent = 'clicked'">Press me</button>
    """

    @Test func readNeverGivesPasswords() async throws {
        let (webView, loading) = await page(Self.form)
        _ = loading
        let read = try await MCPPageScript.run("read", ["maxChars": 1000], in: webView).get()
        let text = JSON(foundation: read)?.text ?? ""
        #expect(read["title"] as? String == "Sign in")
        #expect((read["text"] as? String)?.contains("Welcome back") == true)
        #expect(text.contains("me@example.com"))
        for secret in ["hunter2-secret", "also-secret", "4111111111111111"] { #expect(!text.contains(secret), "\(secret)") }
        let fields = read["fields"] as? [[String: Any]] ?? []
        #expect(fields.contains { $0["selector"] as? String == "#pw" && $0["password"] as? Bool == true && $0["value"] == nil })
        #expect(fields.contains { $0["label"] as? String == "Email" })
        let short = try await MCPPageScript.run("read", ["maxChars": 5], in: webView).get()
        #expect((short["text"] as? String)?.count == 5 && short["truncated"] as? Bool == true)
    }

    @Test func neverTypesPasswords() async throws {
        let (webView, loading) = await page(Self.form)
        _ = loading
        for selector in ["#pw", "#pw2"] {
            let typed = await MCPPageScript.run("type", ["selector": selector, "text": "x", "clear": true, "submit": false], in: webView)
            #expect((try? typed.get()) == nil, "\(selector)")
        }
        let value = try await webView.evaluateJavaScript("document.querySelector('#pw').value") as? String
        #expect(value == "hunter2-secret")
    }

    @Test func typesClicksScrollsAndLists() async throws {
        let (webView, loading) = await page(Self.form + "<div style='height:3000px'></div>")
        _ = loading
        _ = try await MCPPageScript.run("type", ["selector": "#user", "text": "you@example.com", "clear": true, "submit": false], in: webView).get()
        #expect(try await webView.evaluateJavaScript("document.querySelector('#user').value") as? String == "you@example.com")
        _ = try await MCPPageScript.run("type", ["selector": "#user", "text": "!", "clear": false, "submit": true], in: webView).get()
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "sent you@example.com!")
        _ = try await MCPPageScript.run("type", ["selector": "#size", "text": "large", "clear": true, "submit": false], in: webView).get()
        #expect(try await webView.evaluateJavaScript("document.querySelector('#size').value") as? String == "Large")
        let clicked = try await MCPPageScript.run("click", ["text": "press me"], in: webView).get()
        #expect((clicked["clicked"] as? [String: Any])?["tag"] as? String == "button")
        #expect(try await webView.evaluateJavaScript("document.querySelector('#out').textContent") as? String == "clicked")
        let missing = await MCPPageScript.run("click", ["text": "no such thing"], in: webView)
        #expect((try? missing.get()) == nil)
        let invalid = await MCPPageScript.run("click", ["selector": "[[["], in: webView)
        #expect((try? invalid.get()) == nil)
        let scrolled = try await MCPPageScript.run("scroll", ["dy": 500], in: webView).get()
        #expect((scrolled["scrollTop"] as? Double ?? 0) > 0)
        let links = try await MCPPageScript.run("links", ["max": 10], in: webView).get()
        let urls = (links["links"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        #expect(urls == ["https://example.com/help", "https://other.example/x"])
    }

    /// The page's own scripts can't see or replace what the tools run on.
    @Test func runsApartFromThePage() async throws {
        let (webView, loading) = await page("<script>Object.defineProperty(document, 'title', { get: () => 'faked' }); window.find = () => 1;</script><title>Real</title>")
        _ = loading
        let state = try await MCPPageScript.run("state", in: webView).get()
        #expect(state["title"] as? String == "Real")
    }
}

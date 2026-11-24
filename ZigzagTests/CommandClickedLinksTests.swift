import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A modified click on a link: ⌘ is the browser's, so the page whose own script follows links itself (YouTube's video
/// links, #317) never hears it; ⇧ and ⌥ reach the page, and the link they landed on is reported so the navigation the
/// page makes right after one is that click's (#322).
@MainActor
struct CommandClickedLinksTests {
    /// Cancels every navigation, recording the URL and modifiers.
    private final class Links: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        var clicked: [(url: String, flags: NSEvent.ModifierFlags)] = []
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated else { decisionHandler(.allow); return }
            clicked.append((action.request.url?.absoluteString ?? "", action.modifierFlags))
            decisionHandler(.cancel)
        }
    }

    /// What the page script reports about a ⇧ or ⌥ click: the link it was on, and which of the two was held.
    private final class Clicks: NSObject, WKScriptMessageHandler {
        var reported: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "zigzagLinkClick", let body = message.body as? [String: Any] else { return }
            reported.append(body)
        }
    }

    /// Each element's click handler takes the click as YouTube's router does: it cancels it and moves the page.
    private static let html = """
    <style>body { margin: 0 } a, button, div { display: block; width: 100%; height: 100px; margin: 0; padding: 0; border: 0 }</style>
    <a id="video" href="https://example.com/watch?v=1">video</a>
    <div contenteditable="true"><a id="edited" href="https://example.com/edited">edited</a></div>
    <button id="button">button</button>
    <a id="script" href="javascript:void 0">script</a>
    <a id="file" href="https://example.com/download.zip" download>file</a>
    <a id="quote" data-zigzag-href="/status/1">quote</a>
    <a id="unsafe" data-zigzag-href="javascript:void 0">unsafe</a>
    <script>
      window.heard = [];
      for (const element of document.querySelectorAll('a, button')) element.addEventListener('click', (e) => {
        heard.push(element.id);
        e.preventDefault();
        if (element.id === 'video') history.pushState({}, '', '/watch?v=1');
      });
    </script>
    """

    private func page() async -> (WKWebView, NSWindow, Links, Clicks) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PageScripts.modifiedLinkClicks)
        let clicks = Clicks()
        configuration.userContentController.add(clicks, contentWorld: .defaultClient, name: "zigzagLinkClick")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), configuration: configuration)
        window.contentView = webView
        let links = Links()
        webView.navigationDelegate = links
        await withCheckedContinuation { done in
            links.done = done
            webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, window, links, clicks)
    }

    /// A click `y` CSS pixels from the top with `flags`.
    private func click(_ webView: WKWebView, y: Double, flags: NSEvent.ModifierFlags) async throws {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let point = webView.convert(NSPoint(x: 50, y: webView.isFlipped ? y : webView.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    /// A middle click `y` CSS pixels from the top.
    private func middleClick(_ webView: WKWebView, y: Double) async throws {
        guard let window = webView.window else { return }
        window.makeFirstResponder(webView)
        let point = webView.convert(NSPoint(x: 50, y: webView.isFlipped ? y : webView.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            let made = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let cgEvent = try #require(made.cgEvent)
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            let event = try #require(NSEvent(cgEvent: cgEvent))
            if type == .otherMouseDown { webView.otherMouseDown(with: event) } else { webView.otherMouseUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    private func heard(_ webView: WKWebView) async throws -> [String] {
        try await webView.evaluateJavaScript("heard") as? [String] ?? []
    }

    @Test func aCommandClickOnALinkThePageFollowsItselfOpensTheLink() async throws {
        let (webView, window, links, _) = await page()
        try await click(webView, y: 50, flags: .command)
        #expect(try await heard(webView) == [])
        #expect(try await webView.evaluateJavaScript("location.href") as? String == "https://example.com/")
        #expect(links.clicked.map(\.url) == ["https://example.com/watch?v=1"])
        #expect(links.clicked.first?.flags.contains(.command) == true)
        withExtendedLifetime(window) {}
    }

    /// ⇧ is the page's (#322): its own script hears the click as it always did, so range-select on a real link keeps
    /// working, and the script reports the link the click landed on, for the navigation the page makes right after it.
    @Test func aShiftClickReachesThePageAndIsReported() async throws {
        let (webView, window, links, clicks) = await page()
        try await click(webView, y: 50, flags: .shift)
        #expect(try await heard(webView) == ["video"])
        #expect(links.clicked.isEmpty)
        #expect(clicks.reported.count == 1)
        #expect(clicks.reported.first?["url"] as? String == "https://example.com/watch?v=1")
        #expect(clicks.reported.first?["shift"] as? Bool == true)
        #expect(clicks.reported.first?["alt"] as? Bool == false)
        withExtendedLifetime(window) {}
    }

    /// ⌥ is the page's too: reported for the download it asks for, and never taken from the page.
    @Test func anOptionClickReachesThePageAndIsReported() async throws {
        let (webView, window, links, clicks) = await page()
        try await click(webView, y: 50, flags: .option)
        #expect(try await heard(webView) == ["video"])
        #expect(links.clicked.isEmpty)
        #expect(clicks.reported.first?["alt"] as? Bool == true)
        #expect(clicks.reported.first?["shift"] as? Bool == false)
        withExtendedLifetime(window) {}
    }

    @Test func aPlainClickIsStillThePages() async throws {
        let (webView, window, links, clicks) = await page()
        try await click(webView, y: 50, flags: [])
        #expect(try await heard(webView) == ["video"])
        #expect(try await webView.evaluateJavaScript("location.href") as? String == "https://example.com/watch?v=1")
        #expect(links.clicked.isEmpty)
        #expect(clicks.reported.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// A link in text being edited, a button, a script's link and a link to download have nothing for WebKit to open:
    /// the page has them, and a ⇧ or ⌥ click on one is not reported either.
    @Test func otherModifiedClicksAreThePages() async throws {
        let (webView, window, links, clicks) = await page()
        for y in [150.0, 250.0, 350.0, 450.0] { try await click(webView, y: y, flags: .command) }
        #expect(try await heard(webView) == ["edited", "button", "script", "file"])
        #expect(links.clicked.isEmpty)
        for y in [150.0, 250.0, 350.0, 450.0] { try await click(webView, y: y, flags: .shift) }
        #expect(clicks.reported.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// An anchor whose href was taken off on purpose keeps its address in `data-zigzag-href` (#517): a ⌘ press
    /// puts it back for WebKit to open in a tab, and the page's own handler never hears the click.
    @Test func aCommandClickOnADelinkedAnchorOpensItsAddress() async throws {
        let (webView, window, links, _) = await page()
        try await click(webView, y: 550, flags: .command)
        #expect(try await heard(webView) == [])
        #expect(links.clicked.map(\.url) == ["https://example.com/status/1"])
        #expect(links.clicked.first?.flags.contains(.command) == true)
        #expect(try await webView.evaluateJavaScript("quote.hasAttribute('data-zigzag-modified')") as? Bool == true)
        withExtendedLifetime(window) {}
    }

    @Test func aMiddleClickOnADelinkedAnchorOpensItsAddress() async throws {
        let (webView, window, links, _) = await page()
        try await middleClick(webView, y: 550)
        #expect(links.clicked.map(\.url) == ["https://example.com/status/1"])
        #expect(try await webView.evaluateJavaScript("quote.hasAttribute('data-zigzag-modified')") as? Bool == true)
        withExtendedLifetime(window) {}
    }

    /// A plain click stays the page's, so its own viewer opens; ⇧ and ⌥ are the page's too, with nothing put back.
    @Test func otherClicksOnADelinkedAnchorAreThePages() async throws {
        let (webView, window, links, clicks) = await page()
        try await click(webView, y: 550, flags: [])
        try await click(webView, y: 550, flags: .shift)
        try await click(webView, y: 550, flags: .option)
        #expect(try await heard(webView) == ["quote", "quote", "quote"])
        #expect(links.clicked.isEmpty)
        #expect(clicks.reported.isEmpty)
        #expect(try await webView.evaluateJavaScript("quote.hasAttribute('href') || quote.hasAttribute('data-zigzag-modified')") as? Bool == false)
        withExtendedLifetime(window) {}
    }

    /// Only a web address is put back: a script's stays off.
    @Test func aDelinkedAnchorWithAScriptAddressStaysOff() async throws {
        let (webView, window, links, _) = await page()
        try await click(webView, y: 650, flags: .command)
        try await middleClick(webView, y: 650)
        #expect(links.clicked.isEmpty)
        #expect(try await webView.evaluateJavaScript("unsafe.hasAttribute('href')") as? Bool == false)
        withExtendedLifetime(window) {}
    }

    @Test func everyPageGetsIt() {
        #expect(PageScripts.all.contains(PageScripts.modifiedLinkClicks))
    }
}

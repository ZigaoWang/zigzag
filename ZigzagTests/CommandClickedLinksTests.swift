import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A ⌘-click on a link the page's script follows itself, as YouTube's video links are, opens a new tab instead of
/// moving the page (#317): the page never hears that click, and WebKit asks about the link with ⌘ held.
@MainActor
struct CommandClickedLinksTests {
    /// Loads the page, then cancels every link it's asked about, writing each one down with its keys.
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

    /// Each element's click handler takes the click as YouTube's router does: it cancels it and moves the page.
    private static let html = """
    <style>body { margin: 0 } a, button, div { display: block; width: 100%; height: 100px; margin: 0; padding: 0; border: 0 }</style>
    <a id="video" href="https://example.com/watch?v=1">video</a>
    <div contenteditable="true"><a id="edited" href="https://example.com/edited">edited</a></div>
    <button id="button">button</button>
    <a id="script" href="javascript:void 0">script</a>
    <script>
      window.heard = [];
      for (const element of document.querySelectorAll('a, button')) element.addEventListener('click', (e) => {
        heard.push(element.id);
        e.preventDefault();
        if (element.id === 'video') history.pushState({}, '', '/watch?v=1');
      });
    </script>
    """

    private func page() async -> (WKWebView, NSWindow, Links) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PageScripts.commandClickedLinks)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        window.contentView = webView
        let links = Links()
        webView.navigationDelegate = links
        await withCheckedContinuation { done in
            links.done = done
            webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, window, links)
    }

    /// A click `y` CSS pixels from the page's top, with `flags` held, as the window hands it to the page.
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

    private func heard(_ webView: WKWebView) async throws -> [String] {
        try await webView.evaluateJavaScript("heard") as? [String] ?? []
    }

    @Test func aCommandClickOnALinkThePageFollowsItselfOpensTheLink() async throws {
        let (webView, window, links) = await page()
        try await click(webView, y: 50, flags: .command)
        #expect(try await heard(webView) == [])
        #expect(try await webView.evaluateJavaScript("location.href") as? String == "https://example.com/")
        #expect(links.clicked.map(\.url) == ["https://example.com/watch?v=1"])
        #expect(links.clicked.first?.flags.contains(.command) == true)
        withExtendedLifetime(window) {}
    }

    @Test func aPlainClickIsStillThePages() async throws {
        let (webView, window, links) = await page()
        try await click(webView, y: 50, flags: [])
        #expect(try await heard(webView) == ["video"])
        #expect(try await webView.evaluateJavaScript("location.href") as? String == "https://example.com/watch?v=1")
        #expect(links.clicked.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// A link in text being edited, a button and a script's link have nothing for WebKit to open: the page has them.
    @Test func otherCommandClicksAreThePages() async throws {
        let (webView, window, links) = await page()
        try await click(webView, y: 150, flags: .command)
        try await click(webView, y: 250, flags: .command)
        try await click(webView, y: 350, flags: .command)
        let heard = try await heard(webView)
        #expect(heard == ["edited", "button", "script"])
        #expect(links.clicked.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func everyPageGetsIt() {
        #expect(PageScripts.all.contains(PageScripts.commandClickedLinks))
    }
}

import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A site that calls FingerprintJS 2 to start (中语智汇's web.zyamoy.com) stayed blank with the file blocked; it gets a
/// stand-in the moment the blocker stops the script, and nothing where the script isn't blocked.
@MainActor
struct BlockedScriptStandInsTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// The blocker's own rule for the file, as EasyPrivacy has it, and the same for a page script's address.
    private static let rules = """
    [{"trigger": {"url-filter": "\\\\/fingerprint2\\\\.min\\\\.js"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "\\\\/blocked-app\\\\.js"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "\\\\/api\\\\/v0\\\\/telemetry"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "\\\\/api\\\\/v0\\\\/blocked-call"}, "action": {"type": "block"}}]
    """

    private func page(_ html: String, standIn: Bool = true, store: WKWebsiteDataStore = .nonPersistent(),
                      at address: String = "https://example.com/") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let list = try #require(try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "zigzag-test-standins-\(UUID().uuidString)",encodedContentRuleList: Self.rules))
        configuration.userContentController.add(list)
        if standIn { configuration.userContentController.addUserScript(BlockedScriptStandIns.script) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: address))
        }
        withExtendedLifetime(loading) {}
        return webView
    }

    /// The site's own start: its next script calls the library straight away.
    private static let site = """
    <script src="https://cdn.example.com/lib/fingerprint2.min.js"></script>
    <script>
      window.started = 'no';
      Fingerprint2.get((components) => {
        window.id = Fingerprint2.x64hash128(components.map((c) => c.value).join(''), 31);
        window.started = 'yes';
      });
    </script>
    """

    private func waitFor(_ script: String, in webView: WKWebView) async throws -> Any? {
        for _ in 0..<50 {
            if let value = try await webView.evaluateJavaScript(script), !(value is NSNull) { return value }
            try await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }

    @Test func aSiteThatNeedsTheBlockedLibraryStarts() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let webView = try await page(Self.site, store: store)
        let id = try await waitFor("window.started === 'yes' ? window.id : null", in: webView) as? String
        #expect(id?.count == 32)
        // The same on the next visit to the site: one ID per site, kept with its own data.
        let again = try await page(Self.site, store: store)
        #expect(try await waitFor("window.started === 'yes' ? window.id : null", in: again) as? String == id)
    }

    @Test func withoutTheStandInTheSiteStopsAtItsFirstCall() async throws {
        let webView = try await page(Self.site, standIn: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await webView.evaluateJavaScript("typeof Fingerprint2") as? String == "undefined")
        #expect(try await webView.evaluateJavaScript("window.started") as? String == "no")
    }

    @Test func aPageThatNeverAskedForItSeesNothing() async throws {
        let webView = try await page("<script>window.seen = typeof Fingerprint2</script>")
        #expect(try await webView.evaluateJavaScript("window.seen") as? String == "undefined")
    }

    @Test func itGoesWithTheBlocker() {
        let controller = WKUserContentController()
        BlockedScriptStandIns.apply(true, to: controller)
        BlockedScriptStandIns.apply(true, to: controller)
        #expect(controller.userScripts.filter(BlockedScriptStandIns.isOurs).count == 1)
        // Blocking off, or the site allowed: the library loads as it is, with nothing standing in.
        BlockedScriptStandIns.apply(false, to: controller)
        #expect(controller.userScripts.isEmpty)
    }

    @Test func noOtherBlockedScriptGetsOne() async throws {
        let webView = try await page("<script src=\"https://cdn.example.com/blocked-app.js\"></script>")
        #expect(try await webView.evaluateJavaScript("typeof Fingerprint2") as? String == "undefined")
    }

    @Test func theRealLibraryIsNeverReplaced() async throws {
        // Loaded or not, a library the page already has stays the page's.
        let webView = try await page("""
        <script>window.Fingerprint2 = { real: true };</script>
        <script src="https://cdn.example.com/lib/fingerprint2.min.js"></script>
        """)
        #expect(try await webView.evaluateJavaScript("Fingerprint2.real === true") as? Bool == true)
    }

    @Test func itsNamesAreTheOnesTheListsBlock() throws {
        let names = try Regex(BlockedScriptStandIns.fingerprint2Files).ignoresCase()
        for path in ["/fingerprint2.min.js", "/js/fingerprint2.js?v=2", "/lib/fp2.min.js", "/Fingerprintjs2/fpt2.js"] {
            #expect(path.contains(names), "\(path)")
        }
        for path in ["/fingerprint2.min.js.map", "/myfingerprint2.min.js", "/app.js"] {
            #expect(!path.contains(names), "\(path)")
        }
    }

    // MARK: Blocked requests a site checks on

    /// DeepSeek's own flush, as its telemetry sends it: a keepalive POST to the blocked address, read as a network
    /// failure when nothing comes back (#208). Then the same by XMLHttpRequest.
    private static let telemetry = """
    const sent = await fetch('/api/v0/telemetry', { method: 'POST', body: new Uint8Array([1, 2, 3]), keepalive: true,
                                                     headers: { 'Content-Type': 'application/octet-stream' } })
      .then((response) => response.status, () => 'failed');
    const posted = await new Promise((done) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/api/v0/telemetry');
      xhr.onload = () => done(xhr.readyState + ' ' + xhr.status);
      xhr.onerror = () => done('failed');
      xhr.send('x');
    });
    return sent + ' ' + posted;
    """

    private func run(_ body: String, in webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page).map { String(describing: $0) }
    }

    @Test func deepSeeksBlockedTelemetryGetsAnEmptyAnswer() async throws {
        let webView = try await page("<p>DeepSeek</p>", at: "https://chat.deepseek.com/")
        #expect(try await run(Self.telemetry, in: webView) == "200 4 200")
    }

    @Test func withoutTheStandInTheTelemetryFails() async throws {
        let webView = try await page("<p>DeepSeek</p>", standIn: false, at: "https://chat.deepseek.com/")
        #expect(try await run(Self.telemetry, in: webView) == "failed failed")
    }

    @Test func otherSitesAndOtherCallsAreLeftAlone() async throws {
        // Another site's own telemetry stays blocked, and its fetch stays the browser's.
        let other = try await page("<p>Other</p>")
        #expect(try await run(Self.telemetry, in: other) == "failed failed")
        #expect(try await run("return String(fetch.toString().includes('[native code]'))", in: other) == "true")
        // On DeepSeek, a blocked address that isn't its telemetry stays blocked too.
        let deepSeek = try await page("<p>DeepSeek</p>", at: "https://chat.deepseek.com/")
        let call = "return await fetch('/api/v0/blocked-call').then((response) => String(response.status), () => 'failed')"
        #expect(try await run(call, in: deepSeek) == "failed")
    }

    @Test func quietAddressesAreTheOnesTheListsBlock() throws {
        let deepSeek = try #require(BlockedScriptStandIns.quietRequests.first { $0.site == "chat.deepseek.com" })
        let address = try Regex(deepSeek.address).ignoresCase()
        // EasyPrivacy's `||chat.deepseek.com/api/v0/telemetry`.
        for url in ["https://chat.deepseek.com/api/v0/telemetry", "https://chat.deepseek.com/api/v0/telemetry?x=1"] {
            #expect(url.contains(address), "\(url)")
        }
        for url in ["https://chat.deepseek.com/api/v0/chat/completion", "https://example.com/chat.deepseek.com/api/v0/telemetry",
                    "https://chat.deepseek.com.example/api/v0/telemetry"] {
            #expect(!url.contains(address), "\(url)")
        }
    }
}

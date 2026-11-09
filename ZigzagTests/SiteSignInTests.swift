import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// A site's own sign-in (HTTP Basic and the like), offered to extensions' webRequest.onAuthRequired listeners as
/// Chrome offers it: who may answer, what they're told, and how their answers decide it.
@MainActor
struct SiteSignInTests {
    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(method: String = NSURLAuthenticationMethodHTTPBasic, url: String = "http://127.0.0.1:8123/private/page?x=1",
                           realm: String? = "Test Area", proxy: Bool = false, failures: Int = 0) -> URLAuthenticationChallenge {
        let space = proxy ? URLProtectionSpace(proxyHost: "127.0.0.1", port: 8123, type: NSURLProtectionSpaceHTTPProxy, realm: realm, authenticationMethod: method)
            : URLProtectionSpace(host: "127.0.0.1", port: 8123, protocol: NSURLProtectionSpaceHTTP, realm: realm, authenticationMethod: method)
        let response = HTTPURLResponse(url: URL(string: url)!, statusCode: 401, httpVersion: "HTTP/1.1",
                                       headerFields: ["WWW-Authenticate": "Basic realm=\"Test Area\"", "Content-Length": "0"])
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures,
                                          failureResponse: response, error: nil, sender: Sender())
    }

    @Test func detailsAreChromes() throws {
        let page = URL(string: "http://127.0.0.1:8123/private/page?x=1")
        let site = try #require(SiteChallenge(challenge(), pageURL: page))
        let details = BridgeWebRequest.details(site, tabHint: ["url": "http://127.0.0.1:8123/private/page?x=1", "index": 2, "active": true],
                                               now: Date(timeIntervalSince1970: 1_000))
        #expect(details["url"] as? String == "http://127.0.0.1:8123/private/page?x=1")
        #expect(details["method"] as? String == "GET")
        #expect(details["type"] as? String == "main_frame")
        #expect(details["frameId"] as? Int == 0)
        #expect(details["parentFrameId"] as? Int == -1)
        #expect(details["tabId"] as? Int == -1)
        #expect(details["isProxy"] as? Bool == false)
        #expect(details["scheme"] as? String == "basic")
        #expect(details["realm"] as? String == "Test Area")
        #expect(details["statusCode"] as? Int == 401)
        #expect(details["statusLine"] as? String == "HTTP/1.1 401 Unauthorized")
        #expect(details["timeStamp"] as? Double == 1_000_000)
        let challenger = try #require(details["challenger"] as? [String: Any])
        #expect(challenger["host"] as? String == "127.0.0.1")
        #expect(challenger["port"] as? Int == 8123)
        let headers = try #require(details["responseHeaders"] as? [[String: String]])
        #expect(headers.contains { $0["name"]?.lowercased() == "www-authenticate" && $0["value"] == "Basic realm=\"Test Area\"" })
        // The tab hint is for the bridge, which swaps it for WebKit's tab ID before any listener sees the details.
        #expect((details["__zigzagTab"] as? [String: Any])?["index"] as? Int == 2)
        // Chrome leaves out a realm the server didn't give.
        let bare = try #require(SiteChallenge(challenge(method: NSURLAuthenticationMethodHTTPDigest, realm: nil), pageURL: page))
        #expect(BridgeWebRequest.details(bare, tabHint: nil)["realm"] == nil)
        #expect(BridgeWebRequest.details(bare, tabHint: nil)["scheme"] as? String == "digest")
        #expect(BridgeWebRequest.details(bare, tabHint: nil)["__zigzagTab"] == nil)
    }

    @Test func onlyASitesOwnPasswordQuestionsAreOffered() throws {
        #expect(SiteChallenge(challenge(proxy: true), pageURL: nil) == nil)
        #expect(SiteChallenge(challenge(method: NSURLAuthenticationMethodServerTrust), pageURL: nil) == nil)
        #expect(SiteChallenge(challenge(method: NSURLAuthenticationMethodClientCertificate), pageURL: nil) == nil)
        #expect(try #require(SiteChallenge(challenge(method: NSURLAuthenticationMethodNTLM), pageURL: nil)).scheme == "ntlm")
        // Something on the page, not the page itself.
        let image = try #require(SiteChallenge(challenge(url: "http://127.0.0.1:8123/private/photo.png"), pageURL: URL(string: "http://127.0.0.1:8123/")))
        #expect(BridgeWebRequest.details(image, tabHint: nil)["type"] as? String == "other")
    }

    @Test func onlyExtensionsChromeLetsAnswerAreAsked() {
        func may(_ permissions: Set<String>, version: Double = 3, access: Bool = true) -> Bool {
            BridgeWebRequest.mayAnswer(allows: { permissions.contains($0) }, manifestVersion: version, hasAccess: access)
        }
        // 1Password and Bitwarden, Manifest V3.
        #expect(may(["webRequest", "webRequestAuthProvider"]))
        #expect(!may(["webRequest"]))
        #expect(!may(["webRequestAuthProvider"]))
        #expect(!may(["webRequest", "webRequestBlocking"]))
        // Manifest V2: blocking webRequest was enough.
        #expect(may(["webRequest", "webRequestBlocking"], version: 2))
        #expect(may(["webRequest", "webRequestAuthProvider"], version: 2))
        #expect(!may(["webRequest"], version: 2))
        // No access to the site asking, no question.
        #expect(!may(["webRequest", "webRequestAuthProvider"], access: false))
    }

    @Test func answersReadAsChromeReadsThem() {
        #expect(BridgeWebRequest.answer(from: ["authCredentials": ["username": "tester", "password": "fake-pass"]]) == .credentials(username: "tester", password: "fake-pass"))
        #expect(BridgeWebRequest.answer(from: ["authCredentials": ["username": "tester"]]) == .credentials(username: "tester", password: ""))
        #expect(BridgeWebRequest.answer(from: ["cancel": true]) == .cancel)
        #expect(BridgeWebRequest.answer(from: ["cancel": false]) == .none)
        #expect(BridgeWebRequest.answer(from: [:]) == .none)
        #expect(BridgeWebRequest.answer(from: ["authCredentials": ["password": "no name"]]) == .none)
    }

    /// A bridge whose questions go to `reply` instead of extensions, which answers as each extension would.
    private func bridge(listening: Set<String>, reply: @escaping (BridgeWebRequest, String, String) -> Void) -> (BridgeWebRequest, () -> [String]) {
        let bridge = BridgeWebRequest()
        final class Log { var sent: [String] = [] }
        let log = Log()
        bridge.isListening = { listening.contains($0) }
        bridge.send = { [weak bridge] id, details in
            log.sent.append(id)
            guard let bridge, let request = details["requestId"] as? String else { return }
            reply(bridge, id, request)
        }
        return (bridge, { log.sent })
    }

    private func answer(_ bridge: BridgeWebRequest, _ id: String, _ request: String, _ reply: [String: Any], after delay: Duration = .zero) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            _ = try? await bridge.call("authAnswer", args: [request, reply], extensionID: id)
        }
    }

    @Test func theFirstNameAndPasswordSignsIn() async {
        let (bridge, sent) = bridge(listening: ["quiet", "filler"]) { bridge, id, request in
            if id == "quiet" { self.answer(bridge, id, request, [:]) }
            if id == "filler" { self.answer(bridge, id, request, ["authCredentials": ["username": "tester", "password": "fake-pass"]], after: .milliseconds(20)) }
        }
        let answer = await bridge.ask(["url": "http://127.0.0.1/"], of: ["quiet", "filler"], timeout: .seconds(5))
        #expect(answer == .credentials(username: "tester", password: "fake-pass"))
        #expect(Set(sent()) == ["quiet", "filler"])
    }

    @Test func aCancelCancels() async {
        let (bridge, _) = bridge(listening: ["blocker"]) { bridge, id, request in self.answer(bridge, id, request, ["cancel": true]) }
        #expect(await bridge.ask([:], of: ["blocker"], timeout: .seconds(5)) == .cancel)
    }

    @Test func nothingSaidLeavesItToTheSheetAtOnce() async {
        let (bridge, _) = bridge(listening: ["a", "b"]) { bridge, id, request in self.answer(bridge, id, request, [:]) }
        let start = ContinuousClock.now
        #expect(await bridge.ask([:], of: ["a", "b"], timeout: .seconds(5)) == .none)
        // Both said nothing: no waiting out the time.
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func noAnswerInTimeLeavesItToTheSheet() async {
        let (bridge, _) = bridge(listening: ["slow"]) { bridge, id, request in
            self.answer(bridge, id, request, ["authCredentials": ["username": "late", "password": "late"]], after: .milliseconds(400))
        }
        #expect(await bridge.ask([:], of: ["slow"], timeout: .milliseconds(50)) == .none)
    }

    @Test func onlyThoseAskedCanAnswer() async {
        let (bridge, _) = bridge(listening: ["asked"]) { bridge, _, request in
            // Another extension answering a question it wasn't asked changes nothing.
            self.answer(bridge, "stranger", request, ["authCredentials": ["username": "stranger", "password": "x"]])
            self.answer(bridge, "asked", request, [:], after: .milliseconds(30))
        }
        #expect(await bridge.ask([:], of: ["asked"], timeout: .seconds(5)) == .none)
    }

    @Test func noOneToAskIsNoAnswer() async {
        #expect(await BridgeWebRequest().ask([:], of: [], timeout: .seconds(5)) == .none)
    }

    // MARK: The bridge script's side

    /// bridge.js in a fake extension background with the given permissions; what it sends Zigzag lands in __sent.
    private func script(permissions: [String]) -> JSContext {
        let context = JSContext()!
        let list = "[" + permissions.map { "'\($0)'" }.joined(separator: ", ") + "]"
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        // Enough of URL for match patterns.
        var URL = function (address) {
          const parts = /^([a-z]+:)\\/\\/([^/:?#]*)(?::\\d+)?([^?#]*)(\\?[^#]*)?/.exec(address);
          if (!parts) throw new TypeError('Invalid URL');
          this.protocol = parts[1]; this.hostname = parts[2]; this.pathname = parts[3] || '/'; this.search = parts[4] || '';
        };
        const event = () => { const l = []; return { addListener: (f) => l.push(f), removeListener: () => {}, hasListener: (f) => l.includes(f), fire: (...a) => l.map((f) => f(...a)) }; };
        var __sent = [], __listening = [];
        var __native = { onMessage: event(), onDisconnect: event(), postMessage: (m) => { if (m.listen) __listening.push(...m.listen); } };
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ manifest_version: 3, permissions: \(list) }),
                     sendNativeMessage: (host, m) => { __sent.push(m); return Promise.resolve({ value: null }); }, connectNative: () => __native },
          tabs: { query: () => Promise.resolve([{ id: 41, index: 0, active: false, url: 'http://127.0.0.1:8123/private/page' },
                                               { id: 42, index: 3, active: true, url: 'http://127.0.0.1:8123/private/page' }]) },
        };
        """)
        context.evaluateScript(ExtensionBridgeScript.source)
        return context
    }

    private func signIn(in context: JSContext) -> [[String: Any]] {
        context.evaluateScript("""
        __native.onMessage.fire({ event: 'webRequest.onAuthRequired', args: [{ requestId: 'zigzag-auth-1', url: 'http://127.0.0.1:8123/private/page',
          type: 'main_frame', tabId: -1, isProxy: false, responseHeaders: [{ name: 'WWW-Authenticate', value: 'Basic' }],
          __zigzagTab: { url: 'http://127.0.0.1:8123/private/page', index: 3, active: true } }] });
        """)
        for _ in 0..<5 { context.evaluateScript("__flush()") }
        let sent = context.evaluateScript("JSON.stringify(__sent)").toString() ?? "[]"
        return (try? JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [[String: Any]]) ?? []
    }

    private func answers(_ sent: [[String: Any]]) -> [[String: Any]] {
        sent.filter { $0["ns"] as? String == "webRequest" && $0["fn"] as? String == "authAnswer" }.compactMap { ($0["args"] as? [Any])?.last as? [String: Any] }
    }

    @Test func oneAsyncBlockingListenerAnswersAs1PasswordDoes() {
        // 1Password's Chrome build: asyncBlocking, and it both calls back and returns a promise of the same answer.
        let context = script(permissions: ["webRequest", "webRequestAuthProvider"])
        context.evaluateScript("""
        var __seen = null;
        __zigzagSignIn.add(async (details, callback) => {
          __seen = details;
          const answer = { authCredentials: { username: 'tester', password: 'fake-pass' } };
          if (callback) callback(answer);
          return answer;
        }, { urls: ['<all_urls>'] }, ['asyncBlocking']);
        """)
        #expect(context.evaluateScript("__listening.includes('webRequest.onAuthRequired')").toBool())
        let sent = answers(signIn(in: context))
        #expect(sent.count == 1)
        let given = sent.first?["authCredentials"] as? [String: String]
        #expect(given?["username"] == "tester")
        #expect(given?["password"] == "fake-pass")
        // The tab asking, by the ID its own tabs.query gives; the hint and the headers it didn't ask for are gone.
        #expect(context.evaluateScript("__seen.tabId").toInt32() == 42)
        #expect(context.evaluateScript("'__zigzagTab' in __seen").toBool() == false)
        #expect(context.evaluateScript("'responseHeaders' in __seen").toBool() == false)
    }

    @Test func blockingListenersAndFiltersAreChromes() {
        let context = script(permissions: ["webRequest", "webRequestBlocking"])
        context.evaluateScript("""
        // For another site only: never asked.
        var __other = 0;
        __zigzagSignIn.add(() => { __other++; return { cancel: true }; }, { urls: ['https://*.example.com/*'] }, ['blocking']);
        // Blocking, returning its answer, with the headers it asked for.
        var __headers = null;
        __zigzagSignIn.add((details) => { __headers = details.responseHeaders; return { authCredentials: { username: 'tester', password: 'fake-pass' } }; },
                           { urls: ['http://127.0.0.1/*'], types: ['main_frame'] }, ['blocking', 'responseHeaders']);
        """)
        let sent = answers(signIn(in: context))
        let given = sent.first?["authCredentials"] as? [String: String]
        #expect(given?["username"] == "tester")
        #expect(context.evaluateScript("__other").toInt32() == 0)
        #expect(context.evaluateScript("__headers && __headers[0].name").toString() == "WWW-Authenticate")
    }

    @Test func aListenerWithNothingToSayIsSaidAtOnce() {
        let context = script(permissions: ["webRequest", "webRequestAuthProvider"])
        context.evaluateScript("__zigzagSignIn.add((details, callback) => { callback({}); }, { urls: ['<all_urls>'] }, ['asyncBlocking']);")
        let sent = answers(signIn(in: context))
        #expect(sent.count == 1)
        #expect(sent.first?.isEmpty == true)
    }

    @Test func aCancelIsPassedOn() {
        let context = script(permissions: ["webRequest", "webRequestAuthProvider"])
        context.evaluateScript("__zigzagSignIn.add(() => ({ cancel: true }), { urls: ['<all_urls>'] }, ['blocking']);")
        #expect(answers(signIn(in: context)).first?["cancel"] as? Bool == true)
    }

    @Test func withoutTheSignInPermissionNothingListens() {
        let context = script(permissions: ["webRequest"])
        #expect(context.evaluateScript("typeof __zigzagSignIn").toString() == "undefined")
    }
}

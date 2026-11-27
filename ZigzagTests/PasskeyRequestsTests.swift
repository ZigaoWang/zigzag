import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A sign-in page's waiting passkey offer, then a second request, got every passkey on every site refused until the
/// Mac restarted: WebKit replaces the waiting request without cancelling it. The page script ends it first.
@MainActor
struct PasskeyRequestsTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Answers the page's question with an error, as a relay that can't be reached would.
    private final class Refusing: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            replyHandler(nil, "No relay")
        }
    }

    /// In place of WebKit's `get` and `create`, which need the entitlement: each call is noted in the top frame's
    /// log, stays open as a real request would, and ends when its signal aborts.
    private static let standIn = WKUserScript(source: """
    (() => {
      if (!window.CredentialsContainer) return;
      const frame = window.top === window ? 'top' : 'frame';
      window.__calls = [];
      if (frame === 'top') window.__log = [];
      const note = (text) => window.top.__log.push(frame + ' ' + text);
      for (const name of ['get', 'create']) {
        CredentialsContainer.prototype[name] = function (options) {
          const call = { options, state: 'open' };
          window.__calls.push(call);
          note('start ' + name);
          return new Promise((resolve, reject) => {
            call.resolve = resolve;
            call.reject = reject;
            const signal = options && options.signal;
            call.signal = signal;
            call.mediation = options && options.mediation;
            if (!(signal instanceof AbortSignal)) return;
            const aborted = () => { call.state = 'aborted'; note('abort ' + name); reject(signal.reason); };
            if (signal.aborted) aborted(); else signal.addEventListener('abort', aborted);
          });
        };
      }
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    private static let frame = "<iframe srcdoc='<p>A frame</p>'></iframe>"

    /// What answers a page with frames: the app (with the frames it asks), nothing, or something that refuses.
    private enum Relay { case app, none, refusing }

    /// `standIn`: the stand-in above, under the script.
    private func page(_ html: String = "<p>Sign in</p>", relay: Relay = .app, standIn: Bool = true,
                      at address: String = "https://example.com/") async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        if standIn { controller.addUserScript(Self.standIn) }
        switch relay {
        case .app:
            controller.addUserScript(PageFrames.script)
            controller.add(PageFrames.shared, contentWorld: .defaultClient, name: PageFrames.messageName)
            Passkeys.attachRequests(to: controller)
        case .none:
            controller.addUserScript(Passkeys.requests)
        case .refusing:
            controller.addUserScript(Passkeys.requests)
            controller.addScriptMessageHandler(Refusing(), contentWorld: .page, name: Passkeys.messageName)
        }
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

    /// Runs `body` in the page, with `waiting()` and `sheet()` for the two kinds of request and `soon()` to let
    /// the page and the app answer.
    private func run(_ body: String, in webView: WKWebView) async throws -> String? {
        let helpers = """
        const quietly = (request) => { request.catch(() => {}); return request; };
        const waiting = (more, credentials = navigator.credentials) =>
          quietly(credentials.get({ publicKey: {}, mediation: 'conditional', ...more }));
        const sheet = (credentials = navigator.credentials) => quietly(credentials.get({ publicKey: {} }));
        const soon = (ms = 150) => new Promise((done) => setTimeout(done, ms));
        const log = () => window.top.__log.join(', ');

        """
        return try await webView.callAsyncJavaScript(helpers + body, contentWorld: .page).map { String(describing: $0) }
    }

    @Test func aSecondRequestEndsTheWaitingOneFirst() async throws {
        let webView = await page()
        #expect(try await run("waiting(); sheet(); return log()", in: webView) == "top start get, top abort get, top start get")
    }

    /// The same turn: WebKit holds the next request only while the abort before it is still being carried out.
    @Test func aPageOnItsOwnIsNeverKeptWaiting() async throws {
        let webView = await page()
        #expect(try await run("waiting(); sheet(); return String(__calls.length)", in: webView) == "2")
    }

    @Test func makingAPasskeyEndsTheWaitingRequestToo() async throws {
        let webView = await page()
        let made = "waiting(); navigator.credentials.create({ publicKey: {} }).catch(() => {}); return log()"
        #expect(try await run(made, in: webView) == "top start get, top abort get, top start create")
    }

    /// A conditional `create` asks nothing of the person and isn't WebKit's waiting request.
    @Test func onlyAWaitingGetIsEnded() async throws {
        let webView = await page()
        let body = """
        navigator.credentials.create({ publicKey: {}, mediation: 'conditional' }).catch(() => {});
        sheet();
        return __calls.map((call) => call.state).join(' ') + ' ' + String(__calls[0].options.mediation);
        """
        #expect(try await run(body, in: webView) == "open open conditional")
    }

    @Test func leavingThePageEndsTheWaitingRequest() async throws {
        let webView = await page()
        let left = "waiting(); window.dispatchEvent(new PageTransitionEvent('pagehide')); return log()"
        #expect(try await run(left, in: webView) == "top start get, top abort get")
    }

    @Test func aRequestInThePageEndsOneWaitingInAFrame() async throws {
        let webView = await page(Self.frame)
        let body = "waiting({}, frames[0].navigator.credentials); await soon(); sheet(); await soon(); return log()"
        #expect(try await run(body, in: webView) == "frame start get, frame abort get, top start get")
    }

    @Test func aRequestInAFrameEndsOneWaitingInThePage() async throws {
        let webView = await page(Self.frame)
        let body = "waiting(); await soon(); waiting({}, frames[0].navigator.credentials); await soon(); return log()"
        #expect(try await run(body, in: webView) == "top start get, top abort get, frame start get")
    }

    /// Both are asked before either has started: the earlier one still starts, and is ended before the later.
    @Test func twoRequestsAtOnceBothStartInTurn() async throws {
        let webView = await page(Self.frame)
        #expect(try await run("waiting(); waiting(); await soon(); return log()", in: webView)
            == "top start get, top abort get, top start get")
    }

    @Test func withNoRelayAFrameStillEndsItsOwn() async throws {
        let webView = await page(Self.frame, relay: .none)
        #expect(try await run("waiting(); sheet(); return log()", in: webView) == "top start get, top abort get, top start get")
    }

    @Test func aRelayThatRefusesDoesntStopTheRequest() async throws {
        let webView = await page(Self.frame, relay: .refusing)
        #expect(try await run("waiting(); await soon(); sheet(); await soon(); return log()", in: webView)
            == "top start get, top abort get, top start get")
    }

    /// Its frames' answers and its own patience can both come: the page is answered once.
    @Test func theAppAnswersOnce() async throws {
        let webView = await page(Self.frame)
        var answers = 0
        Passkeys.endRequests(in: webView) { answers += 1 }
        try await Task.sleep(for: .seconds(Passkeys.patience * 2))
        #expect(answers == 1)
    }

    @Test func aWaitingRequestWaitsForAPasskeySheet() async throws {
        let webView = await page()
        let body = """
        sheet(); waiting(); await soon();
        const during = log();
        __calls[0].resolve(null); await soon();
        return during + ' | ' + log();
        """
        #expect(try await run(body, in: webView) == "top start get | top start get, top start get")
    }

    @Test func aSheetIsNotEndedByALaterRequest() async throws {
        let webView = await page()
        #expect(try await run("sheet(); sheet(); return __calls.map((call) => call.state).join(' ')", in: webView) == "open open")
    }

    @Test func theSitesOwnSignalStillEndsItsRequest() async throws {
        let webView = await page()
        let body = """
        const site = new AbortController();
        const request = waiting({ signal: site.signal });
        site.abort(new Error('the site left'));
        return await request.then(() => 'answered', (error) => error.message + ', ' + __calls[0].state);
        """
        #expect(try await run(body, in: webView) == "the site left, aborted")
    }

    /// WebKit refuses these itself, each in its own way, so they reach it as the site gave them.
    @Test func aSignalWebKitWouldRefuseIsLeftAlone() async throws {
        let webView = await page()
        let body = """
        const site = new AbortController();
        site.abort();
        const ended = { publicKey: {}, mediation: 'conditional', signal: site.signal };
        const wrong = { publicKey: {}, mediation: 'conditional', signal: 5 };
        navigator.credentials.get(ended).catch(() => {});
        navigator.credentials.get(wrong).catch(() => {});
        return String(__calls[0].options === ended) + ' ' + String(__calls[1].options === wrong);
        """
        #expect(try await run(body, in: webView) == "true true")
    }

    @Test func theSitesOptionsReachWebKitAsGiven() async throws {
        let webView = await page()
        let body = """
        waiting({ extra: 7 });
        const call = __calls[0];
        return [call.mediation, call.options.extra, typeof call.options.publicKey, call.signal instanceof AbortSignal].join(' ');
        """
        #expect(try await run(body, in: webView) == "conditional 7 object true")
    }

    @Test func otherCredentialsPassStraightThrough() async throws {
        let webView = await page(Self.frame)
        let body = """
        const options = { password: true };
        waiting(); await soon();
        navigator.credentials.get(options);
        return String(__calls.length) + ' ' + String(__calls[1].options === options) + ' ' + __calls[0].state;
        """
        #expect(try await run(body, in: webView) == "2 true open")
    }

    /// A frame written again runs the script again on the same window.
    @Test func aFrameWrittenAgainIsWrappedOnce() async throws {
        let webView = await page(Self.frame)
        let body = """
        const frame = frames[0];
        frame.document.open(); frame.document.write('<p>Again</p>'); frame.document.close();
        await soon();
        waiting({}, frame.navigator.credentials); await soon();
        return log();
        """
        #expect(try await run(body, in: webView) == "frame start get")
    }

    /// Without passkeys (a page not served securely) the frame still answers the app, and can't answer for itself.
    @Test func aFrameWithoutPasskeysStillAnswers() async throws {
        let webView = await page(at: "http://example.com/")
        let body = """
        const key = Symbol.for('zigzag.passkeys');
        let kept = 'kept';
        try { Object.defineProperty(window, key, { value: { end: () => new Promise(() => {}) } }); kept = 'replaced'; } catch (error) {}
        return [typeof window.CredentialsContainer, window[key].end(), kept].join(' ');
        """
        #expect(try await webView.callAsyncJavaScript(body, contentWorld: .page).map { String(describing: $0) } == "undefined false kept")
    }

    @Test func getAndCreateStillLookNative() async throws {
        let webView = await page(standIn: false)
        let body = """
        const container = CredentialsContainer.prototype;
        return [container.get, container.create].map((made) => made.toString().includes('[native code]')).join(' ');
        """
        #expect(try await webView.callAsyncJavaScript(body, contentWorld: .page).map { String(describing: $0) } == "true true")
    }

    private final class Heard: NSObject, WKScriptMessageHandler {
        var said: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            said.append(String(describing: message.body))
        }
    }

    /// A closed or slept tab's page may not reach WebKit with its abort as it goes, so it's ended before.
    @Test func aRetiredPageEndsItsWaitingRequestFirst() async throws {
        let webView = await page()
        let heard = Heard()
        webView.configuration.userContentController.add(heard, contentWorld: .page, name: "heard")
        let body = "waiting(); __calls[0].signal.addEventListener('abort', () => webkit.messageHandlers.heard.postMessage('aborted')); return log()"
        _ = try await run(body, in: webView)
        PageRetirement.retire(webView, endingPasskeys: true)
        try await Task.sleep(for: .seconds(Passkeys.patience * 2))
        #expect(heard.said == ["aborted"])
    }

    @Test func itGoesInOnceInEveryFrameBeforeThePage() {
        let script = Passkeys.requests
        #expect(Passkeys.isRequests(script))
        #expect(!Passkeys.isOurs(script))
        #expect(!script.isForMainFrameOnly)
        #expect(script.injectionTime == .atDocumentStart)
        let controller = WKUserContentController()
        Passkeys.attachRequests(to: controller)
        Passkeys.attachRequests(to: controller)
        #expect(controller.userScripts.filter(Passkeys.isRequests).count == 1)
    }

    // MARK: A passkey picked in the fill menu

    private static let key = "const key = window[Symbol.for('zigzag.passkeys')];\n"

    @Test func theWaitingRequestSaysWhatItAsksFor() async throws {
        let webView = await page()
        let body = Self.key + """
        const none = JSON.stringify(key.offered());
        waiting({ publicKey: { rpId: 'example.com', allowCredentials: [{ type: 'public-key', id: new Uint8Array([1, 2, 3]) }, { type: 'public-key', id: new Uint8Array([251, 255]).buffer }] } });
        return none + ' ' + JSON.stringify(key.offered());
        """
        #expect(try await run(body, in: webView) == #"null {"rpId":"example.com","allow":["AQID","-_8"]}"#)
    }

    @Test func aPickedPasskeyAnswersTheWaitingRequest() async throws {
        let webView = await page()
        let body = Self.key + """
        const site = new AbortController();
        const request = waiting({ signal: site.signal, publicKey: { challenge: new Uint8Array([9]), userVerification: 'required' } });
        const chosen = key.choose('AQID');
        await soon();
        const one = __calls[1];
        const allowed = one.options.publicKey.allowCredentials;
        const asked = [String(one.mediation), one.signal === site.signal, one.options.publicKey.userVerification,
                       allowed.length, allowed[0].type, [...allowed[0].id].join('.'), String(key.offered())].join(' ');
        one.resolve('signed in');
        return [chosen, log(), asked, await request].join(' | ');
        """
        #expect(try await run(body, in: webView)
            == "true | top start get, top abort get, top start get | undefined true required 1 public-key 1.2.3 null | signed in")
    }

    /// Closed without signing in, the request waits again as it did, and the site's request is still open.
    @Test func aCancelledSheetWaitsAgain() async throws {
        let webView = await page()
        let body = Self.key + """
        let settled = 'open';
        waiting().then(() => { settled = 'answered'; }, () => { settled = 'refused'; });
        key.choose('AQID');
        await soon();
        __calls[1].reject(new DOMException('Cancelled', 'NotAllowedError'));
        await soon();
        return [log(), settled, __calls[2].mediation, String(key.offered() !== null)].join(' | ');
        """
        #expect(try await run(body, in: webView) == "top start get, top abort get, top start get, top start get | open | conditional | true")
    }

    @Test func theSiteEndingItsRequestEndsTheSheetsAnswerToo() async throws {
        let webView = await page()
        let body = Self.key + """
        const site = new AbortController();
        const request = waiting({ signal: site.signal });
        key.choose('AQID');
        await soon();
        __calls[1].reject(new Error('the site left'));
        site.abort();
        return await request.then(() => 'answered', (error) => error.message + ' ' + String(__calls.length));
        """
        #expect(try await run(body, in: webView) == "the site left 2")
    }

    /// Only a passkey the request allows, and only while one waits.
    @Test func onlyAnAllowedPasskeyCanBeChosen() async throws {
        let webView = await page()
        let body = Self.key + """
        const before = key.choose('AQID');
        waiting({ publicKey: { allowCredentials: [{ type: 'public-key', id: new Uint8Array([1, 2, 3]) }] } });
        return [before, key.choose('AQIE'), key.choose(5), String(__calls.length), key.choose('AQID')].join(' ');
        """
        #expect(try await run(body, in: webView) == "false false false 1 true")
    }

    @Test func aModalRequestStillPassesStraightThrough() async throws {
        let webView = await page()
        let body = Self.key + """
        const options = { publicKey: {} };
        navigator.credentials.get(options).catch(() => {});
        return [String(__calls[0].options === options), String(key.offered())].join(' ');
        """
        #expect(try await run(body, in: webView) == "true null")
    }

    /// The fill menu's rows and the pick, through the page's own script.
    @Test func theMenuListsTheSitesPasskeysAndSignsInWithOne() async throws {
        let webView = await page(at: "https://www.example.com/")
        _ = try await run("waiting({ publicKey: { rpId: 'example.com' } }); return ''", in: webView)
        let mine = SavedPasskey(name: "sam", relyingParty: "example.com", credentialID: Data([1, 2, 3]))
        let other = SavedPasskey(name: "alex", relyingParty: "other.com", credentialID: Data([4]))
        let system = FakePasskeys(access: .allowed, saved: [mine, other])
        let suggestions = PasskeySuggestions(system: system)
        let origin = try #require(Origin(URL(string: "https://www.example.com")))
        let items = await suggestions.items(in: webView, origin: origin)
        #expect(items.count == 1)
        guard case .passkey(let listed) = items.first else { Issue.record("no passkey row"); return }
        #expect(listed == mine)
        #expect(system.askedFor == ["example.com"])
        #expect(await suggestions.use(listed, in: webView))
        #expect(try await run("await soon(); return [...__calls[1].options.publicKey.allowCredentials[0].id].join('.')", in: webView) == "1.2.3")
    }

    /// A page asking for another site's passkeys is shown none, and macOS isn't asked.
    @Test func aPageCantListAnotherSitesPasskeys() async throws {
        let webView = await page(at: "https://example.com/")
        _ = try await run("waiting({ publicKey: { rpId: 'bank.com' } }); return ''", in: webView)
        let system = FakePasskeys(access: .allowed, saved: [SavedPasskey(name: "sam", relyingParty: "bank.com", credentialID: Data([1]))])
        let items = await PasskeySuggestions(system: system).items(in: webView, origin: try #require(Origin(URL(string: "https://example.com"))))
        #expect(items.isEmpty)
        #expect(system.askedFor.isEmpty)
    }
}

/// Stands in for the Mac's passkey access, which needs the entitlement: answers as set, and notes what it was asked.
@MainActor
final class FakePasskeys: SystemPasskeys {
    var access: PasskeyAccess
    var answer: PasskeyAccess
    var saved: [SavedPasskey]
    private(set) var requests = 0
    private(set) var askedFor: [String] = []

    init(access: PasskeyAccess, answer: PasskeyAccess = .allowed, saved: [SavedPasskey] = []) {
        self.access = access
        self.answer = answer
        self.saved = saved
    }

    func requestAccess() async -> PasskeyAccess {
        requests += 1
        access = answer
        return answer
    }

    func passkeys(for relyingParty: String) async -> [SavedPasskey] {
        askedFor.append(relyingParty)
        return access == .allowed ? saved : []
    }
}

/// When Zigzag asks macOS for its saved passkeys, what it does with each answer, and which sites get them.
@MainActor
struct PasskeySuggestionsTests {
    private let offer = PasskeySuggestions.Offer(relyingParty: "example.com", allow: [])

    private func names(_ items: [AutofillMenu.Item]) -> [String] {
        items.map { item in
            switch item {
            case .passkey(let passkey): "passkey " + passkey.name
            case .allowPasskeys: "allow"
            case .login(let login): login.username
            case .systemPasswords: "system"
            default: "other"
            }
        }
    }

    /// Never asked by itself: until you pick the row, the menu offers to ask, and macOS hears nothing.
    @Test func notAskedOffersToAskAndAsksNothing() async {
        let system = FakePasskeys(access: .notAsked)
        let items = await PasskeySuggestions(system: system).items(for: offer)
        #expect(names(items) == ["allow"])
        #expect(system.requests == 0)
        #expect(system.askedFor.isEmpty)
    }

    @Test func allowedListsThisSitesPasskeysByName() async {
        let saved = [SavedPasskey(name: "zoe", relyingParty: "example.com", credentialID: Data([1])),
                     SavedPasskey(name: "Ann", relyingParty: "Example.com", credentialID: Data([2])),
                     SavedPasskey(name: "max", relyingParty: "other.com", credentialID: Data([3]))]
        let items = await PasskeySuggestions(system: FakePasskeys(access: .allowed, saved: saved)).items(for: offer)
        #expect(names(items) == ["passkey Ann", "passkey zoe"])
    }

    /// Denied: nothing is listed and nothing asked again; passkeys a site asks for still go through the Mac's sheet.
    @Test func deniedListsNothing() async {
        let system = FakePasskeys(access: .denied, saved: [SavedPasskey(name: "sam", relyingParty: "example.com", credentialID: Data([1]))])
        #expect(await PasskeySuggestions(system: system).items(for: offer).isEmpty)
        #expect(system.askedFor.isEmpty)
        #expect(system.requests == 0)
    }

    /// Without the entitlement (the dev build) there's nothing to ask.
    @Test func withoutTheEntitlementNothingIsOffered() async {
        let suggestions = PasskeySuggestions(system: nil)
        #expect(!suggestions.isAvailable)
        #expect(suggestions.access == .denied)
        #expect(await suggestions.items(for: offer).isEmpty)
        #expect(await suggestions.requestAccess() == .denied)
    }

    @Test func eachAnswerIsKept() async {
        for answer in [PasskeyAccess.allowed, .denied] {
            let system = FakePasskeys(access: .notAsked, answer: answer)
            let suggestions = PasskeySuggestions(system: system)
            var heard = 0
            let token = PasskeySuggestions.changed.observe { heard += 1 }
            #expect(await suggestions.requestAccess() == answer)
            #expect(suggestions.access == answer)
            #expect(system.requests == 1)
            #expect(heard == 1)
            token.cancel()
        }
    }

    @Test func onlyThePasskeysTheRequestAllows() {
        let one = SavedPasskey(name: "one", relyingParty: "example.com", credentialID: Data([1, 2, 3]))
        let two = SavedPasskey(name: "two", relyingParty: "example.com", credentialID: Data([4]))
        #expect(PasskeySuggestions.listed([one, two], for: .init(relyingParty: "example.com", allow: ["AQID"])) == [one])
        #expect(PasskeySuggestions.listed([one, two], for: .init(relyingParty: "example.com", allow: [])) == [one, two])
    }

    @Test func credentialIDsAreBase64URL() {
        #expect(SavedPasskey(name: "", relyingParty: "", credentialID: Data([251, 255])).id == "-_8")
        #expect(SavedPasskey(name: "", relyingParty: "", credentialID: Data([1, 2, 3])).id == "AQID")
    }

    /// A page lists its own host's passkeys or a parent domain's, never a public suffix's or another site's.
    @Test func whichSitesAPageMayAskFor() {
        #expect(PasskeySuggestions.fits("example.com", on: "example.com"))
        #expect(PasskeySuggestions.fits("example.com", on: "www.example.com"))
        #expect(PasskeySuggestions.fits("login.example.com", on: "login.example.com"))
        #expect(!PasskeySuggestions.fits("www.example.com", on: "example.com"))
        #expect(!PasskeySuggestions.fits("ample.com", on: "example.com"))
        #expect(!PasskeySuggestions.fits("other.com", on: "example.com"))
        #expect(!PasskeySuggestions.fits("co.uk", on: "bbc.co.uk"))
        #expect(!PasskeySuggestions.fits("github.io", on: "alice.github.io"))
        #expect(!PasskeySuggestions.fits("", on: "example.com"))
    }

    @Test func thePagesAnswerIsReadForItsOwnHost() {
        #expect(PasskeySuggestions.offer(from: nil, host: "example.com") == nil)
        #expect(PasskeySuggestions.offer(from: ["rpId": NSNull(), "allow": []], host: "WWW.example.com")
            == .init(relyingParty: "www.example.com", allow: []))
        #expect(PasskeySuggestions.offer(from: ["rpId": "Example.com", "allow": ["AQID"]], host: "www.example.com")
            == .init(relyingParty: "example.com", allow: ["AQID"]))
        #expect(PasskeySuggestions.offer(from: ["rpId": "bank.com"], host: "example.com") == nil)
    }

    @Test func whereTheMenuMayListPasskeys() {
        func may(available: Bool = true, getsYourData: Bool = true, managerOn: Bool = false, isMainFrame: Bool = true,
                 passkeyField: Bool = true, newPassword: Bool = false, scheme: String = "https", host: String = "example.com") -> Bool {
            PasskeySuggestions.mayOffer(available: available, getsYourData: getsYourData, managerOn: managerOn, isMainFrame: isMainFrame,
                                        passkeyField: passkeyField, newPassword: newPassword, scheme: scheme, host: host)
        }
        #expect(may())
        #expect(may(scheme: "http", host: "localhost"))
        #expect(!may(available: false))
        #expect(!may(getsYourData: false))
        // A password manager extension that brings its own passkeys keeps them.
        #expect(!may(managerOn: true))
        #expect(!may(isMainFrame: false))
        #expect(!may(passkeyField: false))
        #expect(!may(newPassword: true))
        #expect(!may(scheme: "http"))
    }

    @Test func passkeysComeFirstThenLoginsThenPasswords() throws {
        let here = try #require(Origin(URL(string: "https://example.com")))
        let login = Credential(id: UUID(), origin: here, username: "sam", title: "", notes: "", otpAuth: "", created: Date(), modified: Date(), lastUsed: nil)
        let passkey = AutofillMenu.Item.passkey(SavedPasskey(name: "sam", relyingParty: "example.com", credentialID: Data([1])))
        #expect(names(Autofill.menuItems([login], on: here, passkeys: [passkey])) == ["passkey sam", "sam", "system"])
        #expect(names(Autofill.menuItems([], on: here, passkeys: [.allowPasskeys])) == ["allow", "system"])
        let many = Array(repeating: passkey, count: 12)
        #expect(Autofill.menuItems([login], on: here, passkeys: many).count <= AutofillMenu.maxRows)
        #expect(names(Autofill.menuItems([login], on: here, passkeys: many)).suffix(2) == ["sam", "system"])
    }
}

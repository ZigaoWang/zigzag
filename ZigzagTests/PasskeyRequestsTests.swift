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
}

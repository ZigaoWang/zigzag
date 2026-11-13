import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Zigzag

/// How `chrome.userScripts` reads what an extension registers (Chrome's globs, patterns and checks), and the world
/// its scripts run in: one of their own, with only what Chrome's user-script world has.
@MainActor
struct UserScriptsTests {
    private func matches(_ glob: String, _ url: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: BridgeUserScripts.globPattern(glob))
        return regex?.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test func globsMatchTheWholeAddressAsChromeDoes() {
        #expect(matches("*://*.example.com/*", "https://www.example.com/page"))
        #expect(!matches("*://*.example.com/*", "https://example.org/page"))
        // `?` is one character, and everything else is itself, dots and all.
        #expect(matches("https://a.com/?.html", "https://a.com/x.html"))
        #expect(!matches("https://a.com/?.html", "https://a.com/xy.html"))
        #expect(!matches("https://a.com/*", "https://abcom/x"))
        #expect(matches("*greasyfork*", "https://greasyfork.org/scripts/1"))
    }

    @Test func codeIsLeftAsItIsWithoutGlobs() {
        #expect(BridgeUserScripts.fileText(code: "let a = 1;", includeGlobs: [], excludeGlobs: []) == "let a = 1;")
        let wrapped = BridgeUserScripts.fileText(code: "let a = 1;", includeGlobs: ["*a*"], excludeGlobs: [])
        #expect(wrapped.contains("let a = 1;") && wrapped.hasPrefix("if ("))
    }

    @Test func registeringChecksAsChromeDoes() {
        func error(_ scripts: [[String: Any]], existing: Set<String> = []) -> String? {
            do { try BridgeUserScripts.checkNew(scripts, existing: existing); return nil } catch { return (error as? BridgeError)?.message }
        }
        let good: [String: Any] = ["id": "a", "matches": ["<all_urls>"], "js": [["code": "1"]]]
        #expect(error([good]) == nil)
        #expect(error([good], existing: ["a"]) == "Duplicate script ID 'a'")
        #expect(error([good, good]) == "Duplicate script ID 'a'")
        #expect(error([["id": "_a", "matches": ["<all_urls>"], "js": [["code": "1"]]]]) == "Script's ID '_a' must not start with '_'")
        #expect(error([["id": "b", "matches": [String](), "js": [["code": "1"]]]]) == "Script with ID 'b' must specify at least one match.")
        #expect(error([["id": "c", "matches": ["<all_urls>"], "js": [["code": "1", "file": "x.js"]]]])?.contains("exactly one of 'code' or 'file'") == true)
        #expect(error([["id": "d", "matches": ["<all_urls>"], "js": [["code": "1"]], "worldId": "_w"]]) == "World IDs beginning with '_' are reserved.")
        #expect(error([["id": "e", "matches": ["<all_urls>"], "js": [["code": "1"]], "worldId": "w", "world": "MAIN"]]) != nil)
    }

    @Test func withBothManagersOnAScriptAddressGoesToTampermonkey() {
        let vm = ExtensionShims.violentmonkeyID, tm = ExtensionShims.tampermonkeyID
        let confirm = URL(string: "webkit-extension://\(vm)/confirm/index.html#abc")!
        func leaves(_ tab: String, on: Bool = true, from id: String = ExtensionShims.violentmonkeyID, url: URL? = nil) -> Bool {
            ExtensionShims.leavesInstallToTampermonkey(id, loading: url ?? confirm, tabURL: URL(string: tab), tampermonkeyOn: on)
        }
        #expect(leaves("https://greasyfork.org/scripts/1/code/x.user.js"))
        #expect(leaves("webkit-extension://\(tm)/ask.html?aid=1"))
        #expect(leaves("webkit-extension://\(ExtensionShims.tampermonkeyBetaID)/ask.html?aid=1"))
        // Only Violentmonkey: its page opens.
        #expect(!leaves("https://greasyfork.org/scripts/1/code/x.user.js", on: false))
        // Its own pages and other tabs, as from its dashboard's "Install from URL".
        #expect(!leaves("webkit-extension://\(vm)/options/index.html"))
        #expect(!leaves("https://example.com/"))
        // Anything else it opens, and any other extension.
        #expect(!leaves("https://a.test/x.user.js", url: URL(string: "webkit-extension://\(vm)/options/index.html")!))
        #expect(!leaves("https://a.test/x.user.js", from: tm, url: URL(string: "webkit-extension://\(tm)/ask.html")!))
    }

    // MARK: Worlds

    @Test func eachExtensionsScriptsHaveAWorldOfTheirOwn() {
        let tm = ExtensionShims.tampermonkeyID
        let name = BridgeUserScripts.worldName(extensionID: tm, worldID: nil)
        // Never WebKit's name for the extension's content-script world, which would give it the extension's API.
        #expect(!name.hasPrefix("WebExtension-"))
        #expect(name != BridgeUserScripts.worldName(extensionID: ExtensionShims.violentmonkeyID, worldID: nil))
        #expect(name != BridgeUserScripts.worldName(extensionID: tm, worldID: "a"))
        #expect(BridgeUserScripts.parseWorld(name)?.extensionID == tm)
        #expect(BridgeUserScripts.parseWorld(name)?.worldID == nil)
        #expect(BridgeUserScripts.parseWorld(BridgeUserScripts.worldName(extensionID: tm, worldID: "a/b"))?.worldID == "a/b")
        #expect(BridgeUserScripts.parseWorld("WebExtension-\(tm)") == nil)
        #expect(BridgeUserScripts.parseWorld(nil) == nil)
    }

    @Test func aWorldsSettingsAreItsOwnOrTheDefaults() {
        let worlds: [[String: Any]] = [
            ["csp": "script-src 'self' 'unsafe-inline' *", "messaging": true],
            ["worldId": "eval", "csp": "default-src 'self'; script-src 'self' 'unsafe-eval'"],
        ]
        // Tampermonkey's: messaging, inline scripts, no eval.
        #expect(BridgeUserScripts.settings(for: nil, in: worlds) == .init(messaging: true, allowsEval: false, allowsInline: true))
        #expect(BridgeUserScripts.settings(for: "eval", in: worlds) == .init(messaging: false, allowsEval: true, allowsInline: false))
        // A world with none of its own takes the default world's.
        #expect(BridgeUserScripts.settings(for: "other", in: worlds) == .init(messaging: true, allowsEval: false, allowsInline: true))
        // Never configured: Chrome's default, no messaging and no eval.
        #expect(BridgeUserScripts.settings(for: nil, in: []) == .init())
        #expect(BridgeUserScripts.allows("'unsafe-eval'", in: "default-src * 'unsafe-eval'"))
        #expect(!BridgeUserScripts.allows("'unsafe-eval'", in: "default-src * 'unsafe-eval'; script-src 'self'"))
    }

    @Test func chromesPatternsAsWebKitAndAsRegularExpressions() {
        #expect(BridgeUserScripts.webKitPatterns(["<all_urls>"]) == ["*://*/*", "file:///*"])
        #expect(BridgeUserScripts.webKitPatterns(["https://*.example.com/*", "*://a.test/x*"]) == ["https://*.example.com/*", "*://a.test/x*"])
        // A port or a query, which WebKit reads differently: the code checks those itself.
        #expect(BridgeUserScripts.webKitPatterns(["https://a.test:8080/*"]) == nil)
        #expect(BridgeUserScripts.webKitPatterns(["https://a.test/x?y=*"]) == nil)
        #expect(BridgeUserScripts.webKitPatterns(["https://a*.test/*"]) == nil)

        func test(_ pattern: String, _ url: String) -> Bool {
            guard let regex = BridgeUserScripts.patternRegex(pattern).flatMap({ try? NSRegularExpression(pattern: $0) }) else { return false }
            return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        #expect(test("*://*.example.com/*", "https://example.com/a"))
        #expect(test("*://*.example.com/*", "http://www.example.com:8080/a"))
        #expect(!test("*://*.example.com/*", "https://notexample.com/a"))
        #expect(!test("*://*.example.com/*", "https://example.com.evil.test/a"))
        #expect(test("https://a.test/x?y=*", "https://a.test/x?y=1"))
        #expect(test("<all_urls>", "file:///Users/a.html"))
        #expect(!test("https://*/*", "http://a.test/"))
        #expect(BridgeUserScripts.patternRegex("not a pattern") == nil)
    }

    // MARK: In a page

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Stands in for Zigzag where a world's messages go: answers what it's sent, and keeps it.
    private final class Echo: NSObject, WKScriptMessageHandlerWithReply {
        var heard: [[String: Any]] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            let body = message.body as? [String: Any] ?? [:]
            heard.append(body)
            replyHandler(["value": ["echo": body["message"] ?? NSNull()]], nil)
        }
    }

    private static let world = WKContentWorld.world(name: BridgeUserScripts.worldName(extensionID: "testextensionaaaaaaaaaaaaaaaaaaa", worldID: nil))

    private func page(_ settings: BridgeUserScripts.WorldSettings, scripts: [WKUserScript] = [], echo: Echo? = nil,
                      at address: String = "https://example.com/") async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: BridgeUserScripts.prelude(settings, extensionID: "testextensionaaaaaaaaaaaaaaaaaaa"), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world))
        scripts.forEach(controller.addUserScript)
        if let echo { controller.addScriptMessageHandler(echo, contentWorld: Self.world, name: BridgeUserScripts.worldHandler) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: address))
        }
        withExtendedLifetime(loading) {}
        return webView
    }

    private func run(_ body: String, in webView: WKWebView, world: WKContentWorld = world) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: world)
    }

    @Test func theWorldHasOnlyWhatChromesUserScriptWorldHas() async throws {
        let echo = Echo()
        let webView = await page(.init(messaging: true, allowsEval: true, allowsInline: false), echo: echo)
        // Messaging and the extension's ID, nothing else: no storage, no tabs, no way to the extension's own pages.
        let surface = try await run("""
            return [typeof chrome.runtime.sendMessage, typeof chrome.runtime.connect, typeof chrome.runtime.onMessage.addListener,
                    typeof chrome.storage, typeof chrome.tabs, typeof chrome.runtime.getURL, chrome.runtime.id,
                    typeof chrome.runtime.sendNativeMessage, typeof browser].join()
            """, in: webView) as? String
        #expect(surface == "function,function,function,undefined,undefined,undefined,testextensionaaaaaaaaaaaaaaaaaaa,undefined,undefined")
        // What a script sends goes to Zigzag, marked as its world's, and the answer comes back.
        let answer = try await run("return JSON.stringify(await chrome.runtime.sendMessage({ cmd: 'GM_xmlhttpRequest' }))", in: webView) as? String
        #expect(answer == #"{"echo":{"cmd":"GM_xmlhttpRequest"}}"#)
        #expect(echo.heard.last?["kind"] as? String == "send")
        #expect((echo.heard.last?["key"] as? String)?.isEmpty == false)
        // The page sees none of it.
        #expect(try await run("return typeof chrome === 'undefined' || chrome.runtime === undefined", in: webView, world: .page) as? Bool == true)
    }

    @Test func withoutMessagingTheWorldHasNoWayOut() async throws {
        let echo = Echo()
        let webView = await page(.init(), echo: echo)
        #expect(try await run("return typeof chrome", in: webView) as? String == "undefined")
        #expect(echo.heard.isEmpty)
    }

    @Test func messagesToTheTabReachOnlyItsOwnDocument() async throws {
        let echo = Echo()
        let webView = await page(.init(messaging: true), echo: echo)
        _ = try await run("chrome.runtime.onMessage.addListener((m, sender, reply) => { reply({ got: m.n, from: sender.id }); return true; })", in: webView)
        let key = try #require(echo.heard.first { $0["kind"] as? String == "listen" }?["key"] as? String)
        let receive = "return JSON.stringify(await globalThis.__zigzagUserScriptReceive(packet))"
        let answer = try await webView.callAsyncJavaScript(receive, arguments: ["packet": ["kind": "tab-message", "key": key, "message": ["n": 1], "sender": ["id": "x"]]],
                                                           in: nil, contentWorld: Self.world) as? String
        #expect(answer == #"{"value":{"got":1,"from":"x"}}"#)
        // Another document's key: not for this one.
        let other = try await webView.callAsyncJavaScript(receive, arguments: ["packet": ["kind": "tab-message", "key": "someone else", "message": ["n": 2]]],
                                                          in: nil, contentWorld: Self.world) as? String
        #expect(other == #"{"none":true}"#)
    }

    @Test func aPortCarriesBothWays() async throws {
        let echo = Echo()
        let webView = await page(.init(messaging: true), echo: echo)
        _ = try await run("""
            globalThis.port = chrome.runtime.connect({ name: 'tm' });
            globalThis.got = [];
            port.onMessage.addListener((m, p) => got.push(m.n + (p === port ? ' same' : ' other')));
            port.onDisconnect.addListener(() => got.push('gone ' + (chrome.runtime.lastError && chrome.runtime.lastError.message)));
            port.postMessage({ n: 1 });
            """, in: webView)
        let connect = try #require(echo.heard.first { $0["kind"] as? String == "connect" })
        #expect(connect["name"] as? String == "tm")
        #expect(echo.heard.contains { $0["kind"] as? String == "post" })
        let key = try #require(connect["key"] as? String), port = try #require(connect["port"])
        for packet: [String: Any] in [["kind": "port-message", "key": key, "port": port, "message": ["n": 7]],
                                      ["kind": "port-disconnect", "key": key, "port": port, "error": "closed"]] {
            _ = try await webView.callAsyncJavaScript("return await globalThis.__zigzagUserScriptReceive(packet)", arguments: ["packet": packet], in: nil, contentWorld: Self.world)
        }
        #expect(try await run("return got.join()", in: webView) as? String == "7 same,gone closed")
    }

    @Test func aWorldsCSPDecidesWhetherStringsRunAsCode() async throws {
        let strict = await page(.init(messaging: false, allowsEval: false, allowsInline: true))
        let refused = try await run("""
            const tries = [() => eval('1'), () => (0, eval)('1'), () => new Function('return 1')(), () => Function('return 1')(),
                           () => (function () {}).constructor('return 1')(), () => (async function () {}).constructor('return 1')];
            return tries.map((t) => { try { t(); return 'ran'; } catch (e) { return e.name; } }).join();
            """, in: strict) as? String
        #expect(refused == "EvalError,EvalError,EvalError,EvalError,EvalError,EvalError")
        // Functions are still functions, and an inline script the world's CSP allows runs in the world.
        #expect(try await run("return (() => {}) instanceof Function && typeof Function.prototype.call", in: strict) as? String == "function")
        #expect(try await run("return globalThis.__zigzagInlineScript('6 * 7')", in: strict) as? Int == 42)

        let open = await page(.init(messaging: false, allowsEval: true, allowsInline: false))
        #expect(try await run("return eval('6 * 7') + new Function('return 1')()", in: open) as? Int == 43)
        #expect(try await run("return typeof globalThis.__zigzagInlineScript", in: open) as? String == "undefined")
    }

    @Test func scriptsRunOnlyWhereTheirPatternsAndSiteAccessAllow() async throws {
        func script(_ flag: String, matches: [String], excludeMatches: [String] = [], globs: [String] = [],
                    access: (allowed: [String], denied: [String])? = nil) -> WKUserScript {
            BridgeUserScripts.userScript(code: "document.documentElement.dataset.\(flag) = 'yes';", matches: matches, excludeMatches: excludeMatches,
                                         includeGlobs: globs, excludeGlobs: [], access: access, injectionTime: .atDocumentEnd,
                                         mainFrameOnly: true, world: Self.world)
        }
        let scripts = [
            script("all", matches: ["<all_urls>"]),
            script("here", matches: ["https://example.com/*"]),
            script("elsewhere", matches: ["https://example.org/*"]),
            script("excluded", matches: ["<all_urls>"], excludeMatches: ["*://example.com/*"]),
            script("port", matches: ["https://example.com:*/*"]),
            script("globbed", matches: ["<all_urls>"], globs: ["*example.org*"]),
            script("allowedHere", matches: ["<all_urls>"], access: (["https://example.com/*"], [])),
            script("allowedElsewhere", matches: ["<all_urls>"], access: (["https://example.org/*"], [])),
            script("offHere", matches: ["<all_urls>"], access: (["<all_urls>"], ["*://example.com/*"])),
        ]
        let webView = await page(.init(), scripts: scripts)
        let ran = try await run("return Object.keys(document.documentElement.dataset).sort().join()", in: webView, world: .page) as? String
        #expect(ran == "all,allowedHere,here,port")
    }

    @Test func theRelayAndPreludeParse() {
        for source in [BridgeUserScripts.prelude(.init(messaging: true, allowsEval: false, allowsInline: true), extensionID: "x"),
                       "async function relay(op) {\n\(BridgeUserScripts.relayCall)\n}"] {
            let context = JSContext()!
            context.setObject(source, forKeyedSubscript: "__source" as NSString)
            context.evaluateScript("new Function(__source)")
            #expect(context.exception == nil)
        }
    }

    // MARK: At the extension

    /// The bridge in an extension's background, with WebKit's API stood in for: what its listeners hear.
    private func background(worker: Bool = false) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; }, clearTimeout = () => {};
        var console = { warn: () => {}, error: () => {}, log: () => {} };
        const event = () => { const l = []; return { l, addListener: (f) => l.push(f), removeListener: (f) => { const i = l.indexOf(f); if (i >= 0) l.splice(i, 1); }, hasListener: (f) => l.includes(f),
          fire: (...a) => l.map((f) => f(...a)) }; };
        var __native = [], __tabMessages = [];
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ permissions: ['userScripts', 'scripting'] }), onMessage: event(), onConnect: event(),
                     // A world whose listener kept the channel open and never answered: Zigzag never replies.
                     sendNativeMessage: (host, m) => { __native.push(m); return m.fn === 'tabMessage' && globalThis.__worlds === 'waiting' ? new Promise(() => {}) : Promise.resolve({ value: m.fn === 'tabMessage' ? globalThis.__worlds : null }); },
                     connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) },
          tabs: { sendMessage: (...a) => { __tabMessages.push(a); return globalThis.__scripts(); } },
          scripting: { getRegisteredContentScripts: () => Promise.resolve([]), unregisterContentScripts: () => Promise.resolve() },
        };
        """)
        if worker {
            context.evaluateScript("""
            var ServiceWorkerGlobalScope = class { static [Symbol.hasInstance](o) { return o === globalThis; } };
            var setInterval = () => 0, clearInterval = () => {};
            chrome.runtime.getBackgroundPage = () => Promise.resolve();
            chrome.runtime.getURL = (p) => 'webkit-extension://x/' + p;
            var location = { protocol: 'webkit-extension:', origin: 'webkit-extension://x', href: 'webkit-extension://x/sw.js' };
            """)
        }
        context.evaluateScript(ExtensionBridgeScript.source)
        // What runs after the bridge in a background, which wraps the same events again.
        if worker { context.evaluateScript(ExtensionBridgeScript.differences) }
        return context
    }

    @Test func whatRunsAfterTheBridgeStillHidesUserScripts() {
        let context = background(worker: true)
        context.evaluateScript("""
        var __own = [], __ownMessages = [], __user = 0;
        chrome.runtime.onConnect.addListener((p) => __own.push(p.name));
        chrome.runtime.onMessage.addListener((m) => { __ownMessages.push(m); });
        chrome.runtime.onUserScriptConnect.addListener(() => __user++);
        const raw = (name) => ({ name, sender: { id: 'x', tab: { id: 2 } }, onMessage: event(), onDisconnect: event(), postMessage() {}, disconnect() {} });
        chrome.runtime.onConnect.fire(raw('__zigzagUserScript' + JSON.stringify({ name: 'keepAlive', key: 'k', world: 'w' })));
        chrome.runtime.onConnect.fire(raw('plain'));
        chrome.runtime.onMessage.fire({ __zigzagUserScript: { kind: 'message', key: 'k', message: {} } }, { id: 'x', tab: { id: 2 }, url: 'https://a.test/' }, () => {});
        """)
        #expect(context.evaluateScript("__own.join()").toString() == "plain")
        #expect(context.evaluateScript("__user").toInt32() == 1)
        #expect(context.evaluateScript("__ownMessages.length").toInt32() == 0)
    }

    @Test func whatUserScriptsSendReachesOnlyTheUserScriptListeners() async throws {
        let context = background()
        context.evaluateScript("""
        var __own = [], __user = [], __replies = [];
        chrome.runtime.onMessage.addListener((m) => { __own.push(m); });
        chrome.runtime.onUserScriptMessage.addListener((m, sender, reply) => { __user.push(m.cmd + ' from tab ' + sender.tab.id); reply('done'); });
        const sender = { id: 'x', tab: { id: 4 }, frameId: 0, url: 'https://example.com/' };
        chrome.runtime.onMessage.fire({ __zigzagUserScript: { kind: 'message', key: 'k', world: 'w', message: { cmd: 'GM_setValue' } } }, sender, (v) => __replies.push(v));
        chrome.runtime.onMessage.fire({ cmd: 'fromContentScript' }, sender, () => {});
        // Another extension's, by WebKit's word: not a user script of this one.
        chrome.runtime.onMessage.fire({ __zigzagUserScript: { kind: 'message', key: 'k', message: { cmd: 'spoof' } } }, { id: 'other' }, () => {});
        """)
        #expect(context.evaluateScript("__user.join()").toString() == "GM_setValue from tab 4")
        #expect(context.evaluateScript("__replies.join()").toString() == "done")
        #expect(context.evaluateScript("__own.length === 1 && __own[0].cmd").toString() == "fromContentScript")
    }

    @Test func aUserScriptsPortReachesOnlyTheUserScriptListeners() {
        let context = background()
        context.evaluateScript("""
        var __own = [], __user = [], __heard = [];
        chrome.runtime.onConnect.addListener((p) => __own.push(p.name));
        chrome.runtime.onUserScriptConnect.addListener((p) => { __user.push(p.name + ' ' + p.sender.tab.id); p.onMessage.addListener((m, port) => __heard.push(m.n + (port === p ? ' same' : ' other'))); p.postMessage('hi'); });
        const raw = (name) => ({ name, sender: { id: 'x', tab: { id: 2 } }, onMessage: event(), onDisconnect: event(), sent: [], postMessage(m) { this.sent.push(m); }, disconnect() {} });
        var __port = raw('__zigzagUserScript' + JSON.stringify({ name: 'tm', key: 'k', world: 'w' }));
        chrome.runtime.onConnect.fire(__port);
        __port.onMessage.fire({ n: 1 }, __port);
        chrome.runtime.onConnect.fire(raw('plain'));
        """)
        #expect(context.evaluateScript("__user.join()").toString() == "tm 2")
        #expect(context.evaluateScript("__heard.join()").toString() == "1 same")
        #expect(context.evaluateScript("__port.sent.join()").toString() == "hi")
        #expect(context.evaluateScript("__own.join()").toString() == "plain")
    }

    @Test func aTabsMessageAlsoReachesItsUserScripts() async throws {
        let context = background()
        // No content script listens (Tampermonkey has none); a user-script world in the tab answers.
        context.evaluateScript("""
        globalThis.__scripts = () => Promise.reject(new Error('Could not establish connection. Receiving end does not exist.'));
        globalThis.__worlds = { reached: 1, answered: true, value: 'ran' };
        chrome.tabs.sendMessage(3, { method: 'executeScript' }, { frameId: 0 }).then((v) => { globalThis.__one = v; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__one").toString() == "ran")
        #expect(context.evaluateScript("JSON.stringify(__native.find((m) => m.fn === 'tabMessage').args[0])").toString() == #"{"tabId":3,"frameId":0}"#)
        // Nothing in the tab at all: WebKit's error, as before.
        context.evaluateScript("""
        globalThis.__worlds = { reached: 0 };
        chrome.tabs.sendMessage(3, { method: 'x' }).then(() => { globalThis.__two = 'answered'; }, (e) => { globalThis.__two = e.message; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__two").toString() == "Could not establish connection. Receiving end does not exist.")
        // Both answer: one of them is the answer, once.
        context.evaluateScript("""
        globalThis.__scripts = () => Promise.resolve('script');
        globalThis.__worlds = { reached: 1, answered: true, value: 'world' };
        globalThis.__three = [];
        chrome.tabs.sendMessage(3, {}, (v) => { globalThis.__three.push(v); });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(["script", "world"].contains(context.evaluateScript("__three.join()").toString()))
    }

    /// As in Chrome, the first answer from anywhere in the tab is the answer: a user script that keeps the channel
    /// open and never answers doesn't hold up a content script's answer, nor one that never answers a world's.
    @Test func aTabsMessageTakesTheFirstAnswer() async throws {
        let context = background()
        context.evaluateScript("""
        globalThis.__scripts = () => Promise.resolve('script');
        globalThis.__worlds = 'waiting';
        chrome.tabs.sendMessage(3, {}).then((v) => { globalThis.__one = v; });
        chrome.tabs.sendMessage(3, {}, (v) => { globalThis.__oneCallback = v; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__one").toString() == "script")
        #expect(context.evaluateScript("__oneCallback").toString() == "script")
        // A content script that keeps its channel open; a user script answers.
        context.evaluateScript("""
        globalThis.__scripts = () => new Promise(() => {});
        globalThis.__worlds = { reached: 1, answered: true, value: 'world' };
        chrome.tabs.sendMessage(3, {}).then((v) => { globalThis.__two = v; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__two").toString() == "world")
        // Heard everywhere, answered nowhere: undefined, not an error.
        context.evaluateScript("""
        globalThis.__scripts = () => Promise.resolve(undefined);
        globalThis.__worlds = { reached: 1 };
        chrome.tabs.sendMessage(3, {}).then((v) => { globalThis.__three = v === undefined ? 'undefined' : v; }, (e) => { globalThis.__three = e.message; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__three").toString() == "undefined")
        // No content script, but a user-script world heard it and didn't answer: undefined too.
        context.evaluateScript("""
        globalThis.__scripts = () => Promise.reject(new Error('Could not establish connection. Receiving end does not exist.'));
        globalThis.__worlds = { reached: 1 };
        chrome.tabs.sendMessage(3, {}).then((v) => { globalThis.__four = v === undefined ? 'undefined' : v; }, (e) => { globalThis.__four = e.message; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__four").toString() == "undefined")
        // Nothing listens anywhere: the error, on lastError for a callback.
        context.evaluateScript("""
        globalThis.__worlds = { reached: 0 };
        chrome.tabs.sendMessage(3, {}, (v) => { globalThis.__five = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none'; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__five").toString() == "Could not establish connection. Receiving end does not exist.")
        // A user-script world in the tab, still listening, while no content script is: the call waits on it, as
        // Chrome's does, rather than failing.
        context.evaluateScript("""
        globalThis.__worlds = 'waiting';
        globalThis.__six = 'pending';
        chrome.tabs.sendMessage(3, {}).then(() => { globalThis.__six = 'settled'; }, () => { globalThis.__six = 'settled'; });
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.evaluateScript("__six").toString() == "pending")
    }
}

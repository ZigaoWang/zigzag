import Foundation
import JavaScriptCore
import SQLite3
import Testing
import WebKit
@testable import Zigzag

extension ExtensionScriptTests {
    @Test func nativeCaptureEndingClosesTheExtensionsAudioStream() throws {
        let source = ExtensionBridgeScript.source
        let start = try #require(source.range(of: "  const captureStream = (id) => {"))
        let end = try #require(source.range(of: "  tabStream = (streamId)", range: start.upperBound..<source.endIndex))
        let context = JSContext()!
        context.evaluateScript("""
        var __stops = 0, __closed = 0, __disconnected = 0;
        var __track = { readyState: 'live', stop: () => { __stops++; __track.readyState = 'ended'; } };
        var AudioContext = function () {
          this.sampleRate = 48000;
          this.createMediaStreamDestination = () => ({ stream: { getAudioTracks: () => [__track] } });
          this.createScriptProcessor = () => ({ connect: () => {}, disconnect: () => __disconnected++ });
          this.close = () => { __closed++; return Promise.resolve(); };
        };
        var send = () => Promise.resolve(null), setTimeout = () => {};
        \(source[start.lowerBound..<end.lowerBound])
        captureStream('test');
        """)
        #expect(context.exception == nil)
        #expect(context.objectForKeyedSubscript("__stops")?.toInt32() == 1)
        #expect(context.objectForKeyedSubscript("__closed")?.toInt32() == 1)
        #expect(context.objectForKeyedSubscript("__disconnected")?.toInt32() == 1)
        #expect(context.evaluateScript("__track.readyState")?.toString() == "ended")
    }

    /// A shared capture of a streamed tab says when it hears the tab and when it pauses (#45): the extension's own
    /// sound goes through Zigzag only meanwhile, and back to the speakers when it pauses or the stream ends, so you
    /// never lose the tab's sound or hear it twice.
    @Test func sharedCaptureRoutesTheExtensionsSoundOnlyWhileItHears() throws {
        let source = ExtensionBridgeScript.source
        let relay = try #require(source.range(of: "  const hearing = new Set();"))
        let relayEnd = try #require(source.range(of: "  // Chrome hands a capture over only after", range: relay.upperBound..<source.endIndex))
        let start = try #require(source.range(of: "  const captureStream = (id) => {"))
        let end = try #require(source.range(of: "  tabStream = (streamId)", range: start.upperBound..<source.endIndex))
        let context = JSContext()!
        context.evaluateScript("""
        var __track = { readyState: 'live', stop: () => { __track.readyState = 'ended'; } };
        var AudioContext = function () {
          this.sampleRate = 48000;
          this.createMediaStreamDestination = () => ({ stream: { getAudioTracks: () => [__track] } });
          this.createScriptProcessor = () => ({ connect: () => {}, disconnect: () => {} });
          this.close = () => Promise.resolve();
        };
        var asked = new Set(), __timers = [];
        var __replies = [[{ hearing: true }], [[48000, '', 0, true]], [{ hearing: false }], [{ hearing: true }], null];
        var send = (namespace, fn) => Promise.resolve(fn === 'read' ? __replies.shift() : null);
        var setTimeout = (run) => { __timers.push(run); };
        \(source[relay.lowerBound..<relayEnd.lowerBound])
        \(source[start.lowerBound..<end.lowerBound])
        captureStream('test');
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("hearing.has('test')")?.toBool() == true)
        context.evaluateScript("__timers.shift()()")
        #expect(context.evaluateScript("hearing.has('test')")?.toBool() == true)
        // Paused: another tab has sound.
        context.evaluateScript("__timers.shift()()")
        #expect(context.evaluateScript("hearing.has('test')")?.toBool() == false)
        context.evaluateScript("__timers.shift()()")
        #expect(context.evaluateScript("hearing.has('test')")?.toBool() == true)
        // Ended: back to the speakers, for good.
        context.evaluateScript("__timers.shift()()")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("hearing.has('test')")?.toBool() == false)
        #expect(context.evaluateScript("__track.readyState")?.toString() == "ended")
    }

    @Test func streamedTabAudioIsRejectedBeforeRoutingOrMuting() throws {
        let url = try #require(Bundle.main.url(forResource: "tab-capture", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let context = JSContext()!
        context.evaluateScript("""
        var window = {}, __contexts = 0, __answer = '';
        var document = { querySelectorAll: () => [{ paused: false, currentSrc: 'blob:https://example.com/media' }] };
        var AudioContext = function () { __contexts++; };
        const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
        new AsyncFunction('tap', 'stop', \(Self.quoted(source)))('test', false)
          .then((answer) => { __answer = JSON.stringify(answer); }, (e) => { __answer = 'failed: ' + e.message; });
        """)
        #expect(context.exception == nil)
        // Answered as streamed, with nothing tapped, so Zigzag hears it through its guarded shared capture (#45).
        #expect(context.objectForKeyedSubscript("__answer")?.toString() == "{\"tapped\":0,\"streamed\":true}")
        #expect(context.objectForKeyedSubscript("__contexts")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__zigzagTap === undefined")?.toBool() == true)
    }

    @Test func stoppingTabCaptureRestoresSoundEvenAfterMediaBecomesStreamed() throws {
        let url = try #require(Bundle.main.url(forResource: "tab-capture", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let context = JSContext()!
        context.evaluateScript("""
        var __restored = 0, __disconnected = 0, __removed = 0, __result = -1;
        const source = { context: { destination: {} }, connect: () => __restored++ };
        var window = { __zigzagTap: { taps: new Map([['test', {
          processor: { disconnect: () => __disconnected++ }, mix: { disconnect: () => __disconnected++ },
          observer: { disconnect: () => __disconnected++ }, muted: [source], onPlay: () => {}
        }]]) } };
        var document = { querySelectorAll: () => [{ paused: false, currentSrc: 'blob:https://example.com/media' }],
                         removeEventListener: () => __removed++ };
        const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
        new AsyncFunction('tap', 'stop', \(Self.quoted(source)))('test', true).then((result) => { __result = result; });
        """)
        #expect(context.exception == nil)
        #expect(context.objectForKeyedSubscript("__restored")?.toInt32() == 1)
        #expect(context.objectForKeyedSubscript("__disconnected")?.toInt32() == 3)
        #expect(context.objectForKeyedSubscript("__removed")?.toInt32() == 1)
        #expect(context.objectForKeyedSubscript("__result")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__zigzagTap.taps.size")?.toInt32() == 0)
    }
}

/// Every script Zigzag puts in front of an extension's own code parses. One that doesn't stops every extension from
/// starting, so it's checked here rather than found by someone using one.
@MainActor
struct ExtensionScriptTests {
    /// Parses without running: a syntax error comes back as an exception.
    private func parses(_ source: String) -> String? {
        let context = JSContext()!
        context.setObject(source, forKeyedSubscript: "__source" as NSString)
        context.evaluateScript("new Function(__source)")
        return context.exception?.toString()
    }

    @Test func extensionPreludesParse() {
        #expect(!ExtensionBridgeScript.source.isEmpty)
        #expect(!ExtensionBridgeScript.surface.isEmpty)
        #expect(parses(ExtensionBridgeScript.source) == nil)
        #expect(parses(ExtensionShims.compatibility) == nil)
        #expect(parses(ExtensionBridgeScript.surface) == nil)
        #expect(!ExtensionBridgeScript.differences.isEmpty)
        #expect(parses(ExtensionBridgeScript.differences) == nil)
        // Firefox's two runtime members, appended after the surface in afterCompatibility.
        #expect(!ExtensionBridgeScript.firefoxPolyfill.isEmpty)
        #expect(parses(ExtensionBridgeScript.firefoxPolyfill) == nil)
        // Each extension's background prelude, as assembled, including those with fixes of their own.
        for id in ["anyextensionidaaaaaaaaaaaaaaaaaa", ExtensionStore.onePasswordID, ExtensionShims.motrixID] {
            let prelude = ExtensionShims.shim(for: id)?.backgroundPrelude ?? ""
            #expect(parses(prelude) == nil, "background prelude for \(id)")
        }
        for (id, source) in ExtensionShims.pagePreludes { #expect(parses(source) == nil, "page prelude for \(id)") }
    }

    @Test func surfaceCoversWhatExtensionsTripOn() throws {
        // Things that stopped real extensions as they started: each must be in Chrome's API list Zigzag fills from.
        let url = try #require(Bundle.main.url(forResource: "chrome-api", withExtension: "json"))
        let api = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        #expect((api["tabGroups"]?["functions"] as? [String])?.contains("query") == true)
        #expect((api["system.display"]?["functions"] as? [String])?.contains("getInfo") == true)
        #expect((api["runtime"]?["functions"] as? [String])?.contains("getContexts") == true)
        #expect((api["debugger"]?["events"] as? [String])?.contains("onEvent") == true)
        #expect(((api["runtime"]?["enums"] as? [String: [String: String]])?["ContextType"])?["OFFSCREEN_DOCUMENT"] == "OFFSCREEN_DOCUMENT")
    }

    /// A fake extension world for api-surface.js: WebKit's runtime, manifest and diagnostics channel, no API namespaces.
    private static func surfaceWorld(_ surface: String? = nil, version: Int? = nil,
                                     permissions: [String] = ["history"], setup: String = "") throws -> JSContext {
        let list = "[" + permissions.map { "'\($0)'" }.joined(separator: ", ") + "]"
        let manifest = version.map { "{ permissions: \(list), manifest_version: \($0) }" } ?? "{ permissions: \(list) }"
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        var __notes = [], __console = [];
        var console = {
          log: (m) => __console.push(String(m)), warn: (m) => __console.push(String(m)),
          error: (m) => __console.push(String((m && m.message) || m)),
        };
        var chrome = {
          runtime: {
            id: 'x',
            getManifest: () => (\(manifest)),
            sendNativeMessage: (host, message) => { __notes.push({ host, ...message }); return Promise.resolve(); },
          },
        };
        // WebKit's lastError is a property of the runtime object, as it is here: the surface must put this one back.
        var __nativeLastError = () => undefined;
        Object.defineProperty(chrome.runtime, 'lastError', { get: __nativeLastError, configurable: true, enumerable: true });
        var browser = chrome;
        """)
        context.evaluateScript(setup)
        let script = try #require(surface ?? (ExtensionBridgeScript.surface.isEmpty ? nil : ExtensionBridgeScript.surface),
                                  "the generated surface script")
        context.evaluateScript(script)
        #expect(context.evaluateScript("globalThis.__zigzagSurface === true")?.toBool() == true, "the surface started")
        return context
    }

    /// A fake background for bridge.js: WebKit's runtime, a bridge that refuses every call, no namespaces.
    private static func bridgeWorld(permissions: [String]) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        let list = "[" + permissions.map { "'\($0)'" }.joined(separator: ", ") + "]"
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        var __warned = [];
        var console = { log: () => {}, warn: (m) => __warned.push(String(m)), error: () => {} };
        const event = () => ({ addListener: () => {}, removeListener: () => {}, hasListener: () => false, hasListeners: () => false });
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ permissions: \(list) }),
                     sendNativeMessage: (host, message) => Promise.resolve({ error: message.ns + '.' + message.fn + ' could not be answered' }),
                     connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) },
        };
        var browser = chrome;
        """)
        context.evaluateScript(ExtensionBridgeScript.source)
        return context
    }

    /// A fake background for the compatibility prelude: WebKit's runtime and the namespaces it supplies; ones the layer adds whole are absent.
    private static func compatibilityWorld(permissions: [String]) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        let list = "[" + permissions.map { "'\($0)'" }.joined(separator: ", ") + "]"
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        var console = { log: () => {}, warn: () => {}, error: () => {} };
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ name: 'Test extension', version: '1.0', permissions: \(list) }),
                     sendNativeMessage: () => Promise.resolve() },
          action: {}, tabs: {}, i18n: {}, storage: {},
        };
        var browser = chrome;
        """)
        context.evaluateScript(ExtensionShims.compatibility)
        return context
    }

    @Test func aBridgedCallbackFailureKeepsMainsQuietShape() {
        let context = Self.bridgeWorld(permissions: ["history", "identity"])
        #expect(context.evaluateScript("typeof chrome.history.search")?.toString() == "function")
        context.evaluateScript("""
        var __called = 0, __during = null, __args = -1, __value = null, __before = chrome.runtime.lastError;
        chrome.history.search({ text: '' }, (...args) => {
          __called++;
          __during = chrome.runtime.lastError;
          __args = args.length;
          __value = args[0];
        });
        var __immediate = __called;
        var __returned = chrome.runtime.lastError;
        """)
        // The callback gets one undefined result and no lastError; the promise still rejects.
        #expect(context.evaluateScript("__immediate").toInt32() == 0)
        #expect(context.evaluateScript("__before === undefined && __returned === undefined").toBool())
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__called").toInt32() == 1)
        #expect(context.evaluateScript("__during === undefined").toBool())
        #expect(context.evaluateScript("__args").toInt32() == 1)
        #expect(context.evaluateScript("__value === undefined").toBool())
        #expect(context.evaluateScript("chrome.runtime.lastError === undefined").toBool())
        context.evaluateScript("""
        var __error = null, __seen = 'not checked';
        chrome.history.getVisits({ url: 'https://a.example/' }).then(
          () => { __error = 'resolved'; },
          (e) => { __error = e.message; __seen = chrome.runtime.lastError; });
        """)
        #expect(context.evaluateScript("__error").toString() == "history.getVisits could not be answered")
        #expect(context.evaluateScript("__seen === undefined && chrome.runtime.lastError === undefined").toBool())
        context.evaluateScript("""
        var __signIn = null, __signInArgs = -1, __signInValue = null;
        chrome.identity.getAuthToken({ interactive: false }, (...args) => {
          __signIn = chrome.runtime.lastError;
          __signInArgs = args.length;
          __signInValue = args[0];
        });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__signIn === undefined").toBool())
        #expect(context.evaluateScript("__signInArgs").toInt32() == 1)
        #expect(context.evaluateScript("__signInValue === undefined").toBool())
        // The failure is still logged.
        #expect(context.evaluateScript("__warned.length").toInt32() == 1)
    }

    @Test func bridgedCallsChromeAnswersWithAPromiseReturnOne() {
        // In Chrome MV3 these return a promise without a callback, and call the callback when given one.
        let context = Self.bridgeWorld(permissions: ["downloads", "downloads.open", "identity"])
        context.evaluateScript("""
        var __seen = [];
        var __open = chrome.downloads.open(1);
        __open.then(() => __seen.push('opened'), (e) => __seen.push('open refused'));
        chrome.identity.clearAllCachedAuthTokens(() => __seen.push('cleared'));
        chrome.identity.getAccounts((accounts) => __seen.push('accounts ' + accounts.length));
        chrome.identity.getAccounts().then((accounts) => __seen.push('promised ' + accounts.length));
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__open instanceof Promise").toBool())
        #expect(context.evaluateScript("__seen.sort().join()").toString() == "accounts 0,cleared,open refused,promised 0")
    }

    @Test func aCompatibilityLayerFailureKeepsMainsCallbackShape() {
        let context = Self.compatibilityWorld(permissions: ["debugger"])
        context.evaluateScript("""
        var __called = 0, __during = null, __args = -1, __value = null, __before = chrome.runtime.lastError;
        chrome.debugger.attach({ tabId: 1 }, (...args) => {
          __called++;
          __during = chrome.runtime.lastError;
          __args = args.length;
          __value = args[0];
        });
        var __returned = chrome.runtime.lastError;
        """)
        #expect(context.evaluateScript("__called").toInt32() == 0)
        #expect(context.evaluateScript("__before === undefined && __returned === undefined").toBool())
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__called").toInt32() == 1)
        #expect(context.evaluateScript("__during === undefined").toBool())
        #expect(context.evaluateScript("__args").toInt32() == 1)
        #expect(context.evaluateScript("__value === undefined").toBool())
        #expect(context.evaluateScript("chrome.runtime.lastError === undefined").toBool())
        // The promise form rejects with an Error and sets no lastError.
        context.evaluateScript("""
        var __promise = chrome.debugger.sendCommand({ tabId: 1 }, 'Runtime.enable', {}), __seen = 'not checked';
        __seen = chrome.runtime.lastError;
        __promise.then(() => { __error = 'resolved'; }, (e) => { __error = { isError: e instanceof Error, message: e.message }; });
        """)
        #expect(context.evaluateScript("__seen === undefined").toBool())
        #expect(context.evaluateScript("__error.isError").toBool())
        #expect(context.evaluateScript("__error.message").toString() == "Debugging pages isn't available in Zigzag")
        #expect(context.evaluateScript("chrome.runtime.lastError === undefined").toBool())
    }

    @Test func convertedCompatibilityMembersKeepMainsQuietAnswers() {
        let context = Self.compatibilityWorld(permissions: ["action", "tabs", "tabGroups", "sessions", "debugger", "fontSettings", "management", "i18n", "storage"])
        context.evaluateScript("""
        var __results = [], __promiseErrors = [], __promiseAnswers = 0;
        var __checks = [
          ['action.setBadgeTextColor', (cb) => chrome.action.setBadgeTextColor('red', cb)],
          ['action.getBadgeTextColor', (cb) => chrome.action.getBadgeTextColor(cb)],
          ['action.getUserSettings', (cb) => chrome.action.getUserSettings(cb)],
          ['tabs.ungroup', (cb) => chrome.tabs.ungroup(1, cb)],
          ['tabs.discard', (cb) => chrome.tabs.discard(1, cb)],
          ['tabs.highlight', (cb) => chrome.tabs.highlight({ windowId: 1, tabs: [1] }, cb)],
          ['tabGroups.query', (cb) => chrome.tabGroups.query({}, cb)],
          ['sessions.getRecentlyClosed', (cb) => chrome.sessions.getRecentlyClosed(cb)],
          ['sessions.getDevices', (cb) => chrome.sessions.getDevices(cb)],
          ['debugger.detach', (cb) => chrome.debugger.detach({ tabId: 1 }, cb)],
          ['debugger.getTargets', (cb) => chrome.debugger.getTargets(cb)],
          ['fontSettings.getFontList', (cb) => chrome.fontSettings.getFontList(cb)],
          ['fontSettings.getFont', (cb) => chrome.fontSettings.getFont({ genericFamily: 'standard' }, cb)],
          ['fontSettings.setFont', (cb) => chrome.fontSettings.setFont({ genericFamily: 'standard', fontId: 'x' }, cb)],
          ['fontSettings.clearFont', (cb) => chrome.fontSettings.clearFont({ genericFamily: 'standard' }, cb)],
          ['management.getAll', (cb) => chrome.management.getAll(cb)],
          ['i18n.detectLanguage', (cb) => chrome.i18n.detectLanguage('hello', cb)],
        ];
        for (const [name, call] of __checks) {
          call((...args) => __results.push(name + ' ' + (chrome.runtime.lastError ? 'failed' : 'quiet') + ' ' + args.length + ' ' + JSON.stringify(args[0])));
          try {
            const answer = call();
            if (!answer || typeof answer.then !== 'function') { __promiseErrors.push(name + ' returned no Promise'); continue; }
            answer.then(() => { __promiseAnswers++; }, () => { __promiseErrors.push(name); });
          } catch (e) { __promiseErrors.push(name + ' threw'); }
        }
        """)
        context.evaluateScript("__flush()")
        let expected = [
            "action.setBadgeTextColor quiet 1 undefined",
            "action.getBadgeTextColor quiet 1 [0,0,0,255]",
            "action.getUserSettings quiet 1 {\"isOnToolbar\":true}",
            "tabs.ungroup quiet 1 undefined", "tabs.discard quiet 1 undefined", "tabs.highlight quiet 1 undefined",
            "tabGroups.query quiet 1 []", "sessions.getRecentlyClosed quiet 1 []", "sessions.getDevices quiet 1 []",
            "debugger.detach quiet 1 undefined", "debugger.getTargets quiet 1 []",
            "fontSettings.getFontList quiet 1 []", "fontSettings.getFont quiet 1 {\"fontId\":\"\"}",
            "fontSettings.setFont quiet 1 undefined", "fontSettings.clearFont quiet 1 undefined",
            "management.getAll quiet 1 []",
            "i18n.detectLanguage quiet 1 {\"isReliable\":false,\"languages\":[]}",
        ]
        #expect(context.evaluateScript("__results.join()").toString() == expected.joined(separator: ","))
        #expect(context.evaluateScript("__promiseAnswers").toInt32() == Int32(expected.count))
        #expect(context.evaluateScript("__promiseErrors.join()").toString().isEmpty)
        // Existing emulations still answer: the manifest and empty managed storage.
        context.evaluateScript("""
        chrome.management.getSelf((info) => { globalThis.__self = info.name + ' ' + info.version + ' ' + info.enabled; });
        chrome.storage.managed.get((values) => { globalThis.__managed = JSON.stringify(values); });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__self").toString() == "Test extension 1.0 true")
        #expect(context.evaluateScript("__managed").toString() == "{}")
        #expect(context.evaluateScript("chrome.runtime.lastError === undefined").toBool())
    }

    /// WebKit can't disable single static rules; the call succeeds silently so backgrounds that treat failure as fatal keep running.
    @Test func unknownStaticRuleSwitchingKeepsMainsQuietAnswer() {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("var __background = true, __page = null, __backgroundPort = null; var __toBackground = () => {}, __connectToBackground = () => {};")
        context.evaluateScript(Self.fakeWorld)
        context.evaluateScript("chrome.declarativeNetRequest = { GUARANTEED_MINIMUM_STATIC_RULES: 30000 };")
        context.evaluateScript(ExtensionBridgeScript.differences)
        context.evaluateScript("""
        var __args = -1, __value = 'unset', __during = 'unset';
        chrome.declarativeNetRequest.updateStaticRules({ ruleIds: [1], enabled: false }, (...args) => {
          __args = args.length; __value = args[0]; __during = chrome.runtime.lastError;
        });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__args").toInt32() == 1)
        #expect(context.evaluateScript("__value === undefined").toBool())
        #expect(context.evaluateScript("__during === undefined").toBool())
        context.evaluateScript("var __resolved = false; chrome.declarativeNetRequest.updateStaticRules({ ruleIds: [1], enabled: false }).then(() => { __resolved = true; }, () => { __resolved = 'rejected'; });")
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__resolved").toBool())
    }

    @Test func anUnsupportedCallbackGetsNoResultAndNoZigzagLastError() throws {
        let context = try Self.surfaceWorld()
        #expect(context.evaluateScript("typeof chrome.history.search")?.toString() == "function")
        context.evaluateScript("""
        var __result = 'not called', __seen = null, __nativeStayed = false;
        var __before = chrome.runtime.lastError;
        chrome.history.search({ text: '' }, (...args) => {
          __seen = chrome.runtime.lastError;
          __nativeStayed = Object.getOwnPropertyDescriptor(chrome.runtime, 'lastError').get === __nativeLastError;
          __result = args.length;
        });
        var __returned = chrome.runtime.lastError;
        """)
        // The callback is asynchronous, with no result.
        #expect(context.evaluateScript("__result").toString() == "not called")
        #expect(context.evaluateScript("__before === undefined && __returned === undefined").toBool())
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__result").toInt32() == 0)
        #expect(context.evaluateScript("__seen === undefined").toBool())
        #expect(context.evaluateScript("__nativeStayed").toBool())
    }

    @Test func anUnsupportedCallbackThrowLeavesWebKitsLastErrorAlone() throws {
        let context = try Self.surfaceWorld()
        context.evaluateScript("""
        var __during = null, __ran = 0, __thrown = 0, __gone = null, __goneAfterThrow = null;
        var __native = Object.getOwnPropertyDescriptor(chrome.runtime, 'lastError').get;
        chrome.history.search({ text: '' }, () => {
          __ran++;
          __during = chrome.runtime.lastError;
          setTimeout(() => { __gone = chrome.runtime.lastError === undefined; }, 0);
        });
        chrome.history.getVisits({ url: 'https://a.example/' }, () => {
          __thrown++;
          setTimeout(() => { __goneAfterThrow = chrome.runtime.lastError === undefined; }, 0);
          throw new Error("the extension's own failure");
        });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__ran").toInt32() == 1)
        #expect(context.evaluateScript("__during === undefined").toBool())
        #expect(context.evaluateScript("__gone").toBool())
        #expect(context.evaluateScript("__thrown").toInt32() == 1)
        #expect(context.evaluateScript("__goneAfterThrow").toBool())
        #expect(context.evaluateScript("Object.getOwnPropertyDescriptor(chrome.runtime, 'lastError').get === __native").toBool())
        #expect(context.evaluateScript("__console.join()").toString().contains("the extension's own failure"))
    }

    @Test func anUnsupportedPromiseRejectsWithTheFeatureNameOnly() throws {
        let context = try Self.surfaceWorld()
        context.evaluateScript("""
        var __error = null, __during = 'not checked';
        var __promise = chrome.history.getVisits({ url: 'https://a.example/' });
        __during = chrome.runtime.lastError;
        __promise.then(
          () => { __error = 'resolved'; },
          (e) => { __error = { name: e.name, message: e.message, isError: e instanceof Error }; },
        );
        """)
        #expect(context.evaluateScript("__error.name").toString() == "Error")
        #expect(context.evaluateScript("__error.message").toString() == "chrome.history.getVisits isn't available in Zigzag")
        #expect(context.evaluateScript("__error.isError").toBool())
        // The promise form never sets lastError.
        #expect(context.evaluateScript("__during === undefined && chrome.runtime.lastError === undefined").toBool())
    }

    @Test func anUnsupportedCallIsNotedOnce() throws {
        let context = try Self.surfaceWorld()
        context.evaluateScript("""
        chrome.history.search({ text: 'a' }, () => {});
        chrome.history.search({ text: 'b' }, () => {});
        chrome.history.getVisits({ url: 'https://a.example/' });
        """)
        #expect(context.evaluateScript("__notes.length").toInt32() == 2)
        #expect(context.evaluateScript("__notes.map((n) => n.text).join()").toString() == "chrome.history.search,chrome.history.getVisits")
        #expect(context.evaluateScript("__notes[0].host + ' ' + __notes[0].where + ' ' + __notes[0].kind").toString()
                == "zigzag.diagnostics surface unavailable")
        // A third call to the same member isn't logged again.
        context.evaluateScript("chrome.history.search({ text: 'c' }).catch(() => {});")
        #expect(context.evaluateScript("__notes.length").toInt32() == 2)
    }

    @Test func unsupportedEventsStayInertWithoutLastError() throws {
        let context = try Self.surfaceWorld()
        context.evaluateScript("""
        var __fired = 0, __otherFired = 0, __rules = [];
        var __event = chrome.history.onVisited, __fresh = chrome.history.onVisitRemoved;
        var __listener = () => { __fired++; }, __other = () => { __otherFired++; };
        __event.addListener(__listener);
        __event.addListener(__other);
        __event.addListener('not a listener');
        __event.addRules([], (...args) => __rules.push({ name: 'add', count: args.length, value: JSON.stringify(args[0]), error: chrome.runtime.lastError }));
        __event.getRules([], (...args) => __rules.push({ name: 'get', count: args.length, value: JSON.stringify(args[0]), error: chrome.runtime.lastError }));
        __event.removeRules([], (...args) => __rules.push({ name: 'remove', count: args.length, value: args[0], error: chrome.runtime.lastError }));
        """)
        #expect(context.evaluateScript("__event !== __fresh").toBool())
        #expect(context.evaluateScript("__fresh.hasListeners()").toBool() == false)
        #expect(context.evaluateScript("__event.hasListeners()").toBool() == false)
        #expect(context.evaluateScript("__event.hasListener(__listener)").toBool() == false)
        #expect(context.evaluateScript("__event.hasListener(__other)").toBool() == false)
        #expect(context.evaluateScript("typeof __event.fire === 'undefined'").toBool())
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__fired + __otherFired").toInt32() == 0)
        #expect(context.evaluateScript("__rules.map((r) => r.name + ' ' + r.count + ' ' + r.value).join()").toString()
                == "add 1 [],get 1 [],remove 0 undefined")
        #expect(context.evaluateScript("__rules.every((r) => r.error === undefined)").toBool())
        context.evaluateScript("__event.removeListener(__listener); __event.removeListener(__other);")
        #expect(context.evaluateScript("__event.hasListeners()").toBool() == false)
    }

    @Test func storageAreasDoNotGainFunctionStubs() throws {
        let context = try Self.surfaceWorld(permissions: ["storage"], setup: """
        var __nativeStorageGet = () => Promise.resolve({ native: true });
        chrome.storage = { local: { get: __nativeStorageGet }, sync: {}, session: {}, managed: {} };
        """)
        let functions = ["get", "getKeys", "getBytesInUse", "set", "remove", "clear", "setAccessLevel"]
        for area in ["local", "sync", "session", "managed"] {
            for function in functions where !(area == "local" && function == "get") {
                #expect(context.evaluateScript("typeof chrome.storage.\(area).\(function)").toString() == "undefined",
                        "\(area).\(function)")
            }
            #expect(context.evaluateScript("typeof chrome.storage.\(area).onChanged.addListener").toString() == "function")
        }
        #expect(context.evaluateScript("chrome.storage.local.get === __nativeStorageGet").toBool())
        #expect(context.evaluateScript("chrome.storage.local.QUOTA_BYTES").toInt32() == 10_485_760)
        #expect(context.evaluateScript("chrome.storage.sync.MAX_ITEMS").toInt32() == 512)
    }

    @Test func storageCallsAnswerInTheOrderMade() {
        // WebKit answers a get before an earlier set; Strongbox reads its settings back right after saving them (#350).
        #expect(ExtensionBridgeScript.differences.contains(ExtensionBridgeScript.storageInOrder))
        #expect(ExtensionStore.contentScriptsFirst.contains(ExtensionBridgeScript.storageInOrder))
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var __flush = () => { const t = __timers.splice(0); t.forEach((f) => f()); };
        var __store = {}, __reads = 0;
        var chrome = { runtime: { id: 'x' }, storage: { sync: {
          set(items, callback) {
            const saved = new Promise((resolve) => setTimeout(() => { Object.assign(__store, items); resolve(); }));
            if (!callback) return saved;
            saved.then(() => callback());
          },
          get(keys, callback) {
            __reads++;
            const values = JSON.parse(JSON.stringify(__store));
            if (!callback) return Promise.resolve(values);
            Promise.resolve().then(() => callback(values));
          },
        } } };
        """)
        context.evaluateScript(ExtensionBridgeScript.storageInOrder)
        context.evaluateScript("""
        var __seen = [];
        chrome.storage.sync.get(null); chrome.storage.sync.get(null);
        var __readsAtOnce = __reads;
        chrome.storage.sync.set({ on: true });
        chrome.storage.sync.get(['on']).then((v) => __seen.push('promise ' + v.on));
        chrome.storage.sync.set({ off: true }, () => __seen.push('saved'));
        chrome.storage.sync.get(null, (v) => __seen.push('callback ' + v.off));
        """)
        for _ in 0..<6 { context.evaluateScript("__flush()") }
        #expect(context.evaluateScript("__readsAtOnce").toInt32() == 2)
        #expect(context.evaluateScript("__seen.join()").toString() == "promise true,saved,callback true")
        // Idle again: a read goes straight to WebKit.
        context.evaluateScript("var __before = __reads; chrome.storage.sync.get(null); var __after = __reads;")
        #expect(context.evaluateScript("__after - __before").toInt32() == 1)
    }

    /// A fake extension world for webkit-differences.js: the background or one of its pages in a tab, with ports
    /// that the test carries between the two.
    private static let fakeWorld = """
    var __timers = [];
    var setTimeout = (f) => { __timers.push(f); return __timers.length; };
    var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
    var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
    const event = () => { const l = []; return { addListener: (f) => l.push(f), removeListener: (f) => { const i = l.indexOf(f); if (i >= 0) l.splice(i, 1); }, hasListener: (f) => l.includes(f), fire: (...a) => l.map((f) => f(...a)) }; };
    var __port = (name, sender, send) => ({ name, sender, onMessage: event(), onDisconnect: event(), postMessage: (m) => send(JSON.stringify(m)), disconnect: () => {} });
    var location = { protocol: 'webkit-extension:', origin: 'webkit-extension://x', href: __background ? 'webkit-extension://x/background.js' : 'webkit-extension://x/frame.html', pathname: '/frame.html', search: '' };
    var __scriptCalls = [];
    var chrome = {
      runtime: { id: 'x', getURL: (p) => 'webkit-extension://x/' + p, getManifest: () => ({}), onMessage: event(), onConnect: event(),
                 sendMessage: () => Promise.resolve(), connect: (info) => { __page = __port(info.name, {}, __toBackground); __connectToBackground(info.name); return __page; } },
      extension: { getBackgroundPage: () => (__background ? globalThis : null) },
      tabs: { sendMessage: (tabId, message, options) => { __scriptCalls.push([tabId, message, options]); return Promise.resolve(__background && 'script answer'); } },
    };
    """

    @Test func motrixWorksOutChromesOriginForPairing() {
        // Motrix checks its own origin against the one the app sees on the WebSocket, which Zigzag sends as Chrome's.
        let id = ExtensionShims.motrixID
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var runtime = { id: '\(id)', getURL: (p) => 'webkit-extension://\(id)/' + String(p).replace(/^\\//, '') };
        var browser = { runtime };
        var chrome = browser;
        """)
        context.evaluateScript(ExtensionShims.motrixPrelude)
        // As its computeVerifiedOrigin does it: the root's protocol and host (no URL in a bare JSContext), which must
        // look like Chrome's.
        let origin = context.evaluateScript("(() => { const m = /^([a-z-]+:)\\/\\/([^/]+)\\/$/.exec(browser.runtime.getURL('/')); return m ? m[1] + '//' + m[2] : ''; })()").toString()
        #expect(origin == "chrome-extension://\(id)")
        #expect(context.evaluateScript("/^(chrome|moz)-extension:\\/\\/[^/]+$/.test('\(origin ?? "")')").toBool())
        // Every other address stays WebKit's: its files, and the root its pages' senders are checked against.
        #expect(context.evaluateScript("browser.runtime.getURL('')").toString() == "webkit-extension://\(id)/")
        #expect(context.evaluateScript("browser.runtime.getURL('popup.html')").toString() == "webkit-extension://\(id)/popup.html")
        #expect(context.evaluateScript("chrome.runtime.getURL('/')").toString() == "chrome-extension://\(id)/")
        // The fix is Motrix's alone, and the origin Zigzag's WebSocket sends is the one it now works out.
        #expect(ExtensionShims.shim(for: id)?.backgroundPrelude?.contains(ExtensionShims.motrixPrelude) == true)
        #expect(ExtensionShims.shim(for: "anyextensionidaaaaaaaaaaaaaaaaaa")?.backgroundPrelude?.contains(ExtensionShims.motrixPrelude) == false)
    }

    @Test func chromesNamedConstantsAreThere() {
        // Coupert's background reads chrome.tabs.TabStatus.LOADING first thing; WebKit has none of these.
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("var __background = true, __page = null, __backgroundPort = null; var __toBackground = () => {}, __connectToBackground = () => {};")
        context.evaluateScript(Self.fakeWorld)
        context.evaluateScript("chrome.windows = {};")
        context.evaluateScript(ExtensionBridgeScript.differences)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("chrome.tabs.TabStatus.LOADING")?.toString() == "loading")
        #expect(context.evaluateScript("chrome.tabs.TAB_ID_NONE")?.toInt32() == -1)
        #expect(context.evaluateScript("chrome.windows.WINDOW_ID_CURRENT")?.toInt32() == -2)
        #expect(context.evaluateScript("chrome.runtime.OnInstalledReason.INSTALL")?.toString() == "install")
    }

    /// Proton Pass replaces `chrome` and `browser` with dead stand-ins after start; WebKit delivers messages via `browser`, so its popup failed (#287). `browser` stays WebKit's; `chrome` may be replaced, as in Chrome.
    @Test func browserStaysWebKitsWhenAnExtensionReplacesIt() {
        let protonsGuard = """
        (() => {
          'use strict';
          for (const name of ['chrome', 'browser']) {
            globalThis[name] = new Proxy(globalThis[name], { get: (target, key) => (key === 'app' ? target.app : undefined), set: () => false });
          }
        })();
        """
        for script in [ExtensionBridgeScript.differences, ExtensionStore.contentScriptsFirst] {
            let context = JSContext()!
            context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
            context.evaluateScript("var __background = true, __page = null, __backgroundPort = null; var __toBackground = () => {}, __connectToBackground = () => {};")
            context.evaluateScript(Self.fakeWorld)
            // As WebKit defines it: an own property of the global, same object as `chrome`.
            context.evaluateScript("Object.defineProperty(globalThis, 'browser', { value: chrome, writable: true, configurable: true, enumerable: true }); var __native = browser;")
            context.evaluateScript(script)
            context.evaluateScript("__flush()")
            context.evaluateScript(protonsGuard)
            #expect(context.evaluateScript("browser === __native && browser.runtime.id === 'x'")?.toBool() == true)
            #expect(context.evaluateScript("chrome.runtime === undefined")?.toBool() == true)
            // Reassigning, strict or not, is a silent no-op.
            #expect(context.evaluateScript("(() => { 'use strict'; browser = {}; return browser === __native; })()")?.toBool() == true)
        }
        // Content scripts get it first, before the reconnect guard.
        #expect(ExtensionStore.contentScriptsFirst.hasPrefix(ExtensionBridgeScript.keepsBrowser))
    }

    @Test func idleCallbacksRunInExtensionPagesAndContentScripts() {
        // Proton Pass's content script stopped on requestIdleCallback, which WebKit doesn't have (#287).
        #expect(ExtensionStore.contentScriptsFirst.contains(ExtensionBridgeScript.idleCallbacks))
        #expect(ExtensionBridgeScript.differences.contains(ExtensionBridgeScript.idleCallbacks))
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = new Map(), __last = 0, document = {};
        var setTimeout = (f) => { __timers.set(++__last, f); return __last; };
        var clearTimeout = (id) => { __timers.delete(id); };
        var __flush = () => { const t = [...__timers.values()]; __timers.clear(); t.forEach((f) => f()); };
        """)
        context.evaluateScript(ExtensionBridgeScript.idleCallbacks)
        context.evaluateScript("""
        var __ran = [];
        requestIdleCallback((deadline) => __ran.push(['a', deadline.didTimeout, deadline.timeRemaining() > 0]));
        cancelIdleCallback(requestIdleCallback(() => __ran.push(['b'])));
        __flush();
        """)
        #expect(context.evaluateScript("JSON.stringify(__ran)")?.toString() == "[[\"a\",false,true]]")
        // A worker has none in Chrome either, and one WebKit has is left as it is.
        let worker = JSContext()!
        worker.evaluateScript(ExtensionBridgeScript.idleCallbacks)
        #expect(worker.evaluateScript("typeof requestIdleCallback")?.toString() == "undefined")
        let own = JSContext()!
        own.evaluateScript("var document = {}; var mine = () => 7; var requestIdleCallback = mine;")
        own.evaluateScript(ExtensionBridgeScript.idleCallbacks)
        #expect(own.evaluateScript("requestIdleCallback === mine")?.toBool() == true)
    }

    @Test func browserIsKeptOnceAnExtensionPageGetsIt() {
        // Extension pages may get the API after Zigzag's scripts run; it's kept before the page's timers fire.
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [], document = {};
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        """)
        context.evaluateScript(ExtensionBridgeScript.keepsBrowser)
        context.evaluateScript("Object.defineProperty(globalThis, 'browser', { value: { runtime: { id: 'x' } }, writable: true, configurable: true }); var __native = browser;")
        context.evaluateScript("__timers.push(() => { browser = undefined; }); for (let i = 0; i < 5 && __timers.length; i++) __timers.splice(0).forEach((f) => f());")
        #expect(context.evaluateScript("browser === __native")?.toBool() == true)
    }

    @Test func tabMessagesReachTheExtensionsOwnFramesInThatTab() throws {
        // WebKit sends tabs.sendMessage to content scripts only; Chrome also to the extension's own pages in that
        // tab, which is how 1Password tells its sign-in banner on a site to close.
        let background = JSContext()!, frame = JSContext()!
        for (context, isBackground) in [(background, true), (frame, false)] {
            context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
            context.evaluateScript("var __background = \(isBackground), __page = null, __backgroundPort = null;")
        }
        // What one side posts arrives at the other after the current script, as over a real port.
        final class Mail { var queue: [(JSContext, String)] = [] }
        let mail = Mail()
        let toBackground: @convention(block) (String) -> Void = { json in
            mail.queue.append((background, "__backgroundPort.onMessage.fire(JSON.parse(\(Self.quoted(json))))"))
        }
        let toFrame: @convention(block) (String) -> Void = { json in
            mail.queue.append((frame, "__page.onMessage.fire(JSON.parse(\(Self.quoted(json))))"))
        }
        let connect: @convention(block) (String) -> Void = { name in
            mail.queue.append((background, "__backgroundPort = __port(\(Self.quoted(name)), { tab: { id: 7 }, frameId: 3, url: 'webkit-extension://x/frame.html' }, __toFrame); chrome.runtime.onConnect.fire(__backgroundPort)"))
        }
        frame.setObject(toBackground, forKeyedSubscript: "__toBackground" as NSString)
        frame.setObject(connect, forKeyedSubscript: "__connectToBackground" as NSString)
        background.setObject(toFrame, forKeyedSubscript: "__toFrame" as NSString)
        for context in [background, frame] {
            context.evaluateScript(Self.fakeWorld)
            context.evaluateScript(ExtensionBridgeScript.differences)
        }
        func run(_ context: JSContext, _ script: String) {
            context.evaluateScript(script)
            for _ in 0..<50 {
                for side in [background, frame] { side.evaluateScript("__flush()") }
                if mail.queue.isEmpty { break }
                let (target, delivery) = mail.queue.removeFirst()
                target.evaluateScript(delivery)
            }
        }
        // The frame listens; the background's own onConnect listeners never see its port.
        run(background, "var __seen = 0; chrome.runtime.onConnect.addListener(() => __seen++);")
        run(frame, "var __got = []; chrome.runtime.onMessage.addListener((m, s, reply) => { __got.push(m.n); reply('frame answer ' + m.n); });")
        #expect(background.evaluateScript("__seen").toInt32() == 0)

        // To the whole tab: the frame hears it too, and its answer comes back.
        run(background, "chrome.tabs.sendMessage(7, { n: 1 }).then((v) => { globalThis.__one = v; });")
        #expect(frame.evaluateScript("__got.join()").toString() == "1")
        #expect(background.evaluateScript("__scriptCalls.length").toInt32() == 1)
        #expect(["frame answer 1", "script answer"].contains(background.evaluateScript("__one").toString()))

        // To the frame by its frameId, with a callback: only the frame, not the content scripts.
        run(background, "chrome.tabs.sendMessage(7, { n: 2 }, { frameId: 3 }, (v) => { globalThis.__two = v; });")
        #expect(background.evaluateScript("__two").toString() == "frame answer 2")
        #expect(background.evaluateScript("__scriptCalls.length").toInt32() == 1)

        // Another tab: left to WebKit exactly as before.
        run(background, "chrome.tabs.sendMessage(8, { n: 3 }).then((v) => { globalThis.__three = v; });")
        #expect(frame.evaluateScript("__got.join()").toString() == "1,2")
        #expect(background.evaluateScript("__three").toString() == "script answer")
    }

    /// A fake service worker background or extension page for the worker-messaging stand-in in webkit-differences.js.
    private static func workerWorld(worker: Bool, setup: String = "") -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        const event = () => { const l = []; return { addListener: (f) => l.push(f), removeListener: () => {}, hasListener: (f) => l.includes(f), fire: (...a) => l.map((f) => f(...a)) }; };
        var __port = (name, sender) => ({ name, sender, sent: [], onMessage: event(), onDisconnect: event(), postMessage(m) { this.sent.push(m); }, disconnect: () => {} });
        var location = { protocol: 'webkit-extension:', origin: 'webkit-extension://x', href: 'webkit-extension://x/' + (\(worker) ? 'sw.js' : 'popup.html'), pathname: '/', search: '' };
        var __asked = [], __ports = [];
        var chrome = {
          runtime: { id: 'x', getURL: (p) => 'webkit-extension://x/' + p, getManifest: () => ({}), onMessage: event(), onConnect: event(),
                     sendMessage: (m) => { __asked.push(m); return Promise.resolve(); },
                     connect: (info) => { const port = __port(info.name, {}); __ports.push(port); return port; } },
          offscreen: { createDocument: () => Promise.resolve() },
        };
        if (\(worker)) {
          var ServiceWorkerGlobalScope = class { static [Symbol.hasInstance](o) { return o === globalThis; } };
          var MessageEvent = class { constructor(type, init) { this.type = type; this.data = init.data; this.ports = init.ports || []; } };
          var __heard = [], __events = [];
          var dispatchEvent = (e) => { __heard.push(e.data); __events.push(e); };
          var __matchAll = async () => [], __get = async () => undefined;
          var clients = { matchAll: __matchAll, get: __get };
        } else {
          var ServiceWorker = class { constructor(url) { this.scriptURL = url; } postMessage(m) { __native.push(m); } };
          var __native = [];
          var navigator = { serviceWorker: { controller: null, dispatchEvent: () => true } };
        }
        """)
        context.evaluateScript(setup)
        context.evaluateScript(ExtensionBridgeScript.differences)
        return context
    }

    @Test func extensionPagesGetNoRuleSizingTheirIcons() {
        // WebKit sizes an <svg> as Chrome does; a `width: 100%` rule stretched Dashlane's icons (#340).
        let context = Self.workerWorld(worker: false, setup: """
        var __styles = [];
        var document = { createElement: () => ({ textContent: '' }), documentElement: { prepend: (node) => __styles.push(node.textContent) } };
        """)
        #expect(context.evaluateScript("__styles.length").toInt32() == 0)
        #expect(context.evaluateScript("__styles.join()").toString() == "")
    }

    private final class PageLoad: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Sizes Chrome gives these icons, measured in Chrome at the same width.
    @MainActor @Test func extensionPageIconsGetChromesSizes() async throws {
        let context = Self.workerWorld(worker: false, setup: """
        var __styles = [];
        var document = { createElement: () => ({ textContent: '' }), documentElement: { prepend: (node) => __styles.push(node.textContent) } };
        """)
        let injected = context.evaluateScript("__styles.join('\\n')").toString() ?? ""
        let shape = #"viewBox="0 0 24 24"><rect width="24" height="24"/></svg>"#
        let html = """
        <style>\(injected)</style><style>body { margin: 0; width: 320px; font: 14px sans-serif } .icon { height: 24px }</style>
        <div id="dashlane" style="display: flex; align-items: center"><svg class="icon" \(shape)<h2 style="margin: 0; font-size: 16px; line-height: 20px">Your logins on this site</h2></div>
        <div id="height-attribute" style="display: flex; align-items: center"><svg height="20" \(shape)<span>Label</span></div>
        <div id="em" style="display: flex; align-items: center"><svg style="height: 1em" \(shape)<span>Label</span></div>
        <div id="mute"><button style="display: flex; align-items: center; justify-content: center; width: 32px; height: 32px; padding: 0; border: 0"><svg \(shape)</button></div>
        <div id="padded"><button style="width: 32px; height: 32px; padding: 4px; border: 0"><svg \(shape)</button></div>
        """
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let loading = PageLoad()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: nil)
        }
        withExtendedLifetime(loading) {}
        let sizes = try #require(try await webView.evaluateJavaScript("""
        JSON.stringify(Object.fromEntries([...document.querySelectorAll('body > div')].map((row) => {
          const box = (node) => { const r = node.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; };
          return [row.id, { icon: box(row.querySelector('svg')), text: row.querySelector('h2') ? box(row.querySelector('h2')) : null }];
        })))
        """) as? String)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(sizes.utf8)) as? [String: [String: Any]])
        let icon = { (id: String) in rows[id]?["icon"] as? [Int] }
        // Dashlane's webcard (#340): the icon keeps its square and the heading stays on one line.
        #expect(icon("dashlane") == [24, 24])
        #expect((rows["dashlane"]?["text"] as? [Int])?.last == 20)
        #expect(icon("height-attribute") == [20, 20])
        #expect(icon("em") == [14, 14])
        // Sound Booster's mute button (#45): an icon with no size fills its button.
        #expect(icon("mute") == [32, 32])
        #expect(icon("padded") == [24, 24])
    }

    @Test func tabsComeWithTheirSiteIcons() {
        // WebKit's tabs have no favIconUrl; Sound Booster's popup drew an empty square for each (#45).
        let context = Self.workerWorld(worker: false, setup: """
        var __asks = [], __callbacks = 0;
        chrome.tabs = {
          query: (info, callback) => {
            if (callback) { __callbacks++; callback(undefined); return; }
            if (info && info.fail) return Promise.reject(new Error('No tab'));
            return Promise.resolve([{ id: 1, url: 'https://video.example/watch' }, { id: 2 }, { id: 3, url: 'https://own.example/', favIconUrl: 'https://own.example/i.png' }]);
          },
          get: (id) => Promise.resolve({ id, url: 'https://video.example/watch' }),
        };
        globalThis.__zigzagFavicons = (urls) => { __asks.push(urls); return Promise.resolve(urls.map((url) => (url === 'https://video.example/watch' ? 'data:image/png;base64,AA' : null))); };
        """)
        context.evaluateScript("""
        chrome.tabs.query({}).then((tabs) => { globalThis.__queried = tabs; });
        chrome.tabs.get(1, (tab) => { globalThis.__got = tab; });
        chrome.tabs.query({ fail: true }, (value) => { globalThis.__failed = String(value); });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__queried[0].favIconUrl").toString() == "data:image/png;base64,AA")
        // No address (no permission to read it): nothing asked, nothing added. One the tab has already is kept.
        #expect(context.evaluateScript("__queried[1].favIconUrl === undefined").toBool())
        #expect(context.evaluateScript("__queried[2].favIconUrl").toString() == "https://own.example/i.png")
        #expect(context.evaluateScript("JSON.stringify(__asks[0])").toString() == "[\"https://video.example/watch\"]")
        #expect(context.evaluateScript("__got.favIconUrl").toString() == "data:image/png;base64,AA")
        // Refused: asked again as the extension asked, so its callback hears WebKit's own answer and lastError.
        #expect(context.evaluateScript("__callbacks").toInt32() == 1)
        #expect(context.evaluateScript("__failed").toString() == "undefined")
    }

    @Test func currentTabOutsideATabIsUndefined() {
        // WebKit answers null in a side panel; Chrome undefined, which Claude's panel checks for exactly (#112).
        let context = Self.workerWorld(worker: false, setup: """
        var __current = null;
        chrome.tabs = { getCurrent: (callback) => { if (callback) { callback(__current); return; } return Promise.resolve(__current); } };
        globalThis.__zigzagFavicons = (urls) => Promise.resolve(urls.map(() => null));
        """)
        context.evaluateScript("""
        chrome.tabs.getCurrent().then((tab) => { globalThis.__promised = tab; });
        chrome.tabs.getCurrent((tab) => { globalThis.__called = [tab]; });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__promised === undefined && '__promised' in globalThis").toBool())
        #expect(context.evaluateScript("__called.length === 1 && __called[0] === undefined").toBool())
        // In a tab, the tab, as before.
        context.evaluateScript("__current = { id: 7, url: 'https://a.example/' }; chrome.tabs.getCurrent().then((tab) => { globalThis.__inTab = tab; });")
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__inTab.id").toInt32() == 7)
        // A popup: WebKit gives the tab in front, Chrome undefined; Proton Pass sized its popup to fit a tab (#287).
        context.evaluateScript("""
        chrome.extension = { getViews: (filter) => (filter && filter.type === 'popup' ? [globalThis] : []) };
        chrome.tabs.getCurrent().then((tab) => { globalThis.__inPopup = tab; });
        chrome.tabs.getCurrent((tab) => { globalThis.__popupCalled = [tab]; });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__inPopup === undefined && '__inPopup' in globalThis").toBool())
        #expect(context.evaluateScript("__popupCalled.length === 1 && __popupCalled[0] === undefined").toBool())
    }

    @Test func workerMessagingIsLeftAloneUntilAnExtensionUsesIt() {
        // A page: controller stays WebKit's, and only posts to the extension's own worker take the hidden port.
        let page = Self.workerWorld(worker: false)
        #expect(page.evaluateScript("navigator.serviceWorker.controller === null").toBool())
        page.evaluateScript("new ServiceWorker('https://site.example/sw.js').postMessage('theirs')")
        #expect(page.evaluateScript("__ports.length").toInt32() == 0)
        page.evaluateScript("new ServiceWorker('webkit-extension://x/zigzag-entry.js').postMessage('ours')")
        #expect(page.evaluateScript("__native.join()").toString() == "theirs")
        #expect(page.evaluateScript("__ports.length === 1 && __ports[0].sent[0].data").toString() == "ours")

        // A worker no page has posted to: WebKit's clients, untouched, asked nothing.
        let quiet = Self.workerWorld(worker: true)
        #expect(quiet.evaluateScript("clients.matchAll === __matchAll && clients.get === __get").toBool())
        quiet.evaluateScript("clients.matchAll().then((all) => { globalThis.__all = all.length; }); __flush();")
        #expect(quiet.evaluateScript("__all").toInt32() == 0)
        #expect(quiet.evaluateScript("__asked.length").toInt32() == 0)

        // Once a page connects, its messages arrive and the worker's clients include it.
        let used = Self.workerWorld(worker: true)
        used.evaluateScript("""
        var __page = __port('__zigzagWorkerClient', { url: 'webkit-extension://x/popup.html' });
        chrome.runtime.onConnect.fire(__page);
        __page.onMessage.fire({ kind: 'message', data: 'hello' });
        clients.matchAll().then((all) => { globalThis.__urls = all.map((c) => c.url).join(); }); __flush();
        """)
        #expect(used.evaluateScript("__heard.join()").toString() == "hello")
        #expect(used.evaluateScript("clients.matchAll !== __matchAll").toBool())
        used.evaluateScript("__flush()")
        #expect(used.evaluateScript("__urls").toString() == "webkit-extension://x/popup.html")

        // Making an offscreen page counts too: Violentmonkey looks for it among its clients right after.
        let offscreen = Self.workerWorld(worker: true)
        offscreen.evaluateScript("chrome.offscreen.createDocument({ url: 'offscreen.html' })")
        #expect(offscreen.evaluateScript("clients.matchAll !== __matchAll").toBool())
    }

    @Test func aLoadUnderWayRunsEachScriptOnceAndHoldsInstall() {
        // WebKit runs a worker's events between the scripts of one importScripts, and can message it before install.
        // Rabby loads its scripts on install or the first message: after a relaunch install came inside the message's
        // load, loaded them again, and the worker left installing before that load reached its main script.
        let worker = Self.workerWorld(worker: true, setup: """
        var __ran = [], __during = {}, __install = [], __held = [];
        globalThis.importScripts = function (...urls) {
          for (const url of urls) { __ran.push(url.split('/').pop()); if (__during[url]) __during[url](); }
        };
        var addEventListener = (type, listener) => { if (type === 'install') __install.push(listener); };
        var __installEvent = () => __install.forEach((listener) => listener({ waitUntil: (promise) => __held.push(promise) }));
        """)
        worker.evaluateScript("""
        let loaded = false, installed = false;
        const loadAll = () => { if (!loaded) { importScripts('/polyfill.js', '/background.js'); loaded = true; } };
        addEventListener('install', () => loadAll());
        // Install arrives as the polyfill finishes; the background loads a chunk of its own, which loads two more.
        __during['/polyfill.js'] = () => { __installEvent(); Promise.all(__held).then(() => { installed = true; }); };
        __during['/background.js'] = () => importScripts('chunk.js');
        __during['chunk.js'] = () => importScripts('/background.js', 'extra.js');
        loadAll();
        """)
        #expect(worker.evaluateScript("__ran.join()").toString() == "polyfill.js,background.js,chunk.js,extra.js")
        #expect(worker.evaluateScript("__held.length").toInt32() == 1)
        #expect(worker.evaluateScript("installed && loaded").toBool())
        // Once that load is over, a later one loads what it asks for again, as in Chrome, and install isn't held.
        worker.evaluateScript("importScripts('/polyfill.js'); __held = []; __installEvent();")
        #expect(worker.evaluateScript("__ran.join()").toString() == "polyfill.js,background.js,chunk.js,extra.js,polyfill.js")
        #expect(worker.evaluateScript("__held.length").toInt32() == 0)
    }

    @Test func webLocksKeepTheirRulesWithoutAskingWebKit() {
        // WebKit kills an extension's process when it asks for a lock, so nothing here may reach the real one.
        let page = Self.workerWorld(worker: false, setup: """
        var DOMException = class extends Error { constructor(message, name) { super(message); this.name = name; } };
        Object.setPrototypeOf(navigator, { locks: { request() { globalThis.__real = true; } } });
        var __order = [], __release = {}, __held = (key) => new Promise((resolve) => { __release[key] = resolve; });
        var __note = (key) => (lock) => { __order.push(key + ':' + (lock && lock.mode)); return __held(key); };
        """)
        page.evaluateScript("""
        navigator.locks.request('a', { mode: 'shared' }, __note('s1'));
        navigator.locks.request('a', { mode: 'shared' }, __note('s2'));
        navigator.locks.request('a', __note('x'));
        navigator.locks.request('a', { mode: 'shared' }, __note('s3'));
        navigator.locks.request('a', { ifAvailable: true }, (lock) => { __order.push('busy:' + lock); });
        navigator.locks.request('b', __note('other'));
        const cancel = { aborted: false, listeners: [], addEventListener(t, f) { this.listeners.push(f); }, removeEventListener() {} };
        navigator.locks.request('a', { signal: cancel }, __note('never')).catch((e) => __order.push(e.name));
        cancel.aborted = true; cancel.listeners.forEach((f) => f());
        navigator.locks.query().then((q) => { globalThis.__query = q.held.length + '/' + q.pending.length; });
        """)
        // Shared together, an exclusive waits for them, what's queued keeps its place, and another name is free.
        #expect(page.evaluateScript("[...__order].sort().join()").toString() == "AbortError,busy:null,other:exclusive,s1:shared,s2:shared")
        #expect(page.evaluateScript("__query").toString() == "3/2")
        page.evaluateScript("__release.s1(); __release.s2();")
        #expect(page.evaluateScript("__order[__order.length - 1]").toString() == "x:exclusive")
        page.evaluateScript("__release.x()")
        #expect(page.evaluateScript("__order[__order.length - 1]").toString() == "s3:shared")
        #expect(page.evaluateScript("globalThis.__real === undefined").toBool())
        // What the API refuses, it refuses here too.
        page.evaluateScript("""
        globalThis.__refused = [];
        for (const [name, options] of [['-x', {}], ['m', { mode: 'other' }], ['s', { steal: true }]]) navigator.locks.request(name, options, () => {}).catch((e) => __refused.push(e.name));
        const reason = new Error('mine'); navigator.locks.request('r', { signal: { aborted: true, reason } }, () => {}).catch((e) => __refused.push(e.message));
        """)
        #expect(page.evaluateScript("__refused.sort().join()").toString() == "NotSupportedError,NotSupportedError,TypeError,mine")
    }

    @Test func registeredScriptsLoseFilePatternsOnlyIfWebKitRefusesThem() {
        // One file: pattern and WebKit refuses the whole registration: Rabby's provider reached no site.
        let worker = Self.workerWorld(worker: true, setup: """
        var __calls = [], __acceptsFiles = false, __notes = [];
        chrome.runtime.sendNativeMessage = (host, message) => { __notes.push(message.text); return Promise.resolve(); };
        chrome.scripting = {
          registerContentScripts: (scripts, callback) => {
            __calls.push(scripts);
            const refused = !__acceptsFiles && scripts.some((s) => (s.matches || []).some((m) => m.startsWith('file:')));
            const answer = scripts[0].id === 'broken' ? Promise.reject(new Error('Script with ID already exists'))
              : refused ? Promise.reject(new Error("Script has an invalid match pattern 'file://*/*'.")) : Promise.resolve();
            if (!callback) return answer;
            answer.then(() => callback(), () => callback());
          },
        };
        var __script = (id) => ({ id, js: ['p.js'], world: 'MAIN', matches: ['file://*/*', 'http://*/*', 'https://*/*'] });
        """)
        worker.evaluateScript("chrome.scripting.registerContentScripts([__script('p'), { id: 'local', matches: ['file:///*'] }])")
        #expect(worker.evaluateScript("__calls.length").toInt32() == 2)
        #expect(worker.evaluateScript("__calls[1].length").toInt32() == 1)
        #expect(worker.evaluateScript("__calls[1][0].matches.join()").toString() == "http://*/*,https://*/*")
        #expect(worker.evaluateScript("__calls[1][0].world").toString() == "MAIN")
        #expect(worker.evaluateScript("__notes.join('|')").toString() == "registerContentScripts: p registered without file: patterns; skipped local, whose matches were all file:")
        // A WebKit that takes them keeps them, and any other refusal stays the extension's to hear about.
        worker.evaluateScript("__calls = []; __acceptsFiles = true; chrome.scripting.registerContentScripts([__script('p')])")
        #expect(worker.evaluateScript("__calls.length + ' ' + __calls[0][0].matches[0]").toString() == "1 file://*/*")
        // Asked again without them if it fails for any reason, and a failure either way is the extension's to hear.
        worker.evaluateScript("__calls = []; __acceptsFiles = false; chrome.scripting.registerContentScripts([__script('broken')]).catch((e) => { globalThis.__error = e.message; })")
        #expect(worker.evaluateScript("__calls.length").toInt32() == 2)
        #expect(worker.evaluateScript("__error").toString() == "Script with ID already exists")
        // Only local files: nothing else to register, so the refusal stands.
        worker.evaluateScript("__calls = []; __error = ''; chrome.scripting.registerContentScripts([{ id: 'local', matches: ['file:///*'] }]).catch((e) => { globalThis.__error = e.message; })")
        #expect(worker.evaluateScript("__calls.length").toInt32() == 1)
        #expect(worker.evaluateScript("__error").toString().contains("match pattern"))
        // A callback hears once, after the retry.
        worker.evaluateScript("__calls = []; globalThis.__heard = 0; chrome.scripting.registerContentScripts([__script('p')], () => { globalThis.__heard += 1; })")
        #expect(worker.evaluateScript("__calls.length + ' ' + __calls[1][0].matches.length + ' ' + __heard").toString() == "2 2 1")
        #expect(worker.evaluateScript("chrome.runtime.lastError === undefined").toBool())
    }

    @Test func aRegistrationCallbackHearsTheFirstFailure() {
        let worker = Self.workerWorld(worker: true, setup: """
        var __calls = [];
        chrome.runtime.sendNativeMessage = () => Promise.resolve();
        chrome.scripting = {
          registerContentScripts: (scripts, callback) => {
            __calls.push(scripts);
            const files = scripts.some((s) => (s.matches || []).some((m) => m.startsWith('file:')));
            const answer = Promise.reject(new Error(files ? "Script has an invalid match pattern 'file://*/*'." : 'Script with ID already exists'));
            if (!callback) return answer;
            answer.catch(() => callback());
          },
        };
        var __heard = [];
        var __listen = () => { __heard.push(chrome.runtime.lastError && chrome.runtime.lastError.message); };
        """)
        // Both tries refused: the callback hears why the first was, as the promise does.
        worker.evaluateScript("chrome.scripting.registerContentScripts([{ id: 'p', matches: ['file://*/*', 'https://*/*'] }], __listen)")
        #expect(worker.evaluateScript("__calls.length").toInt32() == 2)
        #expect(worker.evaluateScript("__heard.join()").toString() == "Script has an invalid match pattern 'file://*/*'.")
        // Only local files: refused straight away, never asked a second time.
        worker.evaluateScript("__calls = []; __heard = []; chrome.scripting.registerContentScripts([{ id: 'local', matches: ['file:///*'] }], __listen)")
        #expect(worker.evaluateScript("__calls.length").toInt32() == 1)
        #expect(worker.evaluateScript("__heard.join()").toString() == "Script has an invalid match pattern 'file://*/*'.")
        // The error is there only while the callback runs.
        #expect(worker.evaluateScript("chrome.runtime.lastError === undefined").toBool())
    }

    @Test func anUpdateSaysWhichScriptsItSkipped() {
        let worker = Self.workerWorld(worker: true, setup: """
        var __calls = [], __notes = [];
        chrome.runtime.sendNativeMessage = (host, message) => { __notes.push(message.text); return Promise.resolve(); };
        chrome.scripting = {
          registerContentScripts: () => Promise.resolve(),
          updateContentScripts: (scripts) => {
            __calls.push(scripts);
            const files = scripts.some((s) => (s.matches || []).some((m) => m.startsWith('file:')));
            return files ? Promise.reject(new Error("Script has an invalid match pattern 'file:///*'.")) : Promise.resolve();
          },
        };
        """)
        // A script whose matches were all file: is left out of the update, and the log says so.
        worker.evaluateScript("chrome.scripting.updateContentScripts([{ id: 'local', matches: ['file:///*'] }, { id: 'p', matches: ['https://*/*'] }])")
        #expect(worker.evaluateScript("__calls.length + ' ' + __calls[1].map((s) => s.id).join()").toString() == "2 p")
        #expect(worker.evaluateScript("__notes.join('|')").toString() == "updateContentScripts: skipped local, whose matches were all file:")
        // One that keeps other patterns is updated without its file: ones.
        worker.evaluateScript("__calls = []; __notes = []; chrome.scripting.updateContentScripts([{ id: 'p', matches: ['file:///*', 'https://*/*'] }])")
        #expect(worker.evaluateScript("__calls[1][0].matches.join()").toString() == "https://*/*")
        #expect(worker.evaluateScript("__notes.join('|')").toString() == "updateContentScripts: p updated without file: patterns")
    }

    @Test func scriptsNamingLocksBringTheStandIn() throws {
        // A dedicated worker gets no prelude: its own file has to carry it, or a lock request kills the process.
        let worker = try #require(ExtensionStore.filled("navigator.locks.request('a', () => {});"))
        #expect(worker.contains(ExtensionBridgeScript.webLocksMark))
        #expect(worker.hasSuffix("navigator.locks.request('a', () => {});"))
        let strict = try #require(ExtensionStore.filled("'use strict';navigator.locks.query();"))
        #expect(strict.hasPrefix("'use strict';"))
        #expect(ExtensionStore.filled("const a = 1;") == nil)
        #expect(ExtensionStore.filled(worker) == nil)
    }

    @Test func wasmPolicySurvivesWebKitDroppingItsKeyword() throws {
        // Bitwarden: script-src limits move to script-src-elem; attributes and workers keep their own.
        let bitwarden = "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"
        #expect(ExtensionStore.wasmCompatiblePolicy(bitwarden)
                == "script-src-elem 'self'; script-src-attr 'none'; worker-src 'self'; object-src 'self'")
        // Directives the extension set stay unchanged.
        #expect(ExtensionStore.wasmCompatiblePolicy("script-src 'self' 'WASM-UNSAFE-EVAL'; worker-src blob:;")
                == "script-src-elem 'self'; script-src-attr 'none'; worker-src blob:")
        // No wasm requested, or a default-src fallback: unchanged.
        #expect(ExtensionStore.wasmCompatiblePolicy("script-src 'self'; object-src 'self'") == nil)
        #expect(ExtensionStore.wasmCompatiblePolicy("default-src 'self'; script-src 'self' 'wasm-unsafe-eval'") == nil)

        let manifest: [String: Any] = ["manifest_version": 3, "content_security_policy": ["extension_pages": bitwarden, "sandbox": "sandbox allow-scripts; script-src 'self'"]]
        let policies = try #require(ExtensionStore.allowingWasm(manifest)["content_security_policy"] as? [String: String])
        #expect(policies["extension_pages"]?.hasPrefix("script-src-elem 'self';") == true)
        #expect(policies["sandbox"] == "sandbox allow-scripts; script-src 'self'")
        // MV2 isn't restricted.
        let v2: [String: Any] = ["manifest_version": 2, "content_security_policy": ["extension_pages": bitwarden]]
        #expect((ExtensionStore.allowingWasm(v2)["content_security_policy"] as? [String: String])?["extension_pages"] == bitwarden)
    }

    @Test func theLockStandInStaysOffWebsitesAndInstallsOnce() {
        let run = { (origin: String) -> JSContext in
            let context = JSContext()!
            context.evaluateScript("var location = { protocol: '\(origin)' }; var navigator = Object.create({ locks: { real: true } });")
            context.evaluateScript(ExtensionBridgeScript.webLocks)
            return context
        }
        #expect(run("https:").evaluateScript("navigator.locks.real === true").toBool())
        let page = run("webkit-extension:")
        #expect(page.evaluateScript("navigator.locks.real === undefined").toBool())
        page.evaluateScript("globalThis.__first = navigator.locks")
        page.evaluateScript(ExtensionBridgeScript.webLocks)
        #expect(page.evaluateScript("navigator.locks === __first").toBool())
    }

    @Test func aPageReachedOverThePortRefusesAPortHandedOver() {
        // Tampermonkey hands its offscreen page a MessageChannel port and waits on it: refused at once, so it goes on.
        let worker = Self.workerWorld(worker: true)
        worker.evaluateScript("""
        var DOMException = class extends Error { constructor(message, name) { super(message); this.name = name; } };
        var __page = __port('__zigzagWorkerClient', { url: 'webkit-extension://x/offscreen.html' });
        chrome.runtime.onConnect.fire(__page);
        clients.matchAll({ includeUncontrolled: true }).then((all) => { globalThis.__client = all[0]; }); __flush();
        """)
        worker.evaluateScript("__flush()")
        let refused = worker.evaluateScript("try { __client.postMessage({ action: 'objectURL' }, [{}]); 'sent' } catch (e) { e.name }")
        #expect(refused?.toString() == "DataCloneError")
        worker.evaluateScript("__client.postMessage('plain', []); __client.postMessage('also')")
        #expect(worker.evaluateScript("__page.sent.map((m) => m.data).join()").toString() == "plain,also")
    }

    /// What a page and its worker have of the web beyond what JavaScriptCore has: ports and base64.
    private static let messagingWorld = """
    var __b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var btoa = (s) => { let o = ''; for (let i = 0; i < s.length; i += 3) { const n = (s.charCodeAt(i) << 16) | ((s.charCodeAt(i + 1) || 0) << 8) | (s.charCodeAt(i + 2) || 0);
      o += __b64[n >> 18 & 63] + __b64[n >> 12 & 63] + (i + 1 < s.length ? __b64[n >> 6 & 63] : '=') + (i + 2 < s.length ? __b64[n & 63] : '='); } return o; };
    var atob = (s) => { let o = '', bits = 0, n = 0; for (const c of s.replace(/=+$/, '')) { n = (n << 6) | __b64.indexOf(c); bits += 6; if (bits >= 8) { bits -= 8; o += String.fromCharCode((n >> bits) & 255); } } return o; };
    var MessagePort = class { constructor() { this.sent = []; this.closed = false; } postMessage(m) { this.sent.push(m); } close() { this.closed = true; } };
    var MessageChannel = class { constructor() {
      const a = new MessagePort(), b = new MessagePort();
      a.postMessage = (m) => { a.sent.push(m); if (b.onmessage) b.onmessage({ data: m }); };
      b.postMessage = (m) => { b.sent.push(m); if (a.onmessage) a.onmessage({ data: m }); };
      this.port1 = a; this.port2 = b;
    } };
    """

    @Test func onlyTheExtensionsOwnPagesReachItsWorkerAsAPage() {
        // A content script runs on a site, and its port says so: it can't stand for one of the extension's pages and
        // post to the worker as if it were one.
        let worker = Self.workerWorld(worker: true)
        worker.evaluateScript("""
        var __script = __port('__zigzagWorkerClient', { url: 'https://evil.example/', tab: { id: 3 }, frameId: 0 });
        __script.disconnect = () => { __script.dropped = true; };
        chrome.runtime.onConnect.fire(__script);
        __script.onMessage.fire({ kind: 'message', data: { cmd: 'GetData' }, ports: [] });
        var __lookalike = __port('__zigzagWorkerClient', { url: 'webkit-extension://xy/popup.html', origin: 'webkit-extension://xy' });
        __lookalike.disconnect = () => { __lookalike.dropped = true; };
        chrome.runtime.onConnect.fire(__lookalike);
        __lookalike.onMessage.fire({ kind: 'message', data: { cmd: 'GetData' }, ports: [] });
        """)
        #expect(worker.evaluateScript("__heard.length").toInt32() == 0)
        #expect(worker.evaluateScript("__script.dropped === true && __lookalike.dropped === true").toBool())
        // Its own page, in a tab or a frame on a site, still does.
        worker.evaluateScript("""
        var __own = __port('__zigzagWorkerClient', { url: 'webkit-extension://x/options.html', origin: 'webkit-extension://x', tab: { id: 3 } });
        chrome.runtime.onConnect.fire(__own);
        __own.onMessage.fire({ kind: 'message', data: { cmd: 'GetData' }, ports: [] });
        """)
        #expect(worker.evaluateScript("__heard.length === 1 && __heard[0].cmd").toString() == "GetData")
    }

    @Test func aPortHandedToTheWorkerIsRelayedBothWays() {
        // Kondo's site hands its extension a MessageChannel port, which the extension's frame passes on to its worker
        // and every request then goes over. WebKit's way to the worker is a runtime port, which carries JSON only.
        let page = Self.workerWorld(worker: false, setup: Self.messagingWorld)
        page.evaluateScript("""
        var __end = new MessagePort();
        new ServiceWorker('webkit-extension://x/zigzag-entry.js').postMessage({ source: 'kondo-iframe' }, [__end]);
        """)
        #expect(page.evaluateScript("JSON.stringify(__ports[0].sent[0])").toString() == #"{"kind":"message","data":{"source":"kondo-iframe"},"ports":[1]}"#)
        // What the site posts on its end goes to the worker, bytes as bytes; what comes back reaches the site.
        page.evaluateScript("__end.onmessage({ data: { id: 1, file: new Uint8Array([1, 2, 255]) } })")
        #expect(page.evaluateScript("JSON.stringify(__ports[0].sent[1])").toString()
                == #"{"kind":"port","id":1,"data":{"id":1,"file":{"__zigzagBytes":"AQL/","type":"Uint8Array"}}}"#)
        page.evaluateScript("__ports[0].onMessage.fire({ kind: 'port', id: 1, data: { id: 1, response: { body: { __zigzagBytes: 'AQL/', type: 'Uint8Array' } } } })")
        #expect(page.evaluateScript("__end.sent[0].id === 1 && __end.sent[0].response.body instanceof Uint8Array && __end.sent[0].response.body.join()").toString() == "1,2,255")
        // The worker went away: so does what was handed to it.
        page.evaluateScript("__ports[0].onDisconnect.fire()")
        #expect(page.evaluateScript("__end.closed").toBool())

        // At the worker: the message comes with a port of its own, and the two are joined over the runtime port.
        let worker = Self.workerWorld(worker: true, setup: Self.messagingWorld)
        worker.evaluateScript("""
        var __page = __port('__zigzagWorkerClient', { url: 'webkit-extension://x/ext.html' });
        chrome.runtime.onConnect.fire(__page);
        __page.onMessage.fire({ kind: 'message', data: { source: 'kondo-iframe' }, ports: [1] });
        var __got = null;
        __events[0].ports[0].onmessage = (e) => { __got = e.data; __events[0].ports[0].postMessage({ id: e.data.id, response: 'ok' }); };
        __page.onMessage.fire({ kind: 'port', id: 1, data: { id: 7 } });
        """)
        #expect(worker.evaluateScript("__heard[0].source").toString() == "kondo-iframe")
        #expect(worker.evaluateScript("__got.id").toInt32() == 7)
        #expect(worker.evaluateScript("JSON.stringify(__page.sent[__page.sent.length - 1])").toString() == #"{"kind":"port","id":1,"data":{"id":7,"response":"ok"}}"#)
    }

    @Test func bytesFromASiteComeBackOnlyAsBytes() {
        // What a site posts on its port reaches the worker: its `type` never names another constructor to call.
        let worker = Self.workerWorld(worker: true, setup: Self.messagingWorld + """
        var __made = 0;
        var Spy = class { constructor() { __made++; } };
        """)
        worker.evaluateScript("""
        var __page = __port('__zigzagWorkerClient', { url: 'webkit-extension://x/ext.html' });
        chrome.runtime.onConnect.fire(__page);
        __page.onMessage.fire({ kind: 'message', ports: [], data: {
          spy: { __zigzagBytes: 'AQL/', type: 'Spy' }, odd: { __zigzagBytes: 'AQL/', type: 'Float64Array' },
          broken: { __zigzagBytes: '%%%', type: 'Uint8Array' }, bytes: { __zigzagBytes: 'AQL/', type: 'Uint8Array' } } });
        """)
        #expect(worker.evaluateScript("__made").toInt32() == 0)
        #expect(worker.evaluateScript("__heard[0].spy instanceof ArrayBuffer && __heard[0].odd instanceof ArrayBuffer").toBool())
        #expect(worker.evaluateScript("__heard[0].bytes instanceof Uint8Array && __heard[0].bytes.join()").toString() == "1,2,255")
    }

    @Test func aPageWithNoWorkerOfItsOwnIsGivenOne() {
        // WebKit gives an extension's page in a tab, or in a frame on a site (Kondo's), no worker: ready never
        // settles. Chrome gives every page of the extension its worker.
        let setup = """
        var ServiceWorkerRegistration = class {};
        var ServiceWorkerContainer = class {};
        Object.defineProperty(ServiceWorkerContainer.prototype, 'ready', { get() { return this.__native; } });
        var __registration;
        navigator.serviceWorker = Object.assign(new ServiceWorkerContainer(), { controller: null, dispatchEvent: () => true,
          __native: Promise.resolve('webkit'), getRegistration: () => Promise.resolve(__registration) });
        chrome.runtime.getManifest = () => ({ background: { service_worker: 'zigzag-entry.js' } });
        """
        let tab = Self.workerWorld(worker: false, setup: setup)
        tab.evaluateScript("navigator.serviceWorker.ready.then((r) => { globalThis.__url = r.active.scriptURL; r.active.postMessage('hi'); })")
        #expect(tab.evaluateScript("__url").toString() == "webkit-extension://x/zigzag-entry.js")
        #expect(tab.evaluateScript("__ports.length === 1 && __ports[0].sent[0].data").toString() == "hi")
        #expect(tab.evaluateScript("navigator.serviceWorker.ready === navigator.serviceWorker.ready").toBool())

        // Where WebKit has one (the popup), it's WebKit's.
        let popup = Self.workerWorld(worker: false, setup: setup + "__registration = {};")
        popup.evaluateScript("navigator.serviceWorker.ready.then((r) => { globalThis.__ready = r; })")
        #expect(popup.evaluateScript("__ready").toString() == "webkit")
    }

    @Test func alarmCallsReturnPromisesAsInChrome() {
        // WebKit's alarms.create returns undefined; The Marvellous Suspender calls .catch on it.
        let background = Self.workerWorld(worker: true, setup: """
        var __made = [];
        chrome.alarms = { create: (...args) => { __made.push(args.length); }, clear: () => undefined, clearAll: () => undefined,
                          get: () => Promise.resolve({ name: 'a' }), getAll: () => Promise.resolve([]), onAlarm: event() };
        """)
        background.evaluateScript("""
        var __seen = [];
        var __made1 = chrome.alarms.create('7', { when: 5 });
        __made1.then(() => __seen.push('created'));
        chrome.alarms.create({ when: 5 }).catch(() => {});
        chrome.alarms.create('8', { when: 5 }, () => __seen.push('callback'));
        chrome.alarms.clear('7').then(() => __seen.push('cleared'));
        chrome.alarms.clearAll().then(() => __seen.push('all cleared'));
        chrome.alarms.get('a').then((alarm) => __seen.push(alarm.name));
        """)
        background.evaluateScript("__flush()")
        #expect(background.evaluateScript("__made1 instanceof Promise").toBool())
        // The callback isn't handed to WebKit, which takes none.
        #expect(background.evaluateScript("__made.join()").toString() == "2,1,2")
        #expect(background.evaluateScript("__seen.sort().join()").toString() == "a,all cleared,callback,cleared,created")
    }

    @Test func framesOfAMissingOrSleepingTabAnswerAsInChrome() {
        // WebKit fails these for a tab with no page (asleep) or a frame that's gone; Chrome answers null, and [] for
        // a tab with no page. iCloud Passwords lists every tab's frames as it starts and stopped at the first asleep.
        let background = Self.workerWorld(worker: true, setup: """
        const refuse = (name, what) => Promise.reject(new Error('Invalid call to webNavigation.' + name + '(). ' + what + ' not found.'));
        chrome.tabs = { get: (id) => (id === 2 ? Promise.resolve({ id: 2 }) : Promise.reject(new Error('Invalid call to tabs.get(). Tab not found.'))) };
        chrome.webNavigation = {
          getAllFrames: (details) => (details.tabId === 1 ? Promise.resolve([
            { frameId: 0, parentFrameId: -1, documentId: 'top', url: 'https://a.example/' },
            { frameId: 7, parentFrameId: 0, documentId: 'sub', url: 'https://b.example/' }]) : refuse('getAllFrames', 'Tab')),
          getFrame: (details) => (details.tabId === 1 && details.frameId === 7
            ? Promise.resolve({ parentFrameId: 0, documentId: 'sub', url: 'https://b.example/', errorOccurred: false })
            : refuse('getFrame', details.tabId === 1 ? 'Frame' : 'Tab')),
          onCompleted: event(),
        };
        """)
        background.evaluateScript("""
        var __seen = {};
        const keep = (name) => (value) => { __seen[name] = JSON.stringify(value); };
        chrome.webNavigation.getAllFrames({ tabId: 1 }).then(keep('frames'));
        chrome.webNavigation.getAllFrames({ tabId: 2 }).then(keep('asleep'), keep('asleep refused'));
        chrome.webNavigation.getAllFrames({ tabId: 3 }).then(keep('missing'), keep('missing refused'));
        chrome.webNavigation.getFrame({ tabId: 1, frameId: 7 }).then(keep('frame'));
        chrome.webNavigation.getFrame({ tabId: 1, frameId: 8 }).then(keep('gone'), keep('gone refused'));
        chrome.webNavigation.getFrame({ tabId: 2, frameId: 0 }, (frame) => { __seen.callback = JSON.stringify(frame) + ' ' + (chrome.runtime.lastError === undefined); });
        """)
        background.evaluateScript("__flush()")
        #expect(background.evaluateScript("__seen.frames").toString() == #"[{"frameId":0,"parentFrameId":-1,"documentId":"top","url":"https://a.example/","frameType":"outermost_frame","documentLifecycle":"active"},{"frameId":7,"parentFrameId":0,"documentId":"sub","url":"https://b.example/","frameType":"sub_frame","documentLifecycle":"active","parentDocumentId":"top"}]"#)
        #expect(background.evaluateScript("__seen.asleep").toString() == "[]")
        #expect(background.evaluateScript("__seen.missing").toString() == "null")
        #expect(background.evaluateScript("__seen.frame").toString() == #"{"parentFrameId":0,"documentId":"sub","url":"https://b.example/","errorOccurred":false,"frameType":"sub_frame","documentLifecycle":"active"}"#)
        #expect(background.evaluateScript("__seen.gone").toString() == "null")
        #expect(background.evaluateScript("__seen.callback").toString() == "null true")
    }

    @Test func cookiesAsChromeDescribesThemAreSet() {
        // A cookie Chrome listed names its store "0" and may have a SameSite of "unspecified"; WebKit refuses both.
        let page = Self.workerWorld(worker: false, setup: """
        var __set = [];
        chrome.cookies = { set: (details) => { __set.push(details); return Promise.resolve(details); }, get: () => Promise.resolve(null),
                           getAll: () => Promise.resolve([]), remove: () => Promise.resolve(null), onChanged: event() };
        """)
        page.evaluateScript("""
        chrome.cookies.set({ url: 'https://linkedin.com', name: 'li_at', value: 'v', storeId: '0', sameSite: 'unspecified', secure: true });
        chrome.cookies.set({ url: 'https://linkedin.com', name: 'lang', value: 'v', storeId: 'persistent-1', sameSite: 'lax' });
        """)
        #expect(page.evaluateScript("JSON.stringify(__set[0])").toString() == #"{"url":"https://linkedin.com","name":"li_at","value":"v","secure":true}"#)
        #expect(page.evaluateScript("__set[1].storeId + ' ' + __set[1].sameSite").toString() == "persistent-1 lax")
    }

    @Test func cookieListenersHearWhichCookieChanged() {
        // WebKit calls cookies.onChanged listeners with nothing; Chrome says which cookie and why. Kondo waits for
        // LinkedIn's sign-in cookie to arrive before it adds the account.
        let background = Self.workerWorld(worker: true, setup: """
        var __jar = [{ name: 'lang', value: 'en', domain: '.linkedin.com', path: '/', storeId: 'persistent-1' }];
        var __changed = event();
        chrome.cookies = { getAll: () => Promise.resolve(__jar.map((c) => ({ ...c }))), onChanged: __changed };
        """)
        background.evaluateScript("""
        var __told = [];
        chrome.cookies.onChanged.addListener((info) => __told.push([info.removed, info.cookie.name, info.cookie.value, info.cause].join(' ')));
        var __second = 0;
        const second = () => { __second++; };
        chrome.cookies.onChanged.addListener(second);
        """)
        background.evaluateScript("__jar.push({ name: 'li_at', value: 'a', domain: '.www.linkedin.com', path: '/', storeId: 'persistent-1' }); __changed.fire();")
        #expect(background.evaluateScript("__told.join()").toString() == "false li_at a explicit")
        background.evaluateScript("__told = []; __jar[1].value = 'b'; __changed.fire();")
        #expect(background.evaluateScript("__told.join()").toString() == "true li_at a overwrite,false li_at b explicit")
        background.evaluateScript("__told = []; chrome.cookies.onChanged.removeListener(second); __jar.splice(0, 1); __changed.fire();")
        #expect(background.evaluateScript("__told.join()").toString() == "true lang en explicit")
        #expect(background.evaluateScript("__second").toInt32() == 3)
        #expect(!background.evaluateScript("chrome.cookies.onChanged.hasListener(second)").toBool())
        // Nothing different: nothing heard. A call that says what changed is passed on as it is.
        background.evaluateScript("__told = []; __changed.fire(); __changed.fire({ removed: false, cookie: { name: 'x', value: '1' }, cause: 'explicit' });")
        #expect(background.evaluateScript("__told.join()").toString() == "false x 1 explicit")
    }

    @Test func permissionsContainsAnswersForAnOriginWithAPort() {
        // WebKit refuses a pattern with a port, as 1Password asks on local sites; Chrome answers, as the pattern without it does.
        let page = Self.workerWorld(worker: false, setup: """
        chrome.permissions = { contains: (query) => {
          for (const origin of query.origins || []) {
            if (/:\\d+\\//.test(origin)) throw new Error(`Invalid call to permissions.contains(). The 'origins' value is invalid, because '${origin}' is not a valid pattern.`);
          }
          return Promise.resolve((query.origins || []).every((origin) => origin === 'http://127.0.0.1/*'));
        } };
        """)
        page.evaluateScript("""
        chrome.permissions.contains({ origins: ['http://127.0.0.1:8777/*'] }).then((held) => { globalThis.__local = held; });
        chrome.permissions.contains({ origins: ['https://example.com:8443/*'] }).then((held) => { globalThis.__other = held; });
        """)
        #expect(page.evaluateScript("__local").toBool() == true)
        #expect(page.evaluateScript("__other").toBool() == false)
    }

    @Test func optionalNativeMessagingIsHeldOnlyAsThePersonAllowedIt() {
        // WebKit grants native messaging to every extension for Zigzag's bridge; Bitwarden lists it as optional and
        // asks for it before Touch ID unlock, so Zigzag answers for it (#484).
        let page = Self.workerWorld(worker: false, setup: """
        var __webkit = [];
        chrome.permissions = {
          contains: (q) => { __webkit.push('contains ' + (q.permissions || []).join('+')); return Promise.resolve(true); },
          request: (q) => { __webkit.push('request ' + (q.permissions || []).join('+')); return Promise.resolve(true); },
          remove: (q) => { __webkit.push('remove ' + (q.permissions || []).join('+')); return Promise.resolve(true); },
          getAll: () => Promise.resolve({ permissions: ['storage', 'nativeMessaging'], origins: [] }),
        };
        var __held = false, __zigzag = [];
        globalThis.__zigzagNativeHosts = {
          held: () => Promise.resolve(__held),
          request: () => { __zigzag.push('request'); __held = true; return Promise.resolve(true); },
          remove: () => { __zigzag.push('remove'); const was = __held; __held = false; return Promise.resolve(was); },
        };
        """)
        page.evaluateScript("""
        chrome.permissions.contains({ permissions: ['nativeMessaging'] }).then((v) => { globalThis.__before = v; });
        chrome.permissions.getAll().then((all) => { globalThis.__allBefore = all.permissions.join('+'); });
        """)
        #expect(page.evaluateScript("__before").toBool() == false)
        #expect(page.evaluateScript("__allBefore").toString() == "storage")
        #expect(page.evaluateScript("__webkit.length").toInt32() == 0)
        // Asked for: Zigzag's sheet answers, WebKit isn't asked; then it's held, and the rest still goes to WebKit.
        page.evaluateScript("""
        chrome.permissions.request({ permissions: ['nativeMessaging'] }, (v) => { globalThis.__granted = v; });
        """)
        #expect(page.evaluateScript("__granted").toBool() == true)
        #expect(page.evaluateScript("__zigzag.join()").toString() == "request")
        page.evaluateScript("""
        chrome.permissions.contains({ permissions: ['nativeMessaging', 'tabs'] }).then((v) => { globalThis.__after = v; });
        chrome.permissions.getAll((all) => { globalThis.__allAfter = all.permissions.join('+'); });
        """)
        #expect(page.evaluateScript("__after").toBool() == true)
        #expect(page.evaluateScript("__allAfter").toString() == "storage+nativeMessaging")
        #expect(page.evaluateScript("__webkit.join()").toString() == "contains tabs")
        // Removed: no longer held, and WebKit keeps its grant for the bridge.
        page.evaluateScript("""
        chrome.permissions.remove({ permissions: ['nativeMessaging'] }).then((v) => { globalThis.__removed = v; });
        chrome.permissions.contains({ permissions: ['nativeMessaging'] }).then((v) => { globalThis.__gone = v; });
        """)
        #expect(page.evaluateScript("__removed").toBool() == true)
        #expect(page.evaluateScript("__gone").toBool() == false)
        #expect(page.evaluateScript("__webkit.join()").toString() == "contains tabs")
        // Other permissions are WebKit's as before.
        page.evaluateScript("chrome.permissions.request({ permissions: ['tabs'] }).then((v) => { globalThis.__tabs = v; });")
        #expect(page.evaluateScript("__tabs").toBool() == true)
        #expect(page.evaluateScript("__webkit.join()").toString() == "contains tabs,request tabs")
    }

    @Test func theBridgeAnswersForNativeMessagingOnlyWhenItIsOptional() {
        let bridged = { (manifest: String) -> JSContext in
            let context = JSContext()!
            context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
            context.evaluateScript("""
            var setTimeout = () => 0, clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
            var console = { log: () => {}, warn: () => {}, error: () => {} };
            const event = () => ({ addListener: () => {}, removeListener: () => {}, hasListener: () => false });
            var __sent = [];
            var chrome = { runtime: { id: 'x', getManifest: () => (\(manifest)), onMessage: event(), onConnect: event(),
              sendNativeMessage: (host, m) => { if (host === 'zigzag.bridge') __sent.push(m.ns + '.' + m.fn); return Promise.resolve({ value: true }); },
              connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) } };
            var browser = chrome;
            """)
            context.evaluateScript(ExtensionBridgeScript.source)
            return context
        }
        let optional = bridged("{ manifest_version: 3, permissions: ['storage', 'nativeMessaging'], optional_permissions: ['nativeMessaging'] }")
        optional.evaluateScript("__zigzagNativeHosts.held().then((v) => { globalThis.__held = v; }); __zigzagNativeHosts.request(); __zigzagNativeHosts.remove();")
        #expect(optional.evaluateScript("__held").toBool() == true)
        #expect(optional.evaluateScript("__sent.join()").toString() == "nativeHosts.held,nativeHosts.request,nativeHosts.remove")
        let required = bridged("{ manifest_version: 3, permissions: ['nativeMessaging'] }")
        #expect(required.evaluateScript("typeof __zigzagNativeHosts").toString() == "undefined")
    }

    @Test func nativeMessagingIsWebKitsToAnswerWithoutAnOptionalListing() {
        // 1Password requires it outright: the bridge sets no stand-in, and WebKit's answer stands.
        let page = Self.workerWorld(worker: false, setup: """
        chrome.permissions = { contains: () => Promise.resolve(true), request: () => Promise.resolve(true) };
        """)
        page.evaluateScript("chrome.permissions.contains({ permissions: ['nativeMessaging'] }).then((v) => { globalThis.__held = v; });")
        #expect(page.evaluateScript("__held").toBool() == true)
    }

    @Test func webRequestListenersForMainFramesHearThem() {
        // WebKit's filters: only main_frame hears nothing, only sub_frame hears main frames too. Violentmonkey watches
        // main_frame for .user.js loads; it hears those and nothing else, as in Chrome.
        let page = Self.workerWorld(worker: false, setup: """
        var __listeners = [];
        chrome.webRequest = { onBeforeRequest: {
          addListener: (f, filter) => { __listeners.push({ f, types: filter.types }); },
          removeListener: (f) => { __listeners = __listeners.filter((l) => l.f !== f); },
          hasListener: (f) => __listeners.some((l) => l.f === f),
        } };
        var __load = (type) => __listeners.filter((l) => !l.types || l.types.includes('sub_frame')).forEach((l) => l.f({ type, url: 'http://a.test/x.user.js' }));
        """)
        page.evaluateScript("""
        var __heard = [];
        var main = (d) => { __heard.push('main ' + d.type); }, sub = (d) => { __heard.push('sub ' + d.type); };
        chrome.webRequest.onBeforeRequest.addListener(main, { urls: ['*://*/*.user.js'], types: ['main_frame'] }, []);
        chrome.webRequest.onBeforeRequest.addListener(sub, { urls: ['<all_urls>'], types: ['sub_frame'] });
        __load('main_frame'); __load('sub_frame');
        """)
        #expect(page.evaluateScript("__heard.join()").toString() == "main main_frame,sub sub_frame")
        #expect(page.evaluateScript("chrome.webRequest.onBeforeRequest.hasListener(main)").toBool())
        page.evaluateScript("chrome.webRequest.onBeforeRequest.removeListener(main); __heard = []; __load('main_frame')")
        #expect(page.evaluateScript("chrome.webRequest.onBeforeRequest.hasListener(main)").toBool() == false)
        #expect(page.evaluateScript("__heard.length").toInt32() == 0)
    }

    private static func quoted(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    // MARK: - runtime contexts (Task 8a: getContexts and getBackgroundPage)

    /// `runtime.getContexts` is MV3 only; the bridge doesn't add it for MV2.
    @Test func contextsAreAnMV3MemberOnly() {
        for (version, present) in [(3, true), (2, false)] {
            let context = JSContext()!
            context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
            context.evaluateScript("""
            var window = globalThis;
            var __timers = [];
            var setTimeout = (f) => { __timers.push(f); return __timers.length; }, clearTimeout = () => {};
            var setInterval = () => 0, clearInterval = () => {};
            var console = { warn: () => {}, error: () => {}, log: () => {} };
            var navigator = { userAgent: 'Chrome/140.0.0.0 Safari/537.36' };
            const event = () => ({ addListener: () => {}, removeListener: () => {}, hasListener: () => false });
            var chrome = {
              runtime: { id: 'x', getManifest: () => ({ manifest_version: \(version) }), onMessage: event(), onConnect: event(),
                         sendNativeMessage: () => Promise.resolve({ value: [] }) },
            };
            """)
            context.evaluateScript(ExtensionBridgeScript.source)
            #expect(context.evaluateScript("typeof chrome.runtime.getContexts").toString() == (present ? "function" : "undefined"),
                    "manifest \(version)")
        }
    }

    /// The API surface fills missing runtime functions but leaves MV3's `getContexts` absent in MV2, so feature detection works.
    @Test func theAPISurfaceLeavesGetContextsOutOfMV2() throws {
        let v2 = try Self.surfaceWorld(version: 2)
        #expect(v2.evaluateScript("'getContexts' in chrome.runtime").toBool() == false)
        #expect(v2.evaluateScript("typeof chrome.runtime.getContexts").toString() == "undefined")
        let v3 = try Self.surfaceWorld(version: 3)
        #expect(v3.evaluateScript("typeof chrome.runtime.getContexts").toString() == "function")
        // Where only the surface ran, the member rejects rather than doing nothing.
        v3.evaluateScript("var __error = null; chrome.runtime.getContexts({}).catch((e) => { __error = e.message; });")
        #expect(v3.evaluateScript("__error").toString() == "chrome.runtime.getContexts isn't available in Zigzag")
    }

    /// MV3 has no background page: Chrome's error, not WebKit's null, via promise or callback; `runtime.lastError` only during the callback.
    @Test func anMV3PageIsToldThereIsNoBackgroundPage() {
        let page = Self.workerWorld(worker: false, setup: """
        chrome.runtime.getManifest = () => ({ manifest_version: 3 });
        chrome.runtime.getBackgroundPage = () => null;
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        #expect(page.evaluateScript("typeof chrome.runtime.getBackgroundPage").toString() == "function")
        page.evaluateScript("""
        chrome.runtime.getBackgroundPage().then(() => { globalThis.__promise = 'page'; }, (e) => { globalThis.__promise = e.message; });
        chrome.runtime.getBackgroundPage(() => { globalThis.__heard = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none'; });
        """)
        #expect(page.evaluateScript("__promise").toString() == "You do not have a background page.")
        #expect(page.evaluateScript("__heard").toString() == "You do not have a background page.")
        // The error exists only during the callback.
        #expect(page.evaluateScript("chrome.runtime.lastError === undefined").toBool())
    }

    /// privacy.services.passwordSavingEnabled goes to Zigzag (#513); the other settings answer as before.
    @Test func passwordSavingIsKeptByZigzag() {
        let page = Self.workerWorld(worker: false, setup: """
        const __setting = () => ({ get: () => Promise.reject(new Error("isn't available")), set: () => {}, clear: () => {}, onChange: {} });
        chrome.privacy = { services: { passwordSavingEnabled: __setting(), autofillEnabled: __setting() } };
        var __sent = [], __claim = null, __heard = { addListener: () => {} };
        var __zigzagPasswordSaving = {
          get: () => { __sent.push('get'); return Promise.resolve(__claim === null ? { value: true, levelOfControl: 'controllable_by_this_extension' } : { value: __claim, levelOfControl: 'controlled_by_this_extension' }); },
          set: (details) => { __sent.push('set'); __claim = details.value; return Promise.resolve(null); },
          clear: () => { __sent.push('clear'); __claim = null; return Promise.resolve(null); },
          onChange: __heard,
        };
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        let saving = "chrome.privacy.services.passwordSavingEnabled"
        page.evaluateScript("var __set = 'no'; \(saving).set({ value: false }, (r) => { __set = r === undefined ? 'done' : 'value'; });")
        #expect(page.evaluateScript("__set").toString() == "done")
        page.evaluateScript("\(saving).get({}, (d) => { globalThis.__got = d.levelOfControl + ' ' + d.value; });")
        #expect(page.evaluateScript("__got").toString() == "controlled_by_this_extension false")
        page.evaluateScript("\(saving).clear({}).then(() => \(saving).get({})).then((d) => { globalThis.__after = d.levelOfControl; });")
        #expect(page.evaluateScript("__after").toString() == "controllable_by_this_extension")
        #expect(page.evaluateScript("\(saving).onChange === __heard").toBool())
        #expect(page.evaluateScript("__sent.join()").toString() == "set,get,clear,get")
        // Not Zigzag's to keep: as before.
        page.evaluateScript("chrome.privacy.services.autofillEnabled.get({}, (d) => { globalThis.__other = d.levelOfControl; });")
        page.evaluateScript("__flush()")
        #expect(page.evaluateScript("__other").toString() == "not_controllable")
        // Zigzag can't answer (no privacy permission): as for the others, never an error.
        page.evaluateScript("__zigzagPasswordSaving.get = () => Promise.reject(new Error('passwordSaving needs the privacy permission'));")
        page.evaluateScript("\(saving).get({}).then((d) => { globalThis.__refused = d.levelOfControl + ' ' + d.value; });")
        #expect(page.evaluateScript("__refused").toString() == "not_controllable false")
    }

    /// The bridge sends what a password manager sets to Zigzag, with Chrome's details.
    @Test func theBridgeSendsPasswordSavingToZigzag() {
        let context = Self.bridgeWorld(permissions: ["privacy"])
        context.evaluateScript("""
        var __messages = [];
        chrome.runtime.sendNativeMessage = (host, message) => { __messages.push(host + ' ' + JSON.stringify(message)); return Promise.resolve({ value: null }); };
        __zigzagPasswordSaving.set({ value: false });
        __zigzagPasswordSaving.clear();
        """)
        #expect(context.evaluateScript("__messages.join('|')").toString()
                == #"zigzag.bridge {"ns":"passwordSaving","fn":"set","args":[{"value":false}]}|zigzag.bridge {"ns":"passwordSaving","fn":"clear","args":[]}"#)
        #expect(context.evaluateScript("typeof __zigzagPasswordSaving.onChange.addListener").toString() == "function")
    }

    /// WebKit's own `runtime.lastError` is restored after the failing callback.
    @Test func theBackgroundPageErrorPutsWebKitsLastErrorBack() {
        let page = Self.workerWorld(worker: false, setup: """
        chrome.runtime.getManifest = () => ({ manifest_version: 3 });
        chrome.runtime.getBackgroundPage = () => null;
        var __nativeLastError = () => ({ message: 'native' });
        Object.defineProperty(chrome.runtime, 'lastError', { get: __nativeLastError, configurable: true, enumerable: true });
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        page.evaluateScript("""
        var __during = null;
        chrome.runtime.getBackgroundPage(() => { __during = chrome.runtime.lastError && chrome.runtime.lastError.message; });
        """)
        #expect(page.evaluateScript("__during").toString() == "You do not have a background page.")
        #expect(page.evaluateScript("Object.getOwnPropertyDescriptor(chrome.runtime, 'lastError').get === __nativeLastError").toBool())
        #expect(page.evaluateScript("chrome.runtime.lastError.message").toString() == "native")
    }

    /// MV2 pages get their background page by promise and callback.
    @Test func anMV2PageKeepsItsBackgroundPage() {
        let page = Self.workerWorld(worker: false, setup: """
        chrome.runtime.getManifest = () => ({ manifest_version: 2 });
        globalThis.__background = { isBackgroundPage: true };
        chrome.runtime.getBackgroundPage = () => __background;
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        page.evaluateScript("""
        chrome.runtime.getBackgroundPage().then((p) => { globalThis.__promise = !!p.isBackgroundPage; });
        chrome.runtime.getBackgroundPage((p) => { globalThis.__heard = !!p.isBackgroundPage; });
        """)
        #expect(page.evaluateScript("__promise").toBool())
        #expect(page.evaluateScript("__heard").toBool())
        #expect(page.evaluateScript("chrome.runtime.lastError === undefined").toBool())
    }

    /// MV2 pages without a running background get Chrome's error text, not WebKit's null.
    @Test func anMV2PageWithoutABackgroundHearsChrome() {
        let page = Self.workerWorld(worker: false, setup: """
        chrome.runtime.getManifest = () => ({ manifest_version: 2 });
        chrome.runtime.getBackgroundPage = () => null;
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        page.evaluateScript("""
        chrome.runtime.getBackgroundPage().then(() => { globalThis.__promise = 'page'; }, (e) => { globalThis.__promise = e.message; });
        chrome.runtime.getBackgroundPage(() => { globalThis.__heard = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none'; });
        """)
        #expect(page.evaluateScript("__promise").toString() == "You do not have a background page.")
        #expect(page.evaluateScript("__heard").toString() == "You do not have a background page.")
    }

    /// MV3 workers keep WebKit's `getBackgroundPage`; hiding it needed a runtime Proxy that leaked into the keepalive port. Only pages are corrected.
    @Test func anMV3WorkerKeepsItsGetBackgroundPageMember() {
        let worker = Self.workerWorld(worker: true, setup: """
        var __manifest = () => ({ manifest_version: 3 });
        Object.defineProperty(chrome.runtime, 'getManifest', { value: __manifest, configurable: false, enumerable: true, writable: false });
        Object.defineProperty(chrome.runtime, 'getBackgroundPage', { value: () => null, configurable: false, enumerable: true });
        var browser = { runtime: { id: 'x' } };
        Object.defineProperty(browser.runtime, 'getManifest', { value: __manifest, configurable: false, enumerable: true, writable: false });
        Object.defineProperty(browser.runtime, 'getBackgroundPage', { value: () => null, configurable: false, enumerable: true });
        """)
        worker.evaluateScript("__zigzagAfterSurface()")
        for root in ["chrome", "browser"] {
            #expect(worker.evaluateScript("'getBackgroundPage' in \(root).runtime").toBool(), "\(root)")
            #expect(worker.evaluateScript("typeof \(root).runtime.getBackgroundPage").toString() == "function", "\(root)")
            #expect(worker.evaluateScript("\(root).runtime.getBackgroundPage() === null").toBool(), "\(root)")
            // Enumeration and descriptors are unchanged.
            #expect(worker.evaluateScript("Object.keys(\(root).runtime).includes('getManifest')").toBool(), "\(root)")
            #expect(worker.evaluateScript("Object.keys(\(root).runtime).includes('getBackgroundPage')").toBool(), "\(root)")
            #expect(worker.evaluateScript("typeof Object.getOwnPropertyDescriptor(\(root).runtime, 'getManifest').value").toString() == "function", "\(root)")
            #expect(worker.evaluateScript("Object.getOwnPropertyDescriptor(\(root).runtime, 'getManifest').enumerable").toBool(), "\(root)")
            #expect(worker.evaluateScript("\(root).runtime.getManifest().manifest_version").toInt32() == 3, "\(root)")
            #expect(worker.evaluateScript("typeof JSON.stringify(\(root).runtime)").toString() == "string", "\(root)")
        }
    }

    /// Globals sharing one runtime still share it when a member is hidden (MV2 `getContexts`).
    @Test func aSharedRuntimeStaysOneAcrossGlobals() {
        let page = Self.workerWorld(worker: false, setup: """
        chrome.runtime.getManifest = () => ({ manifest_version: 2 });
        Object.defineProperty(chrome.runtime, 'getContexts', { value: () => [], configurable: false });
        var browser = { runtime: chrome.runtime };
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        #expect(page.evaluateScript("chrome.runtime === browser.runtime").toBool())
        #expect(page.evaluateScript("'getContexts' in browser.runtime").toBool() == false)
    }

    /// MV2 pages lack `getContexts` even when WebKit's property can't be deleted; the rest of runtime stays.
    @Test func anMV2PageHasNoGetContextsEvenWhenWebKitWontGiveItUp() {
        let page = Self.workerWorld(worker: false, setup: """
        chrome.runtime.getManifest = () => ({ manifest_version: 2 });
        Object.defineProperty(chrome.runtime, 'getContexts', { value: () => [], configurable: false });
        """)
        page.evaluateScript("__zigzagAfterSurface()")
        #expect(page.evaluateScript("'getContexts' in chrome.runtime").toBool() == false)
        #expect(page.evaluateScript("typeof chrome.runtime.getContexts").toString() == "undefined")
        #expect(page.evaluateScript("typeof chrome.runtime.getManifest").toString() == "function")
    }
}

/// At launch extensions' service worker registrations go, so their backgrounds start afresh; sites' stay.
struct ServiceWorkerRegistrationTests {
    private func registrations(at file: URL, _ scripts: [String]?) {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        if let scripts {
            sqlite3_exec(db, "CREATE TABLE Records(key TEXT, scriptURL TEXT)", nil, nil, nil)
            for (i, script) in scripts.enumerated() { sqlite3_exec(db, "INSERT INTO Records VALUES('\(i)', '\(script)')", nil, nil, nil) }
        } else {
            sqlite3_exec(db, "CREATE TABLE Other(x TEXT)", nil, nil, nil)
        }
        sqlite3_close(db)
    }

    private func scripts(at file: URL) -> [String] {
        var db: OpaquePointer?, statement: OpaquePointer?
        sqlite3_open(file.path, &db)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        sqlite3_prepare_v2(db, "SELECT scriptURL FROM Records ORDER BY key", -1, &statement, nil)
        var found: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(String(cString: sqlite3_column_text(statement, 0))) }
        return found
    }

    @Test func extensionsRegistrationsGoAndSitesStay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("partition/origin/ServiceWorkers", isDirectory: true)
        let other = root.appendingPathComponent("partition/changed/ServiceWorkers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ServiceWorkerRegistrations-8.sqlite3")
        registrations(at: file, ["webkit-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/zigzag-entry.js", "https://example.com/sw.js"])
        // A layout WebKit changed: no Records table, left as it is.
        registrations(at: other.appendingPathComponent("ServiceWorkerRegistrations-9.sqlite3"), nil)

        ExtensionStore.forgetServiceWorkerRegistrations(in: root)

        #expect(scripts(at: file) == ["https://example.com/sw.js"])
    }
}

/// A message nothing listens for fails as in Chrome ("Receiving end does not exist"), where WebKit answers undefined.
extension ExtensionScriptTests {
    /// A fake background for bridge.js: WebKit's tabs.sendMessage answers `__answer` (undefined, as WebKit answers
    /// when nothing listens), and each frame in `__frames` says whether it listens when the receivers file runs there
    /// (null: executeScript refuses).
    private static func receiverWorld(version: Int = 3) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        let file = ExtensionBridgeScript.receiversFile, mark = ExtensionBridgeScript.receiversMark
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var console = { log: () => {}, warn: () => {}, error: () => {} };
        const event = () => ({ addListener: () => {}, removeListener: () => {}, hasListener: () => false });
        var __sent = [], __injected = [], __answer, __frames = [false], __registered = [];
        const ran = (details) => {
          __injected.push(details);
          if (__frames === null) return Promise.reject(new Error('Cannot access contents of the page'));
          const files = details.files || (details.file ? [details.file] : ['code']);
          const out = [];
          __frames.forEach((listens, frameId) => { for (const file of files) out.push({ frameId, result: file === '\(file)' ? '\(mark)' + listens : 'ran ' + file }); });
          return Promise.resolve(out);
        };
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ manifest_version: \(version), permissions: ['tabs', 'scripting'] }),
                     sendNativeMessage: () => Promise.resolve({ value: null }),
                     connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) },
          tabs: { sendMessage: (...args) => { __sent.push(args); return Promise.resolve(__answer); } },
        };
        if (\(version) === 3) chrome.scripting = {
          executeScript: (injection) => ran(injection),
          registerContentScripts: (scripts) => { __registered = scripts; return Promise.resolve(); },
          updateContentScripts: (scripts) => { __registered = scripts; return Promise.resolve(); },
          getRegisteredContentScripts: () => Promise.resolve(__registered),
        };
        else chrome.tabs.executeScript = (tabId, details) => (typeof tabId === 'object' ? ran(tabId) : ran(details));
        var browser = chrome;
        """)
        context.evaluateScript(ExtensionBridgeScript.source)
        return context
    }

    private static func settle(_ context: JSContext) { for _ in 0..<5 { context.evaluateScript("0") } }

    @Test func aTabMessageNothingHearsFails() {
        let context = Self.receiverWorld()
        let none = ExtensionBridgeScript.noReceiver
        // No frame listens: the promise fails with Chrome's error.
        context.evaluateScript("__frames = [false, false]; chrome.tabs.sendMessage(1, { a: 1 }).then((v) => { globalThis.__one = 'answered ' + v; }, (e) => { globalThis.__one = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__one").toString() == none)
        #expect(context.evaluateScript("JSON.stringify(__injected[0])").toString() == #"{"target":{"tabId":1,"allFrames":true},"files":["\#(ExtensionBridgeScript.receiversFile)"]}"#)
        // A callback gets nothing, and runtime.lastError says why while it runs.
        context.evaluateScript("chrome.tabs.sendMessage(1, {}, (v) => { globalThis.__two = [v === undefined, chrome.runtime.lastError && chrome.runtime.lastError.message]; });")
        Self.settle(context)
        #expect(context.evaluateScript("__two[0]").toBool() == true)
        #expect(context.evaluateScript("__two[1]").toString() == none)
        #expect(context.evaluateScript("chrome.runtime.lastError === undefined").toBool() == true)
        // A frame it names, or a document: only that one is asked; a frame that isn't there fails too.
        context.evaluateScript("__frames = []; chrome.tabs.sendMessage(1, {}, { frameId: 5 }).catch((e) => { globalThis.__three = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__three").toString() == none)
        #expect(context.evaluateScript("JSON.stringify(__injected[__injected.length - 1].target)").toString() == #"{"tabId":1,"frameIds":[5]}"#)
        context.evaluateScript("chrome.tabs.sendMessage(1, {}, { documentId: 'd' }).catch(() => {});")
        Self.settle(context)
        #expect(context.evaluateScript("JSON.stringify(__injected[__injected.length - 1].target)").toString() == #"{"tabId":1,"documentIds":["d"]}"#)
        // The options go on to WebKit as they were.
        #expect(context.evaluateScript("JSON.stringify(__sent[__sent.length - 1])").toString() == #"[1,{},{"documentId":"d"}]"#)
    }

    @Test func aTabMessageHeardButUnansweredIsUndefined() {
        let context = Self.receiverWorld()
        // A frame listens and gives no answer: undefined, no error, either way.
        context.evaluateScript("""
        __frames = [false, true];
        chrome.tabs.sendMessage(2, {}).then((v) => { globalThis.__one = v === undefined ? 'undefined' : v; }, (e) => { globalThis.__one = e.message; });
        """)
        Self.settle(context)
        #expect(context.evaluateScript("__one").toString() == "undefined")
        // Found lately: not asked again.
        context.evaluateScript("var __asked = __injected.length; chrome.tabs.sendMessage(2, {}, (v) => { globalThis.__two = chrome.runtime.lastError ? 'error' : 'none'; });")
        Self.settle(context)
        #expect(context.evaluateScript("__two").toString() == "none")
        #expect(context.evaluateScript("__injected.length === __asked").toBool() == true)
        // An answer is the answer, and nothing is asked.
        context.evaluateScript("__answer = 'hi'; chrome.tabs.sendMessage(3, {}).then((v) => { globalThis.__three = v; });")
        Self.settle(context)
        #expect(context.evaluateScript("__three").toString() == "hi")
        #expect(context.evaluateScript("__injected.length === __asked").toBool() == true)
        // Where the frames can't be asked, it stays WebKit's undefined.
        context.evaluateScript("__answer = undefined; __frames = null; chrome.tabs.sendMessage(4, {}).then((v) => { globalThis.__four = v === undefined ? 'undefined' : v; }, (e) => { globalThis.__four = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__four").toString() == "undefined")
    }

    @Test func injectedAndRegisteredFilesAreCounted() {
        let context = Self.receiverWorld()
        let file = ExtensionBridgeScript.receiversFile
        // The receivers file goes first; the extension is told only of its own files.
        context.evaluateScript("__frames = [false, false]; chrome.scripting.executeScript({ target: { tabId: 1, allFrames: true }, files: ['a.js', 'b.js'] }).then((r) => { globalThis.__one = r.map((x) => x.frameId + ':' + x.result).join(); });")
        Self.settle(context)
        #expect(context.evaluateScript("__one").toString() == "0:ran a.js,0:ran b.js,1:ran a.js,1:ran b.js")
        #expect(context.evaluateScript("__injected[0].files.join()").toString() == "\(file),a.js,b.js")
        context.evaluateScript("chrome.scripting.executeScript({ target: { tabId: 1 }, files: ['a.js'] }, (r) => { globalThis.__two = r.length; });")
        Self.settle(context)
        #expect(context.evaluateScript("__two").toInt32() == 2)
        // The page's own world is left alone; a function gets the file just before it, in the same frames.
        context.evaluateScript("chrome.scripting.executeScript({ target: { tabId: 1 }, files: ['m.js'], world: 'MAIN' }); chrome.scripting.executeScript({ target: { tabId: 1, frameIds: [2] }, func: () => 1 });")
        Self.settle(context)
        #expect(context.evaluateScript("__injected[2].files.join()").toString() == "m.js")
        #expect(context.evaluateScript("JSON.stringify(__injected[3])").toString() == #"{"target":{"tabId":1,"frameIds":[2]},"files":["\#(file)"]}"#)
        #expect(context.evaluateScript("__injected[4].files === undefined && typeof __injected[4].func === 'function'").toBool() == true)
        context.evaluateScript("chrome.scripting.executeScript({ target: { tabId: 1 }, func: () => 1, world: 'MAIN' });")
        Self.settle(context)
        #expect(context.evaluateScript("__injected.length").toInt32() == 6)
        // Registered scripts: registered with the file first, shown as the extension registered them.
        context.evaluateScript("""
        chrome.scripting.registerContentScripts([{ id: 'a', matches: ['<all_urls>'], js: ['c.js'] }, { id: 'm', matches: ['<all_urls>'], js: ['m.js'], world: 'MAIN' }, { id: 'css', matches: ['<all_urls>'], css: ['c.css'] }]);
        """)
        Self.settle(context)
        #expect(context.evaluateScript("__registered.map((s) => (s.js || []).join('+')).join()").toString() == "\(file)+c.js,m.js,")
        context.evaluateScript("chrome.scripting.getRegisteredContentScripts().then((list) => { globalThis.__three = list.map((s) => (s.js || []).join('+')).join(); });")
        Self.settle(context)
        #expect(context.evaluateScript("__three").toString() == "c.js,m.js,")
        context.evaluateScript("chrome.scripting.updateContentScripts([{ id: 'a', js: ['d.js'] }, { id: 'm', matches: ['https://example.com/*'] }]);")
        Self.settle(context)
        #expect(context.evaluateScript("__registered.map((s) => (s.js || []).join('+')).join()").toString() == "\(file)+d.js,")
    }

    @Test func manifestV2TabsAskWithTabsExecuteScript() {
        let context = Self.receiverWorld(version: 2)
        let file = ExtensionBridgeScript.receiversFile
        context.evaluateScript("chrome.tabs.sendMessage(1, {}).catch((e) => { globalThis.__one = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__one").toString() == ExtensionBridgeScript.noReceiver)
        #expect(context.evaluateScript("JSON.stringify(__injected[0])").toString() == #"{"file":"\#(file)","allFrames":true}"#)
        // Its injections: the file is run just before, in the same frames.
        context.evaluateScript("chrome.tabs.executeScript(1, { file: 'a.js', frameId: 3 }); chrome.tabs.executeScript({ code: '1' });")
        Self.settle(context)
        #expect(context.evaluateScript("JSON.stringify(__injected.slice(1))").toString()
                == #"[{"file":"\#(file)","frameId":3},{"file":"a.js","frameId":3},{"file":"\#(file)"},{"code":"1"}]"#)
    }

    /// The content-script world's part: its onMessage listeners counted, and runtime.sendMessage checked.
    private static func contentWorld() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        const event = () => { const l = []; return { addListener: (f) => { if (!l.includes(f)) l.push(f); }, removeListener: (f) => { const i = l.indexOf(f); if (i >= 0) l.splice(i, 1); }, hasListener: (f) => l.includes(f) }; };
        var __answer, __probe, __sent = [];
        var chrome = { runtime: { id: 'x', onMessage: event(),
          sendMessage: (...args) => { __sent.push(args); return Promise.resolve(args[0] && args[0].\(ExtensionBridgeScript.receiverProbe) ? __probe : __answer); } } };
        var browser = chrome;
        """)
        return context
    }

    @Test func contentScriptsCountTheirListeners() {
        let context = Self.contentWorld()
        let mark = ExtensionBridgeScript.receiversMark
        #expect(context.evaluateScript(ExtensionBridgeScript.receivers).toString() == mark + "false")
        context.evaluateScript("var __f = () => {}; chrome.runtime.onMessage.addListener(__f);")
        #expect(context.evaluateScript(ExtensionBridgeScript.receivers).toString() == mark + "true")
        // Once per world: run again, it keeps the count it had.
        context.evaluateScript("chrome.runtime.onMessage.removeListener(__f);")
        #expect(context.evaluateScript(ExtensionBridgeScript.receivers).toString() == mark + "false")
        #expect(context.evaluateScript("chrome.runtime.onMessage.hasListener(__f)").toBool() == false)
        // The whole prelude for content scripts carries it.
        #expect(ExtensionStore.contentScriptsFirst.contains(ExtensionBridgeScript.receivers))
    }

    @Test func aRuntimeMessageNothingHearsFails() {
        let context = Self.contentWorld()
        context.evaluateScript(ExtensionBridgeScript.receivers)
        let none = ExtensionBridgeScript.noReceiver
        // Unanswered, and no page of the extension listens.
        context.evaluateScript("chrome.runtime.sendMessage({ a: 1 }).then(() => { globalThis.__one = 'answered'; }, (e) => { globalThis.__one = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__one").toString() == none)
        context.evaluateScript("chrome.runtime.sendMessage({ a: 1 }, (v) => { globalThis.__two = [v === undefined, chrome.runtime.lastError && chrome.runtime.lastError.message]; });")
        Self.settle(context)
        #expect(context.evaluateScript("__two[1]").toString() == none)
        #expect(context.evaluateScript("chrome.runtime.lastError === undefined").toBool() == true)
        // To its own ID, the same.
        context.evaluateScript("chrome.runtime.sendMessage('x', {}).catch((e) => { globalThis.__three = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__three").toString() == none)
        // To another extension: left as WebKit has it.
        context.evaluateScript("chrome.runtime.sendMessage('other', {}).then((v) => { globalThis.__four = v === undefined ? 'undefined' : v; });")
        Self.settle(context)
        #expect(context.evaluateScript("__four").toString() == "undefined")
        // A page listens and gives no answer: undefined, no error; then trusted for a while.
        context.evaluateScript("__probe = true; chrome.runtime.sendMessage({}).then((v) => { globalThis.__five = v === undefined ? 'undefined' : v; }, (e) => { globalThis.__five = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__five").toString() == "undefined")
        context.evaluateScript("__probe = undefined; var __count = __sent.length; chrome.runtime.sendMessage({}, () => { globalThis.__six = chrome.runtime.lastError ? 'error' : 'none'; });")
        Self.settle(context)
        #expect(context.evaluateScript("__six").toString() == "none")
        #expect(context.evaluateScript("__sent.length - __count").toInt32() == 1)
        // An answer is the answer.
        context.evaluateScript("__answer = 'hi'; chrome.runtime.sendMessage({}, (v) => { globalThis.__seven = v; });")
        Self.settle(context)
        #expect(context.evaluateScript("__seven").toString() == "hi")
    }

    @Test func extensionPagesSayWhetherTheyListen() {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        let probe = ExtensionBridgeScript.receiverProbe
        context.evaluateScript("var __background = true, __page = null;")
        context.evaluateScript(Self.fakeWorld)
        context.evaluateScript("var __probe; chrome.runtime.sendMessage = (m) => Promise.resolve(m && m.\(probe) ? __probe : undefined);")
        context.evaluateScript(ExtensionBridgeScript.differences)
        // Nothing listens here: no answer to the question.
        context.evaluateScript("var __replies = []; var __ask = () => chrome.runtime.onMessage.fire({ \(probe): true }, { id: 'x' }, (v) => __replies.push(v)); __ask();")
        #expect(context.evaluateScript("__replies.length").toInt32() == 0)
        // A listener: yes, and the listener never sees the question.
        context.evaluateScript("var __heard = []; var __l = (m) => { __heard.push(m); }; chrome.runtime.onMessage.addListener(__l); __ask();")
        #expect(context.evaluateScript("__replies.join()").toString() == "true")
        #expect(context.evaluateScript("__heard.length").toInt32() == 0)
        context.evaluateScript("chrome.runtime.onMessage.removeListener(__l); __ask();")
        #expect(context.evaluateScript("__replies.length").toInt32() == 1)
        // The page's own runtime.sendMessage, unanswered with nothing listening elsewhere, fails.
        context.evaluateScript("chrome.runtime.sendMessage({}).catch((e) => { globalThis.__one = e.message; });")
        Self.settle(context)
        #expect(context.evaluateScript("__one").toString() == ExtensionBridgeScript.noReceiver)
        context.evaluateScript("__probe = true; chrome.runtime.sendMessage({}).then((v) => { globalThis.__two = v === undefined ? 'undefined' : v; });")
        Self.settle(context)
        #expect(context.evaluateScript("__two").toString() == "undefined")
    }

    @Test func aCallbackHearsTheErrorWhereLastErrorCantBeDefinedOver() {
        // In a background WebKit's runtime keeps its own lastError: the global chrome stands in while the callback runs.
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var console = { log: () => {}, warn: () => {}, error: () => {} };
        const event = () => ({ addListener: () => {}, removeListener: () => {}, hasListener: () => false });
        const base = { id: 'x', getManifest: () => ({ manifest_version: 3, permissions: ['scripting'] }),
                       sendNativeMessage: () => Promise.resolve({ value: null }), getURL: (p) => 'webkit-extension://x/' + p,
                       connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) };
        Object.defineProperty(base, 'lastError', { value: null, enumerable: true, configurable: true });
        // As WebKit's: defining lastError over it is taken and changes nothing.
        const runtime = new Proxy(base, { defineProperty: () => true });
        const api = { runtime, tabs: { sendMessage: () => Promise.resolve() }, scripting: { executeScript: () => Promise.resolve([{ frameId: 0, result: '\(ExtensionBridgeScript.receiversMark)false' }]) } };
        Object.defineProperty(globalThis, 'chrome', { value: api, configurable: true, writable: true });
        """)
        context.evaluateScript(ExtensionBridgeScript.source)
        context.evaluateScript("chrome.tabs.sendMessage(1, {}, () => { globalThis.__seen = chrome.runtime.lastError && chrome.runtime.lastError.message; globalThis.__id = chrome.runtime.id; });")
        Self.settle(context)
        #expect(context.evaluateScript("__seen").toString() == ExtensionBridgeScript.noReceiver)
        #expect(context.evaluateScript("__id").toString() == "x")
        #expect(context.evaluateScript("chrome === api && chrome.runtime.lastError === null").toBool() == true)
    }

    @Test func theScriptsAgreeOnTheReceiversNames() {
        #expect(ExtensionBridgeScript.source.contains("'\(ExtensionBridgeScript.receiversFile)'"))
        #expect(ExtensionBridgeScript.source.contains("'\(ExtensionBridgeScript.receiversMark)'"))
        #expect(ExtensionBridgeScript.source.contains("'\(ExtensionBridgeScript.noReceiver)'"))
        #expect(ExtensionBridgeScript.differences.contains("'\(ExtensionBridgeScript.receiverProbe)'"))
        #expect(ExtensionBridgeScript.differences.contains("'\(ExtensionBridgeScript.noReceiver)'"))
    }
}

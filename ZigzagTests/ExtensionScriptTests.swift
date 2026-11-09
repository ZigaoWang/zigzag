import JavaScriptCore
import Testing
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

    @Test func streamedTabAudioIsRejectedBeforeRoutingOrMuting() throws {
        let url = try #require(Bundle.main.url(forResource: "tab-capture", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let context = JSContext()!
        context.evaluateScript("""
        var window = {}, __contexts = 0, __failure = '';
        var document = { querySelectorAll: () => [{ paused: false, currentSrc: 'blob:https://example.com/media' }] };
        var AudioContext = function () { __contexts++; };
        const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
        new AsyncFunction('tap', 'stop', \(Self.quoted(source)))('test', false)
          .then(() => { __failure = 'unexpected success'; }, (e) => { __failure = e.message; });
        """)
        #expect(context.exception == nil)
        #expect(context.objectForKeyedSubscript("__failure")?.toString().contains("cannot be captured without recording other tabs") == true)
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
        #expect(parses(ExtensionProfile.compatibility) == nil)
        #expect(parses(ExtensionBridgeScript.surface) == nil)
        #expect(!ExtensionBridgeScript.differences.isEmpty)
        #expect(parses(ExtensionBridgeScript.differences) == nil)
        // Each extension's background prelude, as assembled, including those with fixes of their own.
        for id in ["anyextensionidaaaaaaaaaaaaaaaaaa", ExtensionStore.onePasswordID] {
            let prelude = ExtensionProfile.profile(for: id)?.backgroundPrelude ?? ""
            #expect(parses(prelude) == nil, "background prelude for \(id)")
        }
        for (id, source) in ExtensionProfile.pagePreludes { #expect(parses(source) == nil, "page prelude for \(id)") }
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
            mail.queue.append((background, "__backgroundPort = __port(\(Self.quoted(name)), { tab: { id: 7 }, frameId: 3 }, __toFrame); chrome.runtime.onConnect.fire(__backgroundPort)"))
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
          var MessageEvent = class { constructor(type, init) { this.type = type; this.data = init.data; } };
          var __heard = [];
          var dispatchEvent = (e) => { __heard.push(e.data); };
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
        #expect(worker.evaluateScript("__notes.length").toInt32() == 1)
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
}

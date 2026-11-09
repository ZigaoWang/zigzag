import Foundation
import JavaScriptCore
import SQLite3
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

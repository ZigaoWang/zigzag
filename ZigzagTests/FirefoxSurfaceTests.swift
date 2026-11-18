import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// Firefox's `browser`: WebKit already gives a Firefox add-on a promise-based one, so firefox-polyfill.js copies
/// nothing and wraps nothing. It only adds the two runtime members Firefox has and WebKit does not, on WebKit's own
/// objects, and only for a package whose manifest carries Mozilla's keys. A copy broke storage, whose methods live on
/// a prototype, and answered runtime.id with a gecko ID no message's sender.id matched.
///
/// The world here follows the JavaScriptCore harness in ExtensionScriptTests: `chrome` and `browser` are WebKit's
/// (two objects, as WebKit keeps them), the bridge is loaded over `chrome`, and the timers are driven by hand.
@MainActor
struct FirefoxSurfaceTests {
    /// A Firefox package's manifest, as firefox-polyfill.js reads it. Its own `version` must not be mistaken for the
    /// browser's, which getBrowserInfo reports.
    private static let firefoxManifest = "{ manifest_version: 3, version: '9.9.9', permissions: ['history'], "
        + "browser_specific_settings: { gecko: { id: 'firefox@zigzag.test' } } }"
    /// The same package's manifest before `browser_specific_settings` (Mozilla's older key).
    private static let legacyManifest = "{ manifest_version: 2, permissions: ['history'], "
        + "applications: { gecko: { id: 'legacy@zigzag.test' } } }"

    /// A fake extension background: WebKit's `chrome` and `browser` (kept apart, as WebKit keeps them, and with
    /// `storage.local`'s methods on a prototype), a native bridge answering one call of `history`, and the bridge
    /// itself. `extra` runs before the bridge, as an extension page's own setup would. With `surface`, the real
    /// api-surface.js runs in its place — after the bridge, as in the prelude — so the stand-ins it fills are present
    /// when the polyfill runs, exactly as they are in the app. `polyfill` replaces the injected script, for a test
    /// that injects something of its own.
    private static func firefoxWorld(manifest: String, extra: String = "", surface: Bool = false,
                                     polyfill: String? = nil) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        var __warned = [];
        var console = { log: () => {}, warn: (m) => __warned.push(String(m)), error: () => {} };
        const event = () => { const l = []; return { addListener: (f) => l.push(f),
          removeListener: (f) => { const i = l.indexOf(f); if (i >= 0) l.splice(i, 1); }, hasListener: (f) => l.includes(f) }; };
        var __manifest = \(manifest);
        // A namespace on a prototype, as WebKit keeps storage.local: copying own members alone would lose them.
        const storageProto = { get: (key) => Promise.resolve({ [key]: 'stored' }), set: () => Promise.resolve() };
        const makeAPI = () => ({
          runtime: { id: 'x', getManifest: () => __manifest, getURL: (p) => 'webkit-extension://x/' + p,
                     onMessage: event(), onConnect: event(),
                     sendNativeMessage: (host, message) => Promise.resolve(message.fn === 'search'
                       ? { value: [{ id: 7, url: 'https://found.example/' }] }
                       : { error: message.ns + '.' + message.fn + ' could not be answered' }),
                     connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) },
          tabs: { query: (info) => Promise.resolve([{ id: 1, url: 'https://a.example/' }]) },
          storage: { local: Object.create(storageProto) },
          i18n: { getMessage: (key) => 'message:' + key, getUILanguage: () => 'en-US', getAcceptLanguages: () => ['en-US'] },
        });
        var chrome = makeAPI();
        var browser = makeAPI();
        """)
        context.evaluateScript(extra)
        context.evaluateScript(ExtensionBridgeScript.source)
        if surface { context.evaluateScript(ExtensionBridgeScript.surface) }
        context.evaluateScript(polyfill ?? ExtensionBridgeScript.firefoxPolyfill)
        return context
    }

    // MARK: Self-gating

    /// WebKit's `browser` is left as it is and gets the two members: nothing is copied, so what a prototype holds
    /// still answers, and the events are the same objects WebKit delivers through.
    @Test func aFirefoxManifestAddsOnlyFirefoxsTwoRuntimeMembers() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("var __browser = browser, __storage = browser.storage.local;")
        #expect(context.evaluateScript("browser === __browser")?.toBool() == true)
        #expect(context.evaluateScript("browser !== chrome")?.toBool() == true)
        #expect(context.evaluateScript("typeof browser.runtime.getBrowserInfo")?.toString() == "function")
        #expect(context.evaluateScript("typeof browser.runtime.getPlatformInfo")?.toString() == "function")
        // Storage's methods are on the prototype, which no copy ever carried: they are still there and still answer.
        context.evaluateScript("var __stored = null; browser.storage.local.get('k').then((v) => { __stored = v; });")
        #expect(context.evaluateScript("__stored.k")?.toString() == "stored")
        #expect(context.evaluateScript("browser.storage.local === __storage")?.toBool() == true)
    }

    @Test func aChromeManifestLeavesBrowserExactlyAsItWas() {
        // A package with neither browser_specific_settings nor applications: not Firefox's, so untouched.
        let context = Self.firefoxWorld(manifest: "{ manifest_version: 3 }", extra: "var __before = browser;")
        #expect(context.evaluateScript("browser === __before")?.toBool() == true)
        #expect(context.evaluateScript("typeof browser.runtime.getBrowserInfo")?.toString() == "undefined")
        #expect(context.evaluateScript("browser.runtime === __before.runtime")?.toBool() == true)
        #expect(context.evaluateScript("chrome.runtime.id")?.toString() == "x")
    }

    /// Mozilla's older key, `applications`, still names a Firefox package.
    @Test func theOlderApplicationsKeyCountsToo() {
        let context = Self.firefoxWorld(manifest: Self.legacyManifest)
        #expect(context.evaluateScript("typeof browser.runtime.getBrowserInfo")?.toString() == "function")
        // The ID is WebKit's, the same one a message's sender carries.
        #expect(context.evaluateScript("browser.runtime.id")?.toString() == "x")
    }

    // MARK: The ID a sender carries

    @Test func runtimeIDStaysWebKitsSoASenderMatches() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("browser.runtime.id")?.toString() == "x")
        #expect(context.evaluateScript("browser.runtime.id === chrome.runtime.id")?.toBool() == true)
        // The gecko ID in the manifest is not what the runtime answers with.
        #expect(context.evaluateScript("browser.runtime.id")?.toString() != "firefox@zigzag.test")
    }

    // MARK: Calls

    /// WebKit's own promise is what a Firefox caller gets: nothing is wrapped on the way, so what it answers with is
    /// what WebKit answered.
    @Test func aCallAnswersWebKitsOwnPromise() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("var __promise = browser.tabs.query({}); var __tabs = null;")
        #expect(context.evaluateScript("__promise instanceof Promise")?.toBool() == true)
        context.evaluateScript("__promise.then((tabs) => { __tabs = tabs; });")
        context.evaluateScript("__flush();")
        #expect(context.evaluateScript("__tabs[0].url")?.toString() == "https://a.example/")
    }

    @Test func aBridgedCallResolvesWithTheBridgesAnswer() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("var __found = null; chrome.history.search({ text: '' }).then((items) => { __found = items; });")
        #expect(context.evaluateScript("__found[0].url")?.toString() == "https://found.example/")
    }

    @Test func aFailingCallRejectsWithTheBridgesError() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("""
        var __error = null;
        chrome.history.getVisits({ url: 'https://a.example/' }).then(() => { __error = 'resolved'; },
          (error) => { __error = error; });
        """)
        #expect(context.evaluateScript("__error.message")?.toString() == "history.getVisits could not be answered")
    }

    // MARK: Firefox-only members

    @Test func getBrowserInfoAnswersAsZigzag() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("var __info = null; browser.runtime.getBrowserInfo().then((info) => { __info = info; });")
        #expect(context.evaluateScript("__info.name")?.toString() == "Zigzag")
        #expect(context.evaluateScript("__info.vendor")?.toString() == "Zigzag")
        #expect(context.evaluateScript("__info.buildID")?.toString() == "")
        // The app's version, as ExtensionBridge.swift writes it in — never the extension manifest's.
        #expect(context.evaluateScript("__info.version")?.toString() == ExtensionBridgeScript.firefoxAppVersion)
        #expect(context.evaluateScript("__info.version")?.toString() != "9.9.9")
    }

    @Test func getPlatformInfoFallsBackToFirefoxsWhenAbsent() {
        // No runtime.getPlatformInfo at all: Firefox's own answer, and no rejection. The arch is the app's own,
        // injected from ExtensionBridge.swift — not a literal.
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("""
        var __platform = null, __failed = false;
        browser.runtime.getPlatformInfo().then((info) => { __platform = info; }, () => { __failed = true; });
        """)
        #expect(context.evaluateScript("__failed")?.toBool() == false)
        #expect(context.evaluateScript("__platform.os")?.toString() == "mac")
        #expect(context.evaluateScript("__platform.arch")?.toString() == ExtensionBridgeScript.firefoxAppArch)
    }

    /// The fallback architecture is the app's own, injected from ExtensionBridge.swift, not a literal: a build for
    /// another machine must tell Firefox's binding design its own arch.
    @Test func theFallbackArchComesFromTheAppNotALiteral() throws {
        let url = try #require(Bundle.main.url(forResource: "firefox-polyfill", withExtension: "js"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        let injected = raw.replacingOccurrences(of: "__ZIGZAG_ARCH__", with: "\"x86-64\"")
            .replacingOccurrences(of: "__ZIGZAG_VERSION__", with: "\"\"")
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest, polyfill: injected)
        context.evaluateScript("var __platform = null; browser.runtime.getPlatformInfo().then((info) => { __platform = info; });")
        #expect(context.evaluateScript("__platform.arch")?.toString() == "x86-64")
    }

    @Test func aRealPlatformAnswerIsMadeFirefoxs() {
        let arm = Self.firefoxWorld(manifest: Self.firefoxManifest,
                                    extra: "browser.runtime.getPlatformInfo = () => Promise.resolve({ os: 'mac', arch: 'arm64' });")
        arm.evaluateScript("var __platform = null; browser.runtime.getPlatformInfo().then((info) => { __platform = info; });")
        #expect(arm.evaluateScript("__platform.os")?.toString() == "mac")
        #expect(arm.evaluateScript("__platform.arch")?.toString() == "aarch64")

        let intel = Self.firefoxWorld(manifest: Self.firefoxManifest,
                                      extra: "browser.runtime.getPlatformInfo = () => Promise.resolve({ os: 'mac', arch: 'x86_64' });")
        intel.evaluateScript("var __platform = null; browser.runtime.getPlatformInfo().then((info) => { __platform = info; });")
        #expect(intel.evaluateScript("__platform.arch")?.toString() == "x86-64")
    }

    /// api-surface.js runs before the polyfill in the real prelude and fills runtime.getPlatformInfo with its
    /// `unavailable` stand-in, which answers with a rejection. browser.runtime.getPlatformInfo must still resolve
    /// Firefox's answer — the stand-in's refusal must not reach the extension — while chrome's own member refuses.
    @Test func theRealSurfaceDoesNotRefuseThePlatformAnswer() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest, surface: true)
        #expect(context.evaluateScript("globalThis.__zigzagSurface === true")?.toBool() == true)
        #expect(context.evaluateScript("typeof browser.runtime.getPlatformInfo")?.toString() == "function")
        context.evaluateScript("""
        var __nativeFailed = false;
        chrome.runtime.getPlatformInfo().then(() => {}, () => { __nativeFailed = true; });
        var __platform = null, __failed = false, __info = null;
        browser.runtime.getPlatformInfo().then((info) => { __platform = info; }, () => { __failed = true; });
        browser.runtime.getBrowserInfo().then((info) => { __info = info; });
        """)
        #expect(context.evaluateScript("__nativeFailed")?.toBool() == true)
        #expect(context.evaluateScript("__failed")?.toBool() == false)
        #expect(context.evaluateScript("__platform.os")?.toString() == "mac")
        #expect(context.evaluateScript("__platform.arch")?.toString() == ExtensionBridgeScript.firefoxAppArch)
        #expect(context.evaluateScript("__info.name")?.toString() == "Zigzag")
        #expect(context.evaluateScript("__info.vendor")?.toString() == "Zigzag")
    }

    @Test func anAbsentMemberStaysUndefined() {
        // Feature detection reads undefined through `browser`: nothing Zigzag doesn't have is invented.
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("typeof browser.runtime.getPackageDirectoryEntry")?.toString() == "undefined")
        #expect(context.evaluateScript("'getPackageDirectoryEntry' in browser.runtime")?.toBool() == false)
        #expect(context.evaluateScript("browser.sidebarAction === undefined")?.toBool() == true)
    }

    // MARK: Events

    /// The polyfill hands back no stand-in objects, so a listener added through `browser` is on WebKit's own event,
    /// and the bridge sees it under the same object.
    @Test func runtimeEventsAreWebKitsOwnObjects() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("""
        var __event = browser.runtime.onMessage;
        var __listener = () => {};
        __event.addListener(__listener);
        var __seen = browser.runtime.onMessage.hasListener(__listener);
        browser.runtime.onMessage.removeListener(__listener);
        var __gone = !__event.hasListener(__listener);
        var __same = browser.runtime.onMessage === __event;
        """)
        #expect(context.evaluateScript("__same")?.toBool() == true)
        #expect(context.evaluateScript("__seen")?.toBool() == true)
        #expect(context.evaluateScript("__gone")?.toBool() == true)
    }
}

import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// Firefox's Promise `browser` API, built by firefox-polyfill.js over the Chrome surface Zigzag answers. The prelude
/// is injected into every extension's pages and background, so it cannot know what kind of package it is in: the
/// facade gates itself on the package's own manifest. A package with Mozilla's keys gets one; a Chrome package keeps
/// whatever `browser` it had, exactly as it was.
///
/// The world here follows the JavaScriptCore harness in ExtensionScriptTests: `chrome` is WebKit's, the bridge is
/// loaded over it, and the timers are driven by hand.
@MainActor
struct FirefoxSurfaceTests {
    /// A Firefox package's manifest, as firefox-polyfill.js reads it. Its own `version` must not be mistaken for the
    /// browser's, which getBrowserInfo reports.
    private static let firefoxManifest = "{ manifest_version: 3, version: '9.9.9', permissions: ['history'], "
        + "browser_specific_settings: { gecko: { id: 'firefox@zigzag.test' } } }"
    /// The same package's manifest before `browser_specific_settings` (Mozilla's older key).
    private static let legacyManifest = "{ manifest_version: 2, permissions: ['history'], "
        + "applications: { gecko: { id: 'legacy@zigzag.test' } } }"

    /// A fake extension background: WebKit's `chrome`, a native bridge answering one call of `history`, and the bridge
    /// itself. `extra` runs before the bridge, as an extension page's own setup would. With `surface`, the real
    /// api-surface.js runs in its place — after the bridge, as in the prelude — so the stand-ins it fills are present
    /// when the polyfill runs, exactly as they are in the app.
    private static func firefoxWorld(manifest: String, extra: String = "", surface: Bool = false) -> JSContext {
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
        var chrome = {
          runtime: { id: 'x', getManifest: () => __manifest, getURL: (p) => 'webkit-extension://x/' + p,
                     onMessage: event(), onConnect: event(),
                     sendNativeMessage: (host, message) => Promise.resolve(message.fn === 'search'
                       ? { value: [{ id: 7, url: 'https://found.example/' }] }
                       : { error: message.ns + '.' + message.fn + ' could not be answered' }),
                     connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) },
          tabs: { query: (info) => Promise.resolve([{ id: 1, url: 'https://a.example/' }]) },
          i18n: { getMessage: (key) => 'message:' + key, getUILanguage: () => 'en-US', getAcceptLanguages: () => ['en-US'] },
        };
        """)
        context.evaluateScript(extra)
        context.evaluateScript(ExtensionBridgeScript.source)
        if surface { context.evaluateScript(ExtensionBridgeScript.surface) }
        context.evaluateScript(ExtensionBridgeScript.firefoxPolyfill)
        return context
    }

    // MARK: Self-gating

    @Test func aFirefoxManifestBuildsTheBrowserFacade() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("typeof browser")?.toString() == "object")
        #expect(context.evaluateScript("browser !== chrome")?.toBool() == true)
        #expect(context.evaluateScript("typeof browser.runtime.getManifest")?.toString() == "function")
    }

    @Test func aChromeManifestLeavesBrowserExactlyAsItWas() {
        // A package with neither browser_specific_settings nor applications: not Firefox's, so untouched.
        let context = Self.firefoxWorld(manifest: "{ manifest_version: 3 }", extra: "var browser = { marker: 7 }; var __before = browser;")
        #expect(context.evaluateScript("browser === __before")?.toBool() == true)
        #expect(context.evaluateScript("browser.marker")?.toInt32() == 7)
        #expect(context.evaluateScript("browser.runtime === undefined")?.toBool() == true)
        #expect(context.evaluateScript("chrome.runtime.id")?.toString() == "x")
    }

    /// Mozilla's older key, `applications`, still names a Firefox package.
    @Test func theOlderApplicationsKeyCountsToo() {
        let context = Self.firefoxWorld(manifest: Self.legacyManifest)
        #expect(context.evaluateScript("browser !== chrome")?.toBool() == true)
        #expect(context.evaluateScript("browser.runtime.id")?.toString() == "legacy@zigzag.test")
    }

    // MARK: Calls

    @Test func aBridgedCallResolvesWithTheBridgesAnswer() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("var __found = null; browser.history.search({ text: '' }).then((items) => { __found = items; });")
        #expect(context.evaluateScript("__found[0].url")?.toString() == "https://found.example/")
    }

    @Test func aTabsCallAnswersWithAPromise() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("browser.tabs.query({}) instanceof Promise")?.toBool() == true)
        // Nothing is answered before the turn ends: a Promise, not the answer itself.
        #expect(context.evaluateScript("var __tabs = 'waiting'; browser.tabs.query({}).then((tabs) => { __tabs = tabs; }); __tabs")?.toString() == "waiting")
        #expect(context.evaluateScript("__flush(); __tabs[0].url")?.toString() == "https://a.example/")
    }

    @Test func aFailingCallRejectsWithTheBridgesError() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("""
        var __error = null;
        browser.history.getVisits({ url: 'https://a.example/' }).then(() => { __error = 'resolved'; },
          (error) => { __error = error; });
        """)
        #expect(context.evaluateScript("__error.message")?.toString() == "history.getVisits could not be answered")
    }

    // MARK: What Firefox answers at once

    @Test func theSyncMembersAnswerAtOnce() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("browser.runtime.getManifest().manifest_version")?.toInt32() == 3)
        #expect(context.evaluateScript("typeof browser.runtime.getManifest().then")?.toString() == "undefined")
        #expect(context.evaluateScript("browser.runtime.getURL('popup.html')")?.toString() == "webkit-extension://x/popup.html")
        #expect(context.evaluateScript("typeof browser.runtime.getURL('popup.html').then")?.toString() == "undefined")
        #expect(context.evaluateScript("browser.i18n.getMessage('hello')")?.toString() == "message:hello")
        #expect(context.evaluateScript("browser.i18n.getUILanguage()")?.toString() == "en-US")
        #expect(context.evaluateScript("JSON.stringify(browser.i18n.getAcceptLanguages())")?.toString() == "[\"en-US\"]")
        #expect(context.evaluateScript("typeof browser.i18n.getUILanguage().then")?.toString() == "undefined")
    }

    @Test func runtimeIDIsTheGeckos() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("browser.runtime.id")?.toString() == "firefox@zigzag.test")
        // Chrome's own view of the extension is left alone.
        #expect(context.evaluateScript("chrome.runtime.id")?.toString() == "x")
    }

    // MARK: Firefox-only members

    @Test func getBrowserInfoAnswersAsFirefoxs() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("var __info = null; browser.runtime.getBrowserInfo().then((info) => { __info = info; });")
        #expect(context.evaluateScript("__info.name")?.toString() == "Zigzag")
        #expect(context.evaluateScript("__info.vendor")?.toString() == "Lakeland97")
        #expect(context.evaluateScript("__info.buildID")?.toString() == "")
        // The app's version, as ExtensionBridge.swift writes it in — never the extension manifest's.
        #expect(context.evaluateScript("__info.version")?.toString() == ExtensionBridgeScript.firefoxAppVersion)
        #expect(context.evaluateScript("__info.version")?.toString() != "9.9.9")
    }

    @Test func getPlatformInfoFallsBackToFirefoxsWhenAbsent() {
        // No chrome.runtime.getPlatformInfo at all: Firefox's own answer, and no rejection.
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("""
        var __platform = null, __failed = false;
        browser.runtime.getPlatformInfo().then((info) => { __platform = info; }, () => { __failed = true; });
        """)
        #expect(context.evaluateScript("__failed")?.toBool() == false)
        #expect(context.evaluateScript("__platform.os")?.toString() == "mac")
        #expect(context.evaluateScript("__platform.arch")?.toString() == "aarch64")
    }

    @Test func aRealPlatformAnswerIsMadeFirefoxs() {
        let arm = Self.firefoxWorld(manifest: Self.firefoxManifest,
                                    extra: "chrome.runtime.getPlatformInfo = () => Promise.resolve({ os: 'mac', arch: 'arm64' });")
        arm.evaluateScript("var __platform = null; browser.runtime.getPlatformInfo().then((info) => { __platform = info; });")
        #expect(arm.evaluateScript("__platform.os")?.toString() == "mac")
        #expect(arm.evaluateScript("__platform.arch")?.toString() == "aarch64")

        let intel = Self.firefoxWorld(manifest: Self.firefoxManifest,
                                      extra: "chrome.runtime.getPlatformInfo = () => Promise.resolve({ os: 'mac', arch: 'x86_64' });")
        intel.evaluateScript("var __platform = null; browser.runtime.getPlatformInfo().then((info) => { __platform = info; });")
        #expect(intel.evaluateScript("__platform.arch")?.toString() == "x86-64")
    }

    /// api-surface.js runs before the polyfill in the real prelude and fills chrome.runtime.getPlatformInfo with its
    /// `unavailable` stand-in, which answers with a rejection. browser.runtime.getPlatformInfo must still resolve
    /// Firefox's answer — the stand-in's refusal must not reach the extension — while chrome's own member refuses.
    @Test func theRealSurfaceDoesNotRefuseThePlatformAnswer() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest, surface: true)
        #expect(context.evaluateScript("globalThis.__zigzagSurface === true")?.toBool() == true)
        #expect(context.evaluateScript("typeof chrome.runtime.getPlatformInfo")?.toString() == "function")
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
        #expect(context.evaluateScript("__platform.arch")?.toString() == "aarch64")
        #expect(context.evaluateScript("__info.name")?.toString() == "Zigzag")
        #expect(context.evaluateScript("__info.vendor")?.toString() == "Lakeland97")
    }

    @Test func anAbsentMemberStaysUndefined() {
        // Feature detection reads undefined through `browser`: nothing Zigzag doesn't have is invented.
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        #expect(context.evaluateScript("typeof browser.runtime.getPackageDirectoryEntry")?.toString() == "undefined")
        #expect(context.evaluateScript("'getPackageDirectoryEntry' in browser.runtime")?.toBool() == false)
        #expect(context.evaluateScript("browser.sidebarAction === undefined")?.toBool() == true)
    }

    // MARK: Events

    @Test func runtimeEventsAreChromesOwnObjects() {
        let context = Self.firefoxWorld(manifest: Self.firefoxManifest)
        context.evaluateScript("""
        var __same = browser.runtime.onMessage === chrome.runtime.onMessage;
        var __listener = () => {};
        browser.runtime.onMessage.addListener(__listener);
        var __seen = chrome.runtime.onMessage.hasListener(__listener);
        browser.runtime.onMessage.removeListener(__listener);
        var __gone = !chrome.runtime.onMessage.hasListener(__listener);
        """)
        #expect(context.evaluateScript("__same")?.toBool() == true)
        #expect(context.evaluateScript("__seen")?.toBool() == true)
        #expect(context.evaluateScript("__gone")?.toBool() == true)
    }
}

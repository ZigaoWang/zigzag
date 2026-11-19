import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// Runtime context claims for getContexts and getBackgroundPage; MV3-only members stay out of MV2.
struct ExtensionContextClaimsTests {
    /// A fake extension world for api-surface.js: WebKit's runtime, manifest and diagnostics channel, no API namespaces. `setup` runs between world and surface.
    private static func surfaceWorld(version: Int, setup: String = "") throws -> JSContext {
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
            getManifest: () => ({ permissions: ['history'], manifest_version: \(version) }),
            sendNativeMessage: (host, message) => { __notes.push({ host, ...message }); return Promise.resolve(); },
          },
        };
        var __nativeLastError = () => undefined;
        Object.defineProperty(chrome.runtime, 'lastError', { get: __nativeLastError, configurable: true, enumerable: true });
        var browser = chrome;
        """)
        context.evaluateScript(setup)
        let script = try #require(ExtensionBridgeScript.surface.isEmpty ? nil : ExtensionBridgeScript.surface,
                                  "the generated surface script")
        context.evaluateScript(script)
        #expect(context.evaluateScript("globalThis.__zigzagSurface === true")?.toBool() == true, "the surface started")
        return context
    }

    @MainActor @Test func theContextClaimsAreInTheOverlay() throws {
        let overlay = try #require(ExtensionCompatibility.shared.overlay,
                                   "compatibility.json must ship with the app")
        let universe = try #require(ExtensionCompatibility.shared.universe,
                                    "chrome-api.json must ship with the app")
        let registry = CompatibilityRegistry(overlay: overlay)
        let implementations = CompatibilityImplementations.shipped()

        // getContexts is bridged, MV3 only; its text names what Zigzag can't report.
        let contexts = try #require(registry.claim(for: "runtime.getContexts"))
        #expect(contexts.status == .bridged)
        #expect(contexts.implementation == "swift:BridgeContexts")
        #expect(contexts.group == "runtimeContexts")
        #expect(overlay.groups["runtimeContexts"]?.catalog == "extension.limit.runtimeContexts")
        #expect(implementations.implements("swift:BridgeContexts"))
        #expect(CompatibilityText.text(for: "extension.limit.runtimeContexts", fallback: "⟨unwritten⟩")
                != "⟨unwritten⟩")

        // getBackgroundPage is WebKit's, corrected to Chrome's MV2-only behavior.
        let background = try #require(registry.claim(for: "runtime.getBackgroundPage"))
        #expect(background.status == .patched)
        #expect(background.implementation == "js:correctGetBackgroundPage")
        #expect(background.group == "runtimeBackgroundPage")
        #expect(overlay.groups["runtimeBackgroundPage"]?.catalog == "extension.limit.backgroundPage")
        #expect(implementations.implements("js:correctGetBackgroundPage"))
        #expect(CompatibilityText.text(for: "extension.limit.backgroundPage", fallback: "⟨unwritten⟩")
                != "⟨unwritten⟩")

        // The namespace status doesn't override either member, and the overlay validates.
        #expect(registry.claim(for: "runtime.getContexts")?.status == .bridged)
        #expect(registry.claim(for: "runtime.getBackgroundPage")?.status == .patched)
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: universe,
                                                          implementations: implementations)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func mv2SurfaceHasNoMV3OnlyRuntimeMembers() throws {
        // webkit-differences.js adds ContextType first; MV2 still must not see it.
        let context = try Self.surfaceWorld(version: 2, setup: """
        chrome.runtime.ContextType = { TAB: 'TAB', POPUP: 'POPUP' };
        chrome.runtime.OnInstalledReason = { INSTALL: 'install' };
        """)
        #expect(context.evaluateScript("'ContextType' in chrome.runtime").toBool() == false)
        #expect(context.evaluateScript("typeof chrome.runtime.ContextType").toString() == "undefined")
        // getContexts stays absent in MV2 rather than a detectable stand-in.
        #expect(context.evaluateScript("'getContexts' in chrome.runtime").toBool() == false)
        #expect(context.evaluateScript("typeof chrome.runtime.getContexts").toString() == "undefined")
        // Only MV3-reserved members are removed; other constants stay.
        #expect(context.evaluateScript("chrome.runtime.OnInstalledReason.INSTALL").toString() == "install")
    }

    @Test func mv3SurfaceKeepsItsContextMembers() throws {
        let context = try Self.surfaceWorld(version: 3)
        #expect(context.evaluateScript("chrome.runtime.ContextType.SIDE_PANEL").toString() == "SIDE_PANEL")
        #expect(context.evaluateScript("Object.isFrozen(chrome.runtime.ContextType)").toBool())
        // No native handler: the stand-in returns nothing, and the promise form rejects naming the member.
        #expect(context.evaluateScript("typeof chrome.runtime.getContexts").toString() == "function")
        context.evaluateScript("""
        var __called = 0, __args = -1, __lastError = 'unset';
        chrome.runtime.getContexts({}, (...args) => { __called++; __args = args.length; __lastError = chrome.runtime.lastError; });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__called").toInt32() == 1)
        #expect(context.evaluateScript("__args").toInt32() == 0)
        #expect(context.evaluateScript("__lastError === undefined").toBool())
        context.evaluateScript("var __error = null; chrome.runtime.getContexts({}).catch((e) => { __error = e.message; });")
        #expect(context.evaluateScript("__error").toString() == "chrome.runtime.getContexts isn't available in Zigzag")
    }
}

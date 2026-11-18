import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// The runtime context claims: what `runtime.getContexts` and `runtime.getBackgroundPage` promise, and that Chrome's
/// MV3-only members are not part of an MV2 extension's world.
struct ExtensionContextClaimsTests {
    /// A fake extension world for api-surface.js: WebKit's runtime with the manifest and the diagnostics channel an
    /// extension's background has, and none of the API namespaces the surface must fill. `setup` runs after the world
    /// and before the surface, as another prelude layer would.
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

        // runtime.getContexts is answered by the bridge, and only for MV3. Its words name what Zigzag cannot report.
        let contexts = try #require(registry.claim(for: "runtime.getContexts"))
        #expect(contexts.status == .bridged)
        #expect(contexts.implementation == "swift:BridgeContexts")
        #expect(contexts.group == "runtimeContexts")
        #expect(overlay.groups["runtimeContexts"]?.catalog == "extension.limit.runtimeContexts")
        #expect(implementations.implements("swift:BridgeContexts"))
        #expect(CompatibilityText.text(for: "extension.limit.runtimeContexts", fallback: "⟨unwritten⟩")
                != "⟨unwritten⟩")

        // runtime.getBackgroundPage is WebKit's member corrected to Chrome's MV2-only answer.
        let background = try #require(registry.claim(for: "runtime.getBackgroundPage"))
        #expect(background.status == .patched)
        #expect(background.implementation == "js:correctGetBackgroundPage")
        #expect(background.group == "runtimeBackgroundPage")
        #expect(overlay.groups["runtimeBackgroundPage"]?.catalog == "extension.limit.backgroundPage")
        #expect(implementations.implements("js:correctGetBackgroundPage"))
        #expect(CompatibilityText.text(for: "extension.limit.backgroundPage", fallback: "⟨unwritten⟩")
                != "⟨unwritten⟩")

        // The namespace's own answer does not leak over either member, and the whole overlay still holds together.
        #expect(registry.claim(for: "runtime.getContexts")?.status == .bridged)
        #expect(registry.claim(for: "runtime.getBackgroundPage")?.status == .patched)
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: universe,
                                                          implementations: implementations)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func mv2SurfaceHasNoMV3OnlyRuntimeMembers() throws {
        // webkit-differences.js adds ContextType before the surface runs; an MV2 extension must not see it anyway.
        let context = try Self.surfaceWorld(version: 2, setup: """
        chrome.runtime.ContextType = { TAB: 'TAB', POPUP: 'POPUP' };
        chrome.runtime.OnInstalledReason = { INSTALL: 'install' };
        """)
        #expect(context.evaluateScript("'ContextType' in chrome.runtime").toBool() == false)
        #expect(context.evaluateScript("typeof chrome.runtime.ContextType").toString() == "undefined")
        // getContexts is MV3's too, and stays absent rather than becoming a stand-in MV2 extensions would detect.
        #expect(context.evaluateScript("'getContexts' in chrome.runtime").toBool() == false)
        #expect(context.evaluateScript("typeof chrome.runtime.getContexts").toString() == "undefined")
        // Only the members Chrome reserves for MV3 go: an MV2 runtime keeps Chrome's other constants.
        #expect(context.evaluateScript("chrome.runtime.OnInstalledReason.INSTALL").toString() == "install")
    }

    @Test func mv3SurfaceKeepsItsContextMembers() throws {
        let context = try Self.surfaceWorld(version: 3)
        #expect(context.evaluateScript("chrome.runtime.ContextType.SIDE_PANEL").toString() == "SIDE_PANEL")
        #expect(context.evaluateScript("Object.isFrozen(chrome.runtime.ContextType)").toBool())
        // The surface has no native handler: in PR A its stand-in answers quietly, as main's did, and the promise
        // form still rejects with the error naming the member.
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

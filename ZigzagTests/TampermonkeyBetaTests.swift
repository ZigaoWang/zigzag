import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// Tampermonkey's beta gets the stable version's fixes, found by the code's shape rather than its short names.
/// The excerpts are its own code, from 5.6.6242.
@MainActor
struct TampermonkeyBetaTests {
    private func apply(_ file: String, _ text: String) -> String? {
        var result: String?
        for patch in ExtensionShims.tampermonkeyBetaPatches where patch.file == file {
            let overlay = ExtensionStore.OverlayPatch(file: patch.file, find: patch.find, replace: patch.replace, pattern: patch.pattern)
            if let changed = ExtensionStore.patched(result ?? text, by: overlay) { result = changed }
        }
        return result
    }

    @Test func itsStartNoLongerLoadsTheEmptyTestFile() {
        let start = "Kh=Jh;{try{\nimportScripts(\"/test.js\")}catch(e){console.error(e)}const e=globalThis,{skipWaiting:t,clients:n}=e;"
        #expect(apply("background.js", start) == "Kh=Jh;{const e=globalThis,{skipWaiting:t,clients:n}=e;")
    }

    @Test func itsPagesAreAnsweredAndAutoWatchesTheTab() throws {
        let pages = #"B={HAS_SENDER_ID:!0,INTERNAL_PAGE_PROTOCOLS:["chrome-extension:"],SENDS_ORIGIN:!0}"#
        #expect(apply("background.js", pages)?.contains(#"INTERNAL_PAGE_PROTOCOLS:["webkit-extension:"]"#) == true)

        let detection = "Cn=()=>{\nconst e=En.values.scriptUrlDetection;return\"auto\"!=e?e:E()>=152?\"inline\":\"newtab\"\n}"
        let patched = try #require(apply("background.js", detection))
        let context = try #require(JSContext())
        context.evaluateScript("var En = { values: { scriptUrlDetection: 'auto' } }, E = () => 160;")
        context.evaluateScript("var " + patched)
        #expect(context.evaluateScript("Cn()").toString() == "legacy")
        // A choice of the person's own stays theirs.
        context.evaluateScript("En.values.scriptUrlDetection = 'manual'")
        #expect(context.evaluateScript("Cn()").toString() == "manual")
    }

    /// Its function that puts a script into the page, with a stand-in document whose page allows inline scripts or not.
    private func inject(allowingInline: Bool) throws -> (ran: Int32, appended: Int32) {
        let excerpt = #"Pr=function(n,e,t,o,r){let s;const a=Ro(),i=Mo("script");a&&i.setAttribute("nonce",a);try{i.textContent=e,n.appendChild(i)}catch(n){s=n.message||n}if(a&&i.removeAttribute("nonce"),!r){const n=i.parentNode;n&&n.removeChild(i)}return o&&o(s),!s}"#
        let patched = try #require(apply("content.js", excerpt))
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var allowInline = \(allowingInline), attrs = {}, appended = 0, ran = 0;
        var element = () => ({ textContent: '', parentNode: null, setAttribute() {}, removeAttribute() {}, remove() {} });
        var document = { documentElement: { setAttribute(k) { attrs[k] = 1; }, removeAttribute(k) { delete attrs[k]; }, hasAttribute: (k) => k in attrs },
                         createElement: element };
        var Ro = () => 'n1', Mo = element;
        var head = { ownerDocument: document, appendChild(s) { appended++; if (allowInline) (0, eval)(s.textContent); } };
        """)
        context.evaluateScript("var " + patched)
        context.evaluateScript("Pr(head, 'ran++', 0, null, true); Pr(head, 'ran++', 0, null, true);")
        return (context.evaluateScript("ran").toInt32(), context.evaluateScript("appended").toInt32())
    }

    @Test func scriptsRunWhereThePageAllowsNoInlineScripts() throws {
        // Allowed: the test script once, then both scripts as inline scripts, as before.
        let open = try inject(allowingInline: true)
        #expect(open.ran == 2 && open.appended == 3)
        // Not allowed: the test script once, then both run in its own world.
        let closed = try inject(allowingInline: false)
        #expect(closed.ran == 2 && closed.appended == 1)
    }

    @Test func theFixesAlsoFitTheStableVersionsShape() {
        // The same code in the stable version, other short names: the shape is what's found.
        let stable = #"Ss=function(e,t,n,o,s){let r;const i=xo(),c=yo("script");i&&c.setAttribute("nonce",i);try{c.textContent=t,e.appendChild(c)}catch(e){r=e.message||e}"#
        #expect(apply("content.js", stable)?.contains("(0,eval)(t)") == true)
    }

    @Test func aPatchThatNoLongerFitsIsSkipped() {
        let literal = ExtensionStore.OverlayPatch(file: "a.js", find: "x()", replace: "y()")
        #expect(ExtensionStore.patched("x();x()", by: literal) == "y();y()")
        #expect(ExtensionStore.patched("z()", by: literal) == nil)
        // Literal means literal: no pattern is read into it.
        #expect(ExtensionStore.patched("aa", by: .init(file: "a.js", find: "a+", replace: "b")) == nil)
        let pattern = ExtensionStore.OverlayPatch(file: "a.js", find: #"([\w$]+)\(\)"#, replace: "$1(1)", pattern: true)
        #expect(ExtensionStore.patched("f();g$()", by: pattern) == "f(1);g$(1)")
        #expect(ExtensionStore.patched("--", by: pattern) == nil)
        for patch in ExtensionShims.tampermonkeyBetaPatches where patch.pattern {
            #expect((try? NSRegularExpression(pattern: patch.find)) != nil, "\(patch.find)")
        }
    }

    @Test func publicSuffixIsLeftMissingNotAPromise() throws {
        // Chrome's answers at once; a stand-in's rejected promise would be taken as the domain. Missing, Tampermonkey's
        // beta uses its own list.
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        context.evaluateScript("""
        var setTimeout = () => 0;
        var chrome = { runtime: { id: 'x', getManifest: () => ({ permissions: ['publicSuffix', 'alarms'] }), sendNativeMessage() {} } };
        """)
        context.evaluateScript(ExtensionBridgeScript.surface)
        #expect(context.evaluateScript("typeof chrome.publicSuffix").toString() == "undefined")
        #expect(context.evaluateScript("typeof chrome.alarms.create").toString() == "function")
    }
}

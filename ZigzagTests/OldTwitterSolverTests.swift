import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// OldTwitter's challenge solver is sent to Zigzag's hidden sandbox instead of the blob iframe the site's policy blocks.
@MainActor
struct OldTwitterSolverTests {
    private func apply(_ file: String, _ text: String) -> String? {
        var result: String?
        for patch in ExtensionShims.oldTwitterPatches where patch.file == file {
            let overlay = ExtensionStore.OverlayPatch(file: patch.file, find: patch.find, replace: patch.replace, pattern: patch.pattern)
            if let changed = ExtensionStore.patched(result ?? text, by: overlay) { result = changed }
        }
        return result
    }

    @Test func theStoreCopyAndItsOwnManifestAreOldTwitter() {
        #expect(OldTwitterSolver.isOldTwitter(id: OldTwitterSolver.extensionID, manifest: [:]))
        #expect(OldTwitterSolver.isOldTwitter(id: "abc", manifest: ["name": "Old Twitter Layout (2026)",
                                                                   "homepage_url": "https://github.com/dimdenGD/OldTwitter"]))
        #expect(!OldTwitterSolver.isOldTwitter(id: "abc", manifest: ["name": "Old Twitter Layout (2026)"]))
        #expect(!OldTwitterSolver.isOldTwitter(id: "abc", manifest: ["homepage_url": "https://github.com/dimdenGD/OldTwitter"]))
    }

    @Test func itsFrameBecomesNoFrame() throws {
        let excerpt = """
function createSolverFrame() {
    if (solverIframe) solverIframe.remove();
    solverReady = false;
    solverIframe = document.createElement("iframe");
}
createSolverFrame();
"""
        let patched = try #require(apply("scripts/twchallenge.js", excerpt))
        #expect(!patched.contains(#"document.createElement("iframe")"#))
        #expect(patched.contains("requeuePendingSolves();"))
        #expect(patched.contains("solverGeneration++;"))
        #expect(patched.hasSuffix("createSolverFrame();"))
    }

    @Test func eachTransactionGoesThroughTheBridge() throws {
        let excerpt = """
function solveChallenge(path, method) {
    return new Promise((resolve, reject) => {
        reject("Solver timed out");
    });
}

function recoverSolver(reason) {
}
"""
        let patched = try #require(apply("scripts/twchallenge.js", excerpt))
        #expect(patched.contains(#"return window.__zigzagOldTwitterCall({ op: "solve", path, method });"#))
        #expect(!patched.contains("new Promise((resolve, reject)"))
        #expect(patched.contains("function recoverSolver(reason)"))
    }

    @Test func itsInitGoesThroughTheBridgeToo() throws {
        let excerpt = """
        async function sendInit() {
            if (generation !== solverGeneration) return;
            solverIframe.contentWindow.postMessage({ action: "init" }, "*");
        }
        await sendInit();
"""
        let patched = try #require(apply("scripts/twchallenge.js", excerpt))
        #expect(patched.contains(#"op: "init""#))
        #expect(patched.contains("solverReady = true;"))
        #expect(!patched.contains("contentWindow.postMessage"))
    }

    /// Only the sandbox's own initError stops signing, as in Chrome. A timeout, a restart or a tab reloaded under the
    /// sandbox comes back as a thrown error, and the next solve starts a new sandbox over.
    @Test func aFailedInitIsNotTheSolverErroring() throws {
        let excerpt = """
        async function sendInit() {
            if (generation !== solverGeneration) return;
            solverIframe.contentWindow.postMessage({ action: "init" }, "*");
        }
        await sendInit();
"""
        let patched = try #require(apply("scripts/twchallenge.js", excerpt))
        #expect(patched.contains(#"if (reply && reply.initError) {"#))
        let parts = patched.components(separatedBy: "} catch (e) {")
        #expect(parts.count == 2)
        #expect(parts.first?.contains("solverErrored = true;") == true)
        #expect(parts.last?.contains("solverErrored") == false)
    }

    @Test func theSandboxListensForZigzagsCall() throws {
        let excerpt = """
        window.addEventListener('message', async function (event) {
            let data = event.data;
        });
"""
        let patched = try #require(apply("sandbox.html", excerpt))
        #expect(patched == """
        window.__zigzagSolveMessage = async function (event) {
            let data = event.data;
        };
""")
    }

    @Test func aFreshInitStartsOver() throws {
        let excerpt = "if (data.action === 'init') {\n                try {"
        let patched = try #require(apply("sandbox.html", excerpt))
        #expect(patched == "if (data.action === 'init') {\n                initError = false;\n                try {")
    }

    /// One patch that no longer fits leaves every file as it was, so a future build never gets half a fix.
    @Test func everyPatchMustFitOrNoneApply() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("patches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "one\ntwo".write(to: folder.appendingPathComponent("a.js"), atomically: true, encoding: .utf8)
        try "three".write(to: folder.appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        let fits = [ExtensionStore.OverlayPatch(file: "a.js", find: "one", replace: "1"),
                    ExtensionStore.OverlayPatch(file: "b.html", find: "three", replace: "3")]
        #expect(ExtensionStore.patchesFit(fits, in: folder))
        let broken = fits + [ExtensionStore.OverlayPatch(file: "a.js", find: "gone", replace: "x")]
        #expect(!ExtensionStore.patchesFit(broken, in: folder))
    }

    /// A page with one quoted tweet and its video, enough of the DOM for the bridge to run for real: listeners,
    /// observers, the play layer and the quote's link are all recorded.
    private func bridgePage() -> JSContext {
        let context = JSContext()!
        context.evaluateScript(#"""
        var __document = [], __window = [], __global = [], __timers = [], __posted = [];
        var __mutationObservers = 0, __resizeObservers = 0, __layers = 0, __watch = null;
        function Element() {}
        function addEventListener(name) { __global.push(name); }
        function setTimeout(run) { __timers.push(run); }
        function MutationObserver(run) { __mutationObservers++; __watch = run; this.observe = () => {}; }
        function ResizeObserver(run) { __resizeObservers++; this.observe = () => {}; }
        function getComputedStyle() { return { position: "relative" }; }

        var __quoteAttributes = { href: "#/example/status/1" };
        var __quote = {
          nodeType: 1,
          tagName: "A",
          classList: { contains: (name) => name === "tweet-body-quote" },
          style: {},
          getAttribute(name) { return __quoteAttributes[name] || null; },
          setAttribute(name, value) { __quoteAttributes[name] = value; },
          hasAttribute(name) { return __quoteAttributes[name] !== undefined; },
          removeAttribute(name) { delete __quoteAttributes[name]; },
          closest(selector) { return this; },
        };
        var __videoAttributes = {}, __holderAttributes = {}, __holderListeners = {};
        var __holder = {
          style: {},
          getBoundingClientRect: () => ({ left: 0, top: 0, width: 320, height: 180 }),
          appendChild: () => { __layers++; },
          getAttribute(name) { return __holderAttributes[name] || null; },
          setAttribute(name, value) { __holderAttributes[name] = value; },
          hasAttribute(name) { return __holderAttributes[name] !== undefined; },
          addEventListener(name, run) { (__holderListeners[name] || (__holderListeners[name] = [])).push(run); },
        };
        var __video = {
          nodeType: 1,
          tagName: "VIDEO",
          parentElement: __holder,
          preload: "",
          currentTime: 0,
          paused: true,
          getAttribute(name) { return __videoAttributes[name] || null; },
          setAttribute(name, value) { __videoAttributes[name] = value; },
          hasAttribute(name) { return __videoAttributes[name] !== undefined; },
          removeAttribute(name) { delete __videoAttributes[name]; },
          closest(selector) { return selector === "a.tweet-body-quote" ? __quote : selector === "video" ? this : null; },
          getBoundingClientRect: () => ({ left: 0, top: 0, width: 320, height: 180 }),
        };
        var __root = {
          nodeType: 1,
          tagName: "HTML",
          getAttribute() { return null; },
          querySelectorAll() { return [__video, __quote]; },
        };
        var __target = new Element();
        __target.closest = () => __quote;

        var document = {
          documentElement: __root,
          createElement: () => ({ style: {}, setAttribute() {}, addEventListener() {} }),
          addEventListener(name, run) { __document.push([name, run]); },
        };
        var window = {
          addEventListener(name) { __window.push(name); },
          webkit: { messageHandlers: { zigzagOldTwitterSolver: { postMessage(message) { __posted.push(message); } } } },
        };
        var chrome = { runtime: { id: "jgejdcdoeeabklepnkdbglgccjpdgpmf" } };
        var location = { hostname: "x.com" };
        """#)
        #expect(context.exception == nil)
        return context
    }

    private func press(_ context: JSContext, button: Int) {
        context.evaluateScript("__document.find((pair) => pair[0] === 'mousedown')[1]({ button: \(button), target: __target })")
        #expect(context.exception == nil)
    }

    /// The bridge comes from the user script and again from a page that was open when OldTwitter started. The second
    /// run must add nothing: one listener set, one observer, one play layer per video.
    @Test func theBridgeRunsOncePerWorld() throws {
        let context = bridgePage()
        context.evaluateScript(OldTwitterSolver.bridge)
        context.evaluateScript(OldTwitterSolver.bridge)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.__zigzagOldTwitterBridge")?.toBool() == true)
        #expect(context.evaluateScript("__document.length")?.toInt32() == 3) // click, contextmenu, mousedown
        #expect(context.evaluateScript("__window.length")?.toInt32() == 1) // message
        #expect(context.evaluateScript("__global.length")?.toInt32() == 1) // resize
        #expect(context.evaluateScript("__mutationObservers")?.toInt32() == 1)
        #expect(context.evaluateScript("__resizeObservers")?.toInt32() == 2)
        #expect(context.evaluateScript("__layers")?.toInt32() == 1)
        #expect(context.evaluateScript("__holderListeners.click.length")?.toInt32() == 1)
        // Even without the window's flag, the mark on the video keeps its one layer.
        context.evaluateScript("delete window.__zigzagOldTwitterBridge")
        context.evaluateScript(OldTwitterSolver.bridge)
        #expect(context.evaluateScript("__layers")?.toInt32() == 1)
        #expect(context.evaluateScript("__resizeObservers")?.toInt32() == 2)
        #expect(context.evaluateScript("__holderListeners.click.length")?.toInt32() == 1)
        #expect(context.evaluateScript("__video.hasAttribute('data-zigzag-play-video')")?.toBool() == true)
    }

    /// A plain click on a quoted video belongs to the video's own controls. It stops at the video's holder, before
    /// the quote's own click handler, so the quote does not open. A modified click is the browser's and passes.
    @Test func aClickOnAQuotedVideoStopsAtItsHolder() throws {
        let context = bridgePage()
        context.evaluateScript(OldTwitterSolver.bridge)
        #expect(context.evaluateScript("__holder.hasAttribute('data-zigzag-quote-click')")?.toBool() == true)
        #expect(context.evaluateScript("__holderListeners.click.length")?.toInt32() == 1)

        context.evaluateScript("""
        var __plain = { target: __video, metaKey: false, ctrlKey: false, prevented: false, stopped: false,
          preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; } };
        __holderListeners.click[0](__plain);
        """)
        #expect(context.evaluateScript("__plain.prevented")?.toBool() == true)
        #expect(context.evaluateScript("__plain.stopped")?.toBool() == true)

        context.evaluateScript("""
        var __modified = { target: __video, metaKey: true, ctrlKey: false, prevented: false, stopped: false,
          preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; } };
        __holderListeners.click[0](__modified);
        """)
        #expect(context.evaluateScript("__modified.prevented")?.toBool() == false)
        #expect(context.evaluateScript("__modified.stopped")?.toBool() == false)
    }

    /// The native controls stop the click before it leaves them, so the document's capture listener is the one
    /// that keeps a plain click on a quoted video from following the quote's link. A modified click is the browser's.
    @Test func aClickOnAQuotedVideoStopsTheQuotesLink() throws {
        let context = bridgePage()
        context.evaluateScript(OldTwitterSolver.bridge)
        context.evaluateScript("""
        var __click = __document.find((pair) => pair[0] === 'click')[1];
        var __videoTarget = new Element();
        __videoTarget.closest = (selector) => selector === "video" ? __video : selector === "a.tweet-body-quote" ? __quote : null;
        var __plain = { target: __videoTarget, metaKey: false, ctrlKey: false, prevented: false,
          preventDefault() { this.prevented = true; } };
        __click(__plain);
        """)
        #expect(context.evaluateScript("__plain.prevented")?.toBool() == true)
        context.evaluateScript("""
        var __modified = { target: __videoTarget, metaKey: true, ctrlKey: false, prevented: false,
          preventDefault() { this.prevented = true; } };
        __click(__modified);
        """)
        #expect(context.evaluateScript("__modified.prevented")?.toBool() == false)
    }

    /// The ⌘-click script is in every site's page world, but it listens only on x.com and twitter.com, and once.
    @Test func theModifiedClickScriptActsOnlyOnItsSites() throws {
        let other = bridgePage()
        other.evaluateScript("location.hostname = 'github.com'")
        other.evaluateScript(OldTwitterSolver.modified)
        #expect(other.exception == nil)
        #expect(other.evaluateScript("__document.length")?.toInt32() == 0)
        #expect(other.evaluateScript("window.__zigzagOldTwitterModified")?.isUndefined == true)

        let x = bridgePage()
        x.evaluateScript(OldTwitterSolver.modified)
        x.evaluateScript(OldTwitterSolver.modified)
        #expect(x.exception == nil)
        #expect(x.evaluateScript("__document.length")?.toInt32() == 2) // mousedown, click
    }

    /// The bridge leaves every other site alone.
    @Test func theBridgeActsOnlyOnItsSites() throws {
        let context = bridgePage()
        context.evaluateScript("location.hostname = 'github.com'")
        context.evaluateScript(OldTwitterSolver.bridge)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__document.length")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__zigzagOldTwitterBridge")?.isUndefined == true)
    }

    /// A right press puts the quote's link back for the menu and marks it, and the observer leaves it until the
    /// menu has been built. The next press takes it off again, as a ⌘ or middle press keeps its own.
    @Test func aRightPressKeepsTheQuotesLinkForItsMenu() throws {
        let context = bridgePage()
        context.evaluateScript(OldTwitterSolver.bridge)
        #expect(context.evaluateScript("__quote.hasAttribute('href')")?.toBool() == false)
        #expect(context.evaluateScript("__quote.getAttribute('data-zigzag-href')")?.toString() == "#/example/status/1")

        press(context, button: 2)
        #expect(context.evaluateScript("__quote.hasAttribute('href')")?.toBool() == true)
        #expect(context.evaluateScript("__quote.hasAttribute('data-zigzag-menu')")?.toBool() == true)
        // What the observer sees just after the press.
        context.evaluateScript("__watch([{ type: 'attributes', target: __quote }])")
        #expect(context.evaluateScript("__quote.hasAttribute('href')")?.toBool() == true)
        // The menu has it: the mark and the link go, and the quote can open in the extension's viewer again.
        context.evaluateScript("__timers.shift()()")
        #expect(context.evaluateScript("__quote.hasAttribute('data-zigzag-menu')")?.toBool() == false)
        #expect(context.evaluateScript("__quote.hasAttribute('href')")?.toBool() == false)
        #expect(context.evaluateScript("__quote.getAttribute('data-zigzag-href')")?.toString() == "#/example/status/1")

        // A middle press keeps the link for the browser, and the next left press takes it off.
        press(context, button: 1)
        #expect(context.evaluateScript("__quote.hasAttribute('href')")?.toBool() == true)
        press(context, button: 0)
        #expect(context.evaluateScript("__quote.hasAttribute('href')")?.toBool() == false)
        #expect(context.evaluateScript("__quote.hasAttribute('data-zigzag-menu')")?.toBool() == false)
    }

    /// A right press on a timeline video reports the biggest mp4 the page lists, not the playlist Safari plays.
    @Test func aRightPressOnAVideoReportsItsMp4() throws {
        let context = bridgePage()
        context.evaluateScript(OldTwitterSolver.bridge)
        context.evaluateScript("""
        __video.currentSrc = "https://video.example/a.m3u8";
        __video.querySelectorAll = () => [
          { type: "application/x-mpegURL", src: "https://video.example/a.m3u8" },
          { type: "video/mp4", src: "https://video.example/1280x720/high.mp4" },
          { type: "video/mp4", src: "https://video.example/320x180/low.mp4" },
          { type: "video/mp4", src: "https://video.example/no-size.mp4" },
        ];
        __document.find((pair) => pair[0] === "contextmenu")[1]({ target: __video });
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__posted.length")?.toInt32() == 1)
        #expect(context.evaluateScript("__posted[0].op")?.toString() == "video")
        #expect(context.evaluateScript("__posted[0].src")?.toString() == "https://video.example/a.m3u8")
        #expect(context.evaluateScript("__posted[0].file")?.toString() == "https://video.example/1280x720/high.mp4")
    }

    /// The sandbox has no body of its own in a hidden page, so the parts the challenge reads are made when missing.
    @Test func theChallengePiecesAreMadeWhenThePageHasNone() throws {
        let excerpt = #"""
        function setPageData(data) {
            let animsDiv = document.getElementById('anims');
            animsDiv.innerHTML = '';
            for (let anim of data.anims) {
                animsDiv.innerHTML += `\n${anim}`;
            }
            let verif = document.querySelector('meta[name="twitter-site-verification"]');
            verif.content = data.verificationCode;
        }
"""#
        let patched = try #require(apply("sandbox.html", excerpt))
        #expect(patched.contains("if (!animsDiv) {"))
        #expect(patched.contains("if (!verif) {"))
        #expect(patched.contains("verif.name = 'twitter-site-verification';"))
    }


}

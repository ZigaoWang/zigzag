import Foundation
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

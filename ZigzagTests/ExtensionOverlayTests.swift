import Foundation
import Testing
@testable import Zigzag

/// The loaded copy's manifest and background, for extensions whose shims or patches need one. Each test builds its
/// own package in a temporary folder: nothing here reads or writes an installed extension.
@MainActor
struct ExtensionOverlayTests {
    private static let prelude = "// Zigzag's prelude\n"

    private struct Fixture {
        let work: URL
        let package: URL
        let overlay: URL
    }

    private static func fixture(_ manifest: [String: Any], files: [String: String] = [:]) throws -> Fixture {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionOverlayTests-\(UUID().uuidString)")
        let package = work.appendingPathComponent("package"), overlay = work.appendingPathComponent("overlay")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: package.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            let file = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return Fixture(work: work, package: package, overlay: overlay)
    }

    private static func manifest(in overlay: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: overlay.appendingPathComponent("manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func background(in overlay: URL) throws -> [String: Any] {
        try #require(try manifest(in: overlay)["background"] as? [String: Any])
    }

    private static func text(_ path: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func mv2BackgroundScriptsRunThePreludeFirst() throws {
        let fixture = try Self.fixture(
            ["manifest_version": 2, "name": "MV2 scripts", "version": "1.0",
             "background": ["scripts": ["js/one.js", "/js/two.js", "./js/one.js"]]],
            files: ["js/one.js": "one();", "js/two.js": "two();"])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        #expect(try Self.background(in: fixture.overlay)["scripts"] as? [String] == ["zigzag-prelude.js", "js/one.js", "js/two.js"])
        #expect(try Self.text("zigzag-prelude.js", in: fixture.overlay) == Self.prelude)
    }

    @Test func mv2BackgroundPageGetsThePreludeAheadOfItsScripts() throws {
        let html = """
        <!doctype html>
        <html><head>
        <meta http-equiv="Content-Security-Policy" content="script-src 'self'">
        <!-- <script src="commented-out.js"></script> -->
        <script src="first.js"></script>
        <script src="second.js"></script>
        </head><body></body></html>
        """
        let fixture = try Self.fixture(
            ["manifest_version": 2, "name": "MV2 page", "version": "1.0", "background": ["page": "background.html"]],
            files: ["background.html": html])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        // The key and its page are still the extension's own.
        #expect(try Self.background(in: fixture.overlay)["page"] as? String == "background.html")
        let page = try Self.text("background.html", in: fixture.overlay)
        let tag = #"<script src="/zigzag-prelude.js" data-zigzag-prelude="1"></script>"#
        #expect(page.components(separatedBy: tag).count == 2)
        let tagRange = try #require(page.range(of: tag))
        let comment = try #require(page.range(of: "<!--"))
        let first = try #require(page.range(of: "first.js"))
        let second = try #require(page.range(of: "second.js"))
        // Before the first real script, and not inside the comment that names one.
        #expect(comment.upperBound < tagRange.lowerBound)
        #expect(tagRange.lowerBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound)
        // Nothing else about the page changed: CSP, addresses and script order are the extension's.
        #expect(page.replacingOccurrences(of: tag, with: "") == html)
    }

    @Test func aBackgroundPageInASubfolderLoadsThePreludeFromTheRoot() throws {
        let html = #"<!doctype html><html><head><script src="../js/app.js"></script></head></html>"#
        let fixture = try Self.fixture(
            ["manifest_version": 2, "name": "Nested page", "version": "1.0", "background": ["page": "pages/background.html"]],
            files: ["pages/background.html": html, "js/app.js": "app();"])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        #expect(try Self.background(in: fixture.overlay)["page"] as? String == "pages/background.html")
        let page = try Self.text("pages/background.html", in: fixture.overlay)
        let tag = #"<script src="/zigzag-prelude.js" data-zigzag-prelude="1"></script>"#
        #expect(page.components(separatedBy: tag).count == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.overlay.appendingPathComponent("zigzag-prelude.js").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.overlay.appendingPathComponent("pages/zigzag-prelude.js").path))
    }

    @Test func thePreludeTagIsInsertedOnce() throws {
        let fixture = try Self.fixture(
            ["manifest_version": 2, "name": "Once", "version": "1.0", "background": ["page": "background.html"]],
            files: ["background.html": #"<html><head><script src="app.js"></script></head></html>"#])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        // The overlay is made again from the package: a second pass must not add a second tag.
        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        var page = try Self.text("background.html", in: fixture.overlay)
        #expect(page.components(separatedBy: "data-zigzag-prelude").count == 2)

        // A page that already carries the marker is left as it is.
        let marked = #"<html><head><script src="/zigzag-prelude.js" data-zigzag-prelude="1"></script><script src="app.js"></script></head></html>"#
        let already = try Self.fixture(
            ["manifest_version": 2, "name": "Marked", "version": "1.0", "background": ["page": "background.html"]],
            files: ["background.html": marked])
        defer { try? FileManager.default.removeItem(at: already.work) }
        #expect(ExtensionStore.writeOverlayManifest(in: already.overlay, from: already.package, prelude: Self.prelude))
        page = try Self.text("background.html", in: already.overlay)
        #expect(page == marked)
    }

    @Test func mv3WorkerStillGetsTheEntryScript() throws {
        let fixture = try Self.fixture(
            ["manifest_version": 3, "name": "Worker", "version": "1.0",
             "background": ["service_worker": "/js/background.js"]],
            files: ["js/background.js": "work();"])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        #expect(try Self.background(in: fixture.overlay)["service_worker"] as? String == "zigzag-entry.js")
        #expect(try Self.text("zigzag-entry.js", in: fixture.overlay) == "importScripts('zigzag-prelude.js', 'js/background.js');\n")
        #expect(try Self.text("zigzag-prelude.js", in: fixture.overlay) == Self.prelude)

        // A module worker keeps its imports, the prelude first.
        let module = try Self.fixture(
            ["manifest_version": 3, "name": "Module worker", "version": "1.0",
             "background": ["service_worker": "background.js", "type": "module"]],
            files: ["background.js": "export {};"])
        defer { try? FileManager.default.removeItem(at: module.work) }
        #expect(ExtensionStore.writeOverlayManifest(in: module.overlay, from: module.package, prelude: Self.prelude))
        #expect(try Self.text("zigzag-entry.js", in: module.overlay) == "import './zigzag-prelude.js';\nimport './background.js';\n")
    }

    @Test func aManifestWithNoBackgroundStillGetsPatchesAndTheConnectGuard() throws {
        let fixture = try Self.fixture(
            ["manifest_version": 2, "name": "No background", "version": "1.0", "permissions": ["storage"],
             "content_scripts": [["matches": ["https://example.com/*"], "js": ["content.js"]]]],
            files: ["content.js": "content();"])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        // No background to run a prelude, but the overlay is still made: its manifest is what patches and the language
        // fill then build on.
        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        let manifest = try Self.manifest(in: fixture.overlay)
        #expect(manifest["background"] == nil)
        #expect((manifest["permissions"] as? [String])?.contains("nativeMessaging") == true)
        let scripts = try #require((manifest["content_scripts"] as? [[String: Any]])?.first?["js"] as? [String])
        #expect(scripts == [ConnectGuard.file, "content.js"])
        #expect(FileManager.default.fileExists(atPath: fixture.overlay.appendingPathComponent(ConnectGuard.file).path))
    }

    /// A background file is looked up inside the package only. A climb out, or an absolute address, finds nothing
    /// rather than a file elsewhere on the Mac.
    @Test func backgroundsOutsideThePackageAreRefused() throws {
        let outside = try Self.fixture([:])
        defer { try? FileManager.default.removeItem(at: outside.work) }
        try #"<html><script src="outside.js"></script></html>"#.write(to: outside.work.appendingPathComponent("outside.html"), atomically: true, encoding: .utf8)
        let addresses: [[String: Any]] = [
            ["page": "../outside.html"],
            ["scripts": ["../outside.js", "app.js"]],
            ["service_worker": "../outside.js"],
            ["page": outside.work.appendingPathComponent("outside.html").path],
        ]
        for background in addresses {
            let fixture = try Self.fixture(["manifest_version": 2, "name": "Outside", "version": "1.0", "background": background],
                                           files: ["app.js": "app();"])
            defer { try? FileManager.default.removeItem(at: fixture.work) }
            #expect(!ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
            #expect(!FileManager.default.fileExists(atPath: fixture.overlay.appendingPathComponent("manifest.json").path))
        }
    }

    /// The marker records what the overlay was made from. An unpacked background page can be edited in place, so its
    /// own bytes are part of it: the next load rebuilds the copy once.
    @Test func editingAnUnpackedBackgroundPageRebuildsItsOverlay() throws {
        let fixture = try Self.fixture(
            ["manifest_version": 2, "name": "Edited page", "version": "1.0", "background": ["page": "background.html"]],
            files: ["background.html": #"<html><head><script src="app.js"></script></head></html>"#])
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        let fill = ExtensionStore.Fills(language: "language", webLocks: "locks", webLocksMark: "mark")
        func signature() -> String {
            ExtensionStore.overlaySignature(prelude: Self.prelude, patches: [], fill: fill, package: fixture.package)
        }

        let first = signature()
        #expect(signature() == first)
        try #"<html><head><script src="edited.js"></script></head></html>"#
            .write(to: fixture.package.appendingPathComponent("background.html"), atomically: true, encoding: .utf8)
        let edited = signature()
        #expect(edited != first)

        // The rebuilt overlay is the edited page, still with one prelude before its first script.
        #expect(ExtensionStore.writeOverlayManifest(in: fixture.overlay, from: fixture.package, prelude: Self.prelude))
        let page = try Self.text("background.html", in: fixture.overlay)
        #expect(page.contains("edited.js"))
        #expect(page.components(separatedBy: "data-zigzag-prelude").count == 2)
    }

    /// A service worker and a persistent MV2 page stay awake. An MV2 event page must be able to suspend, so it gets the
    /// prelude but not the native keepalive port.
    @Test func anMV2EventPageMaySuspendWhileAWorkerStaysAwake() {
        let awake = ExtensionShims.backgroundPrelude(keepsAlive: true)
        let eventPage = ExtensionShims.backgroundPrelude(keepsAlive: false)
        #expect(awake.contains(ExtensionShims.nativeKeepAlive))
        #expect(!eventPage.contains(ExtensionShims.nativeKeepAlive))
        #expect(!eventPage.contains(ExtensionShims.keepAliveHost))
        // The rest of the prelude, the WebSocket stand-in included, still runs in the page.
        #expect(eventPage.contains("class WebSocket"))

        #expect(ExtensionShims.keepsAlive(manifest: ["background": ["service_worker": "worker.js"]]))
        #expect(ExtensionShims.keepsAlive(manifest: ["background": ["page": "background.html"]]))
        #expect(ExtensionShims.keepsAlive(manifest: ["background": ["scripts": ["background.js"]]]))
        #expect(!ExtensionShims.keepsAlive(manifest: ["background": ["page": "background.html", "persistent": false]]))
        #expect(!ExtensionShims.keepsAlive(manifest: ["background": ["scripts": ["background.js"], "persistent": false]]))
        #expect(!ExtensionShims.keepsAlive(manifest: ["name": "No background"]))
    }
}

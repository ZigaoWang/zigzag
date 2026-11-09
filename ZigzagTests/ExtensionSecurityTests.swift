import Foundation
import Testing
import WebKit
@testable import Zigzag

/// What keeps an extension inside its lines: the files its package may hold, and what Zigzag opens for it.
@MainActor
struct ExtensionSecurityTests {
    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionSecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Zips a folder's contents as a package would be, with ditto, which keeps symbolic links as links.
    private static func zip(_ folder: URL, to file: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, file.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
    }

    @Test func packageOfPlainFilesUnpacks() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data(#"{"version": "1.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("png".utf8).write(to: source.appendingPathComponent("icons/16.png"))
        let file = work.appendingPathComponent("package.zip")
        try Self.zip(source, to: file)

        let out = work.appendingPathComponent("out")
        #expect(ExtensionStore.extract(file, into: out))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("icons/16.png").path))
    }

    @Test func packageWithASymbolicLinkIsRefused() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"version": "1.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        // A link to a file outside the package, which the extension could then fetch as one of its own.
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("hosts.txt").path, withDestinationPath: "/etc/hosts")
        let file = work.appendingPathComponent("package.zip")
        try Self.zip(source, to: file)

        let out = work.appendingPathComponent("out")
        #expect(!ExtensionStore.extract(file, into: out))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func folderWithALinkedFolderOrHardLinkIsRefused() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let outside = work.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)

        let linkedFolder = work.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.appendingPathComponent("up").path, withDestinationPath: work.path)
        #expect(!ExtensionStore.holdsOnlyItsOwnFiles(linkedFolder))

        let hardLinked = work.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: hardLinked, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: outside, to: hardLinked.appendingPathComponent("copy.txt"))
        #expect(!ExtensionStore.holdsOnlyItsOwnFiles(hardLinked))

        let plain = work.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: plain.appendingPathComponent("nested/file.js"))
        #expect(ExtensionStore.holdsOnlyItsOwnFiles(plain))
    }

    /// A small extension's context, read from a manifest in a temporary folder.
    private static func context(_ manifest: [String: Any] = [:]) async throws -> WKWebExtensionContext {
        let folder = try temporaryFolder()
        var full: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0"]
        full.merge(manifest) { $1 }
        try JSONSerialization.data(withJSONObject: full).write(to: folder.appendingPathComponent("manifest.json"))
        return WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
    }

    @Test func privateTabsTellExtensionsNothing() async throws {
        let context = try await Self.context()
        let url = URL(string: "https://example.com/private")!
        let everyday = Tab(url: url, title: "Everyday", spaceID: UUID())
        #expect(everyday.url(for: context) == url)
        #expect(everyday.title(for: context) == "Everyday")
        #expect(everyday.shouldGrantPermissionsOnUserGesture(for: context))

        let hidden = Tab(url: url, title: "Private", spaceID: UUID())
        hidden.privateStore = .nonPersistent()
        #expect(hidden.url(for: context) == nil)
        #expect(hidden.title(for: context) == nil)
        #expect(hidden.webView(for: context) == nil)
        #expect(!hidden.shouldGrantPermissionsOnUserGesture(for: context))
        #expect(ExtensionHost.shared.actions(for: hidden).isEmpty)
        #expect(ExtensionHost.shared.menuItems(for: hidden).isEmpty)
    }

    @Test func captureIsOfTheTabYouUsedItOn() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let tab = UUID(), other = UUID()
        let start = Date()
        var use = ExtensionUse()
        let closed: (ObjectIdentifier) -> Bool = { _ in false }
        // Never used: nothing.
        #expect(!use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: true, windowOpen: closed, now: start))

        use.invoked(id, tabID: tab, origin: "https://music.example", at: start)
        #expect(use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: false, windowOpen: closed, now: start.addingTimeInterval(2)))
        // Another tab, or the same tab gone to another site: not that use.
        #expect(!use.mayCapture(id, tabID: other, origin: "https://music.example", popupShown: true, windowOpen: closed, now: start.addingTimeInterval(2)))
        #expect(!use.mayCapture(id, tabID: tab, origin: "https://bank.example", popupShown: true, windowOpen: closed, now: start.addingTimeInterval(2)))
        #expect(!use.mayCapture(id, tabID: tab, origin: nil, popupShown: true, windowOpen: closed, now: start.addingTimeInterval(2)))
        // Later on, only while its popup, or the window it opened in answer, is still open.
        let later = start.addingTimeInterval(ExtensionUse.captureWindow + 1)
        #expect(!use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: false, windowOpen: closed, now: later))
        #expect(use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: true, windowOpen: closed, now: later))
        let window = ObjectIdentifier(NSObject())
        #expect(!use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: false, windowOpen: { $0 == window }, now: later))
        use.openedWindow(id, window)
        #expect(use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: false, windowOpen: { $0 == window }, now: later))
        #expect(!use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: false, windowOpen: closed, now: later))
        // Another extension used on that tab is no use of this one.
        #expect(!use.mayCapture("ponmlkjihgfedcbaponmlkjihgfedcba", tabID: tab, origin: "https://music.example", popupShown: true, windowOpen: closed, now: start))

        use.forget(id)
        #expect(!use.mayCapture(id, tabID: tab, origin: "https://music.example", popupShown: true, windowOpen: closed, now: start))
    }

    @Test func aGestureCountsForAMoment() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let start = Date()
        var use = ExtensionUse()
        #expect(!use.hasGesture(id, now: start))
        use.touched(id, at: start)
        #expect(use.hasGesture(id, now: start.addingTimeInterval(1)))
        #expect(!use.hasGesture(id, now: start.addingTimeInterval(ExtensionUse.gestureWindow + 1)))
        #expect(!use.hasGesture("ponmlkjihgfedcbaponmlkjihgfedcba", now: start.addingTimeInterval(1)))
        // Using it on a tab is a gesture too.
        use.invoked(id, tabID: UUID(), origin: nil, at: start.addingTimeInterval(10))
        #expect(use.hasGesture(id, now: start.addingTimeInterval(11)))
    }

    @Test func captureFollowsSiteSettings() {
        let url = URL(string: "https://www.music.example/song")!
        #expect(BridgeTabCapture.siteAllows(url, offSites: [], hasAccess: true, allSites: false))
        #expect(BridgeTabCapture.siteAllows(url, offSites: [], hasAccess: false, allSites: true))
        #expect(!BridgeTabCapture.siteAllows(url, offSites: [], hasAccess: false, allSites: false))
        // Extensions off on the site, or on the site it's under: never, whatever access says.
        #expect(!BridgeTabCapture.siteAllows(url, offSites: ["music.example"], hasAccess: true, allSites: true))
        #expect(!BridgeTabCapture.siteAllows(URL(string: "https://player.music.example/")!, offSites: ["music.example"], hasAccess: true, allSites: true))
        #expect(BridgeTabCapture.siteAllows(URL(string: "https://notmusic.example/")!, offSites: ["music.example"], hasAccess: true, allSites: true))
    }

    @Test func onlyAServiceWorkerGetsTheSocketStandIn() {
        #expect(ExtensionProfile.usesWebSocketShim(manifest: ["background": ["service_worker": "background.js"]]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: ["background": ["scripts": ["background.js"]]]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: ["background": ["page": "background.html"]]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: ["name": "No background"]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: nil))
    }
}

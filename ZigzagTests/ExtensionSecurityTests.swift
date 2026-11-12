import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Waits for a web view's page to finish loading.
@MainActor
private final class PageLoad: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    func wait() async throws {
        if done { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

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
        #expect(Profiles.shared.default.extensions.actions(for: hidden).isEmpty)
        let menu = NSMenu()
        menu.addItem(withTitle: "An extension's item WebKit put in", action: nil, keyEquivalent: "")
        Profiles.shared.default.extensions.addMenuItems(for: hidden, to: menu)
        #expect(menu.items.isEmpty)
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

    /// The ways real extensions capture, step by step (#45): Shazam captures from its popup the moment it opens;
    /// Sound Booster's popup or background names the tab with getMediaStreamId and its offscreen page asks for it.
    @Test func captureFlowsOfRealExtensions() {
        let shazam = "mmioliijnhnoblpgimnlajmefafdfilb", booster = "plmlopfeeobajiecodiggabcihohcnge"
        let tab = UUID(), site = "https://music.example"
        let click = Date()
        let closed: (ObjectIdentifier) -> Bool = { _ in false }
        var use = ExtensionUse()
        use.invoked(shazam, tabID: tab, origin: site, at: click)
        use.invoked(booster, tabID: tab, origin: site, at: click)
        // Shazam's popup page runs before Zigzag has shown it: the click alone counts.
        #expect(use.mayCapture(shazam, tabID: tab, origin: site, popupShown: false, windowOpen: closed, now: click.addingTimeInterval(0.1)))
        // Sound Booster's slider, moved a minute later in its popup that's still open: its background names the tab.
        let slider = click.addingTimeInterval(60)
        #expect(use.mayCapture(booster, tabID: tab, origin: site, popupShown: true, windowOpen: closed, now: slider))
        #expect(!use.mayCapture(booster, tabID: tab, origin: site, popupShown: false, windowOpen: closed, now: slider))
        // Its offscreen page asks for the named tab a moment later: the stream ID is what counts there, not the popup.
        let expires = slider.addingTimeInterval(10)
        #expect(BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: booster, expires: expires, namedOrigin: site, origin: site,
                                                  isPrivate: false, now: slider.addingTimeInterval(1)))
        // Never another extension's, a late one, a tab gone to another site, or a private one.
        #expect(!BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: shazam, expires: expires, namedOrigin: site, origin: site,
                                                   isPrivate: false, now: slider.addingTimeInterval(1)))
        #expect(!BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: booster, expires: expires, namedOrigin: site, origin: site,
                                                   isPrivate: false, now: expires.addingTimeInterval(1)))
        #expect(!BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: booster, expires: expires, namedOrigin: site, origin: "https://bank.example",
                                                   isPrivate: false, now: slider.addingTimeInterval(1)))
        #expect(!BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: booster, expires: expires, namedOrigin: nil, origin: nil,
                                                   isPrivate: false, now: slider.addingTimeInterval(1)))
        #expect(!BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: booster, expires: expires, namedOrigin: site, origin: site,
                                                   isPrivate: true, now: slider.addingTimeInterval(1)))
        // Shazam asks for no sites at all: on every site you let it reach, its capture goes ahead (Chrome's needs no
        // host permission). An extension with only activeTab has the site once you click it, as WebKit grants it.
        let url = URL(string: "https://www.music.example/song")!
        #expect(BridgeTabCapture.siteAllows(url, offSites: [], hasAccess: false, allSites: true))
        #expect(BridgeTabCapture.siteAllows(url, offSites: [], hasAccess: true, allSites: false))
        #expect(!BridgeTabCapture.siteAllows(url, offSites: ["music.example"], hasAccess: true, allSites: true))
    }

    /// Tabs come with their site's icon only while open, not private, and readable by the extension: never one from
    /// history or the icon cache, which would tell where you've been (#45).
    @Test func tabIconsOnlyForOpenTabsTheExtensionCanRead() throws {
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let open = [
            BridgeFavicons.OpenTab(url: "https://video.example/watch", icon: icon, isPrivate: false, mayRead: true),
            BridgeFavicons.OpenTab(url: "https://bank.example/", icon: icon, isPrivate: false, mayRead: false),
            BridgeFavicons.OpenTab(url: "https://secret.example/", icon: icon, isPrivate: true, mayRead: true),
            BridgeFavicons.OpenTab(url: "https://blank.example/", icon: nil, isPrivate: false, mayRead: true),
        ]
        let found = BridgeFavicons.icons(for: ["https://video.example/watch", "https://bank.example/", "https://secret.example/",
                                               "https://blank.example/", "https://visited-once.example/", nil], among: open)
        #expect(found.map { $0 != nil } == [true, false, false, false, false, false])
        let url = try #require(BridgeFavicons.dataURL(icon, side: BridgeFavicons.side))
        #expect(url.hasPrefix("data:image/png;base64,"))
        let data = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == BridgeFavicons.side && bitmap.pixelsHigh == BridgeFavicons.side)
    }

    /// The page sees the tap's message handler only while a capture of it is live; with none, it goes again.
    @Test func pagesSeeTheTapHandlerOnlyWhileCapturing() async throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<p>hi</p>", baseURL: URL(string: "https://example.com/"))
        try await loaded.wait()
        func seen() async throws -> Bool {
            try await webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.zigzagTap") as? String == "object"
        }
        #expect(try await !seen())
        let capture = BridgeTabCapture(host: Profiles.shared.default.extensions)
        capture.listen(in: webView)
        capture.listen(in: webView)
        #expect(try await seen())
        capture.stopListeningWhereDone()
        #expect(try await !seen())
    }

    @Test func morePermissionsAreAskedForOnlyWhenTheyMatter() {
        let requested = Set(["history", "storage", "alarms", "tabCapture", "webRequestAuthProvider", "contextMenus"].map(WKWebExtension.Permission.init(rawValue:)))
        let (asked, quiet) = ExtensionHost.sort(requested)
        #expect(Set(asked.map(\.rawValue)) == ["history", "tabCapture", "webRequestAuthProvider"])
        #expect(Set(quiet.map(\.rawValue)) == ["storage", "alarms", "contextMenus"])
        // Everything the bridge opens that reaches your data or the network is asked for.
        for permission in ["history", "downloads", "downloads.open", "proxy", "tabCapture", "webRequest", "webRequestAuthProvider",
                           "nativeMessaging", "management", "cookies", "bookmarks", "topSites", "userScripts"] {
            #expect(ExtensionReport.askedPermissions.contains(permission), "\(permission)")
        }
    }

    @Test func theQuestionNamesWhatItWouldGet() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        #expect(ExtensionReport(requesting: ["tabCapture"], id: id).abilities.map(\.text) == ["Hear the sound of tabs you use it on"])
        #expect(ExtensionReport(requesting: ["downloads", "downloads.open"], id: id).abilities.map(\.text) == ["Download files and open them"])
        #expect(ExtensionReport(requesting: ["history", "topSites"], id: id).abilities.map(\.text) == ["Read and change your browsing history"])
        // One with no words of its own still shows.
        #expect(ExtensionReport(requesting: ["debugger"], id: id).abilities.map(\.text) == ["Use more of Zigzag’s features"])
        #expect(ExtensionReport(requesting: ["webRequest", "webRequestAuthProvider"], id: id).abilities.count == 1)
    }

    @Test func onlyAServiceWorkerGetsTheSocketStandIn() {
        #expect(ExtensionShims.usesWebSocketShim(manifest: ["background": ["service_worker": "background.js"]]))
        #expect(!ExtensionShims.usesWebSocketShim(manifest: ["background": ["scripts": ["background.js"]]]))
        #expect(!ExtensionShims.usesWebSocketShim(manifest: ["background": ["page": "background.html"]]))
        #expect(!ExtensionShims.usesWebSocketShim(manifest: ["name": "No background"]))
        #expect(!ExtensionShims.usesWebSocketShim(manifest: nil))
    }
}

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

    /// A zip made byte by byte, as an attacker would: names, kinds and flags exactly as given, stored, no compression.
    private struct CraftedZip {
        struct Item { var name: String; var data = Data(); var mode: UInt32 = 0o100644; var flags: UInt16 = 0; var method: UInt16 = 0; var claimedSize: UInt32? = nil }
        var items: [Item]

        var data: Data {
            var out = Data(), index = Data()
            func u16(_ value: UInt16, _ into: inout Data) { withUnsafeBytes(of: value.littleEndian) { into.append(contentsOf: $0) } }
            func u32(_ value: UInt32, _ into: inout Data) { withUnsafeBytes(of: value.littleEndian) { into.append(contentsOf: $0) } }
            for item in items {
                let name = Data(item.name.utf8), crc = PackageZip.crc32([UInt8](item.data)), offset = UInt32(out.count)
                u32(0x0403_4B50, &out); u16(20, &out); u16(item.flags, &out); u16(item.method, &out); u16(0, &out); u16(0, &out)
                u32(crc, &out); u32(UInt32(item.data.count), &out); u32(item.claimedSize ?? UInt32(item.data.count), &out)
                u16(UInt16(name.count), &out); u16(0, &out); out.append(name); out.append(item.data)
                u32(0x0201_4B50, &index); u16(0x0314, &index); u16(20, &index); u16(item.flags, &index); u16(item.method, &index)
                u16(0, &index); u16(0, &index); u32(crc, &index); u32(UInt32(item.data.count), &index); u32(item.claimedSize ?? UInt32(item.data.count), &index)
                u16(UInt16(name.count), &index); u16(0, &index); u16(0, &index); u16(0, &index); u16(0, &index)
                u32(item.mode << 16, &index); u32(offset, &index); index.append(name)
            }
            let start = UInt32(out.count)
            out.append(index)
            u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(UInt16(items.count), &out); u16(UInt16(items.count), &out)
            u32(UInt32(index.count), &out); u32(start, &out); u16(0, &out)
            return out
        }
    }

    @Test func craftedPackagesThatReachOutsideAreRefusedBeforeAnythingIsWritten() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let manifest = CraftedZip.Item(name: "manifest.json", data: Data(#"{"version": "1.0"}"#.utf8))
        let escapes: [(String, [CraftedZip.Item])] = [
            ("climbs out", [manifest, .init(name: "../escaped.txt", data: Data("x".utf8))]),
            ("climbs out deeper in", [manifest, .init(name: "js/../../escaped.txt", data: Data("x".utf8))]),
            ("absolute", [manifest, .init(name: work.appendingPathComponent("escaped.txt").path, data: Data("x".utf8))]),
            ("backslashes", [manifest, .init(name: "..\\escaped.txt", data: Data("x".utf8))]),
            // A link, then a file written through it: the classic way out of a folder.
            ("link", [manifest, .init(name: "out", data: Data(work.path.utf8), mode: 0o120755), .init(name: "out/escaped.txt", data: Data("x".utf8))]),
            ("link to a file", [manifest, .init(name: "hosts.txt", data: Data("/etc/hosts".utf8), mode: 0o120644)]),
            ("device", [manifest, .init(name: "dev", mode: 0o020644)]),
            ("the same file twice", [manifest, .init(name: "a.js", data: Data("1".utf8)), .init(name: "A.js", data: Data("2".utf8))]),
            ("a file that is also a folder", [manifest, .init(name: "a", data: Data("1".utf8)), .init(name: "a/b.js", data: Data("2".utf8))]),
            ("encrypted", [manifest, .init(name: "a.js", data: Data("1".utf8), flags: 1)]),
            ("an unknown packing", [manifest, .init(name: "a.js", data: Data("1".utf8), method: 12)]),
            ("a dot part", [manifest, .init(name: "./a.js", data: Data("1".utf8))]),
            ("an empty part", [manifest, .init(name: "a//b.js", data: Data("1".utf8))]),
        ]
        for (what, items) in escapes {
            let out = work.appendingPathComponent("out-\(UUID().uuidString)")
            #expect(!ExtensionStore.extract(CraftedZip(items: items).data, into: out), "\(what)")
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(what)")
            #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("escaped.txt").path), "\(what)")
        }
        // Bytes that don't match their checksum.
        var damaged = CraftedZip(items: [manifest, .init(name: "a.js", data: Data("hello".utf8))]).data
        let hello = try #require(damaged.range(of: Data("hello".utf8)))
        damaged[hello.lowerBound] ^= 0x20
        #expect(throws: PackageZip.Failure.damaged("a.js")) { try PackageZip.unpack(damaged, into: work.appendingPathComponent("damaged")) }

        // The same packages made plainly unpack as they are.
        let plain = CraftedZip(items: [manifest, .init(name: "js/", mode: 0o040755), .init(name: "js/a.js", data: Data("let a = 1;".utf8))])
        let out = work.appendingPathComponent("plain")
        #expect(ExtensionStore.extract(plain.data, into: out))
        #expect(try String(contentsOf: out.appendingPathComponent("js/a.js"), encoding: .utf8) == "let a = 1;")
        // Never into a folder that already holds something.
        #expect(throws: PackageZip.Failure.malformed) { try PackageZip.unpack(plain.data, into: out) }
    }

    @Test func namesStayInsideTheFolder() {
        #expect(PackageZip.safePath("js/a.js") == ["js", "a.js"])
        #expect(PackageZip.safePath("icons/") == ["icons"])
        #expect(PackageZip.safePath("..a/b..c") == ["..a", "b..c"])
        for name in ["", "/etc/hosts", "../a", "a/../b", "a/./b", "a//b", "a\\b", "a\u{0}b", "a\nb", "..", "."] {
            #expect(PackageZip.safePath(name) == nil, "\(name)")
        }
    }

    @Test(.enabled(if: CRXPackageTests.hasFixture)) func theRealPackageUnpacksAsDittoWould() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let package = try CRXPackage(try CRXPackageTests.fixture, expectedID: CRXPackageTests.id)
        let ours = work.appendingPathComponent("ours"), theirs = work.appendingPathComponent("ditto")
        #expect(ExtensionStore.extract(package.zip, into: ours))
        let file = work.appendingPathComponent("package.zip")
        try package.zip.write(to: file)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", file.path, theirs.path]
        try ditto.run()
        ditto.waitUntilExit()
        func files(_ folder: URL) -> [String: Data] {
            let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            // ditto reads macOS's own extras (__MACOSX, ._ files) as attributes rather than files.
            let plain = all.filter { !$0.hasDirectoryPath && !$0.path.contains("__MACOSX") && !$0.lastPathComponent.hasPrefix("._") }
            return Dictionary(uniqueKeysWithValues: plain.compactMap { url in
                (try? Data(contentsOf: url)).map { (url.path.replacingOccurrences(of: folder.path, with: ""), $0) }
            })
        }
        let unpacked = files(ours)
        #expect(!unpacked.isEmpty)
        #expect(unpacked == files(theirs))
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

    /// A page click counts for sidePanel.open only via the extension's content script there, with the call within a second.
    @Test func aPageClickCarriesOverThroughAContentScript() {
        let start = Date()
        var use = ExtensionUse()
        let soon = start.addingTimeInterval(0.3)
        // No page click: a message alone opens nothing.
        #expect(!use.carriesPageGesture(messageHosts: ["docs.example.com"], messageAt: start, now: soon))
        use.pageGesture(on: "Docs.Example.com", at: start)
        #expect(use.carriesPageGesture(messageHosts: ["docs.example.com"], messageAt: start.addingTimeInterval(0.1), now: soon))
        // Another page's script, a message before the click, or a late call: no.
        #expect(!use.carriesPageGesture(messageHosts: ["other.example.com"], messageAt: start.addingTimeInterval(0.1), now: soon))
        #expect(!use.carriesPageGesture(messageHosts: ["docs.example.com"], messageAt: start.addingTimeInterval(-2), now: soon))
        #expect(!use.carriesPageGesture(messageHosts: ["docs.example.com"], messageAt: start.addingTimeInterval(0.1),
                                        now: start.addingTimeInterval(ExtensionUse.pageGestureWindow + 0.1)))
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
        // A private one only for an extension allowed in private windows (#353).
        #expect(BridgeTabCapture.namedStreamHolds(givenTo: booster, askedBy: booster, expires: expires, namedOrigin: site, origin: site,
                                                  isPrivate: true, seesPrivate: true, now: slider.addingTimeInterval(1)))
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
        // An extension allowed in private windows gets the private tab's icon too (#353).
        let allowed = BridgeFavicons.icons(for: ["https://secret.example/", "https://bank.example/"], among: open, seesPrivate: true)
        #expect(allowed.map { $0 != nil } == [true, false])
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

    @Test func theBridgeAnswersOnlyWhatWasGrantedAndIsStillAskedFor() {
        let forever = Date.distantFuture
        let declared: (required: Set<String>, optional: Set<String>) = (["history", "proxy"], ["bookmarks"])
        let granted: [WKWebExtension.Permission: Date] = [.init(rawValue: "history"): forever, .init(rawValue: "bookmarks"): forever,
                                                          .init(rawValue: "downloads"): forever, .init(rawValue: "topSites"): .distantPast]
        #expect(ExtensionBridge.allows("history", declared: declared, granted: granted))
        #expect(ExtensionBridge.allows("bookmarks", declared: declared, granted: granted))
        // Its files ask for it, and the person never allowed it: no.
        #expect(!ExtensionBridge.allows("proxy", declared: declared, granted: granted))
        // Allowed once, no longer asked for, or allowed only for a while that's over: no.
        #expect(!ExtensionBridge.allows("downloads", declared: declared, granted: granted))
        #expect(!ExtensionBridge.allows("topSites", declared: (["topSites"], []), granted: granted))
    }

    @Test func aFolderThatNowAsksForMoreWaitsForThePerson() async throws {
        // WebKit leaves out what it doesn't know (the bridge's history, proxy, user scripts), so they're added from the
        // package's own manifest; Zigzag's own native messaging and scripting only as that manifest asks.
        let context = try await Self.context(["permissions": ["storage", "history", "userScripts", "nativeMessaging", "scripting"]])
        let requested = Set(context.webExtension.requestedPermissions.map(\.rawValue))
        #expect(!requested.contains("history"))
        let approved = ExtensionHost.askedPermissions(requested: requested.union(["nativeMessaging", "scripting"]), declared: ["storage", "history", "userScripts"])
        #expect(approved == ["storage", "history", "userScripts"])
        #expect(ExtensionHost.askedPermissions(requested: ["storage", "nativeMessaging"], declared: ["storage", "nativeMessaging"]) == ["storage", "nativeMessaging"])

        // The same folder, changed: now it asks for a proxy and a companion app too. What was recorded is all it has.
        let now = ExtensionHost.askedPermissions(requested: ["storage", "nativeMessaging"], declared: ["storage", "history", "userScripts", "proxy", "nativeMessaging"])
        #expect(now.subtracting(approved) == ["proxy", "nativeMessaging"])
        let restored = Dictionary(uniqueKeysWithValues: approved.union(["nativeMessaging"]).map { (WKWebExtension.Permission(rawValue: $0), Date.distantFuture) })
        #expect(!ExtensionBridge.allows("proxy", declared: (["storage", "history", "userScripts", "proxy", "nativeMessaging"], []), granted: restored))
        #expect(ExtensionBridge.allows("history", declared: (["storage", "history", "userScripts", "proxy", "nativeMessaging"], []), granted: restored))
    }

    @Test func zigzagsOwnGrantsAreRecordedOnlyAsApproved() {
        // Native messaging is granted to every extension for the bridge; recorded, it would pass for the person's yes.
        let live: Set<String> = ["storage", "history", "nativeMessaging", "scripting"]
        #expect(ExtensionHost.recordedGrants(live, before: [], approving: []) == ["storage", "history"])
        #expect(ExtensionHost.recordedGrants(live, before: [], approving: ["nativeMessaging"]) == ["storage", "history", "nativeMessaging"])
        #expect(ExtensionHost.recordedGrants(live, before: ["scripting"], approving: []) == ["storage", "history", "scripting"])
        // A record from before: the bridge's permissions its manifest asks for are added, once; Zigzag's own two stay
        // only as its manifest asks.
        #expect(ExtensionHost.migratedGrants(["storage", "nativeMessaging", "scripting"], declared: ["storage", "history", "userScripts"])
                == ["storage", "history", "userScripts"])
        #expect(ExtensionHost.migratedGrants(["storage", "nativeMessaging"], declared: ["storage", "nativeMessaging"]) == ["storage", "nativeMessaging"])
    }
}

// MARK: Install sheets

extension ExtensionSecurityTests {
    /// Install sheet limits come from compatibility claims; partial and supported rows are silent and never raw-name lines.
    @Test func limitsComeFromClaimsNotFromWebKit() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0",
                                       "permissions": ["storage", "sidePanel"]]
        let context = try await Self.context(manifest)
        let report = ExtensionReport(extension: context.webExtension, manifest: manifest, id: id)
        #expect(report.limits.isEmpty)
        // sidePanel is supported by the claims, so "Side panel" is gone.
        #expect(!report.limits.map(\.text).contains("Side panel"))
    }

    /// A permission unknown to both WebKit and the claims is reported once by its raw name.
    @Test func aPermissionNoClaimCoversIsReportedNotDropped() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0",
                                       "permissions": ["alarms", "totallyMadeUpPermission"],
                                       "optional_permissions": ["anotherUnknownPermission"]]
        let context = try await Self.context(manifest)
        let report = ExtensionReport(extension: context.webExtension, manifest: manifest, id: id)
        // WebKit supports alarms, so it's not a limit.
        #expect(!report.limits.map(\.source).contains("alarms"))
        let madeUp = try #require(report.limits.first { $0.source == "totallyMadeUpPermission" })
        #expect(madeUp.catalogKey == nil)
        #expect(madeUp.text == "totallyMadeUpPermission")
        #expect(madeUp.status == .unsupported)
        #expect(report.limits.filter { $0.source == "totallyMadeUpPermission" }.count == 1)
        let optional = try #require(report.limits.first { $0.source == "anotherUnknownPermission" })
        #expect(optional.catalogKey == nil)
        #expect(optional.text == "anotherUnknownPermission")
        // MV2 host patterns sit in permissions; they aren't unclaimed permissions.
        let legacy: [String: Any] = ["manifest_version": 2, "name": "Test", "version": "1.0",
                                     "permissions": ["storage", "https://*.example.com/*", "<all_urls>"]]
        let legacyContext = try await Self.context(legacy)
        let legacyReport = ExtensionReport(extension: legacyContext.webExtension, manifest: legacy, id: id)
        #expect(!legacyReport.limits.map(\.source).contains("https://*.example.com/*"))
        #expect(!legacyReport.limits.map(\.source).contains("<all_urls>"))
    }

    /// Lines the claims still mark as gaps read as before; partial rows are silent for now.
    @Test func theInstallSheetLimitsReadAsTheyDidBefore() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let permissions = ["sidePanel", "identity", "identity.email", "notifications", "downloads", "downloads.open",
                           "idle", "offscreen", "webRequestBlocking", "history", "bookmarks", "topSites", "tabGroups",
                           "fontSettings", "tts", "ttsEngine", "geolocation", "clipboardRead", "management", "privacy",
                           "debugger", "pageCapture", "desktopCapture", "tabCapture", "system.display", "power", "proxy"]
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0",
                                       "permissions": permissions, "omnibox": ["keyword": "test"]]
        let context = try await Self.context(manifest)
        let report = ExtensionReport(extension: context.webExtension, manifest: manifest, id: id)
        #expect(Set(report.limits.map(\.text)) == [
            "Tab groups", "Blocking requests the old way", "Debugging pages", "Font settings", "Privacy settings",
            "Saving pages", "Recording your screen", "Reading aloud", "Your location",
            "Reading what you copy",
        ])
        // Supported rows, and partial ones (management, tabCapture, proxy, identity.email), have no sheet lines yet.
        for gone in ["Side panel", "Your browsing history", "Your bookmarks", "Your top sites", "Notifications",
                     "Downloads", "Knowing when you’re away", "Background audio and clipboard", "Recording tabs",
                     "Display information", "Keeping your Mac awake", "Signing in with your account",
                     "Tab video capture", "Managing other extensions", "Proxy scripts (PAC)", "Address bar keyword"] {
            #expect(!report.limits.map(\.text).contains(gone), "\(gone)")
        }
    }

    /// Update sheets list only newly added limits, by catalog key.
    @Test func anUpdateShowsOnlyLimitsItAdds() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let old: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0",
                                  "permissions": ["privacy", "tabGroups"]]
        var new = old
        new["version"] = "1.1"
        new["permissions"] = ["privacy", "tabGroups", "fontSettings"]
        let context = try await Self.context(new)
        let report = ExtensionReport(newIn: context.webExtension, manifest: new, comparedTo: old, id: id)
        #expect(report.limits.map(\.text) == ["Font settings"])
        // Removing one isn't an addition.
        var fewer = new
        fewer["permissions"] = ["privacy"]
        let removed = ExtensionReport(newIn: context.webExtension, manifest: fewer, comparedTo: old, id: id)
        #expect(removed.limits.isEmpty)
    }

    /// Permissions a shim covers produce no lines; partial rows add none.
    @Test func aShimCoveredPermissionIsNotReported() async throws {
        let manifest: [String: Any] = ["manifest_version": 3, "name": "1Password", "version": "1.0",
                                       "permissions": ["management", "privacy", "storage"]]
        let context = try await Self.context(manifest)
        let report = ExtensionReport(extension: context.webExtension, manifest: manifest,
                                     id: ExtensionStore.onePasswordID)
        #expect(report.limits.isEmpty)
    }

    /// A mostly working permission doesn't put its whole namespace in the sheet, so "tabs" isn't reported broken for one member.
    @Test func aCommonPermissionNamesItsGapNotItsNamespace() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Tab Tool", "version": "1.0",
                                       "permissions": ["tabs", "cookies", "declarativeNetRequest", "storage"]]
        let context = try await Self.context(manifest)
        let report = ExtensionReport(extension: context.webExtension, manifest: manifest, id: id)
        #expect(report.limits.isEmpty)
        #expect(!report.limits.map(\.text).contains("Some tab actions"))
        #expect(!report.limits.map(\.text).contains("Cookie details"))
        #expect(!report.limits.map(\.text).contains("Blocking rules"))
    }

    /// The later-request sheet shows the same limits as the install sheet.
    @Test func theQuestionShowsTheSameLimitsAsTheSheet() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        #expect(ExtensionReport(requesting: ["privacy", "tabGroups"], id: id).limits.map(\.text)
                == ["Tab groups", "Privacy settings"])
        #expect(ExtensionReport(requesting: ["sidePanel"], id: id).limits.isEmpty)
    }

    /// The install sheet describes each risky permission, like the later-request sheet.
    @Test func theInstallSheetNamesEveryRiskyPermission() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let expected: [(String, String)] = [
            ("tabCapture", "Hear the sound of tabs you use it on"), ("clipboardRead", "Read what you copy"),
            ("webRequest", "See what sites load as you browse"), ("identity", "Open sign-in pages and get what sites send back"),
            ("scripting", "Run its own scripts on the sites it can access"), ("offscreen", "Run hidden pages of its own in the background"),
        ]
        for (permission, line) in expected {
            let manifest: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0", "permissions": [permission]]
            let context = try await Self.context(manifest)
            let report = ExtensionReport(extension: context.webExtension, manifest: manifest, id: id)
            #expect(report.abilities.map(\.text).contains(line), "\(permission)")
            // Requested later: same text, once.
            #expect(ExtensionReport(requesting: [permission], id: id).abilities.map(\.text) == [line], "\(permission)")
        }
    }
}

// MARK: Packages and updates

extension ExtensionSecurityTests {
    /// Entries can't claim more than the file size or the packed bytes could inflate to.
    @Test func entriesCantClaimHugeSizes() {
        let manifest = CraftedZip.Item(name: "manifest.json", data: Data(#"{"version": "1.0"}"#.utf8))
        let huge = CraftedZip(items: [manifest, .init(name: "a.bin", data: Data([0x03, 0x00]), method: 8, claimedSize: UInt32(PackageZip.maxEntrySize + 1))])
        #expect(throws: PackageZip.Failure.tooLarge) { try PackageZip.entries(huge.data) }
        let inflated = CraftedZip(items: [manifest, .init(name: "a.bin", data: Data([0x03, 0x00]), method: 8, claimedSize: 400 << 20)])
        #expect(throws: PackageZip.Failure.damaged("a.bin")) { try PackageZip.entries(inflated.data) }
        let fair = CraftedZip(items: [manifest, .init(name: "a.bin", data: Data(repeating: 1, count: 100), method: 8, claimedSize: 50_000)])
        #expect((try? PackageZip.entries(fair.data))?.count == 2)
    }

    /// Versions name folders: digits and dots only, as Chrome allows.
    @Test func versionsAreOnlyNumbers() {
        for good in ["1", "1.0", "2.10.3", "1.2.3.4", "65535.0"] { #expect(ExtensionStore.isValidVersion(good), "\(good)") }
        for bad in ["", ".", "..", "1..2", "1.", ".1", "1/2", "..\\x", "1.2.3.4.5", "1.0-beta", "65536", "1:2", " 1", "١"] {
            #expect(!ExtensionStore.isValidVersion(bad), "\(bad)")
        }
    }

    /// Updates that change the search engine, Zigzag pages, or external messaging wait for approval.
    @Test func updatesThatTakeOverMoreWait() {
        let old: [String: Any] = ["permissions": ["storage"], "chrome_settings_overrides": ["search_provider": ["search_url": "https://good.example/?q={searchTerms}"]]]
        #expect(!ExtensionStore.asksForMore(old, than: old))
        var moved = old
        moved["chrome_settings_overrides"] = ["search_provider": ["search_url": "https://evil.example/?q={searchTerms}"]]
        #expect(ExtensionStore.asksForMore(moved, than: old))
        var newTab = old
        newTab["chrome_url_overrides"] = ["newtab": "tab.html"]
        #expect(ExtensionStore.asksForMore(newTab, than: old))
        var connectable = old
        connectable["externally_connectable"] = ["matches": ["https://*.example/*"]]
        #expect(ExtensionStore.asksForMore(connectable, than: old))
        // Removing one needs no approval.
        #expect(!ExtensionStore.asksForMore(["permissions": ["storage"]], than: old))
        #expect(ExtensionStore.asksForMore(["permissions": ["storage", "tabs"]], than: old))
    }

    /// MV2 webRequestBlocking is recorded so sign-in handling keeps working; folder records migrate without taking more from disk.
    @Test func blockingIsRecordedAndFoldersMigrateFromTheRecord() {
        #expect(ExtensionHost.askedPermissions(requested: ["webRequest"], declared: ["webRequest", "webRequestBlocking"]).contains("webRequestBlocking"))
        // Extensions approved before blocking was recorded (Tampermonkey) get it without asking.
        #expect(ExtensionHost.carryingBlocking(["storage", "webRequest"], declared: ["webRequest", "webRequestBlocking"]) == ["storage", "webRequest", "webRequestBlocking"])
        #expect(ExtensionHost.carryingBlocking(["storage"], declared: ["webRequest", "webRequestBlocking"]) == nil)
        #expect(ExtensionHost.carryingBlocking(["webRequest", "webRequestBlocking"], declared: ["webRequest", "webRequestBlocking"]) == nil)
        #expect(ExtensionHost.migratedGrants(["storage", "nativeMessaging"], declared: []) == ["storage"])
        // A folder keeps native messaging and scripting from its record while the manifest asks; nothing beyond the record is added.
        #expect(ExtensionHost.migratedGrants(["storage", "nativeMessaging", "scripting"], declared: ["storage", "nativeMessaging", "scripting", "history"],
                                             fromFolder: true) == ["storage", "nativeMessaging", "scripting"])
        #expect(ExtensionHost.migratedGrants(["storage", "nativeMessaging", "scripting"], declared: ["storage"], fromFolder: true) == ["storage"])
        #expect(ExtensionHost.migratedGrants(["storage"], declared: ["storage", "nativeMessaging"], fromFolder: true) == ["storage"])
    }
}

extension ExtensionSecurityTests {
    /// The sign-in window shows the current site.
    @Test func signInWindowsShowTheSite() {
        #expect(BridgeIdentity.shownAddress(URL(string: "https://accounts.example.com/o/oauth2?x=1")) == "accounts.example.com")
        #expect(BridgeIdentity.shownAddress(URL(string: "https://login.example:8443/")) == "login.example:8443")
        #expect(BridgeIdentity.shownAddress(URL(string: "http://login.example/")) == "http://login.example")
        #expect(BridgeIdentity.shownAddress(URL(string: "about:blank")) == "about:")
        #expect(BridgeIdentity.shownAddress(nil) == "")
    }
}

extension ExtensionSecurityTests {
    /// Side panels and offscreen pages stay on extension pages.
    @Test func panelsStayOnTheExtensionsPages() {
        let base = URL(string: "webkit-extension://abcdefghijklmnopabcdefghijklmnop/")!
        #expect(ExtensionPageGuard.staysInExtension(URL(string: "webkit-extension://abcdefghijklmnopabcdefghijklmnop/panel.html?tabId=3"), base: base))
        #expect(ExtensionPageGuard.staysInExtension(URL(string: "about:blank"), base: base))
        #expect(!ExtensionPageGuard.staysInExtension(URL(string: "webkit-extension://ponmlkjihgfedcbaponmlkjihgfedcba/panel.html"), base: base))
        #expect(!ExtensionPageGuard.staysInExtension(URL(string: "https://evil.example/login"), base: base))
        #expect(!ExtensionPageGuard.staysInExtension(URL(string: "data:text/html,hi"), base: base))
        #expect(!ExtensionPageGuard.staysInExtension(nil, base: base))
    }

    /// Clicks and key presses count as gestures; key repeats and mouse moves don't.
    @Test func onlyRealPressesAreGestures() {
        #expect(ExtensionUse.isGesture(.leftMouseDown, isRepeat: false))
        #expect(ExtensionUse.isGesture(.keyDown, isRepeat: false))
        #expect(!ExtensionUse.isGesture(.keyDown, isRepeat: true))
        #expect(!ExtensionUse.isGesture(.mouseMoved, isRepeat: false))
        var use = ExtensionUse()
        use.touched("a")
        #expect(use.hasGesture("a") && !use.hasGesture("b"))
    }
}

extension ExtensionSecurityTests {
    /// Folder extensions show their permissions before they're added, like store packages.
    @Test func foldersAreReviewedBeforeTheyAreAdded() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Folder", "version": "1.0", "permissions": ["history", "clipboardRead"],
                                       "host_permissions": ["<all_urls>"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let reviewed = try #require(await ExtensionStore.reviewUnpacked(folder))
        let lines = reviewed.report.abilities.map(\.text)
        #expect(lines.contains("Read and change what you see on every website"))
        #expect(lines.contains("Read and change your browsing history"))
        #expect(lines.contains("Read what you copy"))
        let empty = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(await ExtensionStore.reviewUnpacked(empty) == nil)
    }
}

/// permissions.request for sites (#489): what site access covers is granted, the rest asked about in the more-access
/// sheet; what you allow is kept until permissions.remove or another site access choice.
@MainActor
struct ExtensionPermissionRequestTests {
    private let id = "permission-request-test"

    @Test func sitesOutsideAccessAreAskedAbout() throws {
        let pattern = { (s: String) in try WKWebExtension.MatchPattern(string: s) }
        let all = try pattern("*://*/*"), github = try pattern("*://*.github.com/*")
        let ublacklist = try pattern("https://ublacklist.github.io/*"), example = try pattern("https://example.com/*")
        let bank = try pattern("*://bank.example/*"), inBank = try pattern("https://bank.example/*")
        // Declared as optional (*://*/*): any site is asked about, except one where extensions are off.
        #expect(ExtensionHost.patternsToAsk([ublacklist, example, inBank], declared: [all], denied: [bank]) == [ublacklist, example])
        // A site it never declared is never asked about.
        #expect(ExtensionHost.patternsToAsk([example], declared: [github], denied: []).isEmpty)
        // Every site is asked about with an off site: that site stays denied.
        #expect(ExtensionHost.patternsToAsk([all], declared: [all], denied: [bank]) == [all])
    }

    @Test func theSheetNamesTheSites() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        #expect(ExtensionReport(requesting: [], patterns: ["https://ublacklist.github.io/*"], id: id).abilities.map(\.text)
                == ["Read and change what you see on ublacklist.github.io"])
        #expect(ExtensionReport(requesting: [], patterns: ["*://*/*"], id: id).abilities.map(\.text)
                == ["Read and change what you see on every website"])
        #expect(ExtensionReport(requesting: [], patterns: ["http://localhost/*"], id: id).abilities.map(\.text)
                == ["Read and change what you see on localhost"])
        #expect(ExtensionReport(requesting: ["history"], patterns: ["https://example.com/*"], id: id).abilities.count == 2)
    }

    @Test func theSheetsSubtitleWrapsInsteadOfTruncating() {
        let header = DialogHeader(title: "Site Request Probe wants more access", subtitle: "Allow it only if it needs this for what you just asked it to do.")
        let oneLine = header.height(for: 280)
        header.wrapsSubtitle = true
        #expect(header.height(for: 280) > oneLine)
        #expect(header.subtitle.lineBreakMode == .byWordWrapping)
    }

    @Test func allowedSitesAreGrantedUnderAnySiteAccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0","optional_host_permissions":["*://*/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        let requested = [try WKWebExtension.MatchPattern(string: "https://ublacklist.github.io/*")]
        let site = try #require(URL(string: "https://ublacklist.github.io/rulesets/"))
        for access: ExtensionInstalls.SiteAccess? in [nil, .click, .sites] {
            ExtensionHost.applySiteAccess(access, approved: [], sites: ["example.com"], requested: requested, offSites: [], approvesActiveTab: false, to: context)
            #expect(context.permissionStatus(for: site) == .grantedExplicitly, "\(String(describing: access))")
        }
        // A site where extensions are off stays off.
        ExtensionHost.applySiteAccess(nil, approved: [], sites: [], requested: requested, offSites: ["ublacklist.github.io"], approvesActiveTab: false, to: context)
        #expect(context.permissionStatus(for: site) == .deniedExplicitly)
    }

    @Test func removingForgetsOnlyWhatWasAskedFor() {
        let recorded = ExtensionInstalls.State(grantedPermissions: ["history", "storage", "activeTab"], grantedMatchPatterns: ["*://*.google.com/*"],
                                               requestedMatchPatterns: ["https://ublacklist.github.io/*"])
        let removed = ExtensionHost.removedGrants(permissions: ["history", "activeTab"], patterns: ["https://ublacklist.github.io/*", "*://*.google.com/*"],
                                                  recorded: recorded, granted: (["storage"], []))
        #expect(removed.permissions == ["history"])
        #expect(removed.patterns == ["https://ublacklist.github.io/*"])
        // Granted again by Zigzag's own change by the time it's looked at: nothing is forgotten.
        let regranted = ExtensionHost.removedGrants(permissions: [], patterns: ["https://ublacklist.github.io/*"], recorded: recorded,
                                                    granted: ([], ["https://ublacklist.github.io/*"]))
        #expect(regranted.patterns.isEmpty)
    }

    @Test func anotherSiteAccessChoiceStartsOver() {
        let library = Library.shared
        let info = library.addProfile(name: "Permission request test")
        let installs = Profiles.shared.profile(info.id).installs
        defer {
            installs.remove(id)
            library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
        }
        installs.save(ExtensionInstalls.State(grantedPermissions: [], grantedMatchPatterns: [], requestedMatchPatterns: ["https://ublacklist.github.io/*"]), for: id)
        installs.setSiteAccess(id, .all)
        #expect(installs.state(id)?.requestedMatchPatterns == ["https://ublacklist.github.io/*"])
        installs.chooseSiteAccess(id, .click)
        #expect(installs.state(id)?.requestedMatchPatterns == nil)
    }
}

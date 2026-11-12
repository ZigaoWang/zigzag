import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Sites installed as apps (#165): the app Zigzag makes, the links between it and Zigzag, where links in its window
/// go, and that removing one never touches anything Zigzag didn't make.
@MainActor
struct WebAppTests {
    let host = "wang.zigao.zigzag"
    let profile = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WebAppTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func icon() -> CGImage { WebAppIcon.render(nil, name: "Example")! }

    private func spec(id: String? = nil, name: String = "Example", launcher: URL) -> WebAppBundle.Spec {
        let url = URL(string: "https://example.com/")!
        return WebAppBundle.Spec(id: id ?? WebApps.makeID(url: url, profileID: profile), name: name, url: url, host: host,
                                 hostPath: "/Applications/Zigzag.app", launcher: launcher, icns: WebAppIcon.icns(from: icon())!,
                                 missingHostMessage: "Gone")
    }

    /// A stand-in for the launcher: any small executable will do for what's checked here.
    private func fakeLauncher(in dir: URL) -> URL {
        let file = dir.appendingPathComponent("launcher")
        try? Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: file)
        return file
    }

    // MARK: Ids and links

    @Test func idIsStableAndDependsOnSiteAndProfile() {
        let url = URL(string: "https://github.com/")!
        let id = WebApps.makeID(url: url, profileID: profile)
        #expect(WebApps.isValidID(id))
        #expect(id == WebApps.makeID(url: url, profileID: profile))
        #expect(id != WebApps.makeID(url: URL(string: "https://gitlab.com/")!, profileID: profile))
        #expect(id != WebApps.makeID(url: url, profileID: UUID()))
        #expect(WebApps.bundleIdentifier(host: host, id: id) == "wang.zigao.zigzag.app.\(id)")
    }

    @Test func linksRoundTrip() {
        let id = "0123456789abcdef"
        let open = WebAppLink.make(.open, id: id)
        #expect(open.absoluteString == "zigzag-webapp://open/0123456789abcdef")
        #expect(WebAppLink.parse(open)?.action == .open)
        #expect(WebAppLink.parse(open)?.id == id)
        #expect(WebAppLink.parse(WebAppLink.make(.close, id: id))?.action == .close)
    }

    @Test func otherLinksAreRefused() {
        for text in ["https://open/0123456789abcdef", "zigzag-webapp://launch/0123456789abcdef", "zigzag-webapp://open/xyz",
                     "zigzag-webapp://open/0123456789ABCDEF", "zigzag-webapp://open/0123456789abcdef0", "zigzag-webapp://open/",
                     "zigzag-webapp://open/0123456789abcdef?url=https://evil.com", "zigzag-webapp://open/../0123456789abcdef"] {
            #expect(WebAppLink.parse(URL(string: text)!) == nil, "\(text)")
        }
    }

    // MARK: Where links go

    @Test func sameSiteStaysAndOtherSitesGoToTheBrowser() {
        let here = URL(string: "https://en.wikipedia.org/wiki/Mac")!
        #expect(!WebApps.opensInBrowser(URL(string: "https://en.wikipedia.org/wiki/Apple")!, from: here, isLinkClick: true))
        #expect(!WebApps.opensInBrowser(URL(string: "https://de.wikipedia.org/wiki/Apple")!, from: here, isLinkClick: true))
        #expect(WebApps.opensInBrowser(URL(string: "https://www.apple.com/")!, from: here, isLinkClick: true))
        #expect(WebApps.opensInBrowser(URL(string: "https://example.co.uk/")!, from: URL(string: "https://other.co.uk/")!, isLinkClick: true))
    }

    @Test func signInsAndRedirectsStay() {
        let here = URL(string: "https://www.notion.so/")!
        #expect(!WebApps.opensInBrowser(URL(string: "https://accounts.google.com/o/oauth2")!, from: here, isLinkClick: true))
        // What the site does on its own (a redirect, a form) isn't a link you clicked.
        #expect(!WebApps.opensInBrowser(URL(string: "https://www.apple.com/")!, from: here, isLinkClick: false))
        #expect(!WebApps.opensInBrowser(URL(string: "mailto:a@b.c")!, from: here, isLinkClick: true))
    }

    @Test func stripShowsTheNameOnTheSiteAndTheHostElsewhere() {
        let app = WebApp(id: "0123456789abcdef", name: "GitHub", url: URL(string: "https://github.com/")!, profileID: profile,
                         spaceID: UUID(), bundlePath: "/x.app", created: Date())
        #expect(WebAppWindowController.stripTitle(app: app, page: URL(string: "https://github.com/issues")!) == "GitHub")
        #expect(WebAppWindowController.stripTitle(app: app, page: URL(string: "https://gist.github.com/")!) == "GitHub")
        #expect(WebAppWindowController.stripTitle(app: app, page: URL(string: "https://accounts.google.com/")!) == "accounts.google.com")
    }

    // MARK: The app Zigzag makes

    @Test func infoPlistNamesTheAppAndItsZigzag() {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = spec(launcher: fakeLauncher(in: dir))
        let plist = WebAppBundle.infoPlist(spec)
        #expect(plist["CFBundleIdentifier"] as? String == "wang.zigao.zigzag.app.\(spec.id)")
        #expect(plist["CFBundleName"] as? String == "Example")
        #expect(plist["CFBundleDisplayName"] as? String == "Example")
        #expect(plist["CFBundleExecutable"] as? String == WebApps.launcherName)
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["LSUIElement"] as? Bool == false)
        #expect(plist["ZigzagWebAppID"] as? String == spec.id)
        #expect(plist["ZigzagHostBundleIdentifier"] as? String == host)
        #expect(plist["ZigzagHostPath"] as? String == "/Applications/Zigzag.app")
    }

    @Test func iconFileHoldsEverySize() {
        let data = WebAppIcon.icns(from: icon())!
        let contents = WebAppIcon.icnsContents(data)
        #expect(contents.map(\.type) == WebAppIcon.icnsEntries.map(\.type))
        for (entry, found) in zip(WebAppIcon.icnsEntries, contents) {
            #expect(found.width == entry.pixels && found.height == entry.pixels, "\(entry.type)")
        }
        #expect(Set(contents.map(\.width)) == [16, 32, 64, 128, 256, 512, 1024])
        // The file says its own length.
        let length = data.prefix(8).suffix(4).reduce(0) { $0 << 8 | Int($1) }
        #expect(length == data.count)
    }

    @Test func iconFillsAFullSquareAndSetsAShapeOnWhite() {
        func solid(_ side: Int, alpha: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.red.withAlphaComponent(alpha).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()!
        }
        #expect(WebAppIcon.isOpaqueSquare(solid(180, alpha: 1)))
        #expect(!WebAppIcon.isOpaqueSquare(solid(180, alpha: 0)))
        let rendered = WebAppIcon.render(solid(180, alpha: 1), name: "A")!
        #expect(rendered.width == 1024 && rendered.height == 1024)
    }

    @Test func iconsAreRankedLargestSquareFirst() {
        let base = URL(string: "https://example.com/")!
        let favicon = WebAppIcon.Candidate(url: URL(string: "https://example.com/favicon.ico")!, size: 32, fillsSquare: false)
        let touch = WebAppIcon.Candidate(url: URL(string: "https://example.com/touch.png")!, size: 180, fillsSquare: true)
        let big = WebAppIcon.Candidate(url: URL(string: "https://example.com/512.png")!, size: 512, fillsSquare: false)
        let ranked = WebAppIcon.ranked([favicon, touch, big], origin: base)
        #expect(ranked.first == big)
        #expect(ranked[1].url == touch.url || ranked[1].url.path == "/apple-touch-icon.png")
        #expect(ranked.last == favicon)
        #expect(WebAppIcon.largestSize("16x16 192x192 48x48") == 192)
    }

    @Test func nameComesFromWhatTheSiteCallsItself() {
        let url = URL(string: "https://www.example.com/")!
        var facts = WebAppIcon.PageFacts(title: "Example Domain")
        #expect(WebAppIcon.name(facts: facts, manifestName: nil, manifestShortName: nil, url: url) == "Example Domain")
        #expect(WebAppIcon.name(facts: facts, manifestName: "Example Site", manifestShortName: "Example", url: url) == "Example")
        facts.appTitle = "Ex"
        #expect(WebAppIcon.name(facts: facts, manifestName: "Example Site", manifestShortName: "Example", url: url) == "Ex")
        #expect(WebAppIcon.name(facts: WebAppIcon.PageFacts(), manifestName: nil, manifestShortName: nil, url: url) == "example.com")
        // A title that ends in the site's name gives just that name.
        let wiki = URL(string: "https://en.wikipedia.org/wiki/Mac_(computer)")!
        #expect(WebAppIcon.name(facts: WebAppIcon.PageFacts(title: "Mac (computer) - Wikipedia"), manifestName: nil, manifestShortName: nil, url: wiki) == "Wikipedia")
        #expect(WebAppIcon.siteName(inTitle: "Inbox (3) | Fastmail", url: URL(string: "https://app.fastmail.com/")!) == "Fastmail")
        #expect(WebAppIcon.siteName(inTitle: "Pull requests · GitHub", url: URL(string: "https://github.com/pulls")!) == "GitHub")
        #expect(WebAppIcon.siteName(inTitle: "Just a page", url: wiki) == nil)
    }

    @Test func manifestIconsResolveAgainstTheManifest() {
        let json = #"{"name":"Wikipedia","short_name":"Wiki","icons":[{"src":"icons/192.png","sizes":"192x192"},{"src":"/mono.png","sizes":"512x512","purpose":"monochrome"},{"src":"https://cdn.example/m.png","sizes":"512x512","purpose":"maskable"}]}"#
        let read = WebAppIcon.manifest(Data(json.utf8), base: URL(string: "https://en.wikipedia.org/w/manifest.json")!)
        #expect(read.name == "Wikipedia")
        #expect(read.shortName == "Wiki")
        #expect(read.icons.map(\.url.absoluteString) == ["https://en.wikipedia.org/w/icons/192.png", "https://cdn.example/m.png"])
        #expect(read.icons.last?.fillsSquare == true)
    }

    @Test func fileNamesAreSafe() {
        #expect(WebApps.fileName(for: "  ../Mail: Inbox/Work ", fallback: "x") == "-Mail- Inbox-Work")
        #expect(WebApps.fileName(for: "   ", fallback: "example.com") == "example.com")
        #expect(WebApps.fileName(for: String(repeating: "a", count: 100), fallback: "x").count == 60)
    }

    @Test func installsASignedAppThatReplacesItsEarlierCopy() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Apps", isDirectory: true)
        let first = try WebAppBundle.install(spec(launcher: fakeLauncher(in: dir)), in: folder, replacing: nil)
        #expect(first.lastPathComponent == "Example.app")
        let contents = first.appendingPathComponent("Contents")
        #expect(FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/\(WebApps.launcherName)").path))
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/AppIcon.icns").path))
        #expect(WebApps.isMadeByZigzag(first, id: spec(launcher: dir).id, host: host))
        // Signed: codesign checks it whole.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", "--strict", first.path]
        try check.run()
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        // Renamed and installed again: one app, under its new name.
        let second = try WebAppBundle.install(spec(name: "Renamed", launcher: fakeLauncher(in: dir)), in: folder, replacing: first)
        #expect(second.lastPathComponent == "Renamed.app")
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Renamed.app"])
    }

    @Test func anotherAppWithTheSameNameIsLeftAlone() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Apps", isDirectory: true)
        let stranger = folder.appendingPathComponent("Example.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: stranger.appendingPathComponent("Info.plist"))
        let made = try WebAppBundle.install(spec(launcher: fakeLauncher(in: dir)), in: folder, replacing: nil)
        #expect(made.lastPathComponent == "Example 2.app")
        #expect(try String(contentsOf: stranger.appendingPathComponent("Info.plist"), encoding: .utf8) == "mine")
    }

    // MARK: Removing

    @Test func onlyAppsZigzagMadeCountAsItsOwn() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Apps", isDirectory: true)
        let spec = spec(launcher: fakeLauncher(in: dir))
        let made = try WebAppBundle.install(spec, in: folder, replacing: nil)
        #expect(WebApps.isMadeByZigzag(made, id: spec.id, host: host))
        // Another id, another Zigzag, not an id at all.
        #expect(!WebApps.isMadeByZigzag(made, id: "ffffffffffffffff", host: host))
        #expect(!WebApps.isMadeByZigzag(made, id: spec.id, host: "wang.zigao.zigzag.dev"))
        #expect(!WebApps.isMadeByZigzag(made, id: "../..", host: host))
        // A link to it.
        let link = dir.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: made)
        #expect(!WebApps.isMadeByZigzag(link, id: spec.id, host: host))
        // Zigzag itself, a plain folder, an app without the marker, one whose marker was copied into another app.
        #expect(!WebApps.isMadeByZigzag(made, id: spec.id, host: host, zigzag: made))
        #expect(!WebApps.isMadeByZigzag(dir, id: spec.id, host: host))
        #expect(!WebApps.isMadeByZigzag(Bundle.main.bundleURL, id: spec.id, host: host))
        let other = folder.appendingPathComponent("Other.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(!WebApps.isMadeByZigzag(folder.appendingPathComponent("Other.app"), id: spec.id, host: host))
        try FileManager.default.copyItem(at: made.appendingPathComponent("Contents/Resources/\(WebApps.markerName)"),
                                         to: other.appendingPathComponent(WebApps.markerName))
        #expect(!WebApps.isMadeByZigzag(folder.appendingPathComponent("Other.app"), id: spec.id, host: host))
    }

    @Test func removingLeavesWhatZigzagDidntMake() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WebAppStore(file: dir.appendingPathComponent("WebApps.json"))
        // A record pointing at someone else's app: removing it only drops the record.
        let stranger = dir.appendingPathComponent("Stranger.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let id = "0123456789abcdef"
        store.save(WebApp(id: id, name: "Stranger", url: URL(string: "https://example.com/")!, profileID: profile, spaceID: UUID(),
                          bundlePath: dir.appendingPathComponent("Stranger.app").path, created: Date()))
        store.remove(id)
        #expect(store.apps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: stranger.path))
        // Read back from disk.
        #expect(WebAppStore(file: dir.appendingPathComponent("WebApps.json")).apps.isEmpty)
    }

    @Test func zigzagCarriesTheLauncher() {
        #expect(FileManager.default.isExecutableFile(atPath: WebAppInstaller.launcher.path))
    }
}

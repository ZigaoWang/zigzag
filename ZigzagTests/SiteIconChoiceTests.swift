import AppKit
import Testing
@testable import Zigzag

/// One site, one icon: its own small icon over its home-screen one, in every tab, whatever the order things load in (#386).
@MainActor
struct SiteIconChoiceTests {
    private static func svg(_ shape: String) -> String {
        let text = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'>\(shape)</svg>"
        return "data:image/svg+xml;base64," + Data(text.utf8).base64EncodedString()
    }
    /// A green circle for the site's own icon, a red square for its home-screen icon.
    private let own = ["rel": "icon", "type": "image/svg+xml", "href": svg("<circle cx='16' cy='16' r='14' fill='#00c000'/>")]
    private let touch = ["rel": "apple-touch-icon", "sizes": "180x180", "href": svg("<rect width='32' height='32' fill='#e00000'/>")]

    private func resolve(_ page: String, _ links: [[String: String]]) async -> NSImage? {
        await withCheckedContinuation { done in
            FaviconStore.shared.resolve(pageURL: URL(string: page)!, links: links) { done.resume(returning: $0) }
        }
    }

    /// Green or red, by the icon's middle pixel.
    private func color(_ image: NSImage?) -> String {
        guard let rep = image?.representations.first as? NSBitmapImageRep,
              let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return "none" }
        return c.greenComponent > 0.5 && c.redComponent < 0.4 ? "green" : c.redComponent > 0.5 && c.greenComponent < 0.4 ? "red" : "other"
    }

    private func files(_ host: String) -> (own: URL, standIn: URL) {
        (Paths.favicons.appendingPathComponent(host + ".png"), Paths.favicons.appendingPathComponent(host + ".touch.png"))
    }

    private func clear(_ host: String) {
        FaviconStore.finishWriting()
        let (a, b) = files(host)
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
    }

    @Test func theOwnIconWinsWhicheverOrderTheLinksComeIn() async {
        let host = "own-first-\(UUID().uuidString.prefix(8).lowercased()).test"
        defer { clear(host) }
        #expect(color(await resolve("https://\(host)/", [touch, own])) == "green")
        #expect(color(await resolve("https://\(host)/", [own, touch])) == "green")
        FaviconStore.finishWriting()
        #expect(FileManager.default.fileExists(atPath: files(host).own.path))
        #expect(!FileManager.default.fileExists(atPath: files(host).standIn.path))
    }

    @Test func everyTabOnTheSiteWearsItsOwnIcon() async {
        let host = "tabs-\(UUID().uuidString.prefix(8).lowercased()).test"
        defer { clear(host) }
        #expect(color(await resolve("https://\(host)/", [own, touch])) == "green")
        // A deep page whose own icon didn't load this time, only the home-screen one: still the site's own.
        #expect(color(await resolve("https://\(host)/repo/issues", [touch])) == "green")
        // Early in a load, before the head is read: the site's own, not a fresh guess at /favicon.ico.
        #expect(color(await resolve("https://\(host)/repo/pulls", [])) == "green")
        // And a tab restored without loading.
        #expect(color(FaviconStore.shared.cachedIcon(for: URL(string: "https://\(host)/repo")!)) == "green")
    }

    @Test func aHomeScreenIconStandsInOnlyUntilTheSiteShowsItsOwn() async {
        let host = "stand-in-\(UUID().uuidString.prefix(8).lowercased()).test"
        defer { clear(host) }
        #expect(color(await resolve("https://\(host)/deep/page", [touch])) == "red")
        FaviconStore.finishWriting()
        #expect(FileManager.default.fileExists(atPath: files(host).standIn.path))
        #expect(!FileManager.default.fileExists(atPath: files(host).own.path))
        // A deep page with the site's own icon replaces the stand-in, which a deep page's icon never does otherwise.
        #expect(color(await resolve("https://\(host)/other/page", [own, touch])) == "green")
        FaviconStore.finishWriting()
        #expect(FileManager.default.fileExists(atPath: files(host).own.path))
        #expect(!FileManager.default.fileExists(atPath: files(host).standIn.path))
        #expect(color(FaviconStore.shared.cachedIcon(for: URL(string: "https://\(host)/")!)) == "green")
        // Back to only the home-screen icon: it never takes over again.
        #expect(color(await resolve("https://\(host)/", [touch])) == "green")
        FaviconStore.finishWriting()
        #expect(!FileManager.default.fileExists(atPath: files(host).standIn.path))
    }

    /// A red square saved the way icons were before #386.
    private func oldIcon(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(red: 0.9, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func iconsKeptBeforeTheUpdateStayUntilTheSiteShowsItsOwn() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("old-icons-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let host = "old-icons-\(UUID().uuidString.prefix(8).lowercased()).test"
        defer { clear(host) }
        try oldIcon(at: folder.appendingPathComponent(host + ".png"))
        try oldIcon(at: folder.appendingPathComponent("imported.test.png"))

        FaviconStore.keepOldIconsAsStandIns(in: folder)
        // Nothing thrown away: every icon is still there, as a stand-in.
        #expect(fm.fileExists(atPath: folder.appendingPathComponent(host + ".touch.png").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("imported.test.touch.png").path))
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent(host + ".png").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent(".own-first").path))
        // Only once: an own icon saved after the update stays one.
        try oldIcon(at: folder.appendingPathComponent("later.test.png"))
        FaviconStore.keepOldIconsAsStandIns(in: folder)
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("later.test.png").path))

        // In the real folder, the old icon shows until a page of the site shows its own, which then wins.
        try fm.moveItem(at: folder.appendingPathComponent(host + ".touch.png"), to: files(host).standIn)
        #expect(color(FaviconStore.shared.cachedIcon(for: URL(string: "https://\(host)/")!)) == "red")
        #expect(color(await resolve("https://\(host)/page", [own, touch])) == "green")
        FaviconStore.finishWriting()
        #expect(fm.fileExists(atPath: files(host).own.path))
        #expect(!fm.fileExists(atPath: files(host).standIn.path))
    }
}

// MARK: - One service per port

extension SiteIconChoiceTests {
    private func files(for url: URL) -> (own: URL, standIn: URL)? {
        guard let key = FaviconStore.siteKey(for: url) else { return nil }
        let base = key.replacingOccurrences(of: "/", with: "_")
        return (Paths.favicons.appendingPathComponent(base + ".png"), Paths.favicons.appendingPathComponent(base + ".touch.png"))
    }

    private func clear(_ urls: [URL]) {
        FaviconStore.finishWriting()
        for url in urls {
            guard let files = files(for: url) else { continue }
            try? FileManager.default.removeItem(at: files.own)
            try? FileManager.default.removeItem(at: files.standIn)
        }
    }

    @Test func aPortIsPartOfTheSite() {
        func key(_ text: String) -> String? { FaviconStore.siteKey(for: URL(string: text)!) }
        #expect(key("http://10.0.0.10:8080/") == "10.0.0.10:8080")
        #expect(key("http://10.0.0.10:8081/") == "10.0.0.10:8081")
        // The port a scheme uses by default is the same site with or without it.
        #expect(key("http://10.0.0.10/") == "10.0.0.10")
        #expect(key("http://10.0.0.10:80/") == "10.0.0.10")
        #expect(key("https://example.com:443/") == "example.com")
        // Another port is another site, even on the same host.
        #expect(key("https://example.com:8443/") == "example.com:8443")
        // As before: www. is left out, and Google's apps stay apart.
        #expect(key("https://www.example.com:8443/") == "example.com:8443")
        #expect(key("https://www.google.com:8443/maps") == "google.com:8443/maps")
    }

    @Test func eachPortKeepsItsOwnIcon() async throws {
        let host = "favicon-ports-\(UUID().uuidString.prefix(8).lowercased()).test"
        let firstService = try #require(URL(string: "http://\(host):8080/"))
        let secondService = try #require(URL(string: "http://\(host):8081/"))
        defer { clear([firstService, secondService]) }
        // One address, two services, a different icon on each.
        #expect(color(await resolve(firstService.absoluteString, [own])) == "green")
        #expect(color(await resolve(secondService.absoluteString, [touch])) == "red")
        #expect(color(FaviconStore.shared.cachedIcon(for: firstService)) == "green")
        #expect(color(FaviconStore.shared.cachedIcon(for: secondService)) == "red")
    }

    @Test func anotherPortNeverStartsWithTheLastOneIcon() async throws {
        let host = "favicon-ports-\(UUID().uuidString.prefix(8).lowercased()).test"
        let first = try #require(URL(string: "http://\(host):8080/"))
        let second = try #require(URL(string: "http://\(host):8081/"))
        defer { clear([first, second]) }
        #expect(color(await resolve(first.absoluteString, [own])) == "green")
        #expect(FaviconStore.shared.cachedIcon(for: second) == nil)
        #expect(!Tab.keepsIcon(from: first, to: second))
        #expect(Tab.keepsIcon(from: first, to: URL(string: "http://\(host):8080/deeper")!))
        // The scheme's own port is the same site, so its icon stays across the move.
        #expect(Tab.keepsIcon(from: URL(string: "http://\(host)/")!, to: URL(string: "http://\(host):80/")!))
        // A page with no host is its scheme's.
        #expect(!Tab.keepsIcon(from: URL(string: "file:///tmp/a.html")!, to: URL(string: "about:blank")!))
    }
}

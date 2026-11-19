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
}

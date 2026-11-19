import AppKit
import Testing
@testable import Zigzag

/// A link, an address or words dropped on an address field (#182): what the page goes to.
@MainActor
struct AddressDropTests {
    private func go(_ text: String?, urls: [URL] = []) -> String? {
        AddressDrop.destination(urls: urls, text: text, engine: .duckDuckGo)?.url.absoluteString
    }

    /// A schemeless address carries an http fallback; links and searches don't.
    @Test func anAddressWithoutASchemeCarriesItsHTTPFallback() {
        #expect(AddressDrop.destination(urls: [], text: "localtest.me:3600", engine: .duckDuckGo)?.httpFallback == true)
        #expect(AddressDrop.destination(urls: [URL(string: "https://localtest.me:3600")!], text: "localtest.me:3600", engine: .duckDuckGo)?
            .httpFallback == false)
        #expect(AddressDrop.destination(urls: [], text: "zigzag browser", engine: .duckDuckGo)?.httpFallback == false)
    }

    @Test func aLinkLoadsAsItIs() {
        let link = URL(string: "https://example.com/a?b=c")!
        #expect(go("Example", urls: [link]) == "https://example.com/a?b=c")
        // The first a page can open, past one it can't.
        #expect(go(nil, urls: [URL(string: "mailto:a@b.com")!, link]) == link.absoluteString)
        #expect(go(nil, urls: [URL(fileURLWithPath: "/tmp/page.html")]) == "file:///tmp/page.html")
    }

    @Test func textThatReadsAsAnAddressLoads() {
        #expect(go("wikipedia.org") == "https://wikipedia.org")
        #expect(go("  https://example.com/path \n") == "https://example.com/path")
        #expect(go("localhost:8080") == "http://localhost:8080")
        #expect(go("github.com/ZigaoWang/zigzag") == "https://github.com/ZigaoWang/zigzag")
    }

    @Test func otherTextIsSearchedFor() {
        #expect(go("zigzag browser") == "https://duckduckgo.com/?q=zigzag%20browser")
        // Not a real top-level domain, an email address: words.
        #expect(go("node.js")?.hasPrefix("https://duckduckgo.com/?q=node.js") == true)
        #expect(go("someone@example.com")?.hasPrefix("https://duckduckgo.com/") == true)
        // Over lines, one search.
        #expect(go("first line\nsecond") == "https://duckduckgo.com/?q=first%20line%20second")
    }

    @Test func nothingUsableIsRefused() {
        #expect(go(nil) == nil)
        #expect(go("   \n ") == nil)
        #expect(go("javascript:alert(1)", urls: [URL(string: "javascript:alert(1)")!]) == nil)
        #expect(go("about:blank") == nil)
    }
}

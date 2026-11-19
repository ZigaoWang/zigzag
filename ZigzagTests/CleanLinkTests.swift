import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Copy Link strips tracking parameters and writes text and HTML to the pasteboard.
@MainActor
struct CleanLinkTests {
    static let table: [(String, String)] = [
        // utm_ and click IDs on any site.
        ("https://example.com/post?utm_source=newsletter&utm_medium=email&utm_campaign=fall", "https://example.com/post"),
        ("https://www.nytimes.com/2026/11/01/a.html?smid=x&utm_source=tw&id=4", "https://www.nytimes.com/2026/11/01/a.html?smid=x&id=4"),
        ("https://shop.example/p?color=red&fbclid=IwAR0abc&size=m", "https://shop.example/p?color=red&size=m"),
        ("https://example.com/?gclid=1&gbraid=2&wbraid=3&dclid=4&msclkid=5&yclid=6", "https://example.com/"),
        ("https://blog.example/x?mc_cid=a&mc_eid=b&_hsenc=c&_hsmi=d&mkt_tok=e&vero_id=f&oly_anon_id=g&oly_enc_id=h&__s=i&s_cid=j&spm=k&igshid=l",
         "https://blog.example/x"),
        ("https://example.com/a?UTM_Source=x&b=1", "https://example.com/a?b=1"),
        // The fragment is kept.
        ("https://example.com/doc?utm_source=x#section-2", "https://example.com/doc#section-2"),
        ("https://example.com/doc?a=1&utm_term=x&b=2#top", "https://example.com/doc?a=1&b=2#top"),
        // YouTube's si goes; video, time and list stay.
        ("https://youtu.be/dQw4w9WgXcQ?si=AbCdEf123&t=42", "https://youtu.be/dQw4w9WgXcQ?t=42"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&si=xyz&t=1m2s", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&t=1m2s"),
        ("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=8d7e6f", "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"),
        // Twitter ref tags.
        ("https://twitter.com/user/status/123?ref_src=twsrc%5Etfw&ref_url=https%3A%2F%2Fa.com", "https://twitter.com/user/status/123"),
        ("https://x.com/user/status/123?s=20&t=AbC", "https://x.com/user/status/123"),
        ("https://x.com/search?q=swift&src=typed_query", "https://x.com/search?q=swift&src=typed_query"),
        // si is kept on other sites.
        ("https://example.com/find?si=3", "https://example.com/find?si=3"),
        // Already clean: unchanged, including order.
        ("https://www.google.com/search?q=hello+world&hl=en", "https://www.google.com/search?q=hello+world&hl=en"),
        ("https://www.amazon.com/Some-Book/dp/B000123/ref=sr_1_1?keywords=book&qid=1", "https://www.amazon.com/Some-Book/dp/B000123/ref=sr_1_1?keywords=book&qid=1"),
        ("https://example.com/a?z=1&a=2&flag&empty=", "https://example.com/a?z=1&a=2&flag&empty="),
        ("https://example.com/p%20q?x=%E4%BD%A0", "https://example.com/p%20q?x=%E4%BD%A0"),
        ("https://example.com/", "https://example.com/"),
        ("file:///Users/me/a.html?utm_source=x", "file:///Users/me/a.html?utm_source=x"),
    ]

    @Test func cleansKnownTrackersOnly() {
        for (dirty, clean) in Self.table {
            #expect(CleanLink.clean(URL(string: dirty)!).absoluteString == clean, "\(dirty)")
        }
    }

    @Test func pasteboardHasTheAddressAndATitledLink() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("CleanLinkTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        CleanLink.write(URL(string: "https://example.com/a?b=1&utm_source=x#c")!, title: "Tom & Jerry <3", to: board)
        #expect(board.string(forType: .string) == "https://example.com/a?b=1#c")
        #expect(board.string(forType: .html) == "<a href=\"https://example.com/a?b=1#c\">Tom &amp; Jerry &lt;3</a>")
        let rtf = try #require(board.data(forType: .rtf))
        let text = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(text.string == "Tom & Jerry <3")
        let link = text.attribute(.link, at: 0, effectiveRange: nil)
        #expect((link as? URL)?.absoluteString ?? (link as? String) == "https://example.com/a?b=1#c")
    }

    @Test func noTitleIsJustTheAddress() {
        let board = NSPasteboard(name: NSPasteboard.Name("CleanLinkTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        CleanLink.write(URL(string: "https://example.com/?fbclid=1")!, title: "  ", to: board)
        #expect(board.string(forType: .string) == "https://example.com/")
        #expect(board.data(forType: .html) == nil && board.data(forType: .rtf) == nil)
    }

    @Test func markdownUsesTheCleanAddress() {
        #expect(CleanLink.markdown(URL(string: "https://youtu.be/abc?si=x&t=5")!, title: "Video") == "[Video](https://youtu.be/abc?t=5)")
    }
}

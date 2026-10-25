import Foundation
import Testing
@testable import Zigzag

/// What the address bar treats as a place to go, and what it searches for.
@MainActor
struct AddressTests {
    @Test func addresses() {
        #expect(CommandRanker.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(CommandRanker.url(from: "example.com?q=1")?.absoluteString == "https://example.com?q=1")
        #expect(CommandRanker.url(from: "example.com#top")?.absoluteString == "https://example.com#top")
        #expect(CommandRanker.url(from: "readme.md")?.absoluteString == "https://readme.md")
        #expect(CommandRanker.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(CommandRanker.url(from: "192.168.1.1/admin")?.absoluteString == "http://192.168.1.1/admin")
        #expect(CommandRanker.url(from: "printer.local")?.absoluteString == "http://printer.local")
    }

    @Test func searches() {
        #expect(CommandRanker.url(from: "node.js") == nil)
        #expect(CommandRanker.url(from: "main.swiftui") == nil)
        #expect(CommandRanker.url(from: "user@example.com") == nil)
        #expect(CommandRanker.url(from: "foo..com") == nil)
        #expect(CommandRanker.url(from: "localhostfoo") == nil)
        #expect(CommandRanker.url(from: "hello world") == nil)
    }
}

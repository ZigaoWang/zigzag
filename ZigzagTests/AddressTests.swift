import AppKit
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
        #expect(CommandRanker.url(from: "youtube.com/@mkbhd")?.absoluteString == "https://youtube.com/@mkbhd")
    }

    @Test func aNewPinGoesLeftAndPinningTwiceChangesNothing() {
        let pins = ExtensionPins(ids: ["a", "b"]).pinning("c")
        #expect(pins.ids == ["c", "a", "b"])
        #expect(pins.pinning("a") == pins)
        #expect(pins.unpinning("a").ids == ["c", "b"])
    }

    @Test func onlyExtensionsThatAreOnUseASlot() {
        let pins = ExtensionPins(ids: ["a", "b", "c"], limit: 3)
        #expect(!pins.canPin(loaded: ["a", "b", "c", "d"]))
        #expect(pins.canPin(loaded: ["a", "b", "d"]))
    }

    @Test func theRightmostLoadedPinsShow() {
        let pins = ExtensionPins(ids: ["a", "b", "c", "d"], limit: 3)
        #expect(pins.shown(among: ["a", "b", "c", "d"]) == ["b", "c", "d"])
        #expect(pins.shown(among: ["a", "b", "d"]) == ["a", "b", "d"])
        #expect(pins.shown(among: []).isEmpty)
    }

    @Test func reorderingFillsOnlyTheVisiblePlaces() {
        // "b" is hidden or off and stays where it is.
        let pins = ExtensionPins(ids: ["a", "b", "c", "d"])
        #expect(pins.reordered(visible: ["d", "a", "c"]).ids == ["d", "b", "a", "c"])
        // "x" went away during the drag.
        #expect(pins.reordered(visible: ["c", "x", "a"]).ids == ["c", "b", "a", "d"])
    }

    @Test func oldStateWithThePinnedFieldStillDecodes() throws {
        let json = Data(#"{"version":"1.0","enabled":true,"pinned":true}"#.utf8)
        #expect(try JSONDecoder().decode(ExtensionStore.State.self, from: json).version == "1.0")
    }

    @Test func keepingDropsOnlyWhatIsNoLongerKept() {
        #expect(ExtensionPins(ids: ["a", "b", "c"]).keeping { $0 != "b" }.ids == ["a", "c"])
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

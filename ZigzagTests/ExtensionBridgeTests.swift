import Foundation
import Testing
@testable import Zigzag

/// What the extension bridge reads from history for `chrome.history`, and how it shapes values for the extension.
@MainActor
struct ExtensionBridgeTests {
    private func store() -> HistoryStore {
        let store = HistoryStore(path: ":memory:")
        let now = Date()
        store.recordVisit(url: URL(string: "https://en.wikipedia.org/wiki/Bauhaus")!, title: "Bauhaus", at: now.addingTimeInterval(-60))
        store.recordVisit(url: URL(string: "https://example.com/old")!, title: "Old page", at: now.addingTimeInterval(-10 * 86_400))
        store.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", at: now)
        return store
    }

    @Test func searchesByTextAndTimeNewestFirst() {
        let history = store()
        #expect(history.items(matching: "", from: nil, to: nil, limit: 10).map(\.entry.title) == ["GitHub", "Bauhaus", "Old page"])
        #expect(history.items(matching: "bauhaus wiki", from: nil, to: nil, limit: 10).map(\.entry.title) == ["Bauhaus"])
        #expect(history.items(matching: "", from: Date(timeIntervalSinceNow: -86_400), to: nil, limit: 10).count == 2)
        #expect(history.items(matching: "", from: nil, to: nil, limit: 1).count == 1)
        // Text that would mean something to SQL is only text.
        #expect(history.items(matching: "%", from: nil, to: nil, limit: 10).isEmpty)
    }

    @Test func idsAreStableAndFindTheirPage() {
        let history = store()
        let url = URL(string: "https://github.com/")!
        let first = history.items(matching: "github", from: nil, to: nil, limit: 1).first
        #expect(first?.id == history.item(for: url)?.id)
    }

    @Test func removesARangeAndSaysWhatWent() {
        let history = store()
        var removed: [URL]?
        history.onRemove = { removed = $0 }
        _ = history.remove(from: Date(timeIntervalSinceNow: -20 * 86_400), to: Date(timeIntervalSinceNow: -86_400))
        #expect(removed == [URL(string: "https://example.com/old")!])
        #expect(history.items(matching: "", from: nil, to: nil, limit: 10).count == 2)
    }

    @Test func valuesCrossAsJSON() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = try #require(ExtensionBridge.plain(["when": date, "count": 3, "none": nil, "list": [date]] as [String: Any?]) as? [String: Any])
        #expect(plain["when"] as? Double == 1_700_000_000_000)
        #expect(plain["count"] as? Int == 3)
        #expect(plain["none"] == nil)
        #expect((plain["list"] as? [Any])?.first as? Double == 1_700_000_000_000)
        #expect(JSONSerialization.isValidJSONObject(plain))
    }
}

extension ExtensionBridgeTests {
    /// A name an extension gives a download stays a plain file name inside Downloads.
    @Test func downloadNamesCantClimbOut() {
        #expect(BridgeDownloads.safeName("../../evil/report.pdf") == "report.pdf")
        #expect(BridgeDownloads.safeName("/etc/passwd") == "passwd")
        #expect(BridgeDownloads.safeName("..\\..\\x.txt") == "x.txt")
        #expect(BridgeDownloads.safeName(".hidden") == "hidden")
        #expect(BridgeDownloads.safeName("a:b.txt") == "a-b.txt")
    }
}

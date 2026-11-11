import Foundation
import Testing
import WebKit
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

    /// `chrome.downloads` in one profile sees that profile's downloads only, and never a private window's: what it
    /// can't see it can't erase, open or trash either.
    @Test func downloadsAreSeenOnlyInTheirOwnProfile() {
        let other = UUID()
        let first = DownloadItem(filename: "a.pdf", sourceURL: nil, isPrivate: false)
        let second = DownloadItem(filename: "b.pdf", sourceURL: nil, isPrivate: false, profile: other)
        let hidden = DownloadItem(filename: "c.pdf", sourceURL: nil, isPrivate: true)
        #expect(first.profile == Profile.defaultID)
        #expect(BridgeDownloads.sees(first, in: Profile.defaultID))
        #expect(!BridgeDownloads.sees(first, in: other))
        #expect(BridgeDownloads.sees(second, in: other))
        #expect(!BridgeDownloads.sees(second, in: Profile.defaultID))
        #expect(!BridgeDownloads.sees(hidden, in: Profile.defaultID))
        #expect(!BridgeDownloads.sees(hidden, in: other))
    }

    /// A download fetched again (one listed from before Zigzag started has no store of its own) goes in its own
    /// profile's store, never the one of whichever page is in front: that could be another profile's sign-ins.
    @Test func aDownloadIsFetchedAgainInItsOwnProfile() {
        let made = WKWebsiteDataStore.nonPersistent()
        #expect(DownloadManager.store(for: made, isPrivate: true, profile: Profile.defaultID) === made)
        #expect(DownloadManager.store(for: nil, isPrivate: false, profile: Profile.defaultID) === Profiles.shared.default.store)
        // A private window that's gone, or a profile that's been removed: nowhere to fetch it.
        #expect(DownloadManager.store(for: nil, isPrivate: true, profile: Profile.defaultID) == nil)
        #expect(DownloadManager.store(for: nil, isPrivate: false, profile: UUID()) == nil)
    }
}

/// An extension's notification is named so a click on it finds the extension again, in its own profile.
struct ExtensionNotificationKeyTests {
    private let rabby = "acmacodkjbdgmoleebolmdjonilkdbch"

    @Test func theFirstProfilesKeepTheirForm() {
        let key = ExtensionNotificationKey(profile: nil, extensionID: rabby, id: "tx-1")
        #expect(key.string == "ext|\(rabby)|tx-1")
        #expect(ExtensionNotificationKey(key.string) == key)
    }

    @Test func anotherProfilesNameIt() throws {
        let profile = try #require(UUID(uuidString: "B2222222-2222-4222-8222-222222222222"))
        let key = ExtensionNotificationKey(profile: profile, extensionID: rabby, id: "tx-1")
        #expect(key.string == "ext|B2222222-2222-4222-8222-222222222222|\(rabby)|tx-1")
        #expect(ExtensionNotificationKey(key.string) == key)
    }

    @Test func anIDMayHoldBarsAndBeEmpty() {
        #expect(ExtensionNotificationKey("ext|\(rabby)|a|b")?.id == "a|b")
        #expect(ExtensionNotificationKey("ext|\(rabby)|")?.id == "")
    }

    @Test func whatIsntAnExtensionsIsRefused() {
        #expect(ExtensionNotificationKey("site|example.com|1") == nil)
        #expect(ExtensionNotificationKey("ext|\(rabby)") == nil)
    }
}

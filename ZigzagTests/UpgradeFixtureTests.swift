import Foundation
import Testing
@testable import Zigzag

/// Files a 0.9.5 Debug build wrote (Fixtures/zigzag-0.9.5): two spaces on two profiles, pinned tabs in a folder, a live
/// folder, a favorite, a split and history. This Zigzag reads each and writes it back with nothing an older one kept
/// left out or changed.
@MainActor @Suite struct UpgradeFixtureTests {
    private static let fixtures: URL = {
        let repo = ProcessInfo.processInfo.environment["ZZ_REPO"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("ZigzagTests/Fixtures/zigzag-0.9.5", isDirectory: true)
    }()

    /// A copy to read, as JSONStore sets aside a file it can't read and the fixture must stay.
    private func copy(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpgradeFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: url)
        return url
    }

    private func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }

    /// Every key and value in `old` that isn't in `new`, by path. Keys `new` adds are fine; numbers may differ by
    /// rounding, as dates go through Date.
    private func dropped(_ old: Any, _ new: Any, at path: String = "") -> [String] {
        switch (old, new) {
        case let (old as [String: Any], new as [String: Any]):
            return old.flatMap { key, value in new[key].map { dropped(value, $0, at: "\(path).\(key)") } ?? ["\(path).\(key) is gone"] }
        case let (old as [Any], new as [Any]):
            guard old.count == new.count else { return ["\(path) had \(old.count), has \(new.count)"] }
            return zip(old, new).enumerated().flatMap { dropped($1.0, $1.1, at: "\(path)[\($0)]") }
        case let (old as NSNumber, new as NSNumber):
            return abs(old.doubleValue - new.doubleValue) < 0.001 ? [] : ["\(path) was \(old), is \(new)"]
        case let (old as String, new as String):
            return old == new ? [] : ["\(path) was \(old), is \(new)"]
        default:
            return "\(old)" == "\(new)" ? [] : ["\(path) was \(old), is \(new)"]
        }
    }

    @Test func theLibraryIsReadWhole() throws {
        let file = try copy("Library.json")
        let original = try json(Data(contentsOf: file))
        let stored = try #require(JSONStore.load(Library.Stored.self, from: file))
        #expect(stored.spaces.map(\.name) == ["Personal", "Second"])
        // What a launch does to the spaces it reads changes nothing a 0.9.5 space kept.
        #expect(stored.spaces.map(\.upgraded) == stored.spaces)
        let personal = stored.spaces[0]
        #expect(personal.bookmarks.count == 7)
        let folders = try #require(personal.folders)
        #expect(folders.map(\.name) == ["New Folder", "Local Feed"])
        #expect(folders[1].live?.items.count == 4)
        #expect(stored.favorites?.map(\.title) == ["Page 4"])
        let written = try json(#require(JSONStore.encode(stored)))
        #expect(dropped(original, written) == [])
    }

    @Test func theSessionIsReadWhole() throws {
        let file = try copy("Session.json")
        let original = try json(Data(contentsOf: file))
        let session = try #require(JSONStore.load(SessionState.self, from: file))
        #expect(session.windows.count == 1)
        #expect(session.windows[0].bookmarkTabs.count == 5)
        #expect(session.windows[0].splits?.count == 1)
        let written = try json(#require(JSONStore.encode(session)))
        #expect(dropped(original, written) == [])
    }

    @Test func profilesAndLiveFoldersAreReadWhole() throws {
        let profiles = try copy("Profiles.json")
        let original = try json(Data(contentsOf: profiles))
        let directory = try #require(JSONStore.load(ProfileDirectory.self, from: profiles))
        #expect(directory.all.compactMap(\.name).contains("Work"))
        #expect(dropped(original, try json(#require(JSONStore.encode(directory)))) == [])

        let live = try #require(JSONStore.load([UUID: LiveFolders.State].self, from: try copy("LiveFolders.json")))
        let state = try #require(live.values.first)
        #expect(state.unread == ["item1", "item2", "item3", "item4"])
        #expect(state.seen.count == 4)
        #expect(state.checked != nil)
    }

    @Test func historyIsReadWhole() throws {
        let store = HistoryStore(path: try copy("History.sqlite").path)
        let pages = store.recent(limit: 20).map(\.url.lastPathComponent)
        #expect(Set(pages) == Set((1...6).map { "p\($0).html" }))
    }
}

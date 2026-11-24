import Foundation
import Testing
@testable import Zigzag

/// Dia's sidebar (#511): each profile's pinned tabs come over in the space its bookmarks go in, split views pinned
/// side by side, favorites as favorites; what isn't a web page or a known container stays behind, and importing again
/// adds nothing twice. Read from a made-up Dia folder, never a real one.
@MainActor struct DiaImportTests {
    private final class FixtureMarker {}

    static let personalID = "1C7E4D2A-8B3F-4A51-9C60-0A1B2C3D4E01"
    static let workID = "9F0E8D7C-6B5A-4948-8776-655443322102"

    static var dia: ChromiumImporter.Browser { ChromiumImporter.browsers.first { $0.name == "Dia" }! }

    static func containers() throws -> Data {
        try Data(contentsOf: #require(Bundle(for: FixtureMarker.self).url(forResource: "dia-profile-containers", withExtension: "json")))
    }

    /// A made-up ~/Library/Application Support/Dia: two profiles, one in "Profile 1" whose Local State entry holds
    /// its ID, one in a folder named by its ID. Returns its User Data, and the names its spaces get.
    static func makeRoot() throws -> (userData: URL, personal: String, work: String) {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("dia-\(UUID().uuidString)", isDirectory: true)
        let userData = support.appendingPathComponent("User Data", isDirectory: true)
        for folder in ["Profile 1", workID] {
            try fm.createDirectory(at: userData.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        let personal = "Dia Personal \(UUID().uuidString)", work = "Dia Work \(UUID().uuidString)"
        let state: [String: Any] = ["profile": [
            "profiles_order": ["Profile 1", workID],
            "info_cache": [
                "Profile 1": ["name": personal, "dia_profile": ["id": personalID.lowercased()]],
                workID: ["name": work],
            ],
        ]]
        try JSONSerialization.data(withJSONObject: state).write(to: userData.appendingPathComponent("Local State"))
        try containers().write(to: support.appendingPathComponent(DiaImporter.fileName))
        return (userData, personal, work)
    }

    private func urls(_ rows: [ArcImporter.OpenTab]) -> [[String]] { rows.map { $0.pages.map(\.url.absoluteString) } }

    @Test func eachProfilesFavoritesPinsAndOpenTabsAreRead() throws {
        let groups = try DiaImporter.parse(Self.containers())
        #expect(groups.map(\.profileID) == [Self.personalID, Self.workID])
        let personal = groups[0], work = groups[1]
        #expect(personal.favorites.map(\.title) == ["Mail", "Calendar"])
        #expect(urls(personal.pinned) == [["https://docs.example.com/"], ["https://example.com/left", "https://example.com/right"],
                                          ["https://example.com/alone"], ["https://untitled.example.com/page"]])
        // No title: the page's host.
        #expect(personal.pinned.last?.pages.first?.title == "untitled.example.com")
        #expect(urls(personal.open) == [["https://news.example.com/"], ["https://example.com/one", "https://example.com/two"]])
        #expect(work.pinned.map(\.pages.count) == [1, 4, 1])
        #expect(work.favorites.map(\.title) == ["Mail again"])
    }

    @Test func unknownPartsStayBehind() throws {
        let groups = try DiaImporter.parse(Self.containers())
        let pages: [ArcImporter.OpenPage] = groups.flatMap { group -> [ArcImporter.OpenPage] in
            let rows: [ArcImporter.OpenTab] = group.pinned + group.open
            return group.favorites + rows.flatMap(\.pages)
        }
        let all = pages.map(\.url.absoluteString)
        // An archived container, one with no kind, a chat, an FTP page and a tab without contents or address.
        #expect(!all.contains("https://old.example.com/"))
        #expect(!all.contains("https://nokind.example.com/"))
        #expect(!all.contains { $0.hasPrefix("ftp:") })
        #expect(!pages.contains { $0.title == "Not a page" || $0.title == "No address" })
        // Another shape entirely is a problem to say, never a crash or a half import.
        #expect(throws: (any Error).self) { try DiaImporter.parse(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try DiaImporter.parse(Data("{\"version\": 9}".utf8)) }
        #expect(throws: (any Error).self) { try DiaImporter.parse(Data("not json".utf8)) }
        #expect(try DiaImporter.parse(Data("{\"containers\": [1, {\"id\": 2}, {\"id\": {\"container\": \"pinned\"}, \"tabs\": 3}]}".utf8)).isEmpty)
        // A kind written as a plain word reads the same.
        let plain = Data("{\"containers\": [{\"id\": \"pinned\", \"tabs\": [{\"contents\": [{\"variant\": {\"webContent\": {\"title\": \"A\", \"url\": \"https://a.example.com/\"}}}]}]}]}".utf8)
        #expect(try DiaImporter.parse(plain).first?.pinned.first?.pages.first?.title == "A")
    }

    @Test func profilesMapToTheirFolders() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root.userData.deletingLastPathComponent()) }
        let folders = DiaImporter.folders(for: [Self.personalID, Self.workID, "unknown-profile"], browser: Self.dia, in: root.userData)
        #expect(folders == [Self.personalID: "Profile 1", Self.workID: Self.workID])
        // One ID and one folder left over: those two.
        #expect(DiaImporter.folders(for: [Self.workID, "other"], browser: Self.dia, in: root.userData)["other"] == "Profile 1")
    }

    @Test func pinnedTabsAndFavoritesComeOver() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root.userData.deletingLastPathComponent()) }
        let result = DiaImporter.importSidebar(Self.dia, parts: [.spaces, .favorites], userData: root.userData)
        #expect(result.problems.isEmpty)
        #expect(result.spaces == 2)
        let personal = try #require(Library.shared.spaces.first { $0.name == root.personal })
        let work = try #require(Library.shared.spaces.first { $0.name == root.work })
        #expect(personal.importedFrom == "Dia/User Data/Profile 1")
        #expect(work.importedFrom == "Dia/User Data/\(Self.workID)")
        #expect(personal.bookmarks.map(\.title) == ["Docs", "Left", "Right", "Alone", "untitled.example.com"])
        #expect(work.bookmarks.map(\.title) == ["Wiki", "Q1", "Q2", "Q3", "Q4", "Q5"])
        let favorites = Library.shared.favorites(in: Profile.defaultID).map(\.url.absoluteString)
        #expect(favorites.filter { $0 == "https://mail.example.com/" }.count == 1)
        #expect(favorites.contains("https://calendar.example.com/"))
        #expect(result.bookmarks == 5 + 6 + 2)
    }

    @Test func splitTabsStaySplit() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root.userData.deletingLastPathComponent()) }
        DiaImporter.importSidebar(Self.dia, parts: [.spaces], userData: root.userData)
        func splits(_ name: String) throws -> [[String]] {
            let space = try #require(Library.shared.spaces.first { $0.name == name })
            return (space.pinnedSplits ?? []).map { split in split.ids.compactMap { id in space.bookmarks.first { $0.id == id }?.title } }
        }
        #expect(try splits(root.personal) == [["Left", "Right"]])
        #expect(try splits(root.work) == [["Q1", "Q2", "Q3", "Q4"]])
    }

    @Test func importingAgainAddsNothingTwice() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root.userData.deletingLastPathComponent()) }
        DiaImporter.importSidebar(Self.dia, parts: [.spaces, .favorites], userData: root.userData)
        let spaces = Library.shared.spaces
        let favorites = Library.shared.favorites(in: Profile.defaultID).count
        let again = DiaImporter.importSidebar(Self.dia, parts: [.spaces, .favorites], userData: root.userData)
        #expect(again.spaces == 0 && again.bookmarks == 0)
        #expect(Library.shared.spaces.count == spaces.count)
        for space in spaces {
            let now = try #require(Library.shared.space(space.id))
            #expect(now.bookmarks.map(\.url) == space.bookmarks.map(\.url))
            #expect((now.pinnedSplits ?? []).count == (space.pinnedSplits ?? []).count)
        }
        #expect(Library.shared.favorites(in: Profile.defaultID).count == favorites)
    }
}

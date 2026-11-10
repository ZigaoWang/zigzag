import Foundation
import Testing
import SQLite3
@testable import Zigzag

/// Orion's own files (#46), from made-up copies shaped like them: bookmarks with their folders, the reading list,
/// history, its Chrome Web Store extensions, and its profiles found only when its data is there.
struct OrionImportTests {
    private final class FixtureMarker {}

    static func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle(for: FixtureMarker.self).url(forResource: name, withExtension: ext))
    }

    /// A made-up ~/Library/Application Support/Orion, removed by the caller.
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeProfile(_ folder: String, in root: URL) throws -> URL {
        let profile = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("favourites", "plist"), to: profile.appendingPathComponent("favourites.plist"))
        return profile
    }

    /// The history fixture's schema and rows, written into a real SQLite file named as Orion names it.
    static func makeHistory(at file: URL) throws {
        let sql = try String(contentsOf: fixture("orion-history", "sql"), encoding: .utf8)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
    }

    @Test func bookmarksKeepTheirFoldersWithoutOrionsOwn() throws {
        let found = OrionImporter.bookmarks(at: try Self.fixture("favourites", "plist"))
        #expect(found.map(\.title) == ["Top", "First in Work", "Second in Work", "In Docs", "untitled.test", "Its folder is gone"])
        let folders = Dictionary(uniqueKeysWithValues: found.map { ($0.title, $0.folders) })
        // Favorites, Bookmarks Bar and Bookmarks are Orion's; what's in them comes to the top level.
        #expect(folders["Top"] == [])
        #expect(folders["First in Work"] == ["Work"])
        #expect(folders["In Docs"] == ["Work", "Docs"])
        #expect(folders["untitled.test"] == [])
        #expect(folders["Its folder is gone"] == [])
        // A bookmarklet isn't a page.
        #expect(!found.contains { $0.url.scheme == "javascript" })
        #expect(found.first { $0.title == "In Docs" }?.url.absoluteString == "https://docs.test/")
    }

    @Test func aMissingOrBrokenBookmarksFileIsNothing() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OrionImporter.bookmarks(at: root.appendingPathComponent("favourites.plist")).isEmpty)
        let broken = root.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: broken)
        #expect(OrionImporter.bookmarks(at: broken).isEmpty)
    }

    @Test func readingListComesInItsOwnFolder() throws {
        let found = OrionImporter.readingList(at: try Self.fixture("reading_list", "plist"))
        #expect(found.count == 1)
        #expect(found.first?.url.absoluteString == "https://later.test/article")
        #expect(found.first?.title == "Read later")
        #expect(found.first?.folders.count == 1)
    }

    @Test func historyComesWithCountsAndTimes() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history")
        try Self.makeHistory(at: file)
        let entries = OrionImporter.history(at: file)
        // about:blank isn't kept; newest first.
        #expect(entries.map(\.0.absoluteString) == ["https://news.test/", "https://untitled.test/", "https://old.test/page"])
        #expect(entries[0].1 == "News" && entries[0].2 == 5)
        #expect(entries[1].1 == "" && entries[1].2 == 1)
        // SQLite's own timestamps, in UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(entries[0].3 == utc.date(from: DateComponents(year: 2024, month: 3, day: 1, hour: 12)))
        #expect(entries[2].3 == utc.date(from: DateComponents(year: 2023, month: 1, day: 15, hour: 8, minute: 30)))
    }

    @Test func numericVisitTimesReadInTheirUnit() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(OrionImporter.date("1700000000") == date)
        #expect(OrionImporter.date("1700000000000") == date)
        #expect(OrionImporter.date(String(date.timeIntervalSinceReferenceDate)) == date)
    }

    /// Only an Orion folder with a profile in it counts: Orion's web-app helpers alone, or nothing, isn't Orion.
    @Test func foundOnlyWhenItsDataIsThere() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!OrionImporter.isInstalled(in: root.appendingPathComponent("missing")))
        for folder in ["WebApps", "Shared", "profiles", "Defaults"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        #expect(!OrionImporter.isInstalled(in: root))
        // History alone is enough.
        try Self.makeHistory(at: root.appendingPathComponent("Defaults/history"))
        #expect(OrionImporter.isInstalled(in: root))
        #expect(OrionImporter.profileNames(in: root).map(\.folder) == ["Defaults"])
    }

    @Test func otherProfilesAreListedAfterTheDefault() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.makeProfile("Defaults", in: root)
        let id = "6A1B7C2D-0000-4000-8000-000000000001"
        _ = try Self.makeProfile(id, in: root)
        _ = try Self.makeProfile("8F00AA11-0000-4000-8000-000000000002", in: root)
        // Orion's own folders, even with something in them, aren't profiles.
        _ = try Self.makeProfile("Shared", in: root)
        // A list naming one of them.
        let list: [[String: Any]] = [["identifier": id, "name": "Work"]]
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        try data.write(to: root.appendingPathComponent("profiles"))

        let profiles = OrionImporter.profileNames(in: root)
        #expect(profiles.map(\.folder) == ["Defaults", id, "8F00AA11-0000-4000-8000-000000000002"])
        #expect(profiles[1].name == "Work")
        #expect(profiles[2].name != profiles[2].folder)
        // One profile alone reads only its own folder.
        let work = OrionImporter.Browser().only(id, named: "Work")
        #expect(OrionImporter.profiles(of: work, in: root).map(\.lastPathComponent) == [id])
        #expect(OrionImporter.profiles(of: OrionImporter.Browser(), in: root).count == 3)
    }

    @Test func profileNamesFromAFolderOfLists() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry: [String: Any] = ["profiles": ["x": ["id": "ABC", "title": "Personal"]]]
        try PropertyListSerialization.data(fromPropertyList: entry, format: .xml, options: 0).write(to: folder.appendingPathComponent("list.plist"))
        #expect(OrionImporter.listedNames(in: folder)["abc"] == "Personal")
        #expect(OrionImporter.listedNames(in: root.appendingPathComponent("nothing")).isEmpty)
    }

    /// Only the Chrome Web Store ones that are on, by the name their manifest gives.
    @Test func chromeWebStoreExtensionsThatAreOn() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = root.appendingPathComponent("Defaults/Extensions", isDirectory: true)
        let named = extensions.appendingPathComponent("aaaabbbbccccddddeeeeffffgggghhhh", isDirectory: true)
        try FileManager.default.createDirectory(at: named.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture("orion-extensions", "plist"), to: extensions.appendingPathComponent("extensions.plist"))
        try Data(#"{"manifest_version": 3, "name": "__MSG_appName__", "default_locale": "en", "version": "1.0"}"#.utf8)
            .write(to: named.appendingPathComponent("manifest.json"))
        try Data(#"{"appName": {"message": "Made Up Helper"}}"#.utf8).write(to: named.appendingPathComponent("_locales/en/messages.json"))

        let found = OrionImporter.extensions(inProfile: root.appendingPathComponent("Defaults"))
        #expect(Set(found.map(\.id)) == ["aaaabbbbccccddddeeeeffffgggghhhh", "ccccddddeeeeffffgggghhhhiiiijjjj"])
        #expect(found.first { $0.id == "aaaabbbbccccddddeeeeffffgggghhhh" }?.name == "Made Up Helper")
        // Nothing to add that's already here.
        #expect(ChromiumExtensions.toAdd(found, installed: ["ccccddddeeeeffffgggghhhhiiiijjjj"]).map(\.id) == ["aaaabbbbccccddddeeeeffffgggghhhh"])
    }

    @Test func offersWhatItCanBringAndSaysHowForPasswords() {
        let offers = ImportCoordinator.Source(kind: .orion(OrionImporter.Browser()), name: OrionImporter.name, bundleID: OrionImporter.bundleID).offers
        #expect(offers.contains(.bookmarks) && offers.contains(.history) && offers.contains(.extensions) && offers.contains(.passwords))
        #expect(!offers.contains(.signIns) && !offers.contains(.tabs))
        // Its passwords can't be read: choosing them says how to export them instead.
        let batch = OrionImporter.read(OrionImporter.Browser(), [.passwords])
        #expect(batch.logins.isEmpty)
        #expect(batch.problems.map(\.fix) == [.exportFromApplePasswords])
    }
}

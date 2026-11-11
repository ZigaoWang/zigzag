import Foundation
import Testing
@testable import Zigzag

/// A Chromium browser with several profiles (#131): each profile's bookmarks come over as a space of its own, named
/// after it, even when the browser is listed as one row; importing it again adds to that space; and no space of
/// yours is filled with them. Read from a made-up Chrome folder, never a real one.
struct ChromeProfilesImportTests {
    private final class FixtureMarker {}

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle(for: FixtureMarker.self).url(forResource: name, withExtension: "json"))
    }

    static var chrome: ChromiumImporter.Browser { ChromiumImporter.browsers.first { $0.name == "Chrome" }! }

    /// A made-up ~/Library/Application Support/Google/Chrome with two profiles, Personal and Work, removed by the caller.
    static func makeRoot() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString)", isDirectory: true)
        for folder in ["Default", "Profile 1"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: fixture("chrome-local-state"), to: root.appendingPathComponent("Local State"))
        try fm.copyItem(at: fixture("chrome-bookmarks-personal"), to: root.appendingPathComponent("Default/Bookmarks"))
        try fm.copyItem(at: fixture("chrome-bookmarks-work"), to: root.appendingPathComponent("Profile 1/Bookmarks"))
        return root
    }

    /// Where the bookmarks of `browser` go among `spaces`, every space on the first profile unless `profiles` says.
    static func plan(_ browser: ChromiumImporter.Browser, in root: URL, spaces: [SpaceInfo], profiles: [UUID: UUID] = [:],
                     on target: UUID = Profile.defaultID) -> [(from: ImportBatch.BrowserProfile?, space: SpaceInfo?, name: String, new: [ImportBatch.Bookmark])] {
        let batch = ChromiumImporter.read(browser, [.bookmarks], in: root)
        return ImportCoordinator.plan(batch.bookmarks, source: browser.name, in: spaces, on: target,
                                      profileOf: { profiles[$0] ?? Profile.defaultID })
    }

    /// The spaces a plan leaves, as `addBookmarks` makes them.
    static func apply(_ plan: [(from: ImportBatch.BrowserProfile?, space: SpaceInfo?, name: String, new: [ImportBatch.Bookmark])],
                      to spaces: [SpaceInfo]) -> [SpaceInfo] {
        var spaces = spaces
        for part in plan {
            let pages = part.new.map { Bookmark(url: $0.url, title: $0.title) }
            if let existing = part.space, let i = spaces.firstIndex(where: { $0.id == existing.id }) {
                spaces[i].bookmarks += pages
                spaces[i].importedFrom = part.from?.key
            } else if !pages.isEmpty {
                var space = SpaceInfo(name: part.name, color: .mint)
                space.bookmarks = pages
                space.importedFrom = part.from?.key
                spaces.append(space)
            }
        }
        return spaces
    }

    static let current = SpaceInfo(name: "Personal Space", color: .sky)

    @Test func eachProfilesBookmarksAreMarkedWithIt() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let labels = ChromiumImporter.profileLabels(of: Self.chrome, in: root)
        #expect(labels.map(\.folder) == ["Default", "Profile 1"])
        #expect(labels.map(\.label) == ["Personal", "Work"])
        let bookmarks = ChromiumImporter.read(Self.chrome, [.bookmarks], in: root).bookmarks
        #expect(bookmarks.count == 5)
        #expect(Set(bookmarks.compactMap(\.from?.key)) == ["Google/Chrome/Default", "Google/Chrome/Profile 1"])
        #expect(bookmarks.first { $0.title == "Wiki" }?.from?.name == "Work")
        #expect(bookmarks.first { $0.title == "Map" }?.from?.name == "Personal")
        #expect(bookmarks.first { $0.title == "Map" }?.folders == ["Trips"])
    }

    /// Chrome listed as one row (its profiles unread until macOS allowed it): still a space for each profile.
    @Test func twoProfilesMakeTwoSpacesNamedAfterThem() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = Self.plan(Self.chrome, in: root, spaces: [Self.current])
        #expect(plan.count == 2)
        #expect(plan.allSatisfy { $0.space == nil })
        #expect(plan.map(\.name) == ["Personal", "Work"])
        #expect(plan.map { $0.new.map(\.title) } == [["Recipes", "Map"], ["Tracker", "Docs", "Wiki"]])
        let after = Self.apply(plan, to: [Self.current])
        #expect(after.map(\.name) == ["Personal Space", "Personal", "Work"])
        // The space you were in gets none of it.
        #expect(after[0].bookmarks.isEmpty)
    }

    /// One profile chosen ("Chrome (Work)"): only its space, named the same.
    @Test func oneChosenProfileMakesOnlyItsSpace() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = Self.plan(Self.chrome.only("Profile 1", named: "Work"), in: root, spaces: [Self.current])
        #expect(plan.map(\.name) == ["Work"])
        #expect(plan.first?.new.count == 3)
    }

    @Test func importingAgainAddsToTheSameSpaces() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var spaces = Self.apply(Self.plan(Self.chrome, in: root, spaces: [Self.current]), to: [Self.current])
        // Renamed since: still found by the profile it keeps.
        spaces[2].name = "Day Job"
        let again = Self.plan(Self.chrome, in: root, spaces: spaces)
        #expect(again.map(\.space?.id) == [spaces[1].id, spaces[2].id])
        #expect(again.allSatisfy { $0.new.isEmpty })
        #expect(Self.apply(again, to: spaces).count == 3)
        // A page added in Chrome since comes over into its profile's space alone.
        let file = root.appendingPathComponent("Profile 1/Bookmarks")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var roots = try #require(json["roots"] as? [String: Any])
        var bar = try #require(roots["bookmark_bar"] as? [String: Any])
        bar["children"] = (bar["children"] as? [[String: Any]] ?? []) + [["name": "New", "type": "url", "url": "https://new.example.com/"]]
        roots["bookmark_bar"] = bar
        json["roots"] = roots
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let later = Self.plan(Self.chrome, in: root, spaces: spaces)
        #expect(later.map { $0.new.map(\.title) } == [[], ["New"]])
        #expect(later.last?.space?.id == spaces[2].id)
    }

    /// A space of yours named like a profile is never filled with its bookmarks, nor one on another Zigzag profile.
    @Test func yourOwnSpacesAreLeftAlone() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = SpaceInfo(name: "Work", color: .sky)
        var elsewhere = SpaceInfo(name: "Personal", color: .rose)
        elsewhere.importedFrom = "Google/Chrome/Default"
        let other = UUID()
        let plan = Self.plan(Self.chrome, in: root, spaces: [Self.current, mine, elsewhere], profiles: [elsewhere.id: other])
        #expect(plan.allSatisfy { $0.space == nil })
        // "Work" is taken: "From Chrome (Work)" (in whichever language the Mac reads) instead.
        #expect(plan.last?.name != "Work")
        #expect(plan.last?.name.contains("Chrome (Work)") == true)
    }

    /// A space an earlier version made for the profile ("From Chrome (Work)") is used again, not made twice.
    @Test func aSpaceFromBeforeIsUsedAgain() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = Self.plan(Self.chrome, in: root, spaces: [SpaceInfo(name: "Work", color: .sky)])
        let earlierName = try #require(fresh.last?.name)
        var earlier = SpaceInfo(name: earlierName, color: .mint)
        earlier.bookmarks = [Bookmark(url: URL(string: "https://tracker.example.com/")!, title: "Tracker")]
        let plan = Self.plan(Self.chrome, in: root, spaces: [Self.current, earlier])
        #expect(plan.last?.space?.id == earlier.id)
        #expect(plan.last?.new.map(\.title) == ["Docs", "Wiki"])
    }

    /// Two profiles of one name are told apart by their account, in their sources and spaces alike.
    @Test func profilesOfOneNameAreToldApart() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = """
        {"profile": {"info_cache": {"Default": {"name": "Wang", "user_name": "a@example.com"},
                                    "Profile 1": {"name": "Wang", "user_name": "b@example.com"}}}}
        """
        try Data(state.utf8).write(to: root.appendingPathComponent("Local State"))
        #expect(ChromiumImporter.profileLabels(of: Self.chrome, in: root).map(\.label) == ["a@example.com", "b@example.com"])
        let plan = Self.plan(Self.chrome, in: root, spaces: [])
        #expect(plan.map(\.name) == ["a@example.com", "b@example.com"])
    }
}

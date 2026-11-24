import AppKit
import Foundation
import Testing
@testable import Zigzag

/// File › Export Your Data…: the bookmarks file other browsers import, and the backup File › Import restores.
@MainActor struct ExportTests {
    private func page(_ path: String, _ title: String) -> Bookmark {
        Bookmark(url: URL(string: "https://example.com/\(path)")!, title: title)
    }

    /// A space with a page at the top, a folder holding a page and a subfolder, an empty folder and a split.
    private func sampleSpace(name: String = "Work") -> SpaceInfo {
        let top = page("top", "Top & <Best>"), inner = page("inner?a=1&b=\"2\"", "Inner"), deep = page("deep", "Deep")
        let left = page("left", "Left"), right = page("right", "Right")
        var space = SpaceInfo(name: name, color: .sky)
        space.bookmarks = [top, inner, deep, left, right]
        let outer = BookmarkFolder(name: "Docs \"&\" notes", bookmarkIDs: [inner.id])
        let sub = BookmarkFolder(name: "Sub", bookmarkIDs: [deep.id], parentID: outer.id)
        let empty = BookmarkFolder(name: "Empty")
        space.folders = [outer, sub, empty]
        space.pinnedSplits = [PinnedSplit(left: left.id, right: right.id)]
        return space
    }

    private func contents(_ spaces: [SpaceInfo], favorites: [Bookmark] = [], directory: ProfileDirectory = ProfileDirectory()) -> Library.Contents {
        Library.Contents(spaces: spaces, favorites: favorites, favoriteSplits: [], siteRoutes: [], directory: directory)
    }

    // MARK: Bookmarks file

    @Test func theBookmarksFileNestsAsTheSidebarAndReadsBackThroughTheImporter() {
        var backup = ZigzagBackup()
        backup.profiles = [ProfileInfo(id: Profile.defaultID)]
        backup.spaces = [sampleSpace(), SpaceInfo(name: "Nothing yet", color: .rose)]
        backup.favorites = [page("mail", "Mail")]
        let tree = BookmarksExport.tree(backup)
        let favorites = BookmarksExport.favoritesName
        #expect(tree.map(\.name) == [favorites, "Work", "Nothing yet"])
        // The empty folder sits at the top of its level; a split's pages follow one another.
        guard case .folder(_, let work) = tree[1] else { Issue.record("no Work folder"); return }
        #expect(work.map(\.name) == ["Empty", "Top & <Best>", "Docs \"&\" notes", "Left", "Right"])

        let html = BookmarksExport.html(tree)
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(html.contains("Top &amp; &lt;Best&gt;"))
        #expect(html.contains("HREF=\"https://example.com/inner?a=1&amp;b=%222%22\"") || html.contains("HREF=\"https://example.com/inner?a=1&amp;b=&quot;2&quot;\""))
        #expect(!html.contains("<Best>"))
        let read = BookmarksHTML.bookmarks(in: html).map { ($0.folders + [$0.title]).joined(separator: " / ") }
        // Favorites stay a folder of their own, not folded away as a browser's own Favorites folder is.
        #expect(read == ["\(favorites) / Mail", "Work / Top & <Best>", "Work / Docs \"&\" notes / Inner", "Work / Docs \"&\" notes / Sub / Deep", "Work / Left", "Work / Right"])
        #expect(BookmarksHTML.bookmarks(in: html).first { $0.title == "Inner" }?.url.absoluteString.contains("a=1&b=") == true)
    }

    @Test func eachProfileIsAFolderWithItsOwnFavoritesAndSpaces() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        var backup = ZigzagBackup()
        backup.profiles = directory.all
        let home = SpaceInfo(name: "Home", color: .sky), office = SpaceInfo(name: "Office", color: .rose)
        backup.spaces = [home, office]
        backup.spaceProfiles = [office.id.uuidString: work.id]
        let mine = page("mine", "Mine"), theirs = page("theirs", "Theirs")
        backup.favorites = [mine, theirs]
        backup.favoriteProfiles = [theirs.id.uuidString: work.id]
        backup.openTabs = [ZigzagBackup.SpaceTabs(spaceID: office.id, rows: [[ZigzagBackup.Page(url: URL(string: "https://example.org/a")!, title: "A")]])]
        let tree = BookmarksExport.tree(backup)
        let favorites = BookmarksExport.favoritesName
        let openTabs = String(localized: "Open Tabs", comment: "Folder in an exported bookmarks file holding a space's open tabs, not pinned ones.")
        #expect(tree.map(\.name) == [ProfileInfo(id: Profile.defaultID).displayName, "Work"])
        #expect(tree[0].children.map(\.name) == [favorites, "Home"])
        #expect(tree[1].children.map(\.name) == [favorites, "Office"])
        #expect(tree[1].children[0].children.map(\.name) == ["Theirs"])
        #expect(tree[1].children[1].children.map(\.name) == [openTabs])
    }

    @Test func privateWindowsTabsAreLeftOut() {
        let space = UUID()
        let everyday = TabManager(spaceID: space), secret = TabManager(spaceID: space, isPrivate: true)
        defer { everyday.invalidate(); secret.invalidate() }
        let a = Tab(url: URL(string: "https://example.com/a")!, title: "A", spaceID: space)
        let b = Tab(url: URL(string: "https://example.com/b")!, title: "B", spaceID: space)
        everyday.adopt([a, b], in: space)
        everyday.makeSplit(a, with: b)
        secret.adopt([Tab(url: URL(string: "https://example.com/hidden")!, title: "Hidden", spaceID: space)], in: space)
        let open = ZigzagBackup.openTabs(of: [secret, everyday], spaces: [space])
        #expect(open.map { $0.rows.map { $0.map(\.title) } } == [[["A", "B"]]])
    }

    @Test func defaultNamesCarryTheDate() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 24; parts.hour = 12
        let date = Calendar.current.date(from: parts)!
        #expect(DataExport.stamp(date) == "2026-11-24")
        #expect(DataExport.bookmarksName(date).hasSuffix("2026-11-24.html"))
        #expect(DataExport.backupName(date).hasSuffix("2026-11-24.zigzagbackup"))
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.html", "/tmp/x/a 2.html"]
        #expect(DataExport.unusedFile(named: "a.html", in: folder) { taken.contains($0.path) }.lastPathComponent == "a 3.html")
    }

    // MARK: Backup file

    @Test func aBackupReadsBackAsItWasWritten() throws {
        var backup = ZigzagBackup()
        backup.profiles = [ProfileInfo(id: Profile.defaultID)]
        backup.spaces = [sampleSpace()]
        backup.favorites = [page("mail", "Mail")]
        backup.pageIcons = ["x.png": Data([1, 2, 3])]
        backup.history = [ZigzagBackup.ProfileHistory(profile: Profile.defaultID, visits: [ZigzagBackup.Visit(url: URL(string: "https://example.com")!, title: "E", count: 3, lastVisit: Date(timeIntervalSince1970: 1_700_000_000))])]
        backup.settings = ZigzagBackup.Settings(searchEngine: .duckDuckGo, values: [
            "AskBeforeQuitting": .bool(true), "ArchiveTabsAfter": .string("week"), "FavoritesPerRow": .int(4), "DefaultZoom": .double(1.25),
            "SiteBoosts": .data(Data([9, 8])), "TranslateNever": .array([.string("fr")]), "ZoomLevels": .dictionary(["a.com": .double(1.5)]),
        ])
        let data = try backup.encoded()
        let read = try ZigzagBackup.decode(data).get()
        #expect(read.spaces == backup.spaces)
        #expect(read.favorites == backup.favorites)
        #expect(read.pageIcons == backup.pageIcons)
        #expect(read.history?.first?.visits == backup.history?.first?.visits)
        #expect(read.settings == backup.settings)
        #expect(read.version == ZigzagBackup.currentVersion)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"format\" : \"Zigzag Backup\""))
        #expect(!json.lowercased().contains("password\""))
    }

    @Test func aNewerOrForeignFileIsNotRead() throws {
        var newer = ZigzagBackup()
        newer.version = ZigzagBackup.currentVersion + 1
        #expect(ZigzagBackup.decode(try newer.encoded()).failure == .newer)
        #expect(ZigzagBackup.decode(Data("{\"spaces\": []}".utf8)).failure == .unreadable)
        #expect(ZigzagBackup.decode(Data("not json".utf8)).failure == .unreadable)
    }

    @Test func settingsCarryPreferencesNeverSecretsOrCounters() throws {
        let name = "zigzag-export-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let other = UUID(), gone = UUID()
        for (key, value) in [("AskBeforeQuitting", true as Any), ("SiteBoosts", Data([1])), ("CookiesKeptSites.\(other.uuidString)", ["a.com"]),
                             ("CookiesKeptSites.\(gone.uuidString)", ["b.com"]), ("AllowsAIApps", true), ("MCPPort", 8123),
                             ("AllowJavaScriptFromAppleEvents", true), ("TrustedCertificates", ["x"]), ("PasswordsManager", "id"),
                             ("LaunchCount", 40), ("TutorialDone", true), ("LastRunVersion", "0.9.4")] {
            defaults.set(value, forKey: key)
        }
        let settings = ZigzagBackup.settings(from: defaults, profiles: [Profile.defaultID, other])
        #expect(Set(settings.values.keys) == ["AskBeforeQuitting", "SiteBoosts", "CookiesKeptSites.\(other.uuidString)"])

        // A backup that names more than that only ever writes the carried ones, and only for profiles here.
        let target = try #require(UserDefaults(suiteName: name + "-in"))
        defer { target.removePersistentDomain(forName: name + "-in") }
        let crafted = ZigzagBackup.Settings(values: ["AllowsAIApps": .bool(true), "MCPPort": .int(1), "ReduceMotion": .bool(true),
                                                     "CookiesKeptSites.\(gone.uuidString)": .array([.string("b.com")])])
        #expect(ZigzagBackup.apply(crafted, to: target, profiles: [Profile.defaultID]) == 1)
        #expect(target.bool(forKey: "ReduceMotion"))
        #expect(target.object(forKey: "AllowsAIApps") == nil)
        #expect(target.object(forKey: "MCPPort") == nil)
        #expect(target.object(forKey: "CookiesKeptSites.\(gone.uuidString)") == nil)
    }

    // MARK: Restoring

    @Test func restoringTwiceAddsNothingTheSecondTime() {
        let space = sampleSpace()
        var backup = ZigzagBackup()
        backup.profiles = [ProfileInfo(id: Profile.defaultID)]
        backup.spaces = [space]
        backup.favorites = [page("mail", "Mail")]
        let existing = SpaceInfo(name: "Mine", color: .rose)
        let first = backup.merged(into: contents([existing]))
        #expect(first.spaces == 1)
        #expect(first.pinned == 5)
        #expect(first.favorites == 1)
        #expect(first.contents.spaces.map(\.name) == ["Mine", "Work"])
        let work = first.contents.spaces[1]
        #expect(work.folders?.count == 3)
        #expect(work.pinnedSplits?.count == 1)
        #expect(BookmarksExport.pinned(work) == BookmarksExport.pinned(space))

        let second = backup.merged(into: first.contents)
        #expect(second.spaces == 0 && second.pinned == 0 && second.favorites == 0)
        #expect(second.contents.spaces.map { $0.bookmarks.count } == [0, 5])
        #expect(second.contents.spaces[1].folders?.count == 3)
        #expect(second.contents.favorites.count == 1)
    }

    /// Pinned by hand since the backup: only what the space doesn't have comes over, into the folder it was in.
    @Test func aSpaceThatsStillHereGainsOnlyWhatItLacks() {
        var space = sampleSpace()
        var backup = ZigzagBackup()
        backup.spaces = [space]
        var here = space
        here.bookmarks.removeAll { $0.title == "Deep" }
        here.folders = here.folders.map { folders in folders.map { var f = $0; f.bookmarkIDs.removeAll { id in !here.bookmarks.contains { $0.id == id } }; return f } }
        here.bookmarks.append(page("new", "Mine"))
        let merge = backup.merged(into: contents([here]))
        #expect(merge.spaces == 0)
        #expect(merge.pinned == 1)
        let result = merge.contents.spaces[0]
        let sub = result.folders?.first { $0.name == "Sub" }
        #expect(sub.map { $0.bookmarkIDs.compactMap { id in result.bookmarks.first { $0.id == id }?.title } } == ["Deep"])
        #expect(result.bookmarks.map(\.title).contains("Mine"))
        space.bookmarks = []
        #expect(Set(result.bookmarks.map(\.url)).count == result.bookmarks.count)
    }

    /// On a new Mac the first space, unpinned and of the same name, takes the backup's place and look.
    @Test func aNewMacsFirstSpaceTakesTheBackupsLook() {
        var personal = SpaceInfo(name: "Personal", color: .sage)
        personal.icon = "star"
        var backup = ZigzagBackup()
        backup.spaces = [personal, sampleSpace()]
        let fresh = SpaceInfo(name: "Personal", color: .sky)
        let merge = backup.merged(into: contents([fresh]))
        #expect(merge.contents.spaces.map(\.name) == ["Personal", "Work"])
        #expect(merge.contents.spaces[0].id == fresh.id)
        #expect(merge.contents.spaces[0].color == .sage)
        #expect(merge.contents.spaces[0].icon == "star")
        #expect(merge.spaceIDs[personal.id] == fresh.id)
    }

    @Test func profilesComeBackWithTheirSpacesAndFavorites() {
        var source = ProfileDirectory()
        let work = source.add(name: "Work", color: .rose)
        let office = SpaceInfo(name: "Office", color: .sky)
        let theirs = page("theirs", "Theirs")
        var backup = ZigzagBackup()
        backup.profiles = source.all
        backup.spaces = [office]
        backup.spaceProfiles = [office.id.uuidString: work.id]
        backup.favorites = [theirs]
        backup.favoriteProfiles = [theirs.id.uuidString: work.id]
        // The same page is a favorite of the first profile here, which doesn't stop it being Work's.
        let merge = backup.merged(into: contents([SpaceInfo(name: "Home", color: .rose)], favorites: [page("theirs", "Mine")]))
        let directory = merge.contents.directory
        #expect(directory.profile(work.id)?.name == "Work")
        #expect(directory.profileID(ofSpace: office.id) == work.id)
        #expect(merge.favorites == 1)
        #expect(merge.contents.favorites.filter { directory.profileID(ofFavorite: $0.id) == work.id }.map(\.title) == ["Theirs"])
    }

    @Test func pagesWhoseIDsAreTakenGetNewOnes() {
        var backup = ZigzagBackup()
        let space = sampleSpace()
        backup.spaces = [space]
        // Another space here already uses one of its pages' IDs, at another address.
        var other = SpaceInfo(name: "Other", color: .rose)
        other.bookmarks = [Bookmark(id: space.bookmarks[0].id, url: URL(string: "https://example.net/")!, title: "Taken")]
        let merge = backup.merged(into: contents([other]))
        let ids = merge.contents.spaces.flatMap { $0.bookmarks.map(\.id) }
        #expect(Set(ids).count == ids.count)
        #expect(merge.contents.spaces[1].bookmarks.count == 5)
    }
}

private extension BookmarksExport.Node {
    var name: String {
        switch self {
        case .page(let title, _): title
        case .folder(let name, _): name
        }
    }
    var children: [BookmarksExport.Node] {
        if case .folder(_, let children) = self { children } else { [] }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}

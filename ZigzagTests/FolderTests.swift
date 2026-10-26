import Foundation
import Testing
@testable import Zigzag

/// Folders of pinned pages: they only say which pages they hold, so these check that the pages never get lost,
/// doubled or split from their folder, and that libraries from before folders still open.
struct FolderTests {
    private func pins(_ n: Int) -> [Bookmark] {
        (0..<n).map { Bookmark(url: URL(string: "https://example.com/\($0)")!, title: "\($0)") }
    }

    @Test func folderPagesStayTogether() {
        let b = pins(5)
        let folder = BookmarkFolder(name: "F", bookmarkIDs: [b[1].id, b[4].id])
        let (bookmarks, folders) = Library.tidied(b, [folder])
        #expect(bookmarks.map(\.id) == [b[0], b[1], b[4], b[2], b[3]].map(\.id))
        #expect(folders[0].bookmarkIDs == [b[1].id, b[4].id])
    }

    @Test func noPageIsLostOrDoubled() {
        let b = pins(6)
        let folders = [BookmarkFolder(name: "A", bookmarkIDs: [b[5].id, b[2].id]),
                       BookmarkFolder(name: "B", bookmarkIDs: [b[2].id, b[3].id, UUID()])]
        let (bookmarks, tidy) = Library.tidied(b, folders)
        #expect(Set(bookmarks.map(\.id)) == Set(b.map(\.id)))
        #expect(bookmarks.count == b.count)
        // A page in two folders stays in the first; one that's gone is dropped.
        #expect(tidy[0].bookmarkIDs == [b[2].id, b[5].id])
        #expect(tidy[1].bookmarkIDs == [b[3].id])
    }

    @Test func emptyFolderStays() {
        let b = pins(2)
        let (bookmarks, folders) = Library.tidied(b, [BookmarkFolder(name: "Empty")])
        #expect(bookmarks.map(\.id) == b.map(\.id))
        #expect(folders.count == 1 && folders[0].bookmarkIDs.isEmpty)
    }

    @Test func spaceFromBeforeFoldersOpens() throws {
        let space = SpaceInfo(name: "Old", color: .sage)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(space)) as! [String: Any]
        json.removeValue(forKey: "folders")
        let decoded = try JSONDecoder().decode(SpaceInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.name == "Old")
        #expect((decoded.folders ?? []).isEmpty)
    }
}

/// Arc's pinned folders come over as folders; a pinned split view is just its pages.
struct ArcFolderTests {
    @Test func foldersAndSplitViews() throws {
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["id": id, "title": id, "data": ["tab": ["savedURL": url]], "childrenIds": [String]()]
        }
        let items: [Any] = [
            ["id": "pinned", "childrenIds": ["t1", "folder", "split"], "data": ["itemContainer": [:]]],
            tab("t1", "https://example.com/1"),
            ["id": "folder", "title": "Reading", "data": ["list": [:]], "childrenIds": ["t2", "inner"]],
            tab("t2", "https://example.com/2"),
            ["id": "inner", "title": "Inner", "data": ["list": [:]], "childrenIds": ["t3"]],
            tab("t3", "https://example.com/3"),
            ["id": "split", "data": ["splitView": [:]], "childrenIds": ["t4", "t5"]],
            tab("t4", "https://example.com/4"),
            tab("t5", "https://example.com/5"),
        ]
        let root: [String: Any] = ["sidebar": ["containers": [
            ["global": [:]],
            ["spaces": ["s1", ["id": "s1", "title": "Home", "containerIDs": ["unpinned", "u", "pinned", "pinned"]]], "items": items],
        ]]]
        let (spaces, _) = try ArcImporter.parseSidebar(JSONSerialization.data(withJSONObject: root))
        let space = try #require(spaces.first)
        #expect(space.bookmarks.map(\.url.lastPathComponent) == ["1", "2", "3", "4", "5"])
        let folders = space.folders ?? []
        #expect(folders.map(\.name) == ["Reading"])
        #expect(folders.first?.bookmarkIDs == space.bookmarks[1...2].map(\.id))
    }
}

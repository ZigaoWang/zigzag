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

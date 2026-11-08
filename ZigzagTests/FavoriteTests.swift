import Foundation
import Testing
@testable import Zigzag

/// Favorites are placed by tile, a split's two pages counting as one. These check where they land, away from the saved
/// library.
struct FavoriteTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test func placesBeforeATile() {
        let order = Library.placing([ids[4]], atSlot: 1, in: Array(ids[0..<4]), splits: [])
        #expect(order == [ids[0], ids[4], ids[1], ids[2], ids[3]])
    }

    @Test func pastTheEndGoesLast() {
        #expect(Library.placing([ids[0]], atSlot: nil, in: ids, splits: []).last == ids[0])
        #expect(Library.placing([ids[0]], atSlot: 99, in: ids, splits: []).last == ids[0])
    }

    @Test func aSplitCountsAsOneTile() {
        // Tiles: [0], [1|2], [3]. Slot 2 is the tile of 3, after the split's right page.
        let split = PinnedSplit(left: ids[1], right: ids[2])
        let order = Library.placing([ids[4]], atSlot: 2, in: Array(ids[0..<4]), splits: [split])
        #expect(order == [ids[0], ids[1], ids[2], ids[4], ids[3]])
    }

    @Test func movingASplitKeepsItTogether() {
        let split = PinnedSplit(left: ids[1], right: ids[2])
        let order = Library.placing([ids[1], ids[2]], atSlot: 0, in: Array(ids[0..<4]), splits: [split])
        #expect(order == [ids[1], ids[2], ids[0], ids[3]])
    }

    @Test func joiningAnEarlierFavoriteOntoALaterOne() {
        // [0, 1, 2]: 0 dropped on 1's middle lands where 1 is, not one tile past it.
        let order = Library.placing([ids[1], ids[0]], at: ids[1], in: Array(ids[0..<3]))
        #expect(order == [ids[1], ids[0], ids[2]])
    }

    @Test func joiningALaterFavoriteOntoAnEarlierOne() {
        let order = Library.placing([ids[2], ids[0]], at: ids[0], in: Array(ids[0..<3]))
        #expect(order == [ids[2], ids[0], ids[1]])
    }

    @Test func joiningANewPageKeepsTheOthersInPlace() {
        let new = UUID()
        let order = Library.placing([ids[1], new], at: ids[1], in: Array(ids[0..<3]) + [new])
        #expect(order == [ids[0], ids[1], new, ids[2]])
    }
}

/// What a bookmark is called when you pin a page.
/// On Automatic, the favorites' rows look whole: never one tile left alone on a row of its own.
@MainActor struct FavoriteColumnTests {
    // The grid's width at the narrowest sidebar and at the usual one.
    let narrow: CGFloat = 204, usual: CGFloat = 228

    @Test func fourSitInOneRow() {
        #expect(FavoritesView.columns(for: narrow, count: 4) == 4)
        #expect(FavoritesView.columns(for: usual, count: 4) == 4)
    }

    @Test func fewerLargerTilesWhenRowsComeOutWhole() {
        #expect(FavoritesView.columns(for: usual, count: 3) == 3)
        #expect(FavoritesView.columns(for: usual, count: 6) == 3)
        #expect(FavoritesView.columns(for: usual, count: 9) == 3)
    }

    @Test func noLoneTileOnTheLastRow() {
        for count in 2...24 {
            for width in [narrow, usual, 260, 320, 400] {
                let columns = FavoritesView.columns(for: width, count: count)
                // Unless every count that fits leaves one over, as 13 does in a narrow sidebar.
                let avoidable = (2...FavoritesView.columns(for: width, count: 1000)).contains { count % $0 != 1 }
                guard count > columns, avoidable else { continue }
                #expect(count % columns != 1, "\(count) favorites at \(width) leave one alone with \(columns) columns")
            }
        }
    }
}

struct BookmarkTitleTests {
    @Test func homePageTakesTheSiteName() {
        #expect(TabManager.bookmarkTitle("Inbox (3) - Gmail", url: URL(string: "https://gmail.com/")!) == "Gmail")
        #expect(TabManager.bookmarkTitle("YouTube", url: URL(string: "https://www.youtube.com")!) == "YouTube")
    }

    @Test func otherPagesKeepTheirTitle() {
        let title = "ZigaoWang/zigzag: A browser - GitHub"
        #expect(TabManager.bookmarkTitle(title, url: URL(string: "https://github.com/ZigaoWang/zigzag")!) == title)
        #expect(TabManager.bookmarkTitle("Results - Google Search", url: URL(string: "https://google.com/?q=x")!) == "Results - Google Search")
    }
}

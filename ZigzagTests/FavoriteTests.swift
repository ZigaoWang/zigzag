import AppKit
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

    @Test func arrangingOneProfilesFavoritesLeavesTheOthersAlone() {
        let marks = ids.map { Bookmark(id: $0, url: URL(string: "https://example.com/\($0)")!, title: "") }
        // 0, 2 and 4 are one profile's; 1 and 3 another's, which gains a new one and is put in a new order.
        let new = Bookmark(url: URL(string: "https://example.org/")!, title: "")
        let arranged = Library.arranging(marks, as: [ids[3], new.id, ids[1]], adding: [new])
        #expect(arranged.map(\.id) == [ids[0], ids[2], ids[4], ids[3], new.id, ids[1]])
        // One that isn't there and isn't new is left out.
        #expect(Library.arranging(marks, as: [UUID(), ids[0]]).map(\.id) == [ids[1], ids[2], ids[3], ids[4], ids[0]])
    }

    /// A pair is kept only when both pages are one profile's; the right page then sits just after the left.
    @Test func aPairAcrossProfilesIsUndoneAndOneWithinIsKeptTogether() {
        let marks = ids.map { Bookmark(id: $0, url: URL(string: "https://example.com/\($0)")!, title: "") }
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        // 3 and 4 are Work's; 0, 1 and 2 the first profile's.
        directory.assign(favorite: ids[3], to: work.id)
        directory.assign(favorite: ids[4], to: work.id)
        let across = PinnedSplit(left: ids[0], right: ids[3]), within = PinnedSplit(left: ids[4], right: ids[3])
        let firsts = PinnedSplit(left: ids[2], right: ids[0])
        let (favorites, splits) = Library.tidied(marks, splits: [across, within, firsts], directory: directory)
        #expect(splits.map(\.left) == [ids[4], ids[2]])
        #expect(favorites.map(\.id) == [ids[1], ids[2], ids[0], ids[4], ids[3]])
        // With one profile every pair is within it.
        #expect(Library.tidied(marks, splits: [across], directory: ProfileDirectory()).1.count == 1)
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

/// A favorite's tile shows what a tab row shows: the one you're on, open or not, and a page that moved on from the one
/// it was saved with, as a pinned tab's row does.
@MainActor struct FavoriteTileStateTests {
    private let saved = URL(string: "https://mail.example.com/inbox")!

    @Test func theTileYouAreOnIsSelectedWhateverElse() {
        #expect(FavoriteTile.look(selected: true, loaded: [true]) == .selected)
        #expect(FavoriteTile.look(selected: true, loaded: []) == .selected)
    }

    @Test func aTileIsOpenOnlyWhileOneOfItsPagesIsLoaded() {
        #expect(FavoriteTile.look(selected: false, loaded: [true]) == .open)
        // A split favorite with one page loaded is open, as its pinned row is.
        #expect(FavoriteTile.look(selected: false, loaded: [false, true]) == .open)
        // Never opened, asleep, or not loaded since Zigzag reopened: all closed alike.
        #expect(FavoriteTile.look(selected: false, loaded: []) == .closed)
        #expect(FavoriteTile.look(selected: false, loaded: [false]) == .closed)
        #expect(FavoriteTile.look(selected: false, loaded: [false, false]) == .closed)
    }

    @Test func aTileIconIsNeverFaded() {
        // Never faded: a closed favorite has no edge instead.
        #expect(FavoriteTile.iconAlpha(.closed, hovered: false) == 1)
        #expect(FavoriteTile.iconAlpha(.closed, hovered: true) == 1)
        #expect(FavoriteTile.iconAlpha(.open, hovered: false) == 1)
        #expect(FavoriteTile.iconAlpha(.selected, hovered: false) == 1)
    }

    @Test func onItsSavedPageItIsNotAway() {
        #expect(!FavoriteTile.isAway(current: saved, saved: saved, landing: nil))
        // The same address written another way: http, www, a slash or a fragment.
        #expect(!FavoriteTile.isAway(current: URL(string: "http://www.mail.example.com/inbox/#top")!, saved: saved, landing: nil))
        // Not open: nothing to be away from.
        #expect(!FavoriteTile.isAway(current: nil, saved: saved, landing: nil))
    }

    @Test func whereItsAddressLandsOnItsOwnIsNotAway() {
        let landing = URL(string: "https://accounts.example.com/signin")!
        #expect(!FavoriteTile.isAway(current: landing, saved: saved, landing: landing))
    }

    @Test func anotherPageIsAway() {
        let other = URL(string: "https://video.example.com/watch")!
        #expect(FavoriteTile.isAway(current: other, saved: saved, landing: nil))
        #expect(FavoriteTile.isAway(current: other, saved: saved, landing: URL(string: "https://accounts.example.com/")!))
    }

    @Test func pointingAtAnAwayTileNamesBothPages() {
        #expect(FavoriteTile.pageName(saved: "Mail", away: nil) == "Mail")
        #expect(FavoriteTile.pageName(saved: "Mail", away: "") == "Mail")
        #expect(FavoriteTile.pageName(saved: "Mail", away: "Video") == "Mail — Video")
    }

    @Test func anAwayTileNamesBothPagesInItsTooltip() {
        let favorite = Bookmark(url: saved, title: "Mail")
        let tile = FavoriteTile(bookmark: favorite)
        // The tile holds its pages weakly, as the tab manager owns them.
        let home = Tab(url: saved, title: "Inbox", spaceID: UUID())
        tile.track(home)
        #expect(tile.awayParts == [false])
        #expect(tile.toolTip?.components(separatedBy: "\n").first == "Mail")
        let away = Tab(url: URL(string: "https://video.example.com/watch")!, title: "Video", spaceID: UUID())
        tile.track(away)
        #expect(tile.awayParts == [true])
        #expect(tile.toolTip?.components(separatedBy: "\n").first == "Mail — Video")
        // Unloaded (closed), nothing is away.
        tile.track(nil)
        #expect(tile.awayParts == [false])
        _ = (home, away)
    }

    @Test func aSplitFavoriteTellsWhichOfItsPagesMovedOn() {
        let left = Bookmark(url: saved, title: "Mail"), right = Bookmark(url: URL(string: "https://notes.example.com/")!, title: "Notes")
        let tile = FavoriteTile(bookmark: left, partners: [right])
        let notes = Tab(url: right.url, title: "Notes", spaceID: UUID())
        tile.track(nil, partners: [notes])
        #expect(tile.awayParts == [false, false])
        let video = Tab(url: URL(string: "https://video.example.com/")!, title: "Video", spaceID: UUID())
        tile.track(nil, partners: [video])
        #expect(tile.awayParts == [false, true])
        #expect(tile.accessibilityLabel()?.contains("Notes — Video") == true)
        _ = (notes, video)
    }

    @Test func anAwayPageWithoutAnIconYetShowsTheFavoritesOwn() {
        let current = NSImage(size: NSSize(width: 16, height: 16))
        #expect(FavoriteTile.awayIcon(away: true, current: current) === current)
        // Its page's icon isn't known yet: the favorite as it was saved, never a stand-in for that page's.
        #expect(FavoriteTile.awayIcon(away: true, current: nil) == nil)
        #expect(FavoriteTile.awayIcon(away: false, current: current) == nil)
        let favorite = Bookmark(url: saved, title: "Mail", icon: "star")
        let tile = FavoriteTile(bookmark: favorite)
        let away = Tab(url: URL(string: "https://no-icon-yet.example.com/watch")!, title: "Video", spaceID: UUID())
        tile.track(away)
        #expect(tile.awayParts == [true])
        // Its own icon, and no badge of it on the corner.
        #expect(tile.pageIcons[0].image.map(IconChoice.isPageIcon) == true)
        #expect(tile.pageIcons[0].originalIcon == nil)
        _ = away
    }

    /// Made a favorite while its page is still on its way: where that load lands is its page too.
    @Test func aFavoriteMadeWhileItsPageLoadsIsNotAwayWhereItLands() async throws {
        let saved = URL(string: "https://en.wikipedia.org/")!
        // The page sends itself on as it loads, as a site's redirect does.
        let html = "<script>history.replaceState(null, '', '/wiki/Main_Page')</script>Main Page"
        func open(settling: Bool) async throws -> Tab {
            let tab = Tab(url: nil, spaceID: UUID())
            let webView = tab.ensureWebView()
            webView.loadHTMLString(html, baseURL: saved)
            for _ in 0..<100 where !tab.isLoading { try await Task.sleep(for: .milliseconds(10)) }
            #expect(tab.isLoading)
            if settling { tab.settleLandingIfLoading() }
            for _ in 0..<200 where tab.isLoading || tab.url?.path != "/wiki/Main_Page" { try await Task.sleep(for: .milliseconds(20)) }
            #expect(tab.url?.path == "/wiki/Main_Page")
            return tab
        }
        let favorite = try await open(settling: true)
        #expect(favorite.pinnedLanding?.path == "/wiki/Main_Page")
        #expect(!FavoriteTile.isAway(current: favorite.url, saved: saved, landing: favorite.pinnedLanding))
        // The load over, a while longer for a page that sends itself on, then anywhere else is moving on.
        #expect(favorite.landingUntil.map { $0 < Date().addingTimeInterval(9) } == true)
        // One not settled (a plain tab) has no landing: the same page reads as away.
        let plain = try await open(settling: false)
        #expect(plain.pinnedLanding == nil)
        #expect(FavoriteTile.isAway(current: plain.url, saved: saved, landing: plain.pinnedLanding))
        favorite.close()
        plain.close()
    }
}

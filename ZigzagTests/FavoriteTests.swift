import AppKit
import Testing
@testable import Zigzag

/// Favorites are placed by tile, a split's two pages counting as one. These check where they land, away from the saved
/// library.
struct FavoriteTests {
    private let ids = (0..<5).map { _ in UUID() }

    /// A repeated page is added once per profile, keeping the first name and Arc's order.
    @MainActor @Test func importingFavoritesDeduplicatesTheBatchWithinEachProfile() {
        let library = Library.shared
        let work = library.addProfile(name: "Favorite import Work"), home = library.addProfile(name: "Favorite import Home")
        defer {
            library.removeProfile(work.id); library.finishedRemovingProfile(work.id)
            library.removeProfile(home.id); library.finishedRemovingProfile(home.id)
        }
        let mail = Bookmark(url: URL(string: "https://example.com/mail")!, title: "Mail")
        let docs = Bookmark(url: URL(string: "https://example.com/docs")!, title: "Docs")
        let repeated = Bookmark(url: mail.url, title: "Other name")
        #expect(library.appendFavorites([mail, docs, repeated], in: work.id) == 2)
        #expect(library.favorites(in: work.id).map(\.title) == ["Mail", "Docs"])
        #expect(library.appendFavorites([mail, repeated, docs], in: work.id) == 0)
        #expect(library.appendFavorites([repeated], in: home.id) == 1)
        #expect(library.favorites(in: home.id).map(\.title) == ["Other name"])
        #expect(library.favorites(in: work.id).map(\.title) == ["Mail", "Docs"])
    }

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

    /// Rows come out even rather than a full one and a short one: six where four fit are 3 and 3, not 4 and 2. When
    /// all of them fit in one row they stay in one.
    @Test func rowsComeOutEven() {
        for width in [usual, 240, 250, 260, 280] {
            #expect(FavoritesView.columns(for: width, count: 6) == 3, "width \(width)")
            #expect(FavoritesView.columns(for: width, count: 7) == 4, "width \(width)")
            #expect(FavoritesView.columns(for: width, count: 8) == 4, "width \(width)")
        }
        #expect(FavoritesView.columns(for: 250, count: 5) == 3)
        #expect(FavoritesView.columns(for: 400, count: 6) == 6)
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

/// Many favorites never push the space's name over the footer: past its cap the grid scrolls in its own room.
@MainActor struct FavoriteGridCapTests {
    private func sidebar(favorites count: Int, height: CGFloat = 600) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: height))
        let marks = (0..<count).map { (Bookmark(url: URL(string: "about:blank#\($0)")!, title: "F\($0)"), partners: [Bookmark]()) }
        sidebar.favorites.reload(favorites: marks, selectedID: nil)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func fortyFiveFavoritesLeaveTheTitleAndTabsAboveTheFooter() throws {
        let sidebar = sidebar(favorites: 45)
        let list = try #require(sidebar.list.enclosingScrollView).frame
        let footer = try #require(sidebar.downloadsButton.superview).frame
        let title = NSRect(x: list.minX, y: list.minY, width: list.width, height: sidebar.list.headerHeight)
        #expect(title.maxY <= footer.minY)
        #expect(!title.intersects(footer))
        #expect(list.height - sidebar.list.headerHeight > 0)
        // The grid ends above the title and scrolls for the rest.
        #expect(sidebar.favoritesScroll.frame.maxY < title.minY)
        #expect(sidebar.favorites.frame.height > sidebar.favoritesScroll.frame.height)
    }

    @Test func aFewFavoritesShowWhole() {
        for count in [3, 12] {
            let sidebar = sidebar(favorites: count, height: 800)
            #expect(sidebar.favoritesScroll.frame.height - FavoriteTile.badgeOverhang == sidebar.favorites.frame.height)
        }
        #expect(sidebar(favorites: 0).favoritesScroll.isHidden)
    }

    /// A split favorite's × on the top row's last tile is inside what the grid shows, scrolled or not, and the
    /// tiles sit where they did.
    @Test(arguments: [3, 45]) func aCornerCloseButtonIsNeverCutOff(count: Int) throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let marks = (0..<count).map { i in
            (Bookmark(url: URL(string: "about:blank#\(i)")!, title: "F\(i)"), partners: [Bookmark(url: URL(string: "about:blank#p\(i)")!, title: "P\(i)")])
        }
        sidebar.favorites.reload(favorites: marks, selectedID: nil)
        sidebar.layoutSubtreeIfNeeded()
        let scroll = sidebar.favoritesScroll
        let tiles = sidebar.favorites.subviews.compactMap { $0 as? FavoriteTile }.filter { $0.bookmark != nil }
        let first = try #require(tiles.first)
        let last = try #require(tiles.filter { $0.frame.minY == first.frame.minY }.max { $0.frame.maxX < $1.frame.maxX })
        last.layoutSubtreeIfNeeded()
        let grid = sidebar.favorites.convert(sidebar.favorites.bounds, to: sidebar)
        #expect(grid.minX == Tokens.Sidebar.edge)
        #expect(grid.minY == scroll.frame.minY + FavoriteTile.badgeOverhang)
        func badge() -> NSRect { last.convert(last.debugCloseButton.frame, to: sidebar) }
        let shown = scroll.contentView.convert(scroll.contentView.bounds, to: sidebar)
        #expect(shown.contains(badge()))
        #expect(sidebar.bounds.contains(badge()))
        // Scrolled to the end and back to the first tile: the top row and its × show whole again.
        if count > 20 {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: sidebar.favorites.bounds.height - clip.bounds.height))
            scroll.reflectScrolledClipView(clip)
            first.scrollToVisible(first.bounds)
            #expect(clip.bounds.minY == -scroll.contentInsets.top)
            #expect(scroll.contentView.convert(scroll.contentView.bounds, to: sidebar).contains(badge()))
        }
    }

    @Test func theCapIsWholeRowsInHalfTheRoom() {
        let stride = FavoritesView.tileHeight + Tokens.Sidebar.favoriteGap
        for room: CGFloat in [60, 200, 500, 900] {
            let cap = SidebarView.favoritesCap(room: room)
            let rows = (cap + Tokens.Sidebar.favoriteGap) / stride
            #expect(cap >= FavoritesView.tileHeight)
            #expect(cap <= max(room / 2, FavoritesView.tileHeight))
            #expect(rows == rows.rounded())
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

/// Favorite tiles show selected, open, and moved-away like a pinned tab row.
@MainActor struct FavoriteTileStateTests {
    private let saved = URL(string: "https://mail.example.com/inbox")!

    @Test func theTileYouAreOnIsSelectedWhateverElse() {
        #expect(FavoriteTile.look(selected: true, loaded: [true]) == .selected)
        #expect(FavoriteTile.look(selected: true, loaded: []) == .selected)
    }

    @Test func aTileIsOpenOnlyWhileOneOfItsPagesIsLoaded() {
        #expect(FavoriteTile.look(selected: false, loaded: [true]) == .open)
        // A split favorite with one loaded page is open.
        #expect(FavoriteTile.look(selected: false, loaded: [false, true]) == .open)
        // Never opened, asleep, or not loaded since relaunch: closed.
        #expect(FavoriteTile.look(selected: false, loaded: []) == .closed)
        #expect(FavoriteTile.look(selected: false, loaded: [false]) == .closed)
        #expect(FavoriteTile.look(selected: false, loaded: [false, false]) == .closed)
    }

    @Test func aTileIconWearsTheRingOnlyWhileItsPageIsntLoaded() {
        // Not loaded: the sleeping ring, as a tab's; loaded: plain. Full strength either way (#577).
        let left = Bookmark(url: saved, title: "Mail"), right = Bookmark(url: URL(string: "https://notes.example.com/")!, title: "Notes")
        let tile = FavoriteTile(bookmark: left, partners: [right])
        tile.track(nil, partners: [nil])
        #expect(tile.pageIcons.prefix(2).map(\.isUnloaded) == [true, true])
        let notes = Tab(url: right.url, title: "Notes", spaceID: UUID())
        notes.ensureWebView()
        tile.track(nil, partners: [notes])
        #expect(tile.pageIcons.prefix(2).map(\.isUnloaded) == [true, false])
        #expect(tile.pageIcons.allSatisfy { $0.alphaValue == 1 })
        notes.close()
    }

    @Test func onItsSavedPageItIsNotAway() {
        #expect(!FavoriteTile.isAway(current: saved, saved: saved, landing: nil))
        // Same address with http, www, a slash or a fragment.
        #expect(!FavoriteTile.isAway(current: URL(string: "http://www.mail.example.com/inbox/#top")!, saved: saved, landing: nil))
        // Not open: not away.
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
        // The tile holds pages weakly; the tab manager owns them.
        let home = Tab(url: saved, title: "Inbox", spaceID: UUID())
        tile.track(home)
        #expect(tile.awayParts == [false])
        #expect(tile.toolTip?.components(separatedBy: "\n").first == "Mail")
        let away = Tab(url: URL(string: "https://video.example.com/watch")!, title: "Video", spaceID: UUID())
        tile.track(away)
        #expect(tile.awayParts == [true])
        #expect(tile.toolTip?.components(separatedBy: "\n").first == "Mail — Video")
        // Unloaded: not away.
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
        // Unknown page icon: the saved favorite's, never a placeholder.
        #expect(FavoriteTile.awayIcon(away: true, current: nil) == nil)
        #expect(FavoriteTile.awayIcon(away: false, current: current) == nil)
        let favorite = Bookmark(url: saved, title: "Mail", icon: "star")
        let tile = FavoriteTile(bookmark: favorite)
        let away = Tab(url: URL(string: "https://no-icon-yet.example.com/watch")!, title: "Video", spaceID: UUID())
        tile.track(away)
        #expect(tile.awayParts == [true])
        // Its own icon, with no corner badge.
        #expect(tile.pageIcons[0].image.map(IconChoice.isPageIcon) == true)
        #expect(tile.pageIcons[0].originalIcon == nil)
        _ = away
    }

    /// A favorite made while its page loads isn't away where the load ends up.
    @Test func aFavoriteMadeWhileItsPageLoadsIsNotAwayWhereItLands() async throws {
        let saved = URL(string: "https://en.wikipedia.org/")!
        // The page redirects itself while loading.
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
        // After the load plus a grace period, anywhere else counts as away.
        #expect(favorite.landingUntil.map { $0 < Date().addingTimeInterval(9) } == true)
        // An unsettled plain tab has no landing, so the same page reads as away.
        let plain = try await open(settling: false)
        #expect(plain.pinnedLanding == nil)
        #expect(FavoriteTile.isAway(current: plain.url, saved: saved, landing: plain.pinnedLanding))
        favorite.close()
        plain.close()
    }
}

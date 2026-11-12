import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Icons you give a tab, a pinned tab or a favorite (#153): kept with the page across restarts and reopening, from
/// libraries and sessions that never had one, and shown in place of the site's icon.
struct PageIconTests {
    private let url = URL(string: "https://example.com")!

    // MARK: Kept

    @Test func aLibraryFromBeforeIconsOpens() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","url":"https://example.com","title":"Old"}"#
        let bookmark = try JSONDecoder().decode(Bookmark.self, from: Data(json.utf8))
        #expect(bookmark.id == id)
        #expect(bookmark.icon == nil)
    }

    @Test func aBookmarksIconIsSavedAndReadBack() throws {
        for icon in ["🦊", "star.fill"] {
            let bookmark = Bookmark(url: url, title: "Fox", icon: icon)
            let back = try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(bookmark))
            #expect(back == bookmark)
            #expect(back.icon == icon)
        }
    }

    @Test func settingAnIconReachesTheFavoriteOrPinnedPage() {
        let favorite = Bookmark(url: url, title: "F"), pinned = Bookmark(url: url, title: "P"), other = Bookmark(url: url, title: "O")
        var favorites = [favorite]
        var spaces = [SpaceInfo(name: "S", color: .sky, bookmarks: [other, pinned])]

        #expect(Library.setting("🍕", forBookmark: favorite.id, favorites: &favorites, spaces: &spaces))
        #expect(favorites[0].icon == "🍕")
        #expect(spaces[0].bookmarks.allSatisfy { $0.icon == nil })

        #expect(Library.setting("bolt.fill", forBookmark: pinned.id, favorites: &favorites, spaces: &spaces))
        #expect(spaces[0].bookmarks[1].icon == "bolt.fill")
        #expect(spaces[0].bookmarks[0].icon == nil)

        // The same icon again, or a page that isn't there: nothing changes, so nothing is saved or undoable.
        #expect(!Library.setting("bolt.fill", forBookmark: pinned.id, favorites: &favorites, spaces: &spaces))
        #expect(!Library.setting("🍕", forBookmark: UUID(), favorites: &favorites, spaces: &spaces))

        // Use Site Icon.
        #expect(Library.setting(nil, forBookmark: favorite.id, favorites: &favorites, spaces: &spaces))
        #expect(favorites[0].icon == nil)
    }

    @Test func aSessionFromBeforeIconsOpens() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"Old","lastActivated":0,"createdAt":0,"customTitle":"Mine"}"#
        let state = try JSONDecoder().decode(SessionState.TabState.self, from: Data(json.utf8))
        #expect(state.customIcon == nil)
        #expect(state.customTitle == "Mine")
    }

    @Test func aTabsIconComesBackAfterARestart() throws {
        let tab = Tab(url: nil, title: "Page", spaceID: UUID())
        tab.customIcon = "🐙"
        let saved = SessionState.TabState(tab)
        #expect(saved.customIcon == "🐙")
        let read = try JSONDecoder().decode(SessionState.TabState.self, from: JSONEncoder().encode(saved))
        let restored = Tab(id: read.id, url: read.url, title: read.title, spaceID: UUID())
        read.apply(to: restored)
        #expect(restored.customIcon == "🐙")
        #expect(restored.chosenIcon == "🐙")

        // One without an icon comes back without one.
        let plain = Tab(url: nil, title: "Plain", spaceID: UUID())
        let again = Tab(url: nil, title: "Plain", spaceID: UUID())
        SessionState.TabState(plain).apply(to: again)
        #expect(again.customIcon == nil)
    }

    @Test func aReopenedTabKeepsItsIcon() {
        let tab = Tab(url: nil, title: "Page", spaceID: UUID())
        tab.customIcon = "graduationcap.fill"
        tab.customTitle = "School"
        let closed = TabManager.ClosedTab(tab, at: 2)
        #expect(closed.customIcon == "graduationcap.fill")
        let reopened = Tab(url: closed.url, title: closed.title, spaceID: closed.spaceID)
        closed.apply(to: reopened)
        #expect(reopened.customIcon == "graduationcap.fill")
        #expect(reopened.customTitle == "School")
    }

    // MARK: Shown

    @Test func aChosenIconShowsOverTheSitesIcon() {
        let favicon = NSImage(size: NSSize(width: 16, height: 16))
        let chosen = Tab.displayIcon(chosen: "🌵", favicon: favicon)
        #expect(chosen === IconChoice.pageIcon("🌵"))
        #expect(Tab.displayIcon(chosen: nil, favicon: favicon) === favicon)
        #expect(Tab.displayIcon(chosen: nil, favicon: nil) == nil)
    }

    @Test func aPinnedPagesIconOutranksTheTabsOwn() {
        let id = UUID()
        let withIcon = Bookmark(id: id, url: url, title: "P", icon: "⭐️")
        let without = Bookmark(id: id, url: url, title: "P")
        // Any other tab: its own.
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: nil) { _ in withIcon } == "🐢")
        // A pinned page's or favorite's page: that page's, and with none there, the site's (not the tab's old one).
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: id) { _ in withIcon } == "⭐️")
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: id) { _ in without } == nil)
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: id) { _ in nil } == nil)
    }

    @Test func aTabSaysWhenItsIconChanges() {
        let tab = Tab(url: nil, title: "Page", spaceID: UUID())
        var changes: [Tab.Change] = []
        let token = tab.changed.observe { changes.append($0) }
        tab.customIcon = "🎈"
        #expect(changes.contains(.favicon))
        #expect(tab.displayIcon === IconChoice.pageIcon("🎈"))
        changes.removeAll()
        tab.customIcon = "🎈"
        #expect(!changes.contains(.favicon))
        tab.customIcon = nil
        #expect(changes.contains(.favicon))
        #expect(tab.chosenIcon == nil)
        _ = token
    }

    @Test func aBookmarksChosenIconShows() {
        let bookmark = Bookmark(url: url, title: "P", icon: "🎧")
        #expect(bookmark.displayIcon === IconChoice.pageIcon("🎧"))
    }

    @Test func chosenIconsAreMadeOnceAndKnownAsChosen() {
        let symbol = IconChoice.pageIcon("heart.fill"), emoji = IconChoice.pageIcon("🍋")
        #expect(IconChoice.pageIcon("heart.fill") === symbol)
        #expect(IconChoice.isPageIcon(symbol) && IconChoice.isPageIcon(emoji))
        #expect(!IconChoice.isPageIcon(NSImage(size: NSSize(width: 16, height: 16))))
        // A symbol takes the ink around it; an emoji keeps its colors. Both fill a favicon's square.
        #expect(symbol.isTemplate)
        #expect(!emoji.isTemplate)
        #expect(symbol.size == NSSize(width: Tokens.Sidebar.favicon, height: Tokens.Sidebar.favicon))
        #expect(emoji.size == symbol.size)
    }

    @Test func deletingTheEmojiGoesBackToTheSiteIcon() {
        #expect(IconGrid.clearsEmoji(text: "", selected: "🍕"))
        #expect(!IconGrid.clearsEmoji(text: "", selected: "star.fill"))
        #expect(!IconGrid.clearsEmoji(text: "", selected: nil))
        #expect(!IconGrid.clearsEmoji(text: "🍕", selected: "🍕"))
    }
}

import AppKit
import Foundation
import Testing
import WebKit
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

    @Test func clickingTheChosenSymbolAgainTakesItAway() {
        #expect(IconGrid.toggled("star.fill", from: "star.fill") == nil)
        #expect(IconGrid.toggled("star.fill", from: "heart.fill") == "star.fill")
        #expect(IconGrid.toggled("star.fill", from: nil) == "star.fill")
        #expect(IconGrid.toggled("star.fill", from: "🍕") == "star.fill")
    }

    /// Choose Image… and Use Site Icon are the panels' quiet pill, as the downloads panel's Clear is.
    @MainActor @Test func thePickersButtonsAreQuietPills() {
        let panel = IconPickerPanel(noneSymbol: "globe", selected: "star.fill", onChooseImage: {}) { _ in }
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let views = all(panel)
        let pills = views.compactMap { $0 as? PillButton }
        #expect(pills.count == 2)
        #expect(pills.allSatisfy { $0.style == .quiet })
        #expect(!views.contains { $0 is TextButton })
    }
}

/// Site-wide icon from Site Controls (#310): under a tab's own, per site with subdomains, removable in Settings, per window in private ones.
@MainActor
@Suite(.serialized)
struct SiteIconTests {
    /// A unique site so parallel tests never see its icon.
    private let site = "site-icon-\(UUID().uuidString.prefix(8).lowercased()).test"
    private var url: URL { URL(string: "https://www.\(site)/page")! }

    private func withDefaults(_ body: () throws -> Void) throws {
        let suite = "zigzag-site-icons-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SiteIcons.defaults
        SiteIcons.defaults = defaults
        defer {
            SiteIcons.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try body()
    }

    @Test func aTabsOwnIconWinsOverTheSitesAndTheSitesOverItsFavicon() {
        let id = UUID()
        let withIcon = Bookmark(id: id, url: url, title: "P", icon: "⭐️")
        let without = Bookmark(id: id, url: url, title: "P")
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: nil, site: "🌐") { _ in nil } == "🐢")
        #expect(Tab.chosenIcon(own: nil, bookmarkID: nil, site: "🌐") { _ in nil } == "🌐")
        #expect(Tab.chosenIcon(own: nil, bookmarkID: nil, site: nil) { _ in nil } == nil)
        // A pinned page's or favorite's icon first, then the site's.
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: id, site: "🌐") { _ in withIcon } == "⭐️")
        #expect(Tab.chosenIcon(own: "🐢", bookmarkID: id, site: "🌐") { _ in without } == "🌐")
        let favicon = NSImage(size: NSSize(width: 16, height: 16))
        #expect(Tab.displayIcon(chosen: "🌐", favicon: favicon) === IconChoice.pageIcon("🌐"))
    }

    @Test func everyTabAndPageOnTheSiteShowsIt() throws {
        try withDefaults {
            let first = Tab(url: url, spaceID: UUID())
            let second = Tab(url: URL(string: "https://\(site)/other")!, spaceID: UUID())
            let elsewhere = Tab(url: URL(string: "https://elsewhere-\(site)/")!, spaceID: UUID())
            #expect(first.chosenIcon == nil)
            SiteIcons.set("🦉", forSite: site)
            [first, second, elsewhere].forEach { $0.refreshChosenIcon() }
            #expect(first.displayIcon === IconChoice.pageIcon("🦉"))
            #expect(second.displayIcon === IconChoice.pageIcon("🦉"))
            #expect(elsewhere.chosenIcon == nil)
            // Tabs created later get it immediately.
            #expect(Tab(url: url, spaceID: UUID()).chosenIcon == "🦉")
            // A tab's own icon wins; clearing it shows the site's again.
            first.customIcon = "🐙"
            #expect(first.chosenIcon == "🐙")
            first.customIcon = nil
            #expect(first.chosenIcon == "🦉")
            // A pinned page or favorite without a tab, and one with its own icon.
            #expect(Bookmark(url: url, title: "P").displayIcon === IconChoice.pageIcon("🦉"))
            #expect(Bookmark(url: url, title: "P", icon: "🎧").displayIcon === IconChoice.pageIcon("🎧"))
            // History and the command bar, by URL.
            #expect(SiteIcons.shownIcon(for: url) === IconChoice.pageIcon("🦉"))
            let rule = SiteRoutes.Route(match: .path, site: site + "/example", spaceID: UUID())
            let row = SiteRouteRow(rule)
            row.refresh(rule, spaces: [], number: 1)
            #expect(row.subviews.compactMap { $0 as? FaviconView }.first?.image === IconChoice.pageIcon("🦉"))
        }
    }

    @Test func itIsKeptUnderTheSiteAndCoversItsSubdomains() throws {
        try withDefaults {
            #expect(SiteIcons.site(of: url) == site)
            #expect(SiteIcons.site(of: URL(string: "file:///tmp/a.html")) == nil)
            #expect(SiteIcons.site(of: URL(string: "zigzag://settings")) == nil)
            SiteIcons.set("star.fill", forSite: site)
            #expect(SiteIcons.all == [site: "star.fill"])
            #expect(SiteIcons.defaults.dictionary(forKey: "SiteIcons") as? [String: String] == [site: "star.fill"])
            // Subdomains inherit the site's until they set their own.
            let mail = "mail.\(site)"
            #expect(SiteIcons.icon(forSite: mail) == "star.fill")
            SiteIcons.set("envelope.fill", forSite: mail)
            #expect(SiteIcons.icon(forSite: mail) == "envelope.fill")
            #expect(SiteIcons.icon(forSite: site) == "star.fill")
            // Use Site Icon on the subdomain restores its favicon.
            SiteIcons.set(nil, forSite: mail)
            #expect(SiteIcons.icon(forSite: mail) == nil)
            #expect(SiteIcons.all.isEmpty)
        }
    }

    @Test func forgetAndResetAllClearIt() throws {
        try withDefaults {
            SiteIcons.set("🍕", forSite: site)
            SiteIcons.set("🍔", forSite: "other-\(site)")
            #expect(SiteIcons.sites == [site, "other-\(site)"])
            SiteIcons.forget(site: site)
            #expect(SiteIcons.icon(forSite: site) == nil)
            #expect(SiteIcons.icon(forSite: "other-\(site)") == "🍔")
            SiteIcons.forgetAll()
            #expect(SiteIcons.sites.isEmpty)
            #expect(SiteIcons.defaults.object(forKey: "SiteIcons") == nil)
        }
    }

    @Test func aPrivateWindowsIconIsItsOwn() throws {
        try withDefaults {
            SiteIcons.set("🌳", forSite: site)
            let window = WKWebsiteDataStore.nonPersistent(), other = WKWebsiteDataStore.nonPersistent()
            // Starts from the kept icons.
            #expect(SiteIcons.icon(forSite: site, privateStore: window) == "🌳")
            SiteIcons.set("🎭", forSite: site, privateStore: window)
            SiteIcons.set("🎩", forSite: "other-\(site)", privateStore: window)
            #expect(SiteIcons.icon(forSite: site, privateStore: window) == "🎭")
            // Nothing persists and other windows don't see it.
            #expect(SiteIcons.all == [site: "🌳"])
            #expect(SiteIcons.icon(forSite: site, privateStore: other) == "🌳")
            #expect(SiteIcons.icon(forSite: "other-\(site)") == nil)
            // Use Site Icon there clears it for that window only.
            SiteIcons.set(nil, forSite: site, privateStore: window)
            #expect(SiteIcons.icon(forSite: site, privateStore: window) == nil)
            #expect(SiteIcons.icon(forSite: site) == "🌳")
            // Its tabs show its own.
            let tab = Tab(url: url, spaceID: UUID())
            tab.privateStore = other
            #expect(tab.chosenIcon == "🌳")
            SiteIcons.set("🎪", forSite: site, privateStore: other)
            tab.refreshChosenIcon()
            #expect(tab.chosenIcon == "🎪")
            #expect(SiteIcons.all == [site: "🌳"])
        }
    }
}

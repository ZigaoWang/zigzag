import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Settings › Search › Site Search and the command bar's Tab into a site (specs/settings.md, Search).
@MainActor @Suite(.serialized) struct SiteSearchTests {
    private static let taobao = "http://127.0.0.1:9/search?q=%s"

    /// A store of its own for each test, put back afterwards.
    private func withStore(_ body: () async throws -> Void) async rethrows {
        let name = "SiteSearchTests.\(UUID().uuidString)"
        let previous = SiteSearches.defaults
        SiteSearches.defaults = UserDefaults(suiteName: name)!
        defer {
            SiteSearches.defaults.removePersistentDomain(forName: name)
            SiteSearches.defaults = previous
        }
        try await body()
    }

    @Test func aSiteYouAddIsSearchedWithItsKeyword() async throws {
        try await withStore {
            let saved = try #require(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "TB", template: Self.taobao)))
            #expect(SiteSearches.custom == [saved])
            let site = try #require(SiteSearch.match("tb"))
            #expect(site.name == "Taobao" && site.isCustom)
            #expect(SiteSearch.match("Taob")?.name == "Taobao")
            #expect(site.url(for: "red shoes")?.absoluteString == "http://127.0.0.1:9/search?q=red%20shoes")
            // Built-ins still answer as before.
            #expect(SiteSearch.match("yt")?.name == "YouTube")
        }
    }

    @Test func editingASiteChangesItsKeywordAndAddress() async throws {
        try await withStore {
            var site = try #require(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "tb", template: Self.taobao)))
            site.keyword = "taob"
            site.template = "http://127.0.0.1:9/s?k={query}"
            #expect(SiteSearches.save(site) != nil)
            #expect(SiteSearches.custom.count == 1)
            #expect(SiteSearches.custom[0].template == "http://127.0.0.1:9/s?k=%s")
            #expect(SiteSearch.match("tb") == nil)
            #expect(SiteSearch.match("taob")?.url(for: "x")?.absoluteString == "http://127.0.0.1:9/s?k=x")
            // Turned off, it's left out.
            SiteSearches.setEnabled(false, custom: site.id)
            #expect(SiteSearch.match("taob") == nil)
        }
    }

    @Test func removingASiteTakesItsKeywordAway() async throws {
        try await withStore {
            let site = try #require(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "tb", template: Self.taobao)))
            SiteSearches.remove(site.id)
            #expect(SiteSearches.custom.isEmpty)
            #expect(SiteSearch.match("tb") == nil)
            #expect(SiteSearches.defaults.data(forKey: SiteSearches.key) == nil)
        }
    }

    @Test func aKeywordAlreadyUsedIsRefused() async throws {
        try await withStore {
            let first = try #require(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "tb", template: Self.taobao)))
            #expect(SiteSearches.problem(name: "Other", keyword: "TB", template: Self.taobao) == .keywordTaken("Taobao"))
            #expect(SiteSearches.save(CustomSiteSearch(name: "Other", keyword: "Tb", template: Self.taobao)) == nil)
            // A built-in's, whatever its case, while it's on.
            #expect(SiteSearches.problem(name: "Other", keyword: "YT", template: Self.taobao) == .keywordTaken("YouTube"))
            SiteSearches.setOn(false, builtIn: "youtube")
            #expect(SiteSearches.problem(name: "Other", keyword: "yt", template: Self.taobao) == nil)
            // Its own keyword is no clash when it's saved again.
            #expect(SiteSearches.problem(name: "Taobao", keyword: "tb", template: Self.taobao, editing: first.id) == nil)
            #expect(SiteSearches.problem(name: "Other", keyword: "t b", template: Self.taobao) == .spaceInKeyword)
            #expect(SiteSearches.problem(name: "Other", keyword: "t", template: Self.taobao) == .keywordTooShort)
            #expect(SiteSearches.problem(name: " ", keyword: "ot", template: Self.taobao) == .noName)
        }
    }

    @Test func anAddressThatCantSearchIsRefused() async throws {
        try await withStore {
            for bad in ["", "http://127.0.0.1:9/search", "http://127.0.0.1:9/?q=%s&r=%s", "ftp://example.com/?q=%s",
                        "http://127.0.0.1:9/?q=%s&r={query}"] {
                #expect(SiteSearches.problem(name: "Taobao", keyword: "tb", template: bad) == .invalidTemplate, "\(bad)")
            }
            #expect(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "tb", template: "http://127.0.0.1:9/search")) == nil)
            #expect(SiteSearches.custom.isEmpty)
            #expect(SiteSearches.template("s.taobao.com/search?q={query}") == "https://s.taobao.com/search?q=%s")
        }
    }

    @Test func aBuiltInTurnedOffIsNotOffered() async throws {
        try await withStore {
            SiteSearches.setOn(false, builtIn: "youtube")
            #expect(SiteSearch.match("youtube") == nil)
            #expect(!SiteSearch.all.contains { $0.id == "youtube" })
            SiteSearches.setOn(true, builtIn: "youtube")
            #expect(SiteSearch.match("youtube")?.name == "YouTube")
        }
    }

    @Test func tabSearchesASiteYouAddedAndBackspaceLeavesIt() async throws {
        try await withStore {
            #expect(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "tb", template: Self.taobao)) != nil)
            let space = Library.shared.spaces[0].id
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: nil, title: "A", spaceID: space)
            manager.adopt([tab], in: space)
            manager.select(tab)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 900, height: 600))
            defer { controller.window?.close() }
            controller.newTab(nil)
            let bar = controller.commandBar
            defer { if bar.isVisible { bar.debugEscape(); bar.debugEscape() } }
            bar.debugType("tb")
            #expect(bar.debugState["hint"] as? String == "Search Taobao")
            bar.debugTab()
            #expect(bar.debugState["chip"] as? String == "Taobao")
            #expect(bar.isSearchingSite)
            bar.debugType("shoes")
            let rows = try #require(bar.debugState["rows"] as? [[String: Any]])
            #expect(rows.first?["kind"] as? String == "searchOn(http://127.0.0.1:9/search?q=shoes)")
            #expect(rows.first?["detail"] as? String == "Search Taobao")
            bar.debugType("")
            bar.debugBackspace()
            #expect(bar.debugState["chip"] as? String == "")
            #expect(bar.debugState["typed"] as? String == "tb")
        }
    }

    @Test func settingsListsYourSitesThenZigzagsOwn() async throws {
        try await withStore {
            #expect(SiteSearches.save(CustomSiteSearch(name: "Taobao", keyword: "tb", template: Self.taobao)) != nil)
            let settings = SettingsView(pane: .search)
            settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
            settings.layoutSubtreeIfNeeded()
            let rows = settings.debugSiteSearchRows
            #expect(rows.first == "Taobao")
            #expect(rows.dropFirst().first == "\(SiteSearch.builtIn.count) sites from Zigzag")
            // Removed elsewhere, the list follows.
            SiteSearches.remove(SiteSearches.custom[0].id)
            #expect(settings.debugSiteSearchRows.first == "\(SiteSearch.builtIn.count) sites from Zigzag")
        }
    }
}

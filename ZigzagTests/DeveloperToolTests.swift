import AppKit
import Testing
@testable import Zigzag

/// The developer tools' commands (#141): where each is offered, and that the menu bar has them only while Developer
/// tools is on.
@MainActor
@Suite(.serialized)
struct DeveloperToolTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DeveloperToolTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
    }

    private let local = URL(string: "http://localhost:3000/")
    private let other = URL(string: "https://example.com/")

    @Test func listingASiteIsOfferedOnAnyWebPageWhileTheToolsAreOn() {
        func offered(isOn: Bool = true, url: URL?, isPrivate: Bool = false) -> Bool {
            DeveloperTool.isOffered(.site, isOn: isOn, isDevelopment: false, url: url, isPrivate: isPrivate)
        }
        #expect(offered(url: other))
        #expect(offered(url: local))
        #expect(!offered(isOn: false, url: other))
        #expect(!offered(url: other, isPrivate: true))
        #expect(!offered(url: URL(string: "file:///index.html")))
        #expect(!offered(url: nil))
    }

    @Test func theOtherToolsAreOfferedOnlyOnADevelopmentTab() {
        for tool in DeveloperTool.allCases where tool != .site {
            #expect(DeveloperTool.isOffered(tool, isOn: true, isDevelopment: true, url: local, isPrivate: false))
            #expect(!DeveloperTool.isOffered(tool, isOn: true, isDevelopment: false, url: other, isPrivate: false))
            // A private window keeps nothing to clear; the rest work there as anywhere.
            let clears = tool == .clearCache || tool == .clearCookies
            #expect(DeveloperTool.isOffered(tool, isOn: true, isDevelopment: true, url: local, isPrivate: true) == !clears)
        }
    }

    @Test func aPageInAPrivateWindowIsNotOfferedTheList() {
        #expect(DevelopmentSites.isOffered(for: local, isPrivate: false))
        #expect(!DevelopmentSites.isOffered(for: local, isPrivate: true))
        #expect(!DevelopmentSites.isOffered(for: URL(string: "file:///index.html"), isPrivate: false))
        #expect(!DevelopmentSites.isOffered(for: nil, isPrivate: false))
    }

    @Test func aPagePutsItsSiteOnTheListAndTakesOffWhatCoversIt() {
        withDefaults {
            #expect(DevelopmentSites.entry(covering: URL(string: "http://api.localhost:8080/")) == "localhost")
            #expect(DevelopmentSites.entry(covering: other) == nil)
            #expect(DevelopmentSites.name(for: URL(string: "http://www.app.localtest.me:3000/x")) == "app.localtest.me")
            DevelopmentSites.set(true, for: URL(string: "http://www.app.localtest.me:3000/x"))
            #expect(DevelopmentSites.sites == ["127.0.0.1", "app.localtest.me", "localhost"])
            DevelopmentSites.set(false, for: URL(string: "http://api.localhost:8080/"))
            #expect(DevelopmentSites.sites == ["127.0.0.1", "app.localtest.me"])
            DevelopmentSites.set(false, for: other)
            #expect(DevelopmentSites.sites == ["127.0.0.1", "app.localtest.me"])
        }
    }

    @Test func eachToolIsACommandUnderItsOwnName() {
        for tool in DeveloperTool.allCases {
            #expect(DeveloperTool(commandID: tool.commandID) == tool)
            #expect(!tool.title.isEmpty && !tool.keywords.isEmpty)
        }
        #expect(DeveloperTool(commandID: "clear-cache") == nil)
        #expect(DeveloperTool(commandID: "developer:nothing") == nil)
        // "Clear Cache…" and clear-cache are every site's; this site's have their own.
        #expect(!CommandRanker.actions.map(\.id).contains(DeveloperTool.clearCache.commandID))
    }

    @Test func theCommandBarOffersTheToolsThatApply() {
        var context = CommandRanker.Context()
        #expect(!CommandRanker.contextActions(context).contains { $0.id.hasPrefix(DeveloperTool.commandPrefix) })
        context.developerTools = [.site, .clearCache]
        let ids = CommandRanker.contextActions(context).map(\.id)
        // Listing the site is named for what it will do.
        #expect(CommandRanker.contextActions(context).first { $0.id == "developer:site" }?.title == DeveloperTool.siteTitle(listed: false))
        context.isDevelopmentSite = true
        #expect(CommandRanker.contextActions(context).first { $0.id == "developer:site" }?.title == DeveloperTool.siteTitle(listed: true))
        #expect(DeveloperTool.siteTitle(listed: true) != DeveloperTool.siteTitle(listed: false))
        #expect(ids.contains("developer:site") && ids.contains("developer:clear-cache") && !ids.contains("developer:clear-cookies"))
        // In a private window too, where the spaces' commands are left out.
        context.isPrivate = true
        #expect(CommandRanker.contextActions(context).map(\.id).contains("developer:clear-cache"))
    }

    private func sizeCommands(_ context: CommandRanker.Context) -> [CommandRanker.Action] {
        CommandRanker.contextActions(context).filter { $0.id.hasPrefix("developer-size:") }
    }
    private static func isIPhone16(_ action: CommandRanker.Action) -> Bool { action.keywords.contains("iphone") && action.keywords.contains("16") }

    /// The listed sizes are commands by name, where Page Size is offered, and each id leads back to its size.
    @Test func theCommandBarOffersEachListedSizeByName() {
        withDefaults {
            var context = CommandRanker.Context()
            context.pageSizes = PageSizes.all
            #expect(sizeCommands(context).isEmpty)
            context.developerTools = [.sizeFill, .sizeCustom]
            let sizes = sizeCommands(context)
            #expect(sizes.count == PageSizes.all.count)
            let phone = sizes.first(where: Self.isIPhone16)
            #expect(phone?.symbol == "iphone")
            #expect(phone.flatMap { PageSizes.size(commandID: $0.id) }?.size == CGSize(width: 393, height: 852))
            #expect(PageSizes.size(commandID: "developer-size:999") == nil && PageSizes.size(commandID: "developer:size-fill") == nil)
        }
    }

    private func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { $0.submenu.map(items) ?? [$0] } }
    private func actions(_ menu: NSMenu) -> [Selector] { items(menu).compactMap(\.action) }

    @Test func theMenuBarHasTheToolsOnlyWhileDeveloperToolsIsOn() {
        withDefaults {
            DeveloperTools.isOn = false
            let menu = MainMenu.build()
            let without = items(menu).map(\.title)
            for tool in DeveloperTool.menuItems { #expect(!actions(menu).contains(tool.action)) }

            #expect(MainMenu.setDeveloperTools(true, in: menu))
            #expect(!MainMenu.setDeveloperTools(true, in: menu))
            for tool in DeveloperTool.menuItems { #expect(actions(menu).filter { $0 == tool.action }.count == 1) }
            let site = items(menu).first { $0.action == DeveloperTool.site.action }
            #expect(site?.keyEquivalent == "d" && site?.keyEquivalentModifierMask == [.command, .option, .shift])
            // After the ones always there, under a line of their own.
            let developer = site?.menu?.items ?? []
            #expect(developer.first?.action == #selector(BrowserWindowController.showWebInspector(_:)))
            #expect(developer.filter(\.isSeparatorItem).count == 1)

            #expect(MainMenu.setDeveloperTools(false, in: menu))
            #expect(!MainMenu.setDeveloperTools(false, in: menu))
            #expect(items(menu).map(\.title) == without)
        }
    }

    @Test func builtWithDeveloperToolsOnTheMenuBarHasThem() {
        withDefaults {
            let menu = MainMenu.build()
            // Every tool has an item, the ones that were always there included.
            for tool in DeveloperTool.allCases where tool != .settings { #expect(actions(menu).contains(tool.action)) }
        }
    }

    @Test func clearingASiteWithAPortSaysEveryPortGoes() {
        let note = BrowserWindowController.everyPortNote(for: URL(string: "http://www.app.test:3000/admin")!, site: "app.test")
        #expect(note?.contains("app.test") == true && note?.contains("3000") == true && note?.contains("www") == false)
        #expect(BrowserWindowController.everyPortNote(for: URL(string: "https://example.com/")!, site: "example.com") == nil)
        #expect(BrowserWindowController.everyPortNote(for: URL(string: "http://localhost/")!, site: "localhost") == nil)
        // The port every address of its kind has says nothing.
        #expect(BrowserWindowController.everyPortNote(for: URL(string: "https://localhost:443/")!, site: "localhost") == nil)
        #expect(BrowserWindowController.everyPortNote(for: URL(string: "http://localhost:80/")!, site: "localhost") == nil)
        #expect(BrowserWindowController.everyPortNote(for: URL(string: "http://localhost:443/")!, site: "localhost") != nil)
    }
}

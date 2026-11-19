import AppKit
import Testing
@testable import Zigzag

/// Extensions' items in a page's right-click menu go in once, whether WebKit put them there or Zigzag does (#186).
@MainActor
struct ExtensionMenuItemsTests {
    private func pageItem(_ title: String, _ identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    private func item(_ title: String, under children: [String] = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if !children.isEmpty {
            let submenu = NSMenu()
            children.forEach { submenu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
            item.submenu = submenu
        }
        return item
    }

    /// The page's menu as WebKit makes it, with Bitwarden's item already in it.
    private func webKitMenu() -> [NSMenuItem] {
        [pageItem("Back", "WKMenuItemIdentifierGoBack"), pageItem("Reload", "WKMenuItemIdentifierReload"),
         pageItem("Inspect Element", "WKMenuItemIdentifierInspectElement"), .separator(),
         item("Bitwarden", under: ["Autofill login", "Copy username", "Generate password"])]
    }

    @Test func anItemWebKitAddedIsNotAddedAgain() {
        let existing = webKitMenu()
        let ours = item("Bitwarden", under: ["Autofill login", "Copy username", "Generate password"])
        let plan = ExtensionMenuItems.plan(existing: existing, extensions: [("bitwarden", [ours])], isPrivate: false)
        #expect(plan.added.isEmpty)
        #expect(plan.adopted.count == 1)
        #expect(plan.adopted.first?.item === existing.last)
        #expect(plan.adopted.first?.id == "bitwarden")
        #expect(plan.removed.isEmpty)
    }

    @Test func anItemWebKitLeftOutIsAdded() {
        let ours = item("Translate this page")
        let plan = ExtensionMenuItems.plan(existing: webKitMenu(), extensions: [("bitwarden", [item("Bitwarden", under: ["Autofill login", "Copy username", "Generate password"])]),
                                                                              ("translate", [ours])], isPrivate: false)
        #expect(plan.added.map(\.id) == ["translate"])
        #expect(plan.added.first?.item === ours)
        #expect(plan.adopted.map(\.id) == ["bitwarden"])
    }

    @Test func theSameItemTwiceGoesInOnce() {
        let plan = ExtensionMenuItems.plan(existing: [pageItem("Reload", "WKMenuItemIdentifierReload")],
                                           extensions: [("fixture", [item("Menu Fixture Item"), item("Menu Fixture Item")])], isPrivate: false)
        #expect(plan.added.count == 1)
    }

    @Test func twoExtensionsWithTheSameTitleEachKeepTheirs() {
        let existing = [pageItem("Reload", "WKMenuItemIdentifierReload"), .separator(), item("Translate"), item("Translate")]
        let plan = ExtensionMenuItems.plan(existing: existing, extensions: [("one", [item("Translate")]), ("two", [item("Translate")])], isPrivate: false)
        #expect(plan.added.isEmpty)
        #expect(plan.adopted.map(\.id) == ["one", "two"])
        #expect(plan.adopted[0].item !== plan.adopted[1].item)
    }

    @Test func aDifferentSubmenuIsADifferentItem() {
        let plan = ExtensionMenuItems.plan(existing: webKitMenu(), extensions: [("other", [item("Bitwarden", under: ["Something else"])])], isPrivate: false)
        #expect(plan.added.count == 1)
        #expect(plan.adopted.isEmpty)
    }

    @Test func thePagesOwnItemsAreNeverTakenForAnExtensions() {
        let existing = [pageItem("Reload", "WKMenuItemIdentifierReload")]
        let plan = ExtensionMenuItems.plan(existing: existing, extensions: [("named", [item("Reload")])], isPrivate: false)
        #expect(plan.adopted.isEmpty)
        #expect(plan.added.count == 1)
    }

    @Test func aPrivateTabShowsNone() {
        let existing = webKitMenu()
        let plan = ExtensionMenuItems.plan(existing: existing, extensions: [], isPrivate: true)
        #expect(plan.removed.count == 1)
        #expect(plan.removed.first === existing.last)
        #expect(plan.added.isEmpty && plan.adopted.isEmpty)
    }

    /// In a private tab only extensions allowed there are listed: theirs stay, anyone else's WebKit put in go (#353).
    @Test func aPrivateTabShowsOnlyAllowedExtensions() {
        let existing = webKitMenu() + [item("Translate this page")]
        let plan = ExtensionMenuItems.plan(existing: existing, extensions: [("bitwarden", [item("Bitwarden", under: ["Autofill login", "Copy username", "Generate password"])])],
                                           isPrivate: true)
        #expect(plan.adopted.map(\.id) == ["bitwarden"])
        #expect(plan.removed.count == 1)
        #expect(plan.removed.first === existing.last)
        #expect(plan.added.isEmpty)
    }
    // MARK: Kept across relaunches (#239)

    /// Downie adds items on install only; Zigzag persists them like Chrome, with every change.
    @available(macOS 15.4, *)
    @Test func menuItemsAreKeptWithTheirChanges() {
        var items = BridgeContextMenus.apply("create", args: [["id": "open-in-downie", "title": "Open link in Downie", "contexts": ["link"]]], to: [])
        items = BridgeContextMenus.apply("create", args: [["id": "mp4", "title": "MP4", "contexts": ["page"]]], to: items)
        items = BridgeContextMenus.apply("create", args: [["id": "mp4-hd", "parentId": "mp4", "title": "HD"]], to: items)
        items = BridgeContextMenus.apply("create", args: [["title": "No ID"]], to: items)
        #expect(items.compactMap { $0["id"] as? String } == ["open-in-downie", "mp4", "mp4-hd"])
        // Recreated with the same ID: replaced in place.
        items = BridgeContextMenus.apply("create", args: [["id": "open-in-downie", "title": "Send to Downie", "contexts": ["link"]]], to: items)
        #expect(items.first?["title"] as? String == "Send to Downie")
        items = BridgeContextMenus.apply("update", args: ["mp4", ["title": "MP4 video", "id": "renamed", "enabled": false]], to: items)
        // The title as created; a selection-dependent title is never stored.
        #expect(items[1]["title"] as? String == "MP4")
        #expect(items[1]["enabled"] as? Bool == false)
        #expect(items[1]["id"] as? String == "mp4")
        // Removing one removes its children.
        items = BridgeContextMenus.apply("remove", args: ["mp4"], to: items)
        #expect(items.compactMap { $0["id"] as? String } == ["open-in-downie"])
        #expect(BridgeContextMenus.apply("removeAll", args: [], to: items).isEmpty)
    }

    /// A search item keeps its %s title on disk, never the selected text.
    @available(macOS 15.4, *)
    @Test func selectedTextIsNeverKept() {
        var items = BridgeContextMenus.apply("create", args: [["id": "search", "title": "Search “%s”", "contexts": ["selection"]]], to: [])
        items = BridgeContextMenus.apply("update", args: ["search", ["title": "Search “my bank PIN”"]], to: items)
        #expect(items.count == 1)
        #expect(items.first?["title"] as? String == "Search “%s”")
        let data = try! #require(BridgeContextMenus.encoded(.init(version: "1", items: items)))
        #expect(!String(decoding: data, as: UTF8.self).contains("bank"))
    }

    /// Items over 4 KB are dropped and the file stays under 256 KB.
    @available(macOS 15.4, *)
    @Test func keptItemsHaveALimit() {
        let big = String(repeating: "x", count: BridgeContextMenus.maxItemBytes)
        #expect(BridgeContextMenus.apply("create", args: [["id": "big", "title": big]], to: []).isEmpty)
        var items = BridgeContextMenus.apply("create", args: [["id": "a", "title": "A"]], to: [])
        items = BridgeContextMenus.apply("update", args: ["a", ["documentUrlPatterns": [big]]], to: items)
        #expect(items.first?["documentUrlPatterns"] == nil)
        let many = (0..<BridgeContextMenus.maxItems).map { ["id": "item\($0)", "title": String(repeating: "y", count: 1000)] as [String: Any] }
        let data = try! #require(BridgeContextMenus.encoded(.init(version: "1", items: many)))
        #expect(data.count <= BridgeContextMenus.maxFileBytes)
        let saved = try! #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kept = saved["items"] as? [[String: Any]] ?? []
        #expect(!kept.isEmpty && kept.count < many.count)
        #expect(kept.first?["id"] as? String == "item0")
    }

    @available(macOS 15.4, *)
    @Test func keptItemsComeBackOnlyToTheSameVersionAsItStarts() {
        let kept = BridgeContextMenus.Kept(version: "1.3.3", items: [["id": "mp4", "title": "MP4", "contexts": ["page"]]])
        #expect(BridgeContextMenus.toRestore(kept, version: "1.3.3", isNewInstall: false, persistentBackground: false).count == 1)
        // Installs and updates add their own; a persistent background adds them at start.
        #expect(BridgeContextMenus.toRestore(kept, version: "1.3.3", isNewInstall: true, persistentBackground: false).isEmpty)
        #expect(BridgeContextMenus.toRestore(kept, version: "1.4", isNewInstall: false, persistentBackground: false).isEmpty)
        #expect(BridgeContextMenus.toRestore(kept, version: "1.3.3", isNewInstall: false, persistentBackground: true).isEmpty)
        // Items made before persistence existed: the extension gets one update event to add them again.
        #expect(BridgeContextMenus.addsItemsAgain(neverKept: true, isNewInstall: false, persistentBackground: false))
        #expect(!BridgeContextMenus.addsItemsAgain(neverKept: false, isNewInstall: false, persistentBackground: false))
        #expect(!BridgeContextMenus.addsItemsAgain(neverKept: true, isNewInstall: true, persistentBackground: false))
        #expect(!BridgeContextMenus.addsItemsAgain(neverKept: true, isNewInstall: false, persistentBackground: true))
    }

    /// Downie's button opens its app link: no popup or tab, but it counts as handled, so options stay closed.
    @available(macOS 15.4, *)
    @Test func aClickThatSendsTheTabSomewhereDidSomething() {
        let clicked = Date()
        let soon = clicked.addingTimeInterval(0.1), earlier = clicked.addingTimeInterval(-60)
        #expect(!ExtensionHost.clickShowedNothing(clickedAt: clicked, popupShown: false, sidePanelShown: false, tabsBefore: 2, tabsNow: 2, tabLoadedAt: soon))
        #expect(ExtensionHost.clickShowedNothing(clickedAt: clicked, popupShown: false, sidePanelShown: false, tabsBefore: 2, tabsNow: 2, tabLoadedAt: earlier))
        #expect(ExtensionHost.clickShowedNothing(clickedAt: clicked, popupShown: false, sidePanelShown: false, tabsBefore: 2, tabsNow: 2, tabLoadedAt: nil))
        #expect(!ExtensionHost.clickShowedNothing(clickedAt: clicked, popupShown: true, sidePanelShown: false, tabsBefore: 2, tabsNow: 2, tabLoadedAt: nil))
        #expect(!ExtensionHost.clickShowedNothing(clickedAt: clicked, popupShown: false, sidePanelShown: true, tabsBefore: 2, tabsNow: 2, tabLoadedAt: nil))
        #expect(!ExtensionHost.clickShowedNothing(clickedAt: clicked, popupShown: false, sidePanelShown: false, tabsBefore: 2, tabsNow: 3, tabLoadedAt: nil))
    }
}

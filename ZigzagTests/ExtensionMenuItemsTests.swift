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
}

import AppKit
import Testing
@testable import Zigzag

/// The Web Inspector is where Chrome's habits look for it: last in a page's menu, and on Chrome's keys.
@MainActor
struct DeveloperToolsTests {
    private func item(_ title: String, _ identifier: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        return item
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    @Test func inspectElementGoesBelowExtensions() {
        let menu = NSMenu()
        [item("Back"), item("Reload"), .separator(), item("Inspect Element", "WKMenuItemIdentifierInspectElement"),
         .separator(), item("Save to Notion")].forEach(menu.addItem)
        BrowserWebView.placeInspectElementLast(in: menu)
        #expect(titles(menu) == ["Back", "Reload", "-", "Save to Notion", "-", "Inspect Element"])
    }

    @Test func alreadyLastIsLeftAlone() {
        let menu = NSMenu()
        [item("Back"), .separator(), item("Inspect Element", "WKMenuItemIdentifierInspectElement")].forEach(menu.addItem)
        BrowserWebView.placeInspectElementLast(in: menu)
        #expect(titles(menu) == ["Back", "-", "Inspect Element"])
    }

    @Test func developerMenuHasChromesKeys() throws {
        func find(_ menu: NSMenu, _ action: Selector) -> [NSMenuItem] {
            menu.items.flatMap { ($0.submenu.map { find($0, action) } ?? []) + ($0.action == action ? [$0] : []) }
        }
        let menu = MainMenu.build()
        let keys = { (action: Selector) in find(menu, action).map { "\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)" } }
        let commandOption = NSEvent.ModifierFlags([.command, .option]).rawValue
        #expect(keys(#selector(BrowserWindowController.showWebInspector(_:))) == ["\(commandOption) i", "0 \(String(UnicodeScalar(NSF12FunctionKey)!))"])
        #expect(keys(#selector(BrowserWindowController.showJavaScriptConsole(_:))) == ["\(commandOption) j"])
        #expect(keys(#selector(BrowserWindowController.inspectElement(_:))) == ["\(commandOption) c"])
    }
}

/// A link's menu starts as Chrome's does, not with an Open Link that a click already does (#419).
@MainActor
struct LinkMenuTests {
    private func menu(_ items: [(String, String?)]) -> NSMenu {
        let menu = NSMenu()
        for (title, identifier) in items {
            if title == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(NSText.copy(_:)), keyEquivalent: "")
            item.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
            menu.addItem(item)
        }
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    private let opens = ["Open Link in New Tab", "Open Link in New Window", "Open Link in Private Window", "Open Link in Zigzag Mini", "Open Link"]

    @Test func newTabComesFirst() {
        let link = menu([("Open Link", "WKMenuItemIdentifierOpenLink"), ("Open Link in New Window", "WKMenuItemIdentifierOpenLinkInNewWindow"),
                         ("Download Linked File", "WKMenuItemIdentifierDownloadLinkedFile"), ("-", nil), ("Copy Link", "WKMenuItemIdentifierCopyLink")])
        BrowserWebView.arrangeLinkItems(in: link, target: nil)
        #expect(titles(link) == opens + ["Download Linked File", "-", "Copy Link"])
        // Zigzag's four open through WebKit's new-window item, which is off the menu.
        let original = link.items[0].representedObject as? NSMenuItem
        #expect(original?.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow")
        #expect(link.items.prefix(4).allSatisfy { ($0.representedObject as? NSMenuItem) === original })
        #expect(!link.items.contains { $0 === original })
        #expect(link.items[4].identifier?.rawValue == "WKMenuItemIdentifierOpenLink")
    }

    @Test func anImageLinkStartsTheSameWay() {
        let link = menu([("Open Link", "WKMenuItemIdentifierOpenLink"), ("Open Link in New Window", "WKMenuItemIdentifierOpenLinkInNewWindow"),
                         ("-", nil), ("Open Image in New Window", "WKMenuItemIdentifierOpenImageInNewWindow"), ("Copy Image", "WKMenuItemIdentifierCopyImageToClipboard")])
        BrowserWebView.arrangeLinkItems(in: link, target: nil)
        #expect(titles(link) == opens + ["-", "Open Image in New Window", "Copy Image"])
    }

    @Test func aMenuWithoutALinkIsLeftAlone() {
        let page = menu([("Back", "WKMenuItemIdentifierGoBack"), ("Reload", "WKMenuItemIdentifierReload")])
        BrowserWebView.arrangeLinkItems(in: page, target: nil)
        #expect(titles(page) == ["Back", "Reload"])
    }
}

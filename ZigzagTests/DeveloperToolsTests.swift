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

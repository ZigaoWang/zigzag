import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A page hears shortcuts before Zigzag's menus, as in Safari and Chrome, except the browser's own: tabs, windows, the
/// address, reload, quitting. Which ones are the browser's goes by what the menu item does, so a changed shortcut
/// stays the browser's on its new keys.
@MainActor struct PageShortcutsTests {
    private final class Target: NSObject {
        @objc func newTab(_ sender: Any?) {}
        @objc func closeTab(_ sender: Any?) {}
        @objc func reopenClosedTab(_ sender: Any?) {}
        @objc func savePageAs(_ sender: Any?) {}
        @objc func goBack(_ sender: Any?) {}
        @objc func toggleBookmark(_ sender: Any?) {}
        @objc func nextSpace(_ sender: Any?) {}
        @objc func previousSpace(_ sender: Any?) {}
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let sub = NSMenu()
        func add(_ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            sub.addItem(item)
        }
        add(#selector(Target.newTab(_:)), "t")
        add(#selector(Target.closeTab(_:)), "w")
        add(#selector(Target.reopenClosedTab(_:)), "t", [.command, .shift])
        add(#selector(Target.savePageAs(_:)), "s")
        add(#selector(Target.goBack(_:)), "[")
        // A shortcut moved in Settings: New Tab on ⌥⌘K now.
        add(#selector(Target.newTab(_:)), "k", [.command, .option])
        add(#selector(Target.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        add(#selector(Target.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        let top = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        top.submenu = sub
        menu.addItem(top)
        return menu
    }

    private func key(_ chars: String, _ mods: NSEvent.ModifierFlags = .command) -> NSEvent {
        let shown = mods.contains(.shift) ? chars.uppercased() : chars
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                characters: shown, charactersIgnoringModifiers: shown, isARepeat: false, keyCode: 0)!
    }

    @Test func theBrowsersOwnKeysStayItsOwn() {
        let menu = menu()
        #expect(BrowserWindow.browserKeeps(key("t"), in: menu))
        #expect(BrowserWindow.browserKeeps(key("w"), in: menu))
        #expect(BrowserWindow.browserKeeps(key("t", [.command, .shift]), in: menu))
        #expect(BrowserWindow.browserKeeps(key("k", [.command, .option]), in: menu))
    }

    /// ⌥⌘← and ⌥⌘→ switch spaces even on a page that uses them.
    @Test func theSpaceKeysStayTheBrowsers() {
        let menu = menu()
        #expect(BrowserWindow.browserKeeps(key(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]), in: menu))
        #expect(BrowserWindow.browserKeeps(key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]), in: menu))
    }

    /// ⌘Q quits from a page that takes every ⌘ key, as it did before Quit had an action of its own.
    @Test func theQuitKeyStaysTheBrowsers() {
        #expect(BrowserWindow.browserKeeps(key("q"), in: MainMenu.build()))
    }

    @Test func everythingElseIsThePagesFirst() {
        let menu = menu()
        // A Zigzag item a page may also use (⌘S saves in an editor, ⌘[ indents in Docs), and keys no item has.
        #expect(!BrowserWindow.browserKeeps(key("s"), in: menu))
        #expect(!BrowserWindow.browserKeeps(key("["), in: menu))
        #expect(!BrowserWindow.browserKeeps(key("a"), in: menu))
        #expect(!BrowserWindow.browserKeeps(key("b"), in: menu))
        #expect(!BrowserWindow.browserKeeps(key("k"), in: menu))
    }

    @Test func zigzagsRealMenuKeepsTabsAndWindows() {
        // The shipped list names actions that exist on the browser window's controller.
        for name in ["newTab:", "closeTab:", "openLocation:", "reloadPage:", "selectTabByNumber:", "reopenClosedTab:",
                     "nextSpace:", "previousSpace:", "copyPageURL:", "copyPageURLAsMarkdown:"] {
            #expect(BrowserWindow.browserActions.contains(name))
        }
        // Each one is an action something in Zigzag has.
        let owners: [AnyClass] = [BrowserWindowController.self, WebAppWindowController.self, AppDelegate.self, NSApplication.self, NSWindow.self]
        for name in BrowserWindow.browserActions {
            #expect(owners.contains { $0.instancesRespond(to: NSSelectorFromString(name)) }, "\(name)")
        }
        #expect(!BrowserWindow.browserActions.contains("savePageAs:"))
        #expect(!BrowserWindow.browserActions.contains("selectAll:"))
    }

    /// WKWebView goes Back on ⌫ (Forward on ⇧⌫) with no focused field; it's disabled in every page's preferences.
    @Test func backspaceNeverGoesBack() {
        let key = "backspaceKeyNavigationEnabled"
        let preferences = WKPreferences()
        // WebKit's default is on, which confirms the key name.
        #expect(preferences.value(forKey: key) as? Bool == true)
        WebKitSetup.turnOffBackspaceNavigation(preferences)
        #expect(preferences.value(forKey: key) as? Bool == false)
        // Popups copy their opener's preferences.
        #expect((preferences.copy() as? WKPreferences)?.value(forKey: key) as? Bool == false)
    }
}

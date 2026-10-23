import AppKit

/// The menu bar. Every action in the app is here, with its shortcut shown. Shortcuts follow Arc where it had one.
enum MainMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isAlternate = false
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = menu
        return top
    }

    static func build() -> NSMenu {
        let main = NSMenu()
        typealias C = BrowserWindowController

        main.addItem(submenu("Zigzag", [
            item("About Zigzag", #selector(AppDelegate.showAbout(_:)), ""),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), ""),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            item("Set as Default Browser", #selector(AppDelegate.makeDefaultBrowser(_:)), ""),
            item("Import from Arc…", #selector(AppDelegate.importFromArc(_:)), ""),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide Zigzag", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Zigzag", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(C.newTab(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift]),
            item("Open Location…", #selector(C.openLocation(_:)), "l"),
            item("Open File…", #selector(C.openDocument(_:)), "o"),
            .separator(),
            item("Reopen Closed Tab", #selector(C.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Duplicate Tab", #selector(C.duplicateTab(_:)), "d", [.command, .option]),
            item("Bookmark This Page", #selector(C.toggleBookmark(_:)), "d"),
            .separator(),
            item("Close Tab", #selector(C.closeTab(_:)), "w"),
            item("Close Other Tabs", #selector(C.closeOtherTabs(_:)), "w", [.command, .option]),
            item("Close Window", #selector(C.closeWindow(_:)), "w", [.command, .shift]),
            .separator(),
            item("Export as PDF…", #selector(C.exportAsPDF(_:)), ""),
            item("Print…", #selector(C.printPage(_:)), "p"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Link", #selector(C.copyPageURL(_:)), "c", [.command, .shift]),
            item("Copy Link as Markdown", #selector(C.copyPageURLAsMarkdown(_:)), "c", [.command, .shift, .option]),
            .separator(),
            submenu("Find", [
                item("Find…", #selector(C.showFindBar(_:)), "f"),
                item("Find Next", #selector(C.findNextMatch(_:)), "g"),
                item("Find Previous", #selector(C.findPreviousMatch(_:)), "g", [.command, .shift]),
                item("Use Selection for Find", #selector(C.useSelectionForFind(_:)), "e"),
            ]),
            submenu("Spelling and Grammar", [
                item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
                item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
                .separator(),
                item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""),
                item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)), ""),
                item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), ""),
            ]),
        ]))

        var viewItems: [NSMenuItem] = [
            item("Hide Sidebar", #selector(C.toggleBrowserSidebar(_:)), "s", [.command, .control]),
            item("Show All Tabs", #selector(C.toggleDeskView(_:)), "\\", [.command, .shift]),
            .separator(),
            item("Back", #selector(C.goBack(_:)), "["),
            item("Forward", #selector(C.goForward(_:)), "]"),
            item("Reload Page", #selector(C.reloadPage(_:)), "r"),
            item("Reload Ignoring Cache", #selector(C.reloadPageFromOrigin(_:)), "r", [.command, .shift]),
            item("Stop", #selector(C.stopLoading(_:)), "."),
            .separator(),
            item("Next Tab", #selector(C.selectNextTab(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item("Previous Tab", #selector(C.selectPreviousTab(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Next Space", #selector(C.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item("Previous Space", #selector(C.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            item("New Space", #selector(C.newSpace(_:)), ""),
            item("Edit Space…", #selector(C.renameSpace(_:)), ""),
            .separator(),
            item("Search History…", #selector(C.searchHistory(_:)), "y"),
            .separator(),
            item("Actual Size", #selector(C.actualSize(_:)), "0"),
            item("Zoom In", #selector(C.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(C.zoomOut(_:)), "-"),
            item("Mute Tab", #selector(C.toggleMute(_:)), "m", [.command, .shift]),
            .separator(),
            submenu("Developer", [
                item("Web Inspector", #selector(C.showWebInspector(_:)), "i", [.command, .option]),
                item("View Source", #selector(C.viewSource(_:)), "u", [.command, .option]),
            ]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
        // Shortcuts that don't need a visible menu line: they work, they just don't clutter the menu.
        viewItems += [
            alternate(item("Zoom In", #selector(C.zoomIn(_:)), "=")),
            alternate(item("Back", #selector(C.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!))),
            alternate(item("Forward", #selector(C.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!))),
            alternate(item("Next Tab", #selector(C.selectNextTab(_:)), "}", [.command, .shift])),
            alternate(item("Previous Tab", #selector(C.selectPreviousTab(_:)), "{", [.command, .shift])),
            alternate(item("Close Tabs Below", #selector(C.closeTabsBelow(_:)), "")),
        ]
        for n in 1...9 {
            viewItems.append(alternate(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(C.selectTabByNumber(_:)), "\(n)", tag: n)))
            viewItems.append(alternate(item("Space \(n)", #selector(C.selectSpaceByNumber(_:)), "\(n)", [.control], tag: n)))
        }
        main.addItem(submenu("View", viewItems))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", [])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}

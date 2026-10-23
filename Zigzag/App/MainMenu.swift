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
            item("Open Location…", #selector(C.openLocation(_:)), "l"),
            item("Open File…", #selector(C.openDocument(_:)), "o"),
            .separator(),
            item("Reopen Closed Tab", #selector(C.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Close Tab", #selector(C.closeTab(_:)), "w"),
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
                item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""),
            ]),
            item("Start Dictation", Selector(("startDictation:")), ""),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ]))

        main.addItem(submenu("View", [
            item("Hide Sidebar", #selector(C.toggleSidebar(_:)), "s"),
            item("Show All Tabs", #selector(C.toggleDeskView(_:)), "\\", [.command, .shift]),
            .separator(),
            item("Reload Page", #selector(C.reloadPage(_:)), "r"),
            item("Reload Page Ignoring Cache", #selector(C.reloadPageFromOrigin(_:)), "r", [.command, .shift]),
            item("Stop", #selector(C.stopLoading(_:)), "."),
            .separator(),
            item("Actual Size", #selector(C.actualSize(_:)), "0"),
            item("Zoom In", #selector(C.zoomIn(_:)), "+"),
            alternate(item("Zoom In", #selector(C.zoomIn(_:)), "=")),
            item("Zoom Out", #selector(C.zoomOut(_:)), "-"),
            .separator(),
            submenu("Developer", [
                item("Web Inspector", #selector(C.showWebInspector(_:)), "i", [.command, .option]),
                item("View Source", #selector(C.viewSource(_:)), "u", [.command, .option]),
            ]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(C.goBack(_:)), "["),
            alternate(item("Back", #selector(C.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!))),
            item("Forward", #selector(C.goForward(_:)), "]"),
            alternate(item("Forward", #selector(C.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!))),
            .separator(),
            item("Search History…", #selector(C.searchHistory(_:)), "y"),
        ]))

        main.addItem(submenu("Bookmarks", [
            item("Bookmark This Page", #selector(C.toggleBookmark(_:)), "d"),
        ]))

        var tabItems: [NSMenuItem] = [
            item("Next Tab", #selector(C.selectNextTab(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item("Previous Tab", #selector(C.selectPreviousTab(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            alternate(item("Next Tab", #selector(C.selectNextTab(_:)), "}", [.command, .shift])),
            alternate(item("Previous Tab", #selector(C.selectPreviousTab(_:)), "{", [.command, .shift])),
            .separator(),
        ]
        for n in 1...9 {
            let title = n == 9 ? "Last Tab" : "Tab \(n)"
            tabItems.append(item(title, #selector(C.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        tabItems += [
            .separator(),
            item("Duplicate Tab", #selector(C.duplicateTab(_:)), "d", [.command, .option]),
            item("Mute Tab", #selector(C.toggleMute(_:)), "m", [.command, .shift]),
            .separator(),
            item("Close Tabs Below", #selector(C.closeTabsBelow(_:)), ""),
            item("Close Other Tabs", #selector(C.closeOtherTabs(_:)), "w", [.command, .option]),
        ]
        main.addItem(submenu("Tabs", tabItems))

        var spaceItems: [NSMenuItem] = [
            item("Next Space", #selector(C.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item("Previous Space", #selector(C.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            .separator(),
        ]
        for n in 1...9 {
            spaceItems.append(item("Space \(n)", #selector(C.selectSpaceByNumber(_:)), "\(n)", [.control], tag: n))
        }
        spaceItems += [
            .separator(),
            item("New Space", #selector(C.newSpace(_:)), ""),
            item("Rename Space…", #selector(C.renameSpace(_:)), ""),
        ]
        main.addItem(submenu("Spaces", spaceItems))

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

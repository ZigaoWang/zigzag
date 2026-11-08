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
            item(String(localized: "About Zigzag", comment: "Zigzag menu item."), #selector(AppDelegate.showAbout(_:)), ""),
            item(String(localized: "Check for Updates…", comment: "Zigzag menu item."), #selector(AppDelegate.checkForUpdates(_:)), ""),
            .separator(),
            item(String(localized: "Settings…", comment: "Zigzag menu item."), #selector(AppDelegate.showSettings(_:)), ","),
            item(String(localized: "Passwords", comment: "Zigzag menu item."), #selector(AppDelegate.showPasswords(_:)), "k", [.command, .option]),
            item(String(localized: "Set as Default Browser", comment: "Zigzag menu item."), #selector(AppDelegate.makeDefaultBrowser(_:)), ""),
            .separator(),
            servicesItem(),
            .separator(),
            item(String(localized: "Hide Zigzag", comment: "Zigzag menu item."), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others", comment: "Zigzag menu item."), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All", comment: "Zigzag menu item."), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(String(localized: "Quit Zigzag", comment: "Zigzag menu item."), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu(String(localized: "File", comment: "A menu in the menu bar."), [
            item(String(localized: "New Tab", comment: "File menu item."), #selector(C.newTab(_:)), "t"),
            item(String(localized: "New Window", comment: "File menu item."), #selector(AppDelegate.newWindow(_:)), "n"),
            item(String(localized: "New Private Window", comment: "File menu item."), #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift]),
            item(String(localized: "Open Location…", comment: "File menu item."), #selector(C.openLocation(_:)), "l"),
            item(String(localized: "Open File…", comment: "File menu item."), #selector(C.openDocument(_:)), "o"),
            .separator(),
            item(String(localized: "Import from Another Browser…", comment: "File menu item."), #selector(AppDelegate.importFromBrowser(_:)), "i", [.command, .shift]),
            .separator(),
            // No key: ⌥⌘D belongs to macOS (hide the Dock) and always wins.
            item(String(localized: "Duplicate Tab", comment: "File menu item."), #selector(C.duplicateTab(_:)), ""),
            item(String(localized: "Pin Tab", comment: "File menu item."), #selector(C.toggleBookmark(_:)), "d"),
            item(String(localized: "Add to Favorites", comment: "File menu item."), #selector(C.addToFavorites(_:)), ""),
            item(String(localized: "Move Tab to New Window", comment: "File menu item."), #selector(C.moveTabToNewWindow(_:)), ""),
            .separator(),
            item(String(localized: "Close Tab", comment: "File menu item."), #selector(C.closeTab(_:)), "w"),
            item(String(localized: "Close Other Tabs", comment: "File menu item."), #selector(C.closeOtherTabs(_:)), "w", [.command, .option]),
            item(String(localized: "Close Window", comment: "File menu item."), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            item(String(localized: "Share…", comment: "File menu item."), #selector(C.sharePage(_:)), ""),
            item(String(localized: "Save Page As…", comment: "File menu item."), #selector(C.savePageAs(_:)), "s"),
            item(String(localized: "Export as PDF…", comment: "File menu item."), #selector(C.exportAsPDF(_:)), ""),
            item(String(localized: "Take Screenshot of Whole Page", comment: "File menu item."), #selector(C.takePageScreenshot(_:)), "2", [.command, .shift]),
            item(String(localized: "Print…", comment: "File menu item."), #selector(C.printPage(_:)), "p"),
        ]))

        main.addItem(submenu(String(localized: "Edit", comment: "A menu in the menu bar."), [
            item(String(localized: "Undo", comment: "Edit menu item."), Selector(("undo:")), "z"),
            item(String(localized: "Redo", comment: "Edit menu item."), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut", comment: "Edit menu item."), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy", comment: "Edit menu item."), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste", comment: "Edit menu item."), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Paste and Match Style", comment: "Edit menu item."), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item(String(localized: "Select All", comment: "Edit menu item."), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(String(localized: "Copy Link", comment: "Edit menu item."), #selector(C.copyPageURL(_:)), "c", [.command, .shift]),
            item(String(localized: "Copy Link as Markdown", comment: "Edit menu item."), #selector(C.copyPageURLAsMarkdown(_:)), "c", [.command, .shift, .option]),
            .separator(),
            submenu(String(localized: "Find", comment: "Submenu of the Edit menu."), [
                item(String(localized: "Find…", comment: "Edit › Find menu item."), #selector(C.showFindBar(_:)), "f"),
                item(String(localized: "Find Next", comment: "Edit › Find menu item."), #selector(C.findNextMatch(_:)), "g"),
                item(String(localized: "Find Previous", comment: "Edit › Find menu item."), #selector(C.findPreviousMatch(_:)), "g", [.command, .shift]),
                item(String(localized: "Use Selection for Find", comment: "Edit › Find menu item."), #selector(C.useSelectionForFind(_:)), "e"),
                item(String(localized: "Jump to Selection", comment: "Edit › Find menu item."), #selector(C.jumpToSelection(_:)), "j"),
            ]),
            submenu(String(localized: "Spelling and Grammar", comment: "Submenu of the Edit menu."), [
                item(String(localized: "Show Spelling and Grammar", comment: "Edit › Spelling and Grammar menu item."), #selector(NSText.showGuessPanel(_:)), ":"),
                item(String(localized: "Check Document Now", comment: "Edit › Spelling and Grammar menu item."), #selector(NSText.checkSpelling(_:)), ";"),
                .separator(),
                item(String(localized: "Check Spelling While Typing", comment: "Edit › Spelling and Grammar menu item."), #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""),
                item(String(localized: "Check Grammar With Spelling", comment: "Edit › Spelling and Grammar menu item."), #selector(NSTextView.toggleGrammarChecking(_:)), ""),
                item(String(localized: "Correct Spelling Automatically", comment: "Edit › Spelling and Grammar menu item."), #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), ""),
            ]),
            submenu(String(localized: "Substitutions", comment: "Submenu of the Edit menu."), [
                item(String(localized: "Show Substitutions", comment: "Edit › Substitutions menu item."), #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), ""),
                .separator(),
                item(String(localized: "Smart Copy/Paste", comment: "Edit › Substitutions menu item."), #selector(NSTextView.toggleSmartInsertDelete(_:)), ""),
                item(String(localized: "Smart Quotes", comment: "Edit › Substitutions menu item."), #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), ""),
                item(String(localized: "Smart Dashes", comment: "Edit › Substitutions menu item."), #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), ""),
                item(String(localized: "Smart Links", comment: "Edit › Substitutions menu item."), #selector(NSTextView.toggleAutomaticLinkDetection(_:)), ""),
                item(String(localized: "Text Replacement", comment: "Edit › Substitutions menu item."), #selector(NSTextView.toggleAutomaticTextReplacement(_:)), ""),
            ]),
            submenu(String(localized: "Transformations", comment: "Submenu of the Edit menu."), [
                item(String(localized: "Make Upper Case", comment: "Edit › Transformations menu item."), #selector(NSResponder.uppercaseWord(_:)), ""),
                item(String(localized: "Make Lower Case", comment: "Edit › Transformations menu item."), #selector(NSResponder.lowercaseWord(_:)), ""),
                item(String(localized: "Capitalize", comment: "Edit › Transformations menu item."), #selector(NSResponder.capitalizeWord(_:)), ""),
            ]),
            submenu(String(localized: "Speech", comment: "Submenu of the Edit menu."), [
                item(String(localized: "Start Speaking", comment: "Edit › Speech menu item."), #selector(NSTextView.startSpeaking(_:)), ""),
                item(String(localized: "Stop Speaking", comment: "Edit › Speech menu item."), #selector(NSTextView.stopSpeaking(_:)), ""),
            ]),
        ]))

        var viewItems: [NSMenuItem] = [
            item(String(localized: "Hide Sidebar", comment: "View menu item."), #selector(C.toggleBrowserSidebar(_:)), "s", [.control]),
            item(String(localized: "Show All Tabs", comment: "View menu item."), #selector(C.toggleDeskView(_:)), "\\", [.command, .shift]),
            item(String(localized: "Stack Vertically", comment: "View menu item."), #selector(C.toggleSplitOrientation(_:)), ""),
            item(String(localized: "Separate Tabs", comment: "View menu item."), #selector(C.closeSplitView(_:)), "\\", [.command, .option]),
            .separator(),
            item(String(localized: "Back", comment: "View menu item."), #selector(C.goBack(_:)), "["),
            item(String(localized: "Forward", comment: "View menu item."), #selector(C.goForward(_:)), "]"),
            item(String(localized: "Reload Page", comment: "View menu item."), #selector(C.reloadPage(_:)), "r"),
            item(String(localized: "Reload Ignoring Cache", comment: "View menu item."), #selector(C.reloadPageFromOrigin(_:)), "r", [.command, .option]),
            item(String(localized: "Stop", comment: "View menu item."), #selector(C.stopLoading(_:)), "."),
            .separator(),
            item(String(localized: "Next Tab", comment: "View menu item."), #selector(C.selectNextTab(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Previous Tab", comment: "View menu item."), #selector(C.selectPreviousTab(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Move Tab Up", comment: "View menu item."), #selector(C.moveTabUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .shift]),
            item(String(localized: "Move Tab Down", comment: "View menu item."), #selector(C.moveTabDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .shift]),
            item(String(localized: "Next Space", comment: "View menu item."), #selector(C.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Previous Space", comment: "View menu item."), #selector(C.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "New Space", comment: "View menu item."), #selector(C.newSpace(_:)), "n", [.command, .option]),
            item(String(localized: "Edit Space…", comment: "View menu item."), #selector(C.renameSpace(_:)), ""),
            .separator(),
            item(String(localized: "Actual Size", comment: "View menu item."), #selector(C.actualSize(_:)), "0"),
            item(String(localized: "Zoom In", comment: "View menu item."), #selector(C.zoomIn(_:)), "+"),
            item(String(localized: "Zoom Out", comment: "View menu item."), #selector(C.zoomOut(_:)), "-"),
            item(String(localized: "Mute Tab", comment: "View menu item."), #selector(C.toggleMute(_:)), "m", [.command, .shift]),
            item(String(localized: "Picture in Picture", comment: "View menu item."), #selector(C.togglePictureInPicture(_:)), "p", [.command, .option]),
            item(String(localized: "Show Reader", comment: "View menu item."), #selector(C.toggleReader(_:)), "r", [.command, .shift]),
            item(String(localized: "Translate Page", comment: "View menu item."), #selector(C.translatePage(_:)), "t", [.command, .option]),
            .separator(),
            submenu(String(localized: "Developer", comment: "Submenu of the View menu."), [
                item(String(localized: "Web Inspector", comment: "View › Developer menu item."), #selector(C.showWebInspector(_:)), "i", [.command, .option]),
                item(String(localized: "View Source", comment: "View › Developer menu item."), #selector(C.viewSource(_:)), "u", [.command, .option]),
            ]),
            .separator(),
            item(String(localized: "Enter Full Screen", comment: "View menu item."), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
        // Shortcuts that don't need a visible menu line: they work, they just don't clutter the menu.
        viewItems += [
            alternate(item(String(localized: "Zoom In", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.zoomIn(_:)), "=")),
            alternate(item(String(localized: "Back", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!))),
            alternate(item(String(localized: "Forward", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!))),
            alternate(item(String(localized: "Next Tab", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.selectNextTab(_:)), "}", [.command, .shift])),
            alternate(item(String(localized: "Previous Tab", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.selectPreviousTab(_:)), "{", [.command, .shift])),
            alternate(item(String(localized: "Close Tabs Below", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.closeTabsBelow(_:)), "")),
        ]
        for n in 1...9 {
            viewItems.append(alternate(item(n == 9 ? String(localized: "Last Tab", comment: "Hidden View menu item, named in Settings › Shortcuts.")
                                                     : String(localized: "Tab \(n)", comment: "Hidden View menu item that goes to the tab with this number."), #selector(C.selectTabByNumber(_:)), "\(n)", tag: n)))
            viewItems.append(alternate(item(String(localized: "Space \(n)", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(C.selectSpaceByNumber(_:)), "\(n)", [.control], tag: n)))
        }
        main.addItem(submenu(String(localized: "View", comment: "A menu in the menu bar."), viewItems))

        main.addItem(submenu(String(localized: "History", comment: "A menu in the menu bar."), [
            // One History, as in Chrome: the window, with its own search.
            item(String(localized: "Show History", comment: "History menu item."), #selector(AppDelegate.showHistory(_:)), "y"),
            item(String(localized: "Reopen Closed Tab", comment: "History menu item."), #selector(C.reopenClosedTab(_:)), "t", [.command, .shift]),
            item(String(localized: "Reopen Closed Window", comment: "History menu item."), #selector(AppDelegate.reopenClosedWindow(_:)), ""),
            .separator(),
            item(String(localized: "Clear History…", comment: "History menu item."), #selector(C.clearHistory(_:)), ""),
            item(String(localized: "Clear Cache…", comment: "History menu item."), #selector(C.clearCache(_:)), ""),
            item(String(localized: "Clear Cookies…", comment: "History menu item."), #selector(C.clearCookies(_:)), ""),
        ]))

        let window = submenu(String(localized: "Window", comment: "A menu in the menu bar."), [
            item(String(localized: "Minimize", comment: "Window menu item."), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom", comment: "Window menu item."), #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item(String(localized: "Downloads", comment: "Window menu item."), #selector(C.showDownloads(_:)), "l", [.command, .option]),
            .separator(),
            item(String(localized: "Bring All to Front", comment: "Window menu item."), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu(String(localized: "Help", comment: "A menu in the menu bar."), [
            item(String(localized: "Getting Started", comment: "Help menu item."), #selector(C.showGettingStarted(_:)), ""),
            item(String(localized: "What’s New in Zigzag", comment: "Help menu item."), #selector(C.showWhatsNew(_:)), ""),
            item(String(localized: "Send Feedback…", comment: "Help menu item."), #selector(C.sendFeedback(_:)), ""),
            item(String(localized: "Report a Problem…", comment: "Help menu item."), #selector(C.reportProblem(_:)), ""),
            .separator(),
            item(String(localized: "Zigzag on GitHub", comment: "Help menu item."), #selector(AppDelegate.showSourceCode(_:)), ""),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func servicesItem() -> NSMenuItem {
        let title = String(localized: "Services", comment: "Submenu of the Zigzag menu, filled by macOS.")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}

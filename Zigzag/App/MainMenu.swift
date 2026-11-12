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

    /// Marks the items Developer tools adds to View › Developer (#141), the line before them included.
    private static let developerToolID = NSUserInterfaceItemIdentifier("ZigzagDeveloperTool")

    /// Puts the developer tools' items into View › Developer, after the ones always there, or takes them out:
    /// with Developer tools off they aren't in the menu bar at all, so Settings › Shortcuts doesn't list them and
    /// their keys do nothing. True when the menu changed.
    @discardableResult
    static func setDeveloperTools(_ on: Bool, in main: NSMenu?) -> Bool {
        func find(_ menu: NSMenu) -> NSMenu? {
            if menu.items.contains(where: { $0.action == #selector(BrowserWindowController.viewSource(_:)) }) { return menu }
            return menu.items.lazy.compactMap { $0.submenu.flatMap(find) }.first
        }
        guard let menu = main.flatMap(find) else { return false }
        let ours = menu.items.filter { $0.identifier == developerToolID }
        guard on == ours.isEmpty else { return false }
        guard on else { ours.forEach(menu.removeItem); return true }
        let line = NSMenuItem.separator()
        line.identifier = developerToolID
        menu.addItem(line)
        // A tool that's a choice or a part of one thing (a look, a size, a browser) goes in that thing's submenu,
        // under its short name; a line there sets the choices apart from the rest.
        var submenus: [DeveloperTool.Group: NSMenu] = [:]
        for tool in DeveloperTool.menuItems {
            guard let group = tool.group else {
                let added = item(tool.title, tool.action, tool.key?.0 ?? "", tool.key?.1 ?? [.command])
                added.identifier = developerToolID
                menu.addItem(added)
                continue
            }
            let inside: NSMenu
            if let made = submenus[group] {
                inside = made
            } else {
                let top = submenu(group.title, [])
                top.identifier = developerToolID
                menu.addItem(top)
                inside = top.submenu ?? NSMenu()
                submenus[group] = inside
            }
            if let last = inside.items.last, !last.isSeparatorItem,
               DeveloperTool(action: last.action)?.isChoice != tool.isChoice { inside.addItem(.separator()) }
            inside.addItem(item(tool.shortTitle, tool.action, tool.key?.0 ?? "", tool.key?.1 ?? [.command]))
        }
        return true
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
            // Arc's Little Arc was ⌥⌘N, which is New Space here.
            item(String(localized: "New Zigzag Mini", comment: "File menu item: opens the command bar on its own, for a page in Zigzag Mini (a small window for one page, without the sidebar). Zigzag Mini is a name, kept in Latin letters."), #selector(AppDelegate.newMiniWindow(_:)), "n", [.command, .control]),
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
            item(WebAppInstallSheet.title, #selector(C.installAsApp(_:)), ""),
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

        main.addItem(submenu(String(localized: "Edit", comment: "A menu in the menu bar."), editItems(browser: true)))

        var viewItems: [NSMenuItem] = [
            item(String(localized: "Hide Sidebar", comment: "View menu item."), #selector(C.toggleBrowserSidebar(_:)), "s", [.control]),
            item(String(localized: "Move Sidebar to Right", comment: "View menu item: puts the sidebar along the window's right edge."), #selector(C.toggleSidebarSide(_:)), ""),
            item(String(localized: "Show All Tabs", comment: "View menu item."), #selector(C.toggleDeskView(_:)), "\\", [.command, .shift]),
            item(String(localized: "Stack Vertically", comment: "View menu item."), #selector(C.toggleSplitOrientation(_:)), ""),
            item(String(localized: "Separate Tabs", comment: "View menu item."), #selector(C.closeSplitView(_:)), "\\", [.command, .option]),
            item(PaneHeaderView.zoomTitle(false), #selector(C.zoomPane(_:)), "\r", [.command, .shift]),
            .separator(),
            item(String(localized: "Back", comment: "View menu item."), #selector(C.goBack(_:)), "["),
            item(String(localized: "Forward", comment: "View menu item."), #selector(C.goForward(_:)), "]"),
            item(String(localized: "Reload Page", comment: "View menu item."), #selector(C.reloadPage(_:)), "r"),
            item(DeveloperTool.reloadIgnoringCache.title, #selector(C.reloadPageFromOrigin(_:)), "r", [.command, .option]),
            item(String(localized: "Stop", comment: "View menu item."), #selector(C.stopLoading(_:)), "."),
            .separator(),
            item(String(localized: "Next Tab", comment: "View menu item."), #selector(C.selectNextTab(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Previous Tab", comment: "View menu item."), #selector(C.selectPreviousTab(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Move Tab Up", comment: "View menu item."), #selector(C.moveTabUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .shift]),
            item(String(localized: "Move Tab Down", comment: "View menu item."), #selector(C.moveTabDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .shift]),
            item(String(localized: "Next Space", comment: "View menu item."), #selector(C.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Previous Space", comment: "View menu item."), #selector(C.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            item(String(localized: "Switch Space…", comment: "View menu item: lists the spaces to pick one with the arrow keys."), #selector(C.showSpaceSwitcher(_:)), "s", [.command, .option]),
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
                // Chrome's keys, so its habits work here too.
                item(DeveloperTool.console.title, #selector(C.showJavaScriptConsole(_:)), "j", [.command, .option]),
                item(DeveloperTool.inspect.title, #selector(C.inspectElement(_:)), "c", [.command, .option]),
                item(DeveloperTool.viewSource.title, #selector(C.viewSource(_:)), "u", [.command, .option]),
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
            alternate(item(String(localized: "Web Inspector", comment: "View › Developer menu item."), #selector(C.showWebInspector(_:)), String(UnicodeScalar(NSF12FunctionKey)!), [])),
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
            // No key: ⌥⌘T is Translate Page, and there's no common one for this.
            item(KeepOnTop.title, #selector(AppDelegate.toggleKeepOnTop(_:)), ""),
            .separator(),
            item(String(localized: "Downloads", comment: "Window menu item."), #selector(C.showDownloads(_:)), "l", [.command, .option]),
            .separator(),
            item(String(localized: "Bring All to Front", comment: "Window menu item."), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu(String(localized: "Help", comment: "A menu in the menu bar."), [
            item(String(localized: "Getting Started", comment: "Help menu item."), #selector(C.showGettingStarted(_:)), ""),
            item(String(localized: "Keyboard Shortcuts", comment: "Help menu item: opens Settings › Shortcuts."), #selector(AppDelegate.showKeyboardShortcuts(_:)), ""),
            item(String(localized: "What’s New in Zigzag", comment: "Help menu item."), #selector(C.showWhatsNew(_:)), ""),
            item(String(localized: "Send Feedback…", comment: "Help menu item."), #selector(C.sendFeedback(_:)), ""),
            item(String(localized: "Report a Problem…", comment: "Help menu item."), #selector(C.reportProblem(_:)), ""),
            .separator(),
            item(String(localized: "Zigzag on GitHub", comment: "Help menu item."), #selector(AppDelegate.showSourceCode(_:)), ""),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        setDeveloperTools(DeveloperTools.isOn, in: main)
        return main
    }

    /// The menu bar while an installed app's window is in front (#165): the app's own, as in any Mac app, so ⌘Q quits
    /// that app and not Zigzag, ⌘H hides it, and nothing in it opens a tab or a browser window by surprise. Its menus
    /// for the Window menu and Services are the returned ones, for `NSApp` to use while it shows.
    static func buildWebApp(name: String) -> (menu: NSMenu, windows: NSMenu, services: NSMenu) {
        typealias W = WebAppWindowController
        let main = NSMenu()
        let services = NSMenu(title: String(localized: "Services", comment: "Submenu of the Zigzag menu, filled by macOS."))
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        main.addItem(submenu(name, [
            item(String(localized: "Settings…", comment: "Zigzag menu item."), #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            servicesItem,
            .separator(),
            item(String(localized: "Hide \(name)", comment: "First menu of an installed app's window: hides the app. The placeholder is the app's name, like Wikipedia."), #selector(W.hideWebApp(_:)), "h"),
            item(String(localized: "Hide Others", comment: "Zigzag menu item."), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All", comment: "Zigzag menu item."), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(String(localized: "Quit \(name)", comment: "First menu of an installed app's window: quits the app, and only it. The placeholder is the app's name, like Wikipedia."), #selector(W.quitWebApp(_:)), "q"),
        ]))
        main.addItem(submenu(String(localized: "File", comment: "A menu in the menu bar."), [
            item(String(localized: "Open in Zigzag", comment: "File menu item of an installed app's window: opens the page it shows in a tab of a Zigzag window."), #selector(W.openInBrowser(_:)), ""),
            item(String(localized: "Show in Finder", comment: "File menu item of an installed app's window: shows the app itself, selected in its folder in Finder."), #selector(W.showAppInFinder(_:)), ""),
            .separator(),
            item(String(localized: "Close Window", comment: "File menu item."), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu(String(localized: "Edit", comment: "A menu in the menu bar."), editItems(browser: false)))
        main.addItem(submenu(String(localized: "View", comment: "A menu in the menu bar."), [
            item(W.toolbarTitle(showing: true), #selector(W.toggleToolbar(_:)), ""),
            .separator(),
            item(String(localized: "Back", comment: "View menu item."), #selector(W.goBack(_:)), "["),
            item(String(localized: "Forward", comment: "View menu item."), #selector(W.goForward(_:)), "]"),
            item(String(localized: "Reload Page", comment: "View menu item."), #selector(W.reloadPage(_:)), "r"),
            item(String(localized: "Reload Ignoring Cache", comment: "View menu item."), #selector(W.reloadPageFromOrigin(_:)), "r", [.command, .option]),
            item(String(localized: "Stop", comment: "View menu item."), #selector(W.stopLoading(_:)), "."),
            .separator(),
            item(String(localized: "Actual Size", comment: "View menu item."), #selector(W.actualSize(_:)), "0"),
            item(String(localized: "Zoom In", comment: "View menu item."), #selector(W.zoomIn(_:)), "+"),
            item(String(localized: "Zoom Out", comment: "View menu item."), #selector(W.zoomOut(_:)), "-"),
            .separator(),
            item(String(localized: "Enter Full Screen", comment: "View menu item."), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            alternate(item(String(localized: "Zoom In", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(W.zoomIn(_:)), "=")),
            alternate(item(String(localized: "Back", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(W.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!))),
            alternate(item(String(localized: "Forward", comment: "Hidden View menu item, named in Settings › Shortcuts."), #selector(W.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!))),
        ]))
        let window = submenu(String(localized: "Window", comment: "A menu in the menu bar."), [
            item(String(localized: "Minimize", comment: "Window menu item."), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom", comment: "Window menu item."), #selector(NSWindow.performZoom(_:)), ""),
            item(KeepOnTop.title, #selector(AppDelegate.toggleKeepOnTop(_:)), ""),
            .separator(),
            item(String(localized: "Bring All to Front", comment: "Window menu item."), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        return (main, window.submenu!, services)
    }

    /// The Edit menu: a browser window's, or an installed app's, which has no find bar or Markdown link.
    private static func editItems(browser: Bool) -> [NSMenuItem] {
        typealias C = BrowserWindowController
        var items: [NSMenuItem] = [
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
        ]
        if !browser {
            let browserOnly: Set<Selector> = [#selector(C.copyPageURLAsMarkdown(_:))]
            items.removeAll { $0.action.map(browserOnly.contains) ?? false || $0.submenu?.items.contains { $0.action == #selector(C.showFindBar(_:)) } == true }
        }
        return items
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

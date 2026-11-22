import AppKit
import Foundation
import Testing
@testable import Zigzag

/// The menu bar's keys for everyday things: the item each key is on, then what that item does in a window.
@MainActor @Suite(.serialized) struct MenuShortcutsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// A window over tabs of its own, at these addresses, with the library put back afterwards.
    private func inWindow(_ urls: [URL?], _ body: (BrowserWindowController, [Tab]) async throws -> Void) async rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = urls.enumerated().map { i, url in Tab(url: url, title: "\(i)", spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        try await body(controller, tabs)
    }

    /// Local pages in a folder of their own, removed afterwards.
    private func pages(_ names: [String], _ body: ([URL]) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try names.map { name in
            let url = folder.appendingPathComponent("\(name).html")
            try "<title>\(name)</title><p>\(name)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        try await body(urls)
    }

    private func until(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func settled(_ tab: Tab, at url: URL) async -> Bool {
        await until { tab.webView?.url == url && tab.webView?.isLoading == false }
    }

    /// The keys of the menu bar's items for an action, as "⌥⌘w".
    private func keys(_ action: Selector) -> [String] {
        func find(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { ($0.submenu.map(find) ?? []) + ($0.action == action ? [$0] : []) }
        }
        return find(MainMenu.build()).map { item in
            let flags = item.keyEquivalentModifierMask
            let mods = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { flags.contains($0.0) }.map(\.1).joined()
            let key = switch item.keyEquivalent {
            case String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←"
            case String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"
            default: item.keyEquivalent
            }
            return mods + key
        }
    }

    /// ⌘T opens the command bar for a new tab; ⌘T again closes it.
    @Test func onlyTheCommandQKeyCountsAsTheQuitToAskAbout() {
        let quit = MainMenu.build().items.first?.submenu?.items.first { $0.keyEquivalent == "q" }
        #expect(quit?.action == #selector(AppDelegate.quitFromMenu(_:)))
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 12)
        }
        #expect(AppDelegate.isQuitKey(key("q", .command)))
        // Return on the highlighted item, a click, or no event at all is choosing it in the menu.
        #expect(!AppDelegate.isQuitKey(key("\r", [])))
        #expect(!AppDelegate.isQuitKey(key("q", [.command, .option])))
        #expect(!AppDelegate.isQuitKey(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        #expect(!AppDelegate.isQuitKey(nil))
    }

    @Test func aQuitShortcutSetInSettingsIsTheOneThatAsks() {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
        }
        let custom = Shortcuts.Combo(key: "q", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        #expect(AppDelegate.isQuitKey(key("q", [.command, .option]), combo: custom))
        #expect(!AppDelegate.isQuitKey(key("q", .command), combo: custom))
        // Recorded with ⇧, or shipped as an uppercase key: either way ⇧ is part of it.
        let shifted = Shortcuts.Combo(key: "x", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        #expect(AppDelegate.isQuitKey(key("X", [.command, .shift]), combo: shifted))
        #expect(AppDelegate.isQuitKey(key("X", [.command, .shift]), combo: Shortcuts.Combo(key: "X", modifiers: NSEvent.ModifierFlags.command.rawValue)))
        #expect(!AppDelegate.isQuitKey(key("x", .command), combo: shifted))
        // Taken away in Settings: no key asks.
        #expect(!AppDelegate.isQuitKey(key("q", .command), combo: .none))
    }

    /// A Quit shortcut changed or taken away before Quit had an action of its own stays as you set it.
    @Test func aQuitShortcutSetBeforeKeepsAfterTheRename() {
        let option = Shortcuts.Combo(key: "q", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        #expect(Shortcuts.renamed(["terminate:#0": option]) == ["quitFromMenu:#0": option])
        #expect(Shortcuts.renamed(["terminate:#0": .none, "newTab:#0": option]) == ["quitFromMenu:#0": .none, "newTab:#0": option])
        // One already saved under the new id is the newer choice.
        #expect(Shortcuts.renamed(["terminate:#0": option, "quitFromMenu:#0": .none]) == ["quitFromMenu:#0": .none])
        #expect(Shortcuts.renamed([:]).isEmpty)
    }

    /// On a Russian layout ⌘Q types ⌘Й; it's still the Quit key, where Q sits, as the menu takes it.
    @Test func theQuitKeyOnALayoutWithoutLatinLetters() {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        let quit = Shortcuts.Combo(key: "q", modifiers: NSEvent.ModifierFlags.command.rawValue)
        #expect(AppDelegate.isQuitKey(key("й", .command, code: 12), combo: quit))
        #expect(!AppDelegate.isQuitKey(key("ц", .command, code: 13), combo: quit))
        #expect(!AppDelegate.isQuitKey(key("й", [.command, .option], code: 12), combo: quit))
        // A custom shortcut goes by its own key's place.
        let custom = Shortcuts.Combo(key: "x", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        #expect(AppDelegate.isQuitKey(key("ч", [.command, .option], code: 7), combo: custom))
        #expect(!AppDelegate.isQuitKey(key("й", .command, code: 12), combo: custom))
        // A Latin layout with Q elsewhere (AZERTY's A key) goes by the letter, as the menu does.
        #expect(!AppDelegate.isQuitKey(key("a", .command, code: 12), combo: quit))
        #expect(AppDelegate.isQuitKey(key("q", .command, code: 0), combo: quit))
    }

    @Test func onlyTheQuitKeyAsksButDownloadsAlwaysDo() {
        // The menu and the Dock quit at once; the key asks while the setting is on.
        #expect(AppDelegate.asks(fromKey: true, setting: true, downloading: 0))
        #expect(!AppDelegate.asks(fromKey: false, setting: true, downloading: 0))
        #expect(!AppDelegate.asks(fromKey: true, setting: false, downloading: 0))
        #expect(AppDelegate.asks(fromKey: false, setting: false, downloading: 2))
        #expect(AppDelegate.asks(fromKey: false, setting: true, downloading: 1))
    }

    @Test func commandTOpensTheNewTabBarAndAgainClosesIt() async throws {
        #expect(keys(#selector(BrowserWindowController.newTab(_:))) == ["⌘t"])
        try await inWindow([nil]) { controller, _ in
            controller.newTab(nil)
            #expect(controller.commandBar.isVisible)
            #expect(controller.commandBar.mode == .newTab)
            controller.newTab(nil)
            #expect(!controller.commandBar.isVisible)
        }
    }

    /// ⌘W closes the command bar, then picked rows as one, then the tab, undoably; ⌥⌘W the other tabs; ⇧⌘W is the
    /// window's.
    @Test func commandWClosesWhatIsUpFirstThenTheTab() async throws {
        #expect(keys(#selector(BrowserWindowController.closeTab(_:))) == ["⌘w"])
        #expect(keys(#selector(BrowserWindowController.closeOtherTabs(_:))) == ["⌥⌘w"])
        #expect(keys(#selector(NSWindow.performClose(_:))) == ["⇧⌘w"])
        try await inWindow([nil, nil, nil]) { controller, tabs in
            let manager = controller.tabManager
            controller.commandBar.show(mode: .newTab)
            controller.closeTab(nil)
            #expect(!controller.commandBar.isVisible)
            #expect(manager.currentTabs.count == 3)

            controller.sidebar.list.reload(animated: false)
            controller.sidebar.list.mark(pages: [tabs[1], tabs[2]])
            #expect(controller.sidebar.list.marksHaveFocus)
            controller.closeTab(nil)
            #expect(manager.currentTabs.map(\.id) == [tabs[0].id])
            controller.sidebarUndo.undo()
            #expect(manager.currentTabs.map(\.displayTitle) == ["0", "1", "2"])

            controller.window?.makeFirstResponder(nil)
            manager.select(try #require(manager.currentTabs.first))
            controller.closeTab(nil)
            #expect(manager.currentTabs.map(\.displayTitle) == ["1", "2"])
            controller.sidebarUndo.undo()
            #expect(manager.currentTabs.map(\.displayTitle) == ["0", "1", "2"])

            manager.select(try #require(manager.currentTabs.last))
            controller.closeOtherTabs(nil)
            #expect(manager.currentTabs.map(\.displayTitle) == ["2"])
        }
    }

    /// ⌥⌘→ and ⌥⌘← go to the next and previous space, and stop at the ends.
    @Test func optionCommandArrowsGoThroughTheSpacesAndStopAtTheEnds() async throws {
        #expect(keys(#selector(BrowserWindowController.nextSpace(_:))) == ["⌥⌘→"])
        #expect(keys(#selector(BrowserWindowController.previousSpace(_:))) == ["⌥⌘←"])
        try await inWindow([nil]) { controller, _ in
            while Library.shared.spaces.count < 3 { _ = Library.shared.addSpace(name: "Keys") }
            let spaces = Library.shared.spaces.map(\.id)
            let manager = controller.tabManager
            manager.switchToSpace(spaces[0])
            controller.previousSpace(nil)
            #expect(manager.currentSpaceID == spaces[0])
            for next in spaces.dropFirst() {
                controller.nextSpace(nil)
                #expect(manager.currentSpaceID == next)
            }
            controller.nextSpace(nil)
            #expect(manager.currentSpaceID == spaces.last)
            controller.previousSpace(nil)
            #expect(manager.currentSpaceID == spaces[spaces.count - 2])
            manager.switchToSpace(spaces[0])
        }
    }

    /// ⌘L opens the command bar over the address with the page's address selected; Return on it unchanged loads
    /// the page again, in the same tab.
    @Test func commandLSelectsTheAddressAndReturnUnchangedReloads() async throws {
        #expect(keys(#selector(BrowserWindowController.openLocation(_:))) == ["⌘l"])
        try await pages(["here"]) { urls in
            try await inWindow([urls[0]]) { controller, tabs in
                let tab = tabs[0]
                #expect(await settled(tab, at: urls[0]))
                _ = try await tab.webView?.evaluateJavaScript("window.zigzagMark = 1; 0")
                controller.openLocation(nil)
                #expect(controller.commandBar.isVisible)
                #expect(controller.commandBar.mode == .editCurrent)
                let editor = try #require(controller.window?.firstResponder as? NSTextView)
                #expect(editor.string == urls[0].absoluteString)
                #expect(editor.selectedRange == NSRange(location: 0, length: (editor.string as NSString).length))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                #expect(!controller.commandBar.isVisible)
                #expect(await until { (try? await tab.webView?.evaluateJavaScript("typeof window.zigzagMark") as? String) == "undefined" })
                #expect(await settled(tab, at: urls[0]))
                #expect(controller.tabManager.currentTabs.map(\.id) == [tab.id])
                #expect(controller.tabManager.selectedTab === tab)
            }
        }
    }

    /// ⌘[ and ⌘] go back and forward, with ⌘← and ⌘→ on hidden items of their own.
    @Test func commandBracketsGoBackAndForward() async throws {
        #expect(keys(#selector(BrowserWindowController.goBack(_:))) == ["⌘[", "⌘←"])
        #expect(keys(#selector(BrowserWindowController.goForward(_:))) == ["⌘]", "⌘→"])
        try await pages(["first", "second"]) { urls in
            try await inWindow([urls[0]]) { controller, tabs in
                let tab = tabs[0]
                #expect(await settled(tab, at: urls[0]))
                tab.load(urls[1])
                #expect(await settled(tab, at: urls[1]))
                controller.goBack(nil)
                #expect(await settled(tab, at: urls[0]))
                controller.goForward(nil)
                #expect(await settled(tab, at: urls[1]))
            }
        }
    }

    /// ⌘F shows the find bar with its field focused; ⌘F again there hides it. Away from its field, ⌘F goes back to it.
    /// ⇧⌘2 brings Capture over the page and again takes it away; Esc leaves it too, and so does going to another tab
    /// (#457).
    @Test func shiftCommandTwoOpensCaptureAndEscLeaves() async throws {
        #expect(keys(#selector(BrowserWindowController.takePageScreenshot(_:))) == ["⇧⌘2"])
        try await pages(["one", "two"]) { urls in
            try await inWindow(urls) { controller, tabs in
                #expect(await settled(tabs[0], at: urls[0]))
                controller.root.layoutSubtreeIfNeeded()
                controller.takePageScreenshot(nil)
                #expect(controller.capture.isActive)
                controller.takePageScreenshot(nil)
                #expect(!controller.capture.isActive)
                controller.takePageScreenshot(nil)
                let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                                                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                #expect(controller.capture.handle(esc))
                #expect(!controller.capture.isActive)
                controller.takePageScreenshot(nil)
                #expect(controller.capture.isActive)
                controller.tabManager.select(tabs[1])
                #expect(await until(2) { !controller.capture.isActive })
            }
        }
    }

    @Test func commandFShowsTheFindBarAndAgainHidesIt() async throws {
        #expect(keys(#selector(BrowserWindowController.showFindBar(_:))) == ["⌘f"])
        try await inWindow([nil]) { controller, _ in
            controller.showFindBar(nil)
            #expect(controller.findBar.isVisible)
            #expect(controller.window?.firstResponder is NSTextView)
            controller.window?.makeFirstResponder(nil)
            controller.showFindBar(nil)
            #expect(controller.findBar.isVisible)
            #expect(controller.window?.firstResponder is NSTextView)
            controller.showFindBar(nil)
            #expect(!controller.findBar.isVisible)
        }
    }

    /// ⌘D pins the page at the end of the space's pinned pages, with no question.
    @Test func commandDPinsAtTheEndOfPinnedWithoutAsking() async throws {
        #expect(keys(#selector(BrowserWindowController.toggleBookmark(_:))) == ["⌘d"])
        try await inWindow([URL(string: "http://127.0.0.1:9/keys/pin")!]) { controller, tabs in
            let space = tabs[0].spaceID
            _ = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/keys/already")!, title: "Already", to: space))
            controller.toggleBookmark(nil)
            let id = try #require(tabs[0].bookmarkID)
            #expect(Library.shared.bookmarks(in: space).last?.id == id)
            #expect(Library.shared.folderID(containing: id) == nil)
        }
    }
}

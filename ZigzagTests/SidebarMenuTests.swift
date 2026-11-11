import AppKit
import Testing
@testable import Zigzag

/// The sidebar's own menus, the + and a right-click on its empty space: Zigzag's drawn menu, the same items in the
/// same order, with the shortcuts the menu bar gives them, and the keys a menu takes.
@MainActor
struct SidebarMenuTests {
    @Test func plusOffersTabFolderThenSpace() {
        #expect(SidebarMenus.addEntries(isPrivate: false) == [.newTab, .newFolder, .newSpace])
    }

    @Test func emptySpaceMatchesThePlusWithEditSpace() {
        #expect(SidebarMenus.blankEntries(isPrivate: false) == [.newTab, .newFolder, .separator, .editSpace, .newSpace])
        // The same items as the +, in the same order.
        #expect(SidebarMenus.blankEntries(isPrivate: false).filter { $0 != .separator && $0 != .editSpace } == SidebarMenus.addEntries(isPrivate: false))
    }

    @Test func privateWindowOnlyMakesTabs() {
        #expect(SidebarMenus.blankEntries(isPrivate: true) == [.newTab])
        #expect(SidebarMenus.addEntries(isPrivate: true) == [.newTab])
    }

    @Test func everyItemHasASymbolAndTheMenuBarsShortcut() {
        for entry in SidebarMenus.blankEntries(isPrivate: false) where entry != .separator {
            #expect(SidebarMenus.symbol(of: entry) != nil)
            #expect(!SidebarMenus.title(of: entry).isEmpty)
        }
        #expect(SidebarMenus.action(of: .newTab) == #selector(BrowserWindowController.newTab(_:)))
        #expect(SidebarMenus.action(of: .newSpace) == #selector(BrowserWindowController.newSpace(_:)))
        #expect(SidebarMenus.action(of: .editSpace) == #selector(BrowserWindowController.renameSpace(_:)))
        // No menu bar item makes a folder, so it shows no shortcut rather than an invented one.
        #expect(SidebarMenus.action(of: .newFolder) == nil)
        // New Space makes the space at once, as New Folder does: no ellipsis, the same as in the menu bar.
        #expect(SidebarMenus.title(of: .newSpace) == String(localized: "New Space", comment: "View menu item."))
        #expect(SidebarMenus.title(of: .editSpace).hasSuffix("…"))
    }

    // MARK: The drawn menu

    private func host() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = content
        let anchor = NSView(frame: NSRect(x: 200, y: 20, width: 26, height: 26))
        content.addSubview(anchor)
        return (window, anchor)
    }

    private func key(_ code: UInt16, _ characters: String = "", in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func entries(_ chosen: @escaping (String) -> Void) -> [MenuPanel.Entry] {
        ["New Tab", "New Folder", "New Space"].map { title in
            .item(MenuPanel.Item(title: title, symbol: "plus", shortcut: title == "New Tab" ? "⌘T" : "") { chosen(title) })
        }
    }

    @Test func opensJustAboveThePlusAlignedToIt() throws {
        let (window, anchor) = host()
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .aboveTrailing))
        defer { menu.close(animated: false) }
        let frame = menu.convert(menu.bounds, to: nil)
        let button = anchor.convert(anchor.bounds, to: nil)
        #expect(abs(frame.maxX - button.maxX) < 0.5)
        #expect(frame.minY >= button.maxY)
        #expect(frame.minY - button.maxY <= Tokens.Space.x1 + 0.5)
        #expect(menu.itemTitles == ["New Tab", "New Folder", "New Space"])
        _ = window
    }

    @Test func rightClickOpensUnderThePointer() throws {
        let (_, anchor) = host()
        let point = NSPoint(x: 120, y: 400)
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .at(point)))
        defer { menu.close(animated: false) }
        let frame = menu.convert(menu.bounds, to: nil)
        #expect(abs(frame.minX - point.x) < 0.5)
        #expect(abs(frame.maxY - point.y) < 0.5)
    }

    @Test func aShortcutWidensTheMenuToFitIt() throws {
        let (_, anchor) = host()
        let plain = try #require(MenuPanel.show([.item(MenuPanel.Item(title: "New Tab") {})], from: anchor))
        let plainWidth = plain.frame.width
        plain.close(animated: false)
        let keyed = try #require(MenuPanel.show([.item(MenuPanel.Item(title: "New Tab", shortcut: "⌥⌘N") {})], from: anchor))
        defer { keyed.close(animated: false) }
        #expect(keyed.frame.width > plainWidth)
    }

    @Test func arrowsMoveReturnPicksEscapeCloses() throws {
        let (window, anchor) = host()
        var picked: String?
        let menu = try #require(MenuPanel.show(entries { picked = $0 }, from: anchor, placement: .aboveTrailing))
        #expect(menu.highlightedIndex == nil)
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.highlightedIndex == 0)
        #expect(menu.handleKey(key(125, in: window)))
        #expect(menu.highlightedIndex == 1)
        #expect(menu.handleKey(key(126, in: window)))
        #expect(menu.highlightedIndex == 0)
        // Up from the first stays there; End goes to the last.
        #expect(menu.handleKey(key(126, in: window)))
        #expect(menu.highlightedIndex == 0)
        #expect(menu.handleKey(key(119, in: window)))
        #expect(menu.highlightedIndex == 2)
        #expect(menu.handleKey(key(36, "\r", in: window)))
        #expect(picked == "New Space")
        #expect(MenuPanel.current == nil)

        let again = try #require(MenuPanel.show(entries { picked = $0 }, from: anchor, placement: .aboveTrailing))
        picked = nil
        #expect(again.handleKey(key(53, in: window)))
        #expect(picked == nil)
        #expect(MenuPanel.current == nil)
    }

    @Test func isAMenuOfMenuItemsForVoiceOver() throws {
        let (_, anchor) = host()
        let menu = try #require(MenuPanel.show(entries { _ in }, from: anchor, placement: .aboveTrailing))
        defer { menu.close(animated: false) }
        #expect(menu.accessibilityRole() == .menu)
        let items = (menu.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.accessibilityRole() == .menuItem })
        #expect(items.first?.accessibilityLabel() == "New Tab")
    }
}

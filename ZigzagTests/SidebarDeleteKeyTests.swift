import AppKit
import Testing
@testable import Zigzag

/// Delete closes the rows picked in the sidebar, only while they hold the keys; a plain click never gives the list the
/// keys, so Delete in the page stays the page's (#375).
@MainActor
struct SidebarDeleteKeyTests {
    private final class Host: SidebarListDelegate {
        let tabManager: TabManager
        init(_ manager: TabManager) { tabManager = manager }
        func listSelect(_ tab: Tab) {}
        func listOpenBookmark(_ bookmark: Bookmark) {}
        func listRenameBookmark(_ id: UUID, to name: String) {}
        func listClose(_ tab: Tab) {}
        func listClose(_ tabs: [Tab]) {}
        var removed: [[SidebarItem]] = []
        func listRemove(_ items: [SidebarItem]) { removed.append(items) }
        func listNewTab() {}
        func listClearTabs() {}
        func listSetFolderOpen(_ id: UUID, _ open: Bool) {}
        func listSetGroupOpen(_ id: UUID, _ open: Bool) {}
        func listRenameGroup(_ id: UUID, to name: String) {}
        func listMoveGroup(_ id: UUID, to index: Int, in spaceID: UUID) {}
        func listPinGroup(_ id: UUID, at index: Int, in spaceID: UUID, folder: UUID?) {}
        func listAddToGroup(_ tabs: [Tab], group: UUID) {}
        func listRenameFolder(_ id: UUID, to name: String) {}
        func listSetFolder(of bookmarkID: UUID, to folderID: UUID?) {}
        func listAsOne(_ name: String, _ body: @escaping () -> Void) { body() }
        func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?) {}
        func listMoveFolder(_ id: UUID, to index: Int, in spaceID: UUID, parent: UUID?) {}
        func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {}
        func listMenu(for item: SidebarItem) -> NSMenu? { nil }
        func listMenu(forMarked items: [SidebarItem]) -> NSMenu? { nil }
        func listDragHoverSpace(at windowPoint: NSPoint) -> UUID? { nil }
        func listDragEnded() {}
        func listDropFinished() {}
        func listMove(_ tab: Tab, to index: Int, in spaceID: UUID, nesting: TabManager.Nesting, grouping: TabManager.Grouping) {}
        func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID) {}
        func listUnbookmark(_ bookmarkID: UUID, to index: Int, under parent: UUID?, group: UUID?) {}
        func listSetNestedTabsCollapsed(_ tab: Tab, _ collapsed: Bool) {}
        func listSwitchSpaceDuringDrag(_ spaceID: UUID) {}
        func listDropOutside(_ tabs: [Tab], at screenPoint: NSPoint) -> Bool { false }
        func listMoveToWindow(_ tabs: [Tab], controller: BrowserWindowController, index: Int) -> Bool { false }
        func listMovePinnedToWindow(_ bookmarkID: UUID, controller: BrowserWindowController, at screenPoint: NSPoint) -> NSView? { nil }
        func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID) {}
        func listDragOverFavorites(at windowPoint: NSPoint?, carrying: TabManager.SplitSide?) -> Bool { false }
        func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool) {}
        func listJoinSplit(_ page: TabManager.RowPage, onto target: TabManager.RowPage, onRight: Bool) {}
        func listZoomPane(_ tab: Tab) {}
        func listPinSplit(_ tab: Tab, onto bookmarkID: UUID, tabOnRight: Bool) {}
        func listUnpinSplit(_ bookmarkID: UUID, onto tab: Tab, pinnedOnRight: Bool) {}
        func listJoinPinned(_ bookmarkID: UUID, onto targetID: UUID, onRight: Bool) {}
        func listDropOnFavorites(_ items: [SidebarItem], dragged: SidebarItem) -> Bool { false }
        func listFavoriteTile(for bookmarkID: UUID) -> NSView? { nil }
        func listDragOverPage(at windowPoint: NSPoint?, item: SidebarItem) {}
        func listDropOnPage(_ item: SidebarItem) -> Bool { false }
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: isRepeat, keyCode: code)!
    }

    @Test func deleteClosesPickedRowsOnceAndOnlyWhilePicked() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        let tabs = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false) }
        defer { tabs.forEach { $0.close() }; manager.invalidate() }
        let host = Host(manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        // Nothing picked: a click or Tab never gives the list the keys.
        #expect(!list.acceptsFirstResponder)
        #expect(!list.marksHaveFocus)

        list.mark(pages: [tabs[0], tabs[1]])
        #expect(list.marked.count == 2, "\(list.marked) of \(tabs.map(\.id))")
        #expect(list.marksHaveFocus)
        list.keyDown(with: key(51))
        #expect(host.removed.count == 1)
        #expect(host.removed.first?.count == list.marked.count)
        // Held down, the press closes nothing more.
        list.keyDown(with: key(51, repeat: true))
        #expect(host.removed.count == 1)
        // Forward Delete and ⌘⌫ do the same as ⌫.
        list.keyDown(with: key(117))
        list.keyDown(with: key(51, .command))
        #expect(host.removed.count == 3)
        // ⌥⌫ isn't Delete here.
        list.keyDown(with: key(51, .option))
        #expect(host.removed.count == 3)
    }

    @Test func theRestOfTheDeletePressIsHeldBack() {
        func back(_ type: NSEvent.EventType, _ code: UInt16, _ isRepeat: Bool = false, holding: Bool = true) -> (Bool, Bool) {
            let r = BrowserWindow.holdsBack(type, keyCode: code, isRepeat: isRepeat, holding: holding)
            return (r.drop, r.keep)
        }
        // Repeats of Delete go nowhere, until the key comes up.
        #expect(back(.keyDown, 51, true) == (true, true))
        #expect(back(.keyDown, 117, true) == (true, true))
        #expect(back(.keyUp, 51) == (true, false))
        // A fresh press or another key reaches the page as always.
        #expect(back(.keyDown, 51) == (false, false))
        #expect(back(.keyDown, 0) == (false, false))
        #expect(back(.keyUp, 0) == (false, true))
        #expect(back(.keyDown, 51, true, holding: false) == (false, false))
    }
}

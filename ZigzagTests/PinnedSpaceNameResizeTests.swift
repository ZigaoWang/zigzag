import AppKit
import Testing
@testable import Zigzag

/// The space name stays pinned at the top of a scrolled list through resizes and row rebuilds (sidebar size change), never hidden.
@MainActor
struct PinnedSpaceNameResizeTests {
    private final class Host: SidebarListDelegate {
        let tabManager: TabManager
        init(_ manager: TabManager) { tabManager = manager }
        func listSelect(_ tab: Tab) {}
        func listOpenBookmark(_ bookmark: Bookmark) {}
        func listRenameBookmark(_ id: UUID, to name: String) {}
        func listClose(_ tab: Tab) {}
        func listClose(_ tabs: [Tab]) {}
        func listRemove(_ items: [SidebarItem]) {}
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

    /// The name is pinned: in the scroll view, at the visible top, list width, rows under it clipped.
    private func expectPinned(_ list: SidebarListView, in scroll: NSScrollView, _ comment: Comment) {
        let header = list.headerView
        #expect(header?.superview === scroll, comment)
        #expect(list.layer?.mask != nil, comment)
        guard let header, header.superview === scroll else { return }
        let clip = scroll.contentView
        let shown = scroll.convert(header.frame, to: clip)
        #expect(abs(shown.minY - clip.bounds.minY) < 0.5, comment)
        #expect(shown.maxX <= list.bounds.width + 0.5 && shown.width > list.bounds.width / 2, comment)
        #expect(!header.isHidden && header.alphaValue > 0, comment)
    }

    @Test func theNameStaysThroughAResizeAndARebuild() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        let tabs = (0..<40).map { _ in manager.newTab(url: nil, spaceID: space, select: false) }
        defer { tabs.forEach { $0.close() }; manager.invalidate() }
        let host = Host(manager)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let clip = FlippedClip()
        scroll.contentView = clip
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        scroll.documentView = list
        // In a window so it gets the size-change notification.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(scroll)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        list.delegate = host
        list.reload(animated: false)
        #expect(list.contentHeight > 600)

        // Scrolled down: the name is pinned.
        clip.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(clip)
        list.pinHeader()
        expectPinned(list, in: scroll, "scrolled")

        // Sidebar resized while scrolled.
        list.setFrameSize(NSSize(width: 300, height: list.frame.height))
        expectPinned(list, in: scroll, "wider")
        list.setFrameSize(NSSize(width: 200, height: list.frame.height))
        expectPinned(list, in: scroll, "narrower")

        // Sidebar size changed: every row is rebuilt.
        NotificationCenter.default.post(name: Tokens.Sidebar.sizeChanged, object: nil)
        expectPinned(list, in: scroll, "rows made again")
        list.reload(animated: false)
        expectPinned(list, in: scroll, "reloaded")

        // Back at the top: the first row, nothing masked.
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        list.pinHeader()
        #expect(list.headerView?.superview === list)
        #expect(list.layer?.mask == nil)
    }

    private final class FlippedClip: NSClipView {
        override var isFlipped: Bool { true }
    }
}

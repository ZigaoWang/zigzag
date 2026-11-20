import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Closing one page of a split closes that page alone (#404): the other stays open where the split's row was, and
/// ⌘Z puts the split back. Close Split View closes them all.
@MainActor struct SplitCloseTests {
    private func inWindow(_ titles: [String], _ body: (BrowserWindowController, [Tab]) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = titles.enumerated().map { i, title in Tab(url: URL(string: "https://example.com/split/\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        try body(controller, tabs)
    }

    private func row(_ tab: Tab, partners: [Tab]) -> TabRowView {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: Tokens.Sidebar.rowHeight))
        row.configure(tab: tab)
        row.configure(partners: partners)
        row.closesPart = true
        return row
    }

    /// The split's row sits at A's place; B's own is further down. Closing A leaves B there, selected, alone.
    @Test func closingTheLeftPageLeavesTheOtherInItsPlace() throws {
        try inWindow(["A", "X", "Y", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[3])
            manager.select(tabs[0])
            controller.listClose(tabs[0])
            #expect(manager.tab(with: tabs[0].id) == nil)
            #expect(manager.split(for: tabs[3]) == nil)
            #expect(manager.selectedTab === tabs[3])
            #expect(manager.currentTabs.map(\.displayTitle) == ["B", "X", "Y"])
            // ⌘Z: the split again, A on the left.
            controller.sidebarUndo.undo()
            let pair = try #require(manager.split(for: tabs[3]))
            #expect(pair.ids.count == 2 && pair.ids.last == tabs[3].id)
            #expect(manager.tab(with: pair.ids[0])?.displayTitle == "A")
        }
    }

    @Test func closingTheRightPageKeepsTheLeft() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            controller.listClose(tabs[1])
            #expect(manager.tab(with: tabs[1].id) == nil)
            #expect(manager.split(for: tabs[0]) == nil)
            #expect(manager.selectedTab === tabs[0])
            #expect(manager.currentTabs.map(\.displayTitle) == ["A", "C"])
        }
    }

    /// The row's × is on the part pointed at, else on the page you're in.
    @Test func theRowsCloseButtonClosesOnePart() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let left = tabs[0], right = tabs[1]
            let row = row(left, partners: [right])
            row.isSelected = true
            row.focusedHalf = 1
            #expect(row.closingPage === right)
            row.focusedHalf = 0
            #expect(row.closingPage === left)
            // Not a split row's per-part ×: the row's own tab.
            row.closesPart = false
            #expect(row.closingPage === left)
            _ = controller
        }
    }

    /// Close Tab closes the page alone; Close Split View all of it, and one ⌘Z puts it all back where it was.
    @Test func theMenuOffersBoth() throws {
        try inWindow(["A", "C", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[2])
            let menu = SidebarMenus.tabMenu(for: tabs[2], controller: controller)
            let titles = menu.items.map(\.title)
            let close = try #require(titles.firstIndex(of: "Close Tab"))
            #expect(titles[close + 1] == "Close Split View")
            let item = menu.items[close + 1]
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
            #expect(manager.tab(with: tabs[0].id) == nil && manager.tab(with: tabs[2].id) == nil)
            #expect(manager.currentTabs.map(\.displayTitle) == ["C"])
            controller.sidebarUndo.undo()
            #expect(manager.currentTabs.map(\.displayTitle) == ["A", "C", "B"])
            #expect(manager.currentTabs.first { $0.displayTitle == "A" }.flatMap(manager.split(for:)) != nil)
        }
    }
}

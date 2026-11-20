import AppKit
import Foundation
import Testing
@testable import Zigzag

/// ⌥⌘↑/↓, ⇧⌘[/] and ⌃Tab in sidebar order (#403): the next row down the sidebar as it shows, wrapping, a split one
/// stop, folded rows skipped, never another space.
@MainActor struct TabNavigationTests {
    private func inWindow(_ titles: [String], _ body: (BrowserWindowController, [Tab], UUID) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        if Library.shared.spaces.count < 2 { _ = Library.shared.addSpace(name: "Other") }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = titles.enumerated().map { i, title in Tab(url: URL(string: "https://example.com/nav/\(i)")!, title: title, spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        try body(controller, tabs, space)
    }

    private func next(_ controller: BrowserWindowController) {
        controller.sidebar.list.reload(animated: false)
        controller.selectNextTab(nil)
    }

    private func previous(_ controller: BrowserWindowController) {
        controller.sidebar.list.reload(animated: false)
        controller.selectPreviousTab(nil)
    }

    @Test func goesDownTheSidebarAndWraps() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let manager = controller.tabManager
            next(controller)
            #expect(manager.selectedTab === tabs[1])
            next(controller)
            #expect(manager.selectedTab === tabs[2])
            next(controller)
            #expect(manager.selectedTab === tabs[0])
            previous(controller)
            #expect(manager.selectedTab === tabs[2])
        }
    }

    /// The order is the sidebar's, not the order the tabs were last used in.
    @Test func ignoresRecentUse() throws {
        try inWindow(["A", "B", "C", "D"]) { controller, tabs, _ in
            let manager = controller.tabManager
            manager.select(tabs[3])
            manager.select(tabs[1])
            next(controller)
            #expect(manager.selectedTab === tabs[2])
        }
    }

    /// A split is one row: the next stop after it is the tab below, never its other half.
    @Test func aSplitIsOneStop() throws {
        try inWindow(["A", "B", "C", "D"]) { controller, tabs, _ in
            let manager = controller.tabManager
            // B's own place is lower down; the split's row is A's.
            manager.makeSplit(tabs[0], with: tabs[3])
            manager.select(tabs[0])
            next(controller)
            #expect(manager.selectedTab === tabs[1])
            next(controller)
            #expect(manager.selectedTab === tabs[2])
            next(controller)
            #expect(manager.selectedTab.flatMap(manager.split(for:)) != nil)
            // Back to the split: the page of it you were on last.
            manager.select(tabs[3])
            next(controller)
            #expect(manager.selectedTab === tabs[1])
            previous(controller)
            #expect(manager.selectedTab === tabs[3])
        }
    }

    /// Tabs in a folded group aren't in the sidebar, so the keys go past them.
    @Test func skipsAFoldedGroup() throws {
        try inWindow(["A", "B", "C", "D"]) { controller, tabs, _ in
            let manager = controller.tabManager
            let group = try #require(manager.makeGroup(with: [tabs[1], tabs[2]], name: "G"))
            manager.setGroupOpen(group, false)
            manager.select(tabs[0])
            next(controller)
            #expect(manager.selectedTab === tabs[3])
            manager.setGroupOpen(group, true)
            previous(controller)
            #expect(manager.selectedTab === tabs[2])
        }
    }

    /// Pinned rows come first, open or not, in the sidebar's order; a closed one opens.
    @Test func walksPinnedRowsOpenOrNot() throws {
        try inWindow(["A"]) { controller, tabs, space in
            let manager = controller.tabManager
            let first = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pin/1")!, title: "P1", to: space, at: 0))
            let second = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pin/2")!, title: "P2", to: space, at: 1))
            previous(controller)
            #expect(manager.selectedTab?.bookmarkID == second.id)
            previous(controller)
            #expect(manager.selectedTab?.bookmarkID == first.id)
            previous(controller)
            #expect(manager.selectedTab === tabs[0])
        }
    }

    /// Only this space's rows: the keys never go to another space.
    @Test func staysInTheSpace() throws {
        try inWindow(["A", "B"]) { controller, tabs, space in
            let manager = controller.tabManager
            let other = try #require(Library.shared.spaces.first { $0.id != space }).id
            manager.adopt([Tab(url: URL(string: "https://example.com/nav/other")!, title: "O", spaceID: other)], in: other)
            for _ in 0..<4 {
                next(controller)
                #expect(manager.currentSpaceID == space)
                #expect(manager.selectedTab?.spaceID == space)
            }
            _ = tabs
        }
    }

    /// ⌃Tab keeps the recent-tabs switcher unless Settings › Tabs says sidebar order.
    @Test func controlTabFollowsTheSetting() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TabSwitcher.orderKey)
        defer { defaults.set(saved, forKey: TabSwitcher.orderKey) }
        defaults.removeObject(forKey: TabSwitcher.orderKey)
        #expect(TabSwitcher.order == .recent)
        try inWindow(["A", "B", "C"]) { controller, tabs, _ in
            let manager = controller.tabManager
            let window = try #require(controller.window)
            func controlTab(shift: Bool = false) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.control, .shift] : [.control], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                               isARepeat: false, keyCode: 48))
            }
            TabSwitcher.order = .sidebar
            controller.sidebar.list.reload(animated: false)
            #expect(controller.switcher.handle(try controlTab()))
            #expect(manager.selectedTab === tabs[1])
            #expect(!controller.switcher.isActive)
            #expect(controller.switcher.handle(try controlTab(shift: true)))
            #expect(manager.selectedTab === tabs[0])
            // Recent tabs: the switcher starts, and nothing changes until Control is let go.
            TabSwitcher.order = .recent
            manager.select(tabs[2])
            manager.select(tabs[0])
            #expect(controller.switcher.handle(try controlTab()))
            #expect(controller.switcher.isActive)
            #expect(manager.selectedTab === tabs[0])
            let letGo = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                       context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59))
            _ = controller.switcher.handle(letGo)
            #expect(manager.selectedTab === tabs[2])
        }
    }
}

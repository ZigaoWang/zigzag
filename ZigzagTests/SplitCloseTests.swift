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
        row.configure(parts: partners.map { TabRowView.Part(page: $0) })
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

    /// The × of a split's row sits where a single tab's does, at the row's end, and says it closes the split.
    @Test func theCloseButtonSitsWhereASingleTabsDoes() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs in
            let single = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: Tokens.Sidebar.rowHeight))
            single.configure(tab: tabs[2])
            single.isSelected = true
            single.layoutSubtreeIfNeeded()
            for focused in [0, 1] {
                let row = row(tabs[0], partners: [tabs[1]])
                row.isSelected = true
                row.focusedHalf = focused
                row.layoutSubtreeIfNeeded()
                #expect(!row.closeButton.isHidden)
                #expect(row.closeButton.frame == single.closeButton.frame)
                #expect(row.closeButton.toolTip == "Close Split View")
            }
            let row = row(tabs[0], partners: [tabs[1]])
            row.layoutSubtreeIfNeeded()
            #expect(row.closeButton.isHidden)
            _ = controller
        }
    }

    /// The row's × closes every page of the split, and one ⌘Z brings them back side by side.
    @Test func theRowsCloseButtonClosesTheSplit() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            controller.sidebar.list.reload(animated: false)
            controller.sidebar.list.layoutSubtreeIfNeeded()
            let row = try #require(controller.sidebar.list.row(for: tabs[0]) as? TabRowView)
            row.onClose?()
            #expect(manager.currentTabs.map(\.displayTitle) == ["C"])
            controller.sidebarUndo.undo()
            #expect(manager.currentTabs.map(\.displayTitle) == ["A", "B", "C"])
            #expect(manager.currentTabs.first { $0.displayTitle == "A" }.flatMap(manager.split(for:))?.count == 2)
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

    /// A middle-click on a split's row closes the page of the part under the pointer, the other left open.
    @Test func aMiddleClickClosesThePartUnderThePointer() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            let row = row(tabs[0], partners: [tabs[1]])
            row.layoutSubtreeIfNeeded()
            let middle = row.bounds.midY
            #expect(row.page(at: NSPoint(x: row.bounds.width * 0.25, y: middle)) === tabs[0])
            let pointed = try #require(row.page(at: NSPoint(x: row.bounds.width * 0.75, y: middle)))
            #expect(pointed === tabs[1])
            controller.listClose(pointed)
            #expect(manager.tab(with: tabs[1].id) == nil)
            #expect(manager.tab(with: tabs[0].id) === tabs[0])
            #expect(manager.split(for: tabs[0]) == nil)
        }
    }

    /// Stack Vertically puts the two one above the other, and the item then reads Side by Side, which undoes it.
    @Test func stackVerticallyThenReadsSideBySide() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.toggleSplitOrientation(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(item))
            #expect(item.title == "Stack Vertically")
            #expect(manager.split(for: tabs[0])?.vertical == false)
            controller.toggleSplitOrientation(item)
            #expect(manager.split(for: tabs[0])?.vertical == true)
            #expect(controller.validateMenuItem(item))
            #expect(item.title == "Side by Side")
            controller.toggleSplitOrientation(item)
            #expect(manager.split(for: tabs[0])?.vertical == false)
            #expect(controller.validateMenuItem(item))
            #expect(item.title == "Stack Vertically")
        }
    }

    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = self.item(title, in: sub) { return found }
        }
        return nil
    }

    /// Open in Split View in a tab's sidebar menu puts that tab on the right of the page you're on.
    @Test func openInSplitViewFromTheMenuOpensOnTheRight() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs in
            let manager = controller.tabManager
            manager.select(tabs[1])
            let menu = SidebarMenus.tabMenu(for: tabs[2], controller: controller)
            let open = try #require(item("Open in Split View", in: menu))
            NSApp.sendAction(try #require(open.action), to: open.target, from: open)
            let pair = try #require(manager.split(for: tabs[1]))
            #expect(pair.ids == [tabs[1].id, tabs[2].id])
            #expect(!pair.vertical)
        }
    }

    /// The command bar's Open in Split View puts the page you were on last on the right of the one you're on.
    @Test func openInSplitViewFromTheCommandBarOpensOnTheRight() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs in
            let manager = controller.tabManager
            manager.select(tabs[2])
            manager.select(tabs[1])
            controller.commandBar.runAction("split")
            let pair = try #require(manager.split(for: tabs[1]))
            #expect(pair.ids == [tabs[1].id, tabs[2].id])
        }
    }

    /// Dropped on the middle of a tab's row, a tab opens beside it, on the half it was let go over; on a pinned
    /// page's row, the two become a pinned split.
    @Test func aRowDroppedOnAnotherRowsMiddleOpensBesideIt() throws {
        try inWindow(["A", "B", "C"]) { controller, tabs in
            let manager = controller.tabManager
            controller.listSplit(tabs[0], with: tabs[1], otherOnRight: true)
            #expect(manager.split(for: tabs[0])?.ids == [tabs[0].id, tabs[1].id])
            manager.unsplit(tabs[0])
            controller.listSplit(tabs[0], with: tabs[2], otherOnRight: false)
            #expect(manager.split(for: tabs[0])?.ids == [tabs[2].id, tabs[0].id])
            manager.unsplit(tabs[0])
            let space = tabs[0].spaceID
            let pin = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/split/pin")!, title: "Pin", to: space))
            controller.listPinSplit(tabs[1], onto: pin.id, tabOnRight: true)
            let pinned = try #require(Library.shared.pinnedSplit(containing: pin.id))
            #expect(pinned.ids.count == 2 && pinned.ids.first == pin.id)
            let page = try #require(manager.bookmarkTab(for: pin.id))
            #expect(manager.split(for: page)?.ids.count == 2)
        }
    }

    /// Links and files dropped on the page open as tabs, the first in front, and the split you're in stays as it is.
    @Test func aLinkDroppedOnThePageOpensATabNotASplit() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            let link = URL(string: "https://example.com/split/dropped")!, file = URL(fileURLWithPath: "/tmp/dropped.txt")
            #expect(SidebarContainer.open([link, file], in: controller.window))
            let opened = try #require(manager.selectedTab)
            #expect(opened !== tabs[0] && opened !== tabs[1])
            #expect(manager.split(for: opened) == nil)
            #expect(manager.split(for: tabs[0])?.ids == [tabs[0].id, tabs[1].id])
            #expect(manager.currentTabs.count == 4)
        }
    }

    // MARK: Pane strips

    private func until(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    /// Clicking a pane's address makes that pane the one you're in and opens the command bar over it to edit it.
    @Test func aPanesAddressEditsThatPane() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            let card = try #require(controller.root.paneCards.first { $0.header.tab === tabs[1] })
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            card.header.address.onClick?(event)
            #expect(manager.selectedTab === tabs[1])
            #expect(controller.commandBar.isVisible)
            #expect(controller.commandBar.mode == .editCurrent)
            controller.commandBar.dismiss(restoringFocus: false)
        }
    }

    /// Back, Forward and Reload on a pane's strip go to that pane's page, the other pane left where it is.
    @Test func aStripsButtonsActOnItsOwnPane() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("strip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func page(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent("\(name).html")
            try "<title>\(name)</title><p>\(name)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let leftFirst = try page("left1"), leftSecond = try page("left2"), rightFirst = try page("right1"), rightSecond = try page("right2")
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let left = Tab(url: leftFirst, title: "Left", spaceID: space), right = Tab(url: rightFirst, title: "Right", spaceID: space)
        manager.adopt([left, right], in: space)
        manager.select(left)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        manager.makeSplit(left, with: right)
        manager.select(left)
        func settled(_ tab: Tab, at url: URL) async -> Bool {
            await until { tab.webView?.url == url && tab.webView?.isLoading == false }
        }
        #expect(await settled(left, at: leftFirst))
        #expect(await settled(right, at: rightFirst))
        left.load(leftSecond)
        right.load(rightSecond)
        #expect(await settled(left, at: leftSecond))
        #expect(await settled(right, at: rightSecond))
        let strip = try #require(controller.root.paneCards.first { $0.header.tab === right }).header
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        strip.back.onClick?(event)
        #expect(await settled(right, at: rightFirst))
        #expect(left.webView?.url == leftSecond)
        strip.forward.onClick?(event)
        #expect(await settled(right, at: rightSecond))
        #expect(left.webView?.url == leftSecond)
        // A mark each page holds until it loads again.
        for tab in [left, right] { _ = try await tab.webView?.evaluateJavaScript("window.zigzagMark = 1; 0") }
        strip.reload.onClick?(event)
        #expect(await until { (try? await right.webView?.evaluateJavaScript("typeof window.zigzagMark") as? String) == "undefined" })
        #expect(await settled(right, at: rightSecond))
        #expect((try await left.webView?.evaluateJavaScript("typeof window.zigzagMark")) as? String == "number")
        #expect(manager.selectedTab === left)
    }
}

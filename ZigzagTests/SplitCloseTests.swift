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

    private func row(_ tab: Tab, partners: [Tab], width: CGFloat = 240) -> TabRowView {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: width, height: Tokens.Sidebar.rowHeight))
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

    /// A tile group's non-first pages are shown on cards that were hidden and cleared while the group was away, or
    /// that have just joined it. They must already be their pane's size when they are shown, not resize a frame later.
    @Test func everyPaneComesBackAtItsOwnSize() throws {
        try inWindow(["A", "B", "C", "D", "E"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            let third = try #require(TileShape.placing(.bottomRight, beside: manager.split(for: tabs[0])?.shape.regions ?? []))
            manager.tile(tabs[2], beside: tabs[0], .place(region: .bottomRight, regions: third))
            // The third page joins a card that was hidden until now; it is not the group's first page.
            try expectNoPaneResize(controller, tabs: [tabs[0], tabs[1], tabs[2]])
            let fourth = try #require(TileShape.placing(.bottomLeft, beside: manager.split(for: tabs[0])?.shape.regions ?? []))
            manager.tile(tabs[3], beside: tabs[0], .place(region: .bottomLeft, regions: fourth))
            try expectNoPaneResize(controller, tabs: [tabs[0], tabs[1], tabs[2], tabs[3]])
            // Leave the group, then come back on a pane that is not the group's first page.
            manager.select(tabs[4])
            controller.window?.layoutIfNeeded()
            manager.select(tabs[1])
            // The first pane too: it is the anchor card, and it must come back at its size like the rest.
            try expectNoPaneResize(controller, tabs: [tabs[0], tabs[1], tabs[2], tabs[3]])
        }
    }

    /// The holders are at the size their cards would give them now; a layout pass changes none of them.
    private func expectNoPaneResize(_ controller: BrowserWindowController, tabs: [Tab]) throws {
        let holders = tabs.compactMap { $0.pageHolder }
        #expect(holders.count == tabs.count)
        let before = holders.map(\.frame)
        controller.window?.layoutIfNeeded()
        let after = holders.map(\.frame)
        if after != before {
            Issue.record("a pane resized a layout later: before \(before), after \(after), cards \(controller.root.paneCards.map(\.frame))")
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
            row.debugPoint(atPart: 1)
            #expect(row.closingPage === right)
            // A row of one page: its own tab.
            row.configure(parts: [])
            #expect(row.closingPage === left)
            _ = controller
        }
    }

    /// Each part's × sits inside it, the size, inset and height of a single tab's, and only on the part you point at
    /// or the page you're in.
    @Test(arguments: [2, 4]) func theCloseButtonSitsInItsPart(count: Int) throws {
        try inWindow((0..<count).map { "Page \($0)" } + ["Single"]) { controller, tabs in
            // Wide enough that every part shows its title, as a tab's row does.
            let width: CGFloat = count == 2 ? 240 : 480
            let single = TabRowView(frame: NSRect(x: 0, y: 0, width: width, height: Tokens.Sidebar.rowHeight))
            single.configure(tab: tabs[count])
            single.isSelected = true
            single.layoutSubtreeIfNeeded()
            let inset = single.bounds.maxX - single.closeButton.frame.maxX
            let row = row(tabs[0], partners: Array(tabs[1..<count]), width: width)
            row.isHovered = true
            for part in 0..<count {
                row.debugPoint(atPart: part)
                row.layoutSubtreeIfNeeded()
                #expect(!row.closeButton.isHidden)
                #expect(row.closeButton.toolTip == "Close Tab")
                #expect(row.closeButton.frame.size == single.closeButton.frame.size)
                #expect(row.closeButton.frame.minY == single.closeButton.frame.minY)
                let end = TabRowView.splitParts(count: count, end: row.bounds.width)[part].end
                #expect(end - row.closeButton.frame.maxX == inset)
                #expect(row.closingPage === tabs[part])
            }
            row.debugPoint(atPart: nil)
            row.isHovered = false
            row.layoutSubtreeIfNeeded()
            #expect(row.closeButton.isHidden)
            _ = controller
        }
    }

    /// A part's × closes that page alone, the rest of the split closing up, and ⌘Z puts it back in the split.
    @Test(arguments: [2, 4]) func aPartsCloseButtonClosesOnlyItsPage(count: Int) throws {
        try inWindow((0..<count).map { "Page \($0)" } + ["Other"]) { controller, tabs in
            let manager = controller.tabManager
            let pages = Array(tabs[0..<count])
            if count == 2 { manager.makeSplit(pages[0], with: pages[1]) } else {
                manager.makeGroup(pages, shape: TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], column: 0.5, row: 0.5))
            }
            controller.sidebar.list.reload(animated: false)
            controller.sidebar.list.layoutSubtreeIfNeeded()
            let row = try #require(controller.sidebar.list.row(for: pages[0]) as? TabRowView)
            let shown = row.pages
            #expect(shown.count == count)
            row.isHovered = true
            row.debugPoint(atPart: 1)
            #expect(row.closingPage === shown[1])
            row.onClose?()
            #expect(manager.tab(with: shown[1].id) == nil)
            let rest = shown.filter { $0 !== shown[1] }
            #expect(rest.allSatisfy { manager.tab(with: $0.id) === $0 })
            #expect(count == 2 ? manager.split(for: rest[0]) == nil : manager.split(for: rest[0])?.count == count - 1)
            controller.sidebarUndo.undo()
            let back = try #require(manager.split(for: rest[0]))
            #expect(back.count == count)
            #expect(manager.currentTabs.contains { $0.displayTitle == shown[1].displayTitle })
        }
    }

    /// No row of the tab list, one page or several, gives a system tooltip with a title: the hover card names them.
    @Test func aRowAndItsPartsCarryNoTitleTooltip() throws {
        try inWindow(["A page", "B page", "C page", "D page"]) { controller, tabs in
            let titles = tabs.map(\.displayTitle)
            for partners in [[], [tabs[1]], Array(tabs[1...3])] {
                let row = row(tabs[0], partners: partners)
                row.isHovered = true
                row.debugPoint(atPart: partners.isEmpty ? nil : 1)
                row.layoutSubtreeIfNeeded()
                var views: [NSView] = [row]
                var seen: [NSView] = []
                while let view = views.popLast() { seen.append(view); views += view.subviews }
                for view in seen {
                    #expect(view.toolTip.map { tip in !titles.contains { tip.contains($0) } } ?? true)
                    #expect((view as? NSTextField)?.allowsExpansionToolTips != true)
                }
                // No tooltip rects either: nothing names a page for a point of the row.
                #expect(!row.responds(to: #selector(NSViewToolTipOwner.view(_:stringForToolTip:point:userData:))))
            }
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

    /// Swap trades the panes on screen at once: the page you're in stays yours, find goes over its new place, and a
    /// click picks the page shown where you click.
    @Test func swapMovesThePagesOnScreen() throws {
        try inWindow(["A", "B"]) { controller, tabs in
            let manager = controller.tabManager
            manager.makeSplit(tabs[0], with: tabs[1])
            manager.select(tabs[0])
            let cards = controller.root.paneCards
            #expect(cards[0].header.tab === tabs[0] && cards[1].header.tab === tabs[1])
            cards[0].header.swap.onClick?(try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            #expect(manager.split(for: tabs[0])?.ids == [tabs[1].id, tabs[0].id])
            #expect(cards[0].header.tab === tabs[1] && cards[1].header.tab === tabs[0])
            #expect(manager.selectedTab === tabs[0])
            let frames = controller.root.tileFrames
            #expect(controller.focusedPaneFrame == frames[1])
            // A click on the left pane is for B, shown there now; on the right, back to A.
            func click(_ pane: NSRect) { controller.focusPane(at: controller.root.convert(NSPoint(x: pane.midX, y: pane.midY), to: nil)) }
            click(frames[0])
            #expect(manager.selectedTab === tabs[1])
            #expect(controller.focusedPaneFrame == frames[0])
            click(frames[1])
            #expect(manager.selectedTab === tabs[0])
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

import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Tab groups (#209): a folder over one contiguous run of tabs that stays intact, collapses, restores with the session, and is cleared as one.
struct TabGroupRulesTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    let g = UUID(), h = UUID()

    private func node(_ id: UUID, _ parent: UUID? = nil) -> TabTree.Node { TabTree.Node(id: id, parent: parent) }

    @Test func aNestedTabIsInItsParentsGroup() {
        let nodes = [node(a), node(b, a), node(c)]
        let settled = TabGroups.settled(nodes, groups: [a: g], riders: [:], known: [g])
        #expect(settled == [a: g, b: g])
    }

    @Test func aTabPutDownAmongAGroupsTabsJoinsIt() {
        let nodes = [node(a), node(b), node(c), node(d)]
        let settled = TabGroups.settled(nodes, groups: [a: g, c: g], riders: [:], known: [g])
        #expect(settled == [a: g, b: g, c: g])
    }

    @Test func aGroupInTwoRunsKeepsTheLongerOne() {
        let nodes = [node(a), node(b), node(c), node(d)]
        // d is in g but separated by h's tab: it leaves g.
        let settled = TabGroups.settled(nodes, groups: [a: g, b: g, c: h, d: g], riders: [:], known: [g, h])
        #expect(settled == [a: g, b: g, c: h])
    }

    @Test func aGroupThatsGoneHoldsNoTabs() {
        let settled = TabGroups.settled([node(a), node(b)], groups: [a: g, b: h], riders: [:], known: [h])
        #expect(settled == [b: h])
    }

    @Test func aSplitsOtherPageIsInItsRowsGroup() {
        // b rides in a's row; c rides in a pinned page's row, in no group.
        let nodes = [node(b), node(a), node(d), node(c)]
        let riders: [UUID: UUID?] = [b: a, c: nil]
        let settled = TabGroups.settled(nodes, groups: [a: g, d: g, c: g], riders: riders, known: [g])
        #expect(settled == [a: g, b: g, d: g])
    }

    @Test func aGroupMovesWholeAndNeverIntoAnother() {
        let nodes = [node(a), node(b), node(c), node(d, c), node(e)]
        let groups = [a: g, b: g]
        // Moving between c and its child: placed after both.
        let moved = TabGroups.moving([a, b], to: 1, in: nodes, groups: groups)
        #expect(moved.map(\.id) == [c, d, a, b, e])
        // Into another group's tabs: after them.
        let other = [node(a), node(b), node(c), node(d), node(e)]
        let pushed = TabGroups.moving([e], to: 2, in: other, groups: [a: g, b: g, c: g, e: h])
        #expect(pushed.map(\.id) == [a, b, c, e, d])
    }

    @Test func clearKeepsOrClosesAGroupAsOne() {
        let nodes = [node(a), node(b), node(c), node(d)]
        let parents = TabGroups.clearParents([:], nodes: nodes, groups: [c: g, d: g])
        #expect(parents == [d: c])
        let units = TabManager.units([a, b, c, d], groups: [], parents: parents)
        #expect(units == [[a], [b], [c, d]])
        // c seen just now, d long ago: the group stays whole; only b goes.
        let minutes: [UUID: TimeInterval] = [a: 0, b: 400 * 60, c: 1 * 60, d: 500 * 60]
        let kept = TabManager.clearing([a, b, c, d], current: a, groups: [], parents: parents, busy: [], ages: minutes)
        #expect(kept.ids == [b])
        // Both stale: they go together.
        let old: [UUID: TimeInterval] = [a: 0, b: 60, c: 400 * 60, d: 500 * 60]
        let gone = TabManager.clearing([a, b, c, d], current: a, groups: [], parents: parents, busy: [], ages: old)
        #expect(gone.ids == [c, d])
    }
}

@MainActor struct TabGroupsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// A window with tabs a–e, closed after the test.
    private func window(_ body: (TabManager, [Tab]) throws -> Void) rethrows {
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<5).map { Tab(url: URL(string: "https://example.com/\($0)"), title: "\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs)
    }

    private func order(_ manager: TabManager) -> [UUID] { manager.tabs(in: space).map(\.id) }

    @Test func groupingPutsTheTabsTogetherWhereTheFirstIs() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[3], t[1]], name: "Reading"))
            #expect(order(manager) == [t[0], t[1], t[3], t[2], t[4]].map(\.id))
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[1].id, t[3].id])
            #expect(manager.group(id)?.name == "Reading")
            #expect(manager.group(id)?.isOpen == true)
            #expect(manager.groups(in: space).map(\.id) == [id])
        }
    }

    @Test func tabsGoInAndOut() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            manager.setGroup(of: t[4], to: id)
            #expect(order(manager) == [t[0], t[1], t[4], t[2], t[3]].map(\.id))
            #expect(manager.tabs(inGroup: id).count == 3)
            manager.setGroup(of: t[0], to: nil)
            // Out, just after the group.
            #expect(order(manager) == [t[1], t[4], t[0], t[2], t[3]].map(\.id))
            #expect(t[0].groupID == nil)
            // Moving out of the group leaves it; moving within stays.
            manager.move(t[1], to: 1)
            #expect(t[1].groupID == id)
            manager.move(t[4], to: 4)
            #expect(t[4].groupID == nil)
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[1].id])
        }
    }

    @Test func aTabOpenedFromTheGroupsLastTabIsInIt() throws {
        let place = TabManager.newTabPlace
        defer { TabManager.newTabPlace = place }
        TabManager.newTabPlace = .next
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            let opened = manager.newTab(url: nil, spaceID: space, select: false, opener: t[1])
            #expect(order(manager)[2] == opened.id)
            #expect(opened.groupID == id)
            // Opened from an outside tab next to it: not in the group.
            let other = manager.newTab(url: nil, spaceID: space, select: false, opener: t[4])
            #expect(other.groupID == nil)
        }
    }

    @Test func foldingAndRenaming() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[2]], name: "G"))
            manager.setGroupOpen(id, false)
            #expect(manager.group(id)?.isOpen == false)
            manager.renameGroup(id, to: "  Work ")
            #expect(manager.group(id)?.name == "Work")
            manager.renameGroup(id, to: " ")
            #expect(manager.group(id)?.name == "Work")
        }
    }

    @Test func aGroupWithNoTabsGoesAndComesBackWithThem() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[1], t[2]], name: "Trip"))
            manager.setGroupOpen(id, false)
            let closed = manager.close([t[1], t[2]])
            #expect(manager.group(id) == nil)
            #expect(manager.groups(in: space).isEmpty)
            // Undo Close Tabs restores each tab and the group with its name and collapse state.
            manager.together { for tab in closed.reversed() { manager.reopenClosedTab(tab, select: false) } }
            #expect(manager.group(id)?.name == "Trip")
            #expect(manager.group(id)?.isOpen == false)
            #expect(manager.tabs(inGroup: id).map(\.displayTitle) == ["1", "2"])
            #expect(manager.tabs(in: space).map(\.displayTitle) == ["0", "1", "2", "3", "4"])
        }
    }

    @Test func ungroupingLeavesTheTabsWhereTheyAre() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[1], t[2]], name: "G"))
            manager.ungroup(id)
            #expect(manager.group(id) == nil)
            #expect(order(manager) == t.map(\.id))
            #expect(t.allSatisfy { $0.groupID == nil })
            // Deleted: reopening one of its tabs doesn't restore it.
            manager.close(t[1])
            let back = manager.reopenClosedTab(select: false)
            #expect(back?.groupID == nil)
        }
    }

    @Test func undoPutsTheGroupsBack() throws {
        try window { manager, t in
            let before = manager.arrangement
            let id = try #require(manager.makeGroup(with: [t[3], t[4]], name: "G"))
            let after = manager.arrangement
            #expect(!before.isSame(as: after))
            manager.restore(before, undoing: after)
            #expect(manager.group(id) == nil)
            #expect(order(manager) == t.map(\.id))
            // And again.
            manager.restore(after, undoing: before)
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[3].id, t[4].id])
            // Renames are undoable.
            let named = manager.arrangement
            manager.renameGroup(id, to: "H")
            #expect(!named.isSame(as: manager.arrangement))
        }
    }

    @Test func aGroupMovesWhole() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            manager.moveGroup(id, to: 2)
            #expect(order(manager) == [t[2], t[3], t[0], t[1], t[4]].map(\.id))
            #expect(manager.tabs(inGroup: id).count == 2)
        }
    }

    @Test func aTabMovedToAnotherSpaceLeavesItsGroup() throws {
        guard Library.shared.spaces.count > 1 else { return }
        let other = Library.shared.spaces[1].id
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[0], t[1]], name: "G"))
            manager.moveTabToSpace(t[1], spaceID: other)
            #expect(t[1].groupID == nil)
            #expect(manager.tabs(inGroup: id).map(\.id) == [t[0].id])
            manager.moveTabToSpace(t[0], spaceID: other)
            #expect(manager.group(id) == nil)
        }
    }

    @Test func groupsComeBackWithTheSession() throws {
        let group = TabGroup(name: "Saved", isOpen: false)
        var tab = SessionState.TabState(id: UUID(), url: URL(string: "https://example.com"), title: "x", lastActivated: Date(), createdAt: Date())
        tab.groupID = group.id
        let window = SessionState.WindowState(frame: [0, 0, 800, 600], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
                                              spaces: [SessionState.SpaceTabs(spaceID: space, tabs: [tab], selectedTabID: nil)],
                                              bookmarkTabs: [], isFullScreen: nil, splits: nil, tabGroups: [group])
        let data = try JSONEncoder().encode(SessionState(windows: [window]))
        let read = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(read.windows[0].tabGroups == [group])
        #expect(read.windows[0].spaces[0].tabs[0].groupID == group.id)
        // Restored like at launch: groups first, then tabs.
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        manager.restoreGroups(read.windows[0].tabGroups ?? [])
        let restored = Tab(id: tab.id, url: tab.url, title: tab.title, spaceID: space)
        read.windows[0].spaces[0].tabs[0].apply(to: restored)
        manager.adopt([restored], in: space)
        manager.structureChanged()
        #expect(manager.group(group.id) == group)
        #expect(manager.tabs(inGroup: group.id).map(\.id) == [restored.id])
        // Pre-group sessions have none.
        let old = #"{"windows":[{"frame":[0,0,1,1],"sidebarVisible":true,"sidebarWidth":240,"currentSpaceID":"\#(space.uuidString)","spaces":[],"bookmarkTabs":[]}]}"#
        #expect(try JSONDecoder().decode(SessionState.self, from: Data(old.utf8)).windows[0].tabGroups == nil)
    }
}

/// Which tab shows after closing the one you're on (#412), as in Chrome.
@MainActor @Suite(.serialized) struct TabCloseSelectionTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// A window with tabs 0–4, links opening next to the tab they came from.
    private func window(_ body: (TabManager, [Tab]) throws -> Void) rethrows {
        let place = TabManager.newTabPlace, nests = TabManager.nestsOpenedLinks
        TabManager.newTabPlace = .next
        TabManager.nestsOpenedLinks = false
        defer { TabManager.newTabPlace = place; TabManager.nestsOpenedLinks = nests }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<5).map { Tab(url: nil, title: "\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs)
    }

    @Test func closingGoesToTheTabBelowNotTheOneYouWereOnBefore() {
        window { manager, t in
            manager.select(t[4])
            manager.select(t[2])
            manager.close(t[2])
            #expect(manager.selectedTab === t[3])
            // The last one goes up.
            manager.select(t[4])
            manager.close(t[4])
            #expect(manager.selectedTab === t[3])
        }
    }

    @Test func aNewTabClosesBackToTheTabYouWereOn() {
        window { manager, t in
            manager.select(t[1])
            let opened = manager.newTab(url: nil, spaceID: space, select: true)
            manager.close(opened)
            #expect(manager.selectedTab === t[1])
            // Switched away and back first: an ordinary close, to the tab below.
            manager.select(t[3])
            let again = manager.newTab(url: nil, spaceID: space, select: true)
            manager.select(t[0])
            manager.select(again)
            let index = manager.tabs(in: space).firstIndex { $0 === again } ?? 0
            manager.close(again)
            let list = manager.tabs(in: space)
            #expect(manager.selectedTab === list[min(index, list.count - 1)])
        }
    }

    @Test func aLinkOpenedInFrontClosesBackToItsPage() {
        window { manager, t in
            manager.select(t[1])
            let opened = manager.newTab(url: nil, spaceID: space, select: true, opener: t[1])
            manager.close(opened)
            #expect(manager.selectedTab === t[1])
        }
    }

    @Test func linksOpenedBehindKeepTheirOrderAndCloseToTheNextOne() {
        window { manager, t in
            manager.select(t[1])
            let links = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false, opener: t[1]) }
            #expect(Array(manager.tabs(in: space)[2...4]).map(\.id) == links.map(\.id))
            // Opened in front after them: closing it goes to the last link the page opened, then up the row.
            let front = manager.newTab(url: nil, spaceID: space, select: true, opener: t[1])
            manager.close(front)
            #expect(manager.selectedTab === links[2])
        }
    }

    @Test func switchingTabsYourselfForgetsTheOpener() {
        window { manager, t in
            manager.select(t[1])
            let links = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false, opener: t[1]) }
            // Reading the results one by one: each ⌘W lands on the next, not back on the page they came from.
            manager.select(links[0])
            manager.close(links[0])
            #expect(manager.selectedTab === links[1])
            manager.close(links[1])
            #expect(manager.selectedTab === links[2])
            // Opened in front, then left and come back to: it closes to the tab below, not its page.
            let opened = manager.newTab(url: nil, spaceID: space, select: true, opener: t[0])
            manager.select(t[4])
            manager.select(opened)
            manager.close(opened)
            #expect(manager.selectedTab === t[1])
        }
    }

    @Test func aTabInAShutGroupBelowIsPassedOver() throws {
        try window { manager, t in
            let id = try #require(manager.makeGroup(with: [t[3], t[4]], name: "G"))
            manager.setGroupOpen(id, false)
            manager.select(t[2])
            manager.close(t[2])
            #expect(manager.selectedTab === t[1])
        }
    }

    /// A window over a manager of its own, with the library put back afterwards.
    private func inWindow(_ titles: [String], _ body: (BrowserWindowController, [Tab]) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = titles.map { Tab(url: nil, title: $0, spaceID: space) }
        manager.adopt(tabs, in: space)
        if let first = tabs.first { manager.select(first) }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        try body(controller, tabs)
    }

    /// ⌘W on a pinned page or a favorite unloads it and keeps it; opened again, it's a fresh page at its saved address.
    @Test func closingAPinnedPageOrFavoriteUnloadsItAndKeepsIt() throws {
        try inWindow(["Tab"]) { controller, tabs in
            let manager = controller.tabManager
            let pinned = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/close/pinned")!, title: "Pinned", to: space))
            let favorite = Library.shared.addFavorite(url: URL(string: "http://127.0.0.1:9/close/favorite")!, title: "Favorite",
                                                      in: Library.shared.profileID(ofSpace: space))
            for mark in [pinned, favorite] {
                manager.openBookmark(mark)
                let page = try #require(manager.bookmarkTab(for: mark.id))
                #expect(manager.selectedTab === page)
                controller.closeTab(nil)
                #expect(page.isClosed, "\(mark.title)")
                #expect(manager.bookmarkTab(for: mark.id) == nil, "\(mark.title)")
                #expect(Library.shared.bookmark(mark.id) != nil, "\(mark.title)")
                #expect(manager.tabs(in: space).map(\.id) == [tabs[0].id])
                manager.openBookmark(mark)
                let again = try #require(manager.bookmarkTab(for: mark.id))
                #expect(again !== page)
                #expect(again.url == mark.url)
                controller.closeTab(nil)
            }
        }
    }

    /// What the sidebar lists once it has caught up: pinned rows and favorite tiles by title.
    private func sidebarShows(_ controller: BrowserWindowController) -> [String] {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.sidebar.layoutSubtreeIfNeeded()
        let pins = controller.sidebar.list.debugItems.compactMap { item -> String? in
            guard case .bookmark(let id) = item else { return nil }
            return Library.shared.bookmark(id).map { "pin:" + $0.title }
        }
        return pins + controller.sidebar.favorites.debugTiles().map(\.0)
    }

    /// ⌘W or the row's × on a pinned page or favorite, selected or not, with other tabs or none: the sidebar keeps it.
    @Test func aClosedPinnedPageOrFavoriteStaysInTheSidebar() throws {
        for others in [["Tab"], []] {
            try inWindow(others) { controller, tabs in
                let manager = controller.tabManager
                let pinned = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/stays/pinned")!, title: "Pinned", to: space))
                let favorite = Library.shared.addFavorite(url: URL(string: "http://127.0.0.1:9/stays/favorite")!, title: "Favorite",
                                                          in: Library.shared.profileID(ofSpace: space))
                let both = ["pin:Pinned", "fav:Favorite"]
                #expect(both.allSatisfy(sidebarShows(controller).contains))
                for mark in [pinned, favorite] {
                    for selected in [true, false] where selected || !tabs.isEmpty {
                        manager.openBookmark(mark)
                        let page = try #require(manager.bookmarkTab(for: mark.id))
                        if selected { controller.closeTab(nil) } else { manager.select(tabs[0]); controller.listClose(page) }
                        #expect(page.isClosed)
                        let shown = sidebarShows(controller)
                        #expect(both.allSatisfy(shown.contains), "\(mark.title) selected=\(selected) others=\(others.count): \(shown)")
                    }
                }
            }
        }
    }

    /// A pinned page in an open folder or in a pinned split, closed with ⌘W: its row stays.
    @Test func aClosedPinnedPageInAFolderOrSplitStaysInTheSidebar() throws {
        try inWindow(["Tab"]) { controller, _ in
            let manager = controller.tabManager
            let filed = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/stays/filed")!, title: "Filed", to: space))
            let folder = try #require(Library.shared.addFolder(named: "Folder", with: [filed.id], in: space))
            Library.shared.setFolderOpen(folder.id, true)
            manager.openBookmark(filed)
            controller.closeTab(nil)
            #expect(sidebarShows(controller).contains("pin:Filed"))
            let left = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/stays/left")!, title: "Left", to: space))
            let right = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/stays/right")!, title: "Right", to: space))
            controller.listJoinPinned(right.id, onto: left.id, onRight: true)
            #expect(Library.shared.pinnedSplit(containing: left.id) != nil)
            let page = try #require(manager.bookmarkTab(for: left.id))
            manager.select(page)
            controller.closeTab(nil)
            #expect(sidebarShows(controller).contains("pin:Left"))
            #expect(Library.shared.pinnedSplit(containing: left.id) != nil)
        }
    }

    /// ⌘W on the space's last tab goes to the page you were on before it in the space; with none, the space is empty.
    @Test func closingTheLastTabGoesToTheSpacesRecentPageElseEmpty() throws {
        try inWindow(["Last"]) { controller, tabs in
            let manager = controller.tabManager
            let pinned = try #require(Library.shared.addBookmark(url: URL(string: "http://127.0.0.1:9/close/recent")!, title: "Recent", to: space))
            manager.openBookmark(pinned)
            let page = try #require(manager.bookmarkTab(for: pinned.id))
            manager.select(tabs[0])
            controller.closeTab(nil)
            #expect(manager.tabs(in: space).isEmpty)
            #expect(manager.selectedTab === page)
        }
        try inWindow(["Only"]) { controller, _ in
            let manager = controller.tabManager
            controller.closeTab(nil)
            #expect(manager.tabs(in: space).isEmpty)
            #expect(manager.selectedTab == nil)
            #expect(manager.currentSpaceID == space)
        }
    }
}

/// ⇧⌘T brings back the latest closed tab or window across the app (#411), never a private tab into an everyday window.
@MainActor @Suite(.serialized) struct ReopenLastClosedTests {
    private var space: UUID { Library.shared.spaces[0].id }

    private func manager(isPrivate: Bool = false) -> (TabManager, [Tab]) {
        let manager = TabManager(spaceID: space, isPrivate: isPrivate)
        let tabs = (0..<3).map { Tab(url: nil, title: "\($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        return (manager, tabs)
    }

    @Test func theLatestClosedComesBackFirst() {
        let early = Date(timeIntervalSince1970: 1), late = Date(timeIntervalSince1970: 2)
        #expect(WindowManager.lastClosed(tab: early, tabOfClosedWindow: nil, window: late) == .window)
        #expect(WindowManager.lastClosed(tab: late, tabOfClosedWindow: nil, window: early) == .tab)
        #expect(WindowManager.lastClosed(tab: early, tabOfClosedWindow: late, window: nil) == .tabOfClosedWindow)
        #expect(WindowManager.lastClosed(tab: late, tabOfClosedWindow: late, window: late) == .tab)
        #expect(WindowManager.lastClosed(tab: nil, tabOfClosedWindow: nil, window: nil) == nil)
    }

    @Test func aClosedTabComesBackIntoItsWindow() {
        let (manager, t) = manager()
        defer { manager.invalidate() }
        manager.close(t[1])
        manager.close(t[2])
        #expect(manager.lastClosedTab?.id == t[2].id)
        #expect(WindowManager.shared.canReopenLastClosed(from: manager))
        WindowManager.shared.reopenLastClosed(from: manager)
        #expect(manager.tabs(in: space).map(\.displayTitle) == ["0", "2"])
    }

    @Test func aPrivateTabNeverComesBackInAnEverydayWindow() {
        let (secret, s) = manager(isPrivate: true)
        defer { secret.invalidate() }
        let (everyday, _) = manager()
        defer { everyday.invalidate() }
        secret.close(s[1])
        #expect(!WindowManager.shared.canReopenLastClosed(from: everyday))
        WindowManager.shared.reopenLastClosed(from: everyday)
        #expect(everyday.tabs(in: space).count == 3)
        // In its own private window it comes back.
        #expect(WindowManager.shared.canReopenLastClosed(from: secret))
        WindowManager.shared.reopenLastClosed(from: secret)
        #expect(secret.tabs(in: space).map(\.displayTitle) == ["0", "1", "2"])
    }

    @Test func aTabOfAClosedWindowComesBackOnItsOwn() throws {
        let (closing, t) = manager()
        let group = try #require(closing.makeGroup(with: [t[1], t[2]], name: "G"))
        closing.close(t[1])
        let record = try #require(closing.closedTabRecords.last)
        #expect(record.groupID == group)
        closing.invalidate()
        let (other, _) = manager()
        defer { other.invalidate() }
        let back = try #require(other.reopenFromClosedWindow(record))
        #expect(back.groupID == nil && back.parentID == nil && back.spaceID == space)
        #expect(other.tabs(in: space).count == 4)
        #expect(other.selectedTab === back)
    }
}

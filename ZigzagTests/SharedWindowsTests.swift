import Foundation
import Testing
@testable import Zigzag

/// Every everyday window shows the same tabs (#162): one list, many views, each with its own space and selection,
/// and a page on screen in one window at a time.
@MainActor struct SharedWindowsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// Two windows' views of one store, closed (both) when the test is done.
    private func windows(_ body: (TabManager, TabManager) throws -> Void) rethrows {
        let store = TabStore()
        let a = TabManager(spaceID: space, store: store)
        let b = TabManager(spaceID: space, store: store)
        defer {
            b.invalidate()
            a.invalidate()
        }
        try body(a, b)
    }

    @Test func aTabOpenedInOneWindowIsInTheOther() {
        windows { a, b in
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            #expect(b.tabs(in: space).contains { $0 === tab })
            #expect(b.tab(with: tab.id) === tab)
            b.close(tab)
            #expect(!a.tabs(in: space).contains { $0 === tab })
            #expect(tab.isClosed)
        }
    }

    @Test func movingAndNestingShowInBoth() {
        windows { a, b in
            let one = a.newTab(url: nil, spaceID: space, select: false)
            let two = a.newTab(url: nil, spaceID: space, select: false)
            let before = b.tabs(in: space).map(\.id)
            a.move(two, to: before.count - 1)
            #expect(b.tabs(in: space).map(\.id) == a.tabs(in: space).map(\.id))
            a.move(two, to: (a.tabs(in: space).firstIndex { $0 === one } ?? 0) + 1, nesting: .under(one.id))
            #expect(b.nestedTabs(under: one).contains { $0 === two })
        }
    }

    @Test func eachWindowChoosesItsOwnTab() {
        windows { a, b in
            let one = a.newTab(url: nil, spaceID: space, select: false)
            let two = a.newTab(url: nil, spaceID: space, select: false)
            a.select(one)
            b.select(two)
            #expect(a.selectedTab === one)
            #expect(b.selectedTab === two)
            #expect(!a.isShownElsewhere(one) && !b.isShownElsewhere(two))
        }
    }

    @Test func choosingATabAnotherWindowShowsTakesItsPage() {
        windows { a, b in
            let tab = a.newTab(url: nil, spaceID: space)
            #expect(a.isShowing(tab) && tab.shownBy === a)
            b.select(tab)
            // B has the page now; A still has the tab chosen, and says it's in another window.
            #expect(tab.shownBy === b)
            #expect(a.selectedTab === tab)
            #expect(a.isShownElsewhere(tab))
            #expect(!b.isShownElsewhere(tab))
            #expect(!a.mayShow(tab))
            // Show Here: back to A.
            a.select(tab)
            #expect(tab.shownBy === a)
            #expect(b.isShownElsewhere(tab))
        }
    }

    @Test func aPageLeftInOneWindowIsFreeForTheOther() {
        windows { a, b in
            let one = a.newTab(url: nil, spaceID: space)
            b.select(one)
            let two = a.newTab(url: nil, spaceID: space, select: false)
            b.select(two)
            // B moved on: nothing has `one` on screen but A, which may show it again.
            #expect(!a.isShownElsewhere(one))
            #expect(a.mayShow(one))
            #expect(one.shownBy === a)
        }
    }

    @Test func aTabClosedElsewhereIsReplacedHere() {
        windows { a, b in
            let one = a.newTab(url: nil, spaceID: space, select: false)
            let two = a.newTab(url: nil, spaceID: space, select: false)
            b.select(one)
            b.select(two)
            a.close(two)
            // B was on `two`: it goes to the tab it was on before there.
            #expect(b.selectedTab === one)
        }
    }

    @Test func afterClosingAWindowPrefersATabNoOtherWindowShows() {
        windows { a, b in
            let shown = a.newTab(url: nil, spaceID: space, select: false)
            let free = a.newTab(url: nil, spaceID: space, select: false)
            b.select(free)
            b.select(shown)
            a.select(shown)
            let extra = b.newTab(url: nil, spaceID: space)
            b.close(extra)
            // `shown` was B's most recent, but A has it on screen: B goes to `free`.
            #expect(b.selectedTab === free)
        }
    }

    @Test func closingAWindowClosesNoTabsUnlessItsTheLast() {
        let store = TabStore()
        let a = TabManager(spaceID: space, store: store)
        let b = TabManager(spaceID: space, store: store)
        let tab = b.newTab(url: nil, spaceID: space)
        #expect(!b.isLastView)
        b.invalidate()
        #expect(!tab.isClosed)
        #expect(tab.shownBy == nil)
        #expect(a.tab(with: tab.id) === tab)
        #expect(a.isLastView)
        a.invalidate()
        #expect(tab.isClosed)
    }

    @Test func aPrivateWindowKeepsItsOwnTabs() {
        windows { a, _ in
            let secret = TabManager(spaceID: space, isPrivate: true)
            defer { secret.invalidate() }
            let tab = secret.newTab(url: nil, spaceID: space, select: false)
            #expect(a.tab(with: tab.id) == nil)
            #expect(secret.store !== a.store)
        }
    }

    @Test func aNewWindowStartsWithNoTabChosenInItsSpace() {
        windows { a, b in
            let tab = a.newTab(url: nil, spaceID: space)
            b.startSelection(from: a)
            #expect(a.selectedTab === tab)
            #expect(b.selectedTab == nil)
        }
    }

    // MARK: Sessions

    private func tabState(_ title: String) -> SessionState.TabState {
        SessionState.TabState(id: UUID(), url: URL(string: "https://example.com/\(title)"), title: title, lastActivated: Date(), createdAt: Date())
    }

    private func window(_ tabs: [SessionState.TabState], selected: UUID?) -> SessionState.WindowState {
        SessionState.WindowState(frame: [0, 0, 1200, 800], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
                                 spaces: [SessionState.SpaceTabs(spaceID: space, tabs: tabs, selectedTabID: selected)],
                                 bookmarkTabs: [], isFullScreen: false, splits: nil)
    }

    @Test func anOldSessionsWindowsJoinUpInOrder() {
        // Before #162 each window kept its own tabs: read back, they're one list, the first window's first.
        let first = [tabState("a"), tabState("b")], second = [tabState("c")]
        let store = TabStore()
        let restored = WindowManager.restoreTabs([window(first, selected: first[1].id), window(second, selected: second[0].id)], into: store)
        defer { restored.managers.reversed().forEach { $0.invalidate() } }
        #expect(restored.managers.count == 2)
        #expect(store.tabsBySpace[space]?.map(\.title) == ["a", "b", "c"])
        #expect(restored.selections[0][space] == first[1].id)
        #expect(restored.selections[1][space] == second[0].id)
        #expect(restored.ids == Set((first + second).map(\.id)))
        for (manager, selection) in zip(restored.managers, restored.selections) {
            manager.restoreSelection(selection, currentSpaceID: space)
        }
        // Each window on the tab it had.
        #expect(restored.managers[0].selectedTab?.title == "b")
        #expect(restored.managers[1].selectedTab?.title == "c")
    }

    @Test func aNewSessionKeepsTheListWithTheFirstWindow() throws {
        let tabs = [tabState("a"), tabState("b")]
        let state = SessionState(windows: [window(tabs, selected: tabs[0].id), window([], selected: tabs[1].id)])
        let read = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        #expect(!read.windows[0].isViewOnly)
        #expect(read.windows[1].isViewOnly)
        let store = TabStore()
        let restored = WindowManager.restoreTabs(read.windows, into: store)
        defer { restored.managers.reversed().forEach { $0.invalidate() } }
        #expect(store.tabsBySpace[space]?.map(\.title) == ["a", "b"])
        #expect(restored.selections[1][space] == tabs[1].id)
    }

    @Test func aSessionFromBeforeDecodes() throws {
        // A window as Zigzag wrote it before #162 (and before tile groups): nothing new is needed to read it.
        let id = UUID(), spaceID = UUID()
        let json = """
        {"windows":[{"frame":[0,0,800,600],"sidebarVisible":true,"sidebarWidth":240,"currentSpaceID":"\(spaceID)",
        "spaces":[{"spaceID":"\(spaceID)","tabs":[{"id":"\(id)","url":"https://example.com","title":"Example",
        "lastActivated":0,"createdAt":0}],"selectedTabID":"\(id)"}],"bookmarkTabs":[]}]}
        """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(state.windows.count == 1)
        #expect(state.windows[0].spaces[0].tabs[0].id == id)
        #expect(!state.windows[0].isViewOnly)
    }
}

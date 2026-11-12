import Foundation
import Testing
@testable import Zigzag

/// Each window has its own tabs, as in Chrome and Safari (#167): tabs move between windows with their pages as they
/// are, a split or tile group goes along whole, and a window left with no tabs is one that closes. Sessions saved
/// by 0.8.7 beta 1, when every window showed the same tabs (#162), come back with every tab.
@MainActor struct OwnWindowTabsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// Two windows' tabs, closed when the test is done.
    private func windows(_ body: (TabManager, TabManager) throws -> Void) rethrows {
        let a = TabManager(spaceID: space)
        let b = TabManager(spaceID: space)
        defer {
            b.invalidate()
            a.invalidate()
        }
        try body(a, b)
    }

    private func ids(_ manager: TabManager) -> [UUID] { manager.tabs(in: space).map(\.id) }

    // MARK: Windows' own tabs

    @Test func aTabOpenedInOneWindowIsOnlyThere() {
        windows { a, b in
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            #expect(a.tab(with: tab.id) === tab)
            #expect(b.tab(with: tab.id) == nil)
            #expect(!b.tabs(in: space).contains { $0 === tab })
            b.close(tab)
            #expect(!tab.isClosed)
        }
    }

    @Test func aMovedTabLeavesOneWindowForTheOtherAsItIs() {
        windows { a, b in
            let stays = a.newTab(url: nil, spaceID: space, select: false)
            let tab = a.newTab(url: nil, spaceID: space)
            let there = b.newTab(url: nil, spaceID: space)
            let moved = b.take(tab, from: a, at: 1)
            #expect(moved.map(\.tab) == [tab])
            #expect(!tab.isClosed)
            #expect(a.tab(with: tab.id) == nil)
            #expect(ids(a) == [stays.id])
            // Where it was dropped, and the tab on screen there.
            #expect(ids(b) == [there.id, tab.id])
            #expect(b.selectedTab === tab)
            // The window it left goes on to another of its tabs.
            #expect(a.selectedTab === stays)
            // Not closed: ⇧⌘T in either window doesn't bring a copy back.
            #expect(!a.canReopenClosedTab && !b.canReopenClosedTab)
        }
    }

    @Test func movingBackPutsItWhereItWas() {
        windows { a, b in
            let tabs = (0..<3).map { _ in a.newTab(url: nil, spaceID: space, select: false) }
            let before = ids(a)
            let place = before.firstIndex(of: tabs[1].id) ?? 0
            b.take(tabs[1], from: a, at: 0)
            #expect(ids(a) == before.filter { $0 != tabs[1].id })
            a.take(tabs[1], from: b, at: place)
            #expect(ids(a) == before)
            #expect(ids(b).isEmpty)
        }
    }

    @Test func aSplitMovesWholeAndStaysASplit() {
        windows { a, b in
            let left = a.newTab(url: nil, spaceID: space, select: false)
            let right = a.newTab(url: nil, spaceID: space, select: false)
            a.makeSplit(left, with: right)
            let moved = b.take(right, from: a, at: 0)
            #expect(Set(moved.map(\.tab.id)) == [left.id, right.id])
            #expect(a.split(for: left) == nil && a.tab(with: left.id) == nil)
            let pair = b.split(for: left)
            #expect(pair?.left == left.id && pair?.right == right.id)
            #expect(ids(b) == [left.id, right.id])
        }
    }

    @Test func aTileGroupIsNeverInTwoWindows() {
        windows { a, b in
            let pages = (0..<3).map { _ in a.newTab(url: nil, spaceID: space, select: false) }
            a.makeGroup(pages, shape: TileShape(regions: [.left, .topRight, .bottomRight]))
            let shape = a.split(for: pages[0])
            b.take(pages[1], from: a, at: 0)
            #expect(a.splits.isEmpty)
            #expect(a.tabs(in: space).isEmpty)
            #expect(b.split(for: pages[2]) == shape)
        }
    }

    @Test func theTabsUnderAMovedTabStayAndMoveUp() {
        windows { a, b in
            let parent = a.newTab(url: nil, spaceID: space, select: false)
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            let child = a.newTab(url: nil, spaceID: space, select: false)
            let at = { (t: Tab) in a.tabs(in: space).firstIndex { $0 === t } ?? 0 }
            a.move(tab, to: at(parent) + 1, nesting: .under(parent.id))
            a.move(child, to: at(tab) + 1, nesting: .under(tab.id))
            b.take(tab, from: a, at: 0)
            #expect(child.parentID == parent.id)
            #expect(tab.parentID == nil)
        }
    }

    @Test func aPinnedPagesTabDoesNotMove() {
        windows { a, b in
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            tab.bookmarkID = UUID()
            #expect(b.take(tab, from: a, at: 0).isEmpty)
            tab.bookmarkID = nil
            #expect(a.tab(with: tab.id) === tab)
        }
    }

    @Test func aWindowWithNoTabsLeftIsEmptyThoughPinnedPagesAreOpen() {
        windows { a, b in
            let tab = a.newTab(url: nil, spaceID: space)
            let pinned = Tab(url: URL(string: "https://example.com/pinned"), spaceID: space)
            a.adoptBookmarkTab(pinned, bookmarkID: UUID())
            #expect(a.hasTabs)
            b.take(tab, from: a, at: 0)
            // Pinned tabs and favorites are every window's: an open one doesn't keep the window.
            #expect(!a.hasTabs)
            #expect(b.hasTabs)
        }
    }

    @Test func aTabInAnotherSpaceCountsToo() {
        windows { a, _ in
            guard let other = Library.shared.spaces.dropFirst().first?.id else { return }
            #expect(!a.hasTabs)
            a.newTab(url: nil, spaceID: other, select: false)
            #expect(a.hasTabs)
        }
    }

    // MARK: Sessions

    private func tabState(_ title: String, parent: UUID? = nil) -> SessionState.TabState {
        SessionState.TabState(id: UUID(), url: URL(string: "https://example.com/\(title)"), title: title,
                              lastActivated: Date(timeIntervalSince1970: 1_800_000_000), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                              parentID: parent)
    }

    private func window(_ spaces: [SessionState.SpaceTabs], current: UUID, splits: [TabManager.SplitPair]? = nil,
                        pinned: [SessionState.BookmarkTabState] = [], x: Double = 0) -> SessionState.WindowState {
        SessionState.WindowState(frame: [x, 100, 1200, 800], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: current,
                                 spaces: spaces, bookmarkTabs: pinned, isFullScreen: false, splits: splits)
    }

    private func decode(_ json: String) throws -> SessionState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SessionState.self, from: Data(json.utf8))
    }

    private func count(_ state: SessionState) -> Int {
        state.windows.reduce(0) { $0 + $1.spaces.reduce(0) { $0 + $1.tabs.count } + $1.bookmarkTabs.count }
    }

    private func allIDs(_ state: SessionState) -> [UUID] {
        state.windows.flatMap { $0.spaces.flatMap { $0.tabs.map(\.id) } + $0.bookmarkTabs.map(\.tab.id) }
    }

    /// A session as 0.8.7 beta 1 wrote it: three windows; the first has every tab (two spaces, a split, a nested tab,
    /// an open pinned page), the others only their place and the tab each had chosen in each space.
    private func betaSession() -> (json: String, work: UUID, home: UUID, ids: [String: UUID], pin: UUID) {
        let work = UUID(), home = UUID(), pin = UUID()
        let names = ["mail", "docs", "docsChild", "left", "right", "news", "recipes", "pinned"]
        let ids = Dictionary(uniqueKeysWithValues: names.map { ($0, UUID()) })
        func tab(_ name: String, parent: String? = nil) -> String {
            let parentKey = parent.map { #","parentID":"\#(ids[$0]!)""# } ?? ""
            return #"{"createdAt":1800000000,"id":"\#(ids[name]!)","lastActivated":1800000000\#(parentKey),"title":"\#(name)","url":"https://example.com/\#(name)"}"#
        }
        let json = """
        {"windows":[
         {"bookmarkTabs":[{"bookmarkID":"\(pin)","tab":\(tab("pinned"))}],"currentSpaceID":"\(work)","frame":[0,100,1200,800],
          "isFullScreen":false,"sidebarVisible":true,"sidebarWidth":240,
          "spaces":[{"selectedTabID":"\(ids["mail"]!)","spaceID":"\(work)","tabs":[\(tab("mail")),\(tab("docs")),\(tab("docsChild", parent: "docs")),\(tab("left")),\(tab("right"))]},
                    {"selectedTabID":"\(ids["news"]!)","spaceID":"\(home)","tabs":[\(tab("news")),\(tab("recipes"))]}],
          "splits":[{"left":"\(ids["left"]!)","otherRatio":0.5,"ratio":0.5,"right":"\(ids["right"]!)","vertical":false}]},
         {"bookmarkTabs":[],"currentSpaceID":"\(work)","frame":[1240,100,1000,700],"isFullScreen":false,"sidebarVisible":true,"sidebarWidth":240,
          "spaces":[{"selectedTabID":"\(ids["right"]!)","spaceID":"\(work)","tabs":[]},{"selectedTabID":"\(ids["recipes"]!)","spaceID":"\(home)","tabs":[]}]},
         {"bookmarkTabs":[],"currentSpaceID":"\(home)","frame":[200,300,900,600],"isFullScreen":false,"sidebarVisible":false,"sidebarWidth":240,
          "spaces":[{"selectedTabID":"\(ids["docs"]!)","spaceID":"\(work)","tabs":[]},{"selectedTabID":"\(ids["recipes"]!)","spaceID":"\(home)","tabs":[]}]}
        ]}
        """
        return (json, work, home, ids, pin)
    }

    @Test func aBetaOneSessionKeepsEveryTabAndEveryWindow() throws {
        let beta = betaSession()
        let read = try decode(beta.json)
        #expect(read.windows.count == 3)
        #expect(count(read) == 8)
        let state = read.givingWindowsTheirOwnTabs()
        // Every tab once, every window back.
        #expect(state.windows.count == 3)
        #expect(count(state) == 8)
        #expect(Set(allIDs(state)) == Set(allIDs(read)))
        #expect(allIDs(state).count == Set(allIDs(state)).count)
        let id = beta.ids
        let first = state.windows[0], second = state.windows[1], third = state.windows[2]
        // The second window was on the split's right half in Work: the split comes along whole, still a split.
        #expect(second.spaces.first { $0.spaceID == beta.work }?.tabs.map(\.id) == [id["left"]!, id["right"]!])
        #expect(second.spaces.first { $0.spaceID == beta.work }?.selectedTabID == id["right"]!)
        #expect(second.splits?.first?.ids == [id["left"]!, id["right"]!])
        #expect(first.splits?.isEmpty ?? true)
        // The third was on Recipes in Home; the first window's choice there was News, which stays.
        #expect(third.spaces.first { $0.spaceID == beta.home }?.tabs.map(\.id) == [id["recipes"]!])
        #expect(third.spaces.first { $0.spaceID == beta.home }?.selectedTabID == id["recipes"]!)
        #expect(third.spaces.first { $0.spaceID == beta.work }?.selectedTabID == nil)
        #expect(third.frame == [200, 300, 900, 600])
        // The first keeps the rest, in order, with its choices and the pinned page's open page.
        #expect(first.spaces.first { $0.spaceID == beta.work }?.tabs.map(\.id) == [id["mail"]!, id["docs"]!, id["docsChild"]!])
        #expect(first.spaces.first { $0.spaceID == beta.work }?.selectedTabID == id["mail"]!)
        #expect(first.spaces.first { $0.spaceID == beta.home }?.tabs.map(\.id) == [id["news"]!])
        #expect(first.bookmarkTabs.map(\.bookmarkID) == [beta.pin])
        #expect(first.spaces.first { $0.spaceID == beta.work }?.tabs.last?.parentID == id["docs"]!)
        // Read again, nothing moves twice.
        let again = state.givingWindowsTheirOwnTabs()
        #expect(allIDs(again) == allIDs(state))
    }

    @Test func aTabTheFirstWindowWasOnStaysThere() {
        let a = tabState("a"), b = tabState("b")
        let shared = window([SessionState.SpaceTabs(spaceID: space, tabs: [a, b], selectedTabID: a.id)], current: space)
        let viewer = window([SessionState.SpaceTabs(spaceID: space, tabs: [], selectedTabID: a.id)], current: space, x: 1300)
        let state = SessionState(windows: [shared, viewer]).givingWindowsTheirOwnTabs()
        #expect(state.windows[0].spaces[0].tabs.map(\.id) == [a.id, b.id])
        #expect(state.windows[1].spaces[0].tabs.isEmpty)
        #expect(state.windows[1].spaces[0].selectedTabID == nil)
        #expect(count(state) == 2)
    }

    @Test func aNestedTabTakenOutLiftsTheTabsUnderIt() {
        let parent = tabState("parent")
        let middle = tabState("middle", parent: parent.id)
        let child = tabState("child", parent: middle.id)
        let shared = window([SessionState.SpaceTabs(spaceID: space, tabs: [parent, middle, child], selectedTabID: parent.id)], current: space)
        let viewer = window([SessionState.SpaceTabs(spaceID: space, tabs: [], selectedTabID: middle.id)], current: space)
        let state = SessionState(windows: [shared, viewer]).givingWindowsTheirOwnTabs()
        #expect(state.windows[1].spaces[0].tabs.map(\.id) == [middle.id])
        #expect(state.windows[1].spaces[0].tabs[0].parentID == nil)
        #expect(state.windows[0].spaces[0].tabs.map(\.id) == [parent.id, child.id])
        #expect(state.windows[0].spaces[0].tabs[1].parentID == parent.id)
    }

    @Test func aPinnedPageAnotherWindowWasOnComesWithIt() {
        let a = tabState("a"), page = tabState("pinned"), pin = UUID()
        let shared = window([SessionState.SpaceTabs(spaceID: space, tabs: [a], selectedTabID: a.id)], current: space,
                            pinned: [SessionState.BookmarkTabState(bookmarkID: pin, tab: page)])
        let viewer = window([SessionState.SpaceTabs(spaceID: space, tabs: [], selectedTabID: page.id)], current: space)
        let state = SessionState(windows: [shared, viewer]).givingWindowsTheirOwnTabs()
        #expect(state.windows[0].bookmarkTabs.isEmpty)
        #expect(state.windows[1].bookmarkTabs.map(\.bookmarkID) == [pin])
        #expect(state.windows[1].spaces[0].selectedTabID == page.id)
        #expect(count(state) == 2)
    }

    @Test func aSessionFromBeforeSharedWindowsIsLeftAsItWas() throws {
        // Two windows with tabs of their own, and an empty one, as Zigzag wrote them before 0.8.7 (and before tile
        // groups and nested tabs).
        let spaceID = UUID(), one = UUID(), two = UUID(), three = UUID()
        let json = """
        {"windows":[{"frame":[0,0,800,600],"sidebarVisible":true,"sidebarWidth":240,"currentSpaceID":"\(spaceID)",
        "spaces":[{"spaceID":"\(spaceID)","tabs":[{"id":"\(one)","url":"https://example.com/1","title":"One","lastActivated":0,"createdAt":0},
        {"id":"\(two)","url":"https://example.com/2","title":"Two","lastActivated":0,"createdAt":0}],"selectedTabID":"\(two)"}],"bookmarkTabs":[]},
        {"frame":[900,0,800,600],"sidebarVisible":true,"sidebarWidth":240,"currentSpaceID":"\(spaceID)",
        "spaces":[{"spaceID":"\(spaceID)","tabs":[{"id":"\(three)","url":"https://example.com/3","title":"Three","lastActivated":0,"createdAt":0}],"selectedTabID":"\(three)"}],"bookmarkTabs":[]},
        {"frame":[300,300,800,600],"sidebarVisible":true,"sidebarWidth":240,"currentSpaceID":"\(spaceID)",
        "spaces":[{"spaceID":"\(spaceID)","tabs":[]}],"bookmarkTabs":[]}]}
        """
        let read = try decode(json)
        let state = read.givingWindowsTheirOwnTabs()
        #expect(state.windows.count == 3)
        #expect(count(state) == 3)
        #expect(state.windows[0].spaces[0].tabs.map(\.id) == [one, two])
        #expect(state.windows[0].spaces[0].selectedTabID == two)
        #expect(state.windows[1].spaces[0].tabs.map(\.id) == [three])
        #expect(state.windows[1].spaces[0].selectedTabID == three)
        #expect(state.windows[2].spaces[0].tabs.isEmpty)
    }

    @Test func aSessionRoundTripsWithEveryTab() throws {
        let tabs = [tabState("a"), tabState("b"), tabState("c")]
        let own = [tabState("d")]
        let pair = TabManager.SplitPair(left: tabs[1].id, right: tabs[2].id)
        let state = SessionState(windows: [
            window([SessionState.SpaceTabs(spaceID: space, tabs: tabs, selectedTabID: tabs[1].id)], current: space, splits: [pair]),
            window([SessionState.SpaceTabs(spaceID: space, tabs: own, selectedTabID: own[0].id)], current: space, x: 1300)
        ])
        let data = try #require(JSONStore.encode(state))
        let read = try JSONDecoder.session.decode(SessionState.self, from: data).givingWindowsTheirOwnTabs()
        #expect(read.windows.count == 2)
        #expect(count(read) == 4)
        #expect(read.windows[0].spaces[0].tabs.map(\.id) == tabs.map(\.id))
        #expect(read.windows[0].spaces[0].selectedTabID == tabs[1].id)
        #expect(read.windows[0].splits == [pair])
        #expect(read.windows[1].spaces[0].tabs.map(\.id) == own.map(\.id))
        #expect(JSONStore.encode(read) == data)
    }
}

private extension JSONDecoder {
    static var session: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

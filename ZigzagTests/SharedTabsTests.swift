import Foundation
import Testing
@testable import Zigzag

/// Arc-style shared tabs across windows (#162): one list, each window with its own space and tab, a page on screen in one window at a time. Toggling never loses tabs; sessions restore each tab once.
@MainActor struct SharedTabsTests {
    private var space: UUID { Library.shared.spaces[0].id }

    /// Two windows sharing one list, closed after the test.
    private func shared(_ body: (TabManager, TabManager) throws -> Void) rethrows {
        let store = TabStore()
        let a = TabManager(spaceID: space, store: store)
        let b = TabManager(spaceID: space, store: store)
        defer {
            b.invalidate()
            a.invalidate()
        }
        try body(a, b)
    }

    /// Two windows with separate tabs, closed after the test.
    private func own(_ body: (TabManager, TabManager) throws -> Void) rethrows {
        let a = TabManager(spaceID: space)
        let b = TabManager(spaceID: space)
        defer {
            b.invalidate()
            a.invalidate()
        }
        try body(a, b)
    }

    private func ids(_ manager: TabManager) -> [UUID] { manager.tabs(in: space).map(\.id) }

    // MARK: One list

    @Test func bothWindowsListTheSameTabs() {
        shared { a, b in
            let one = a.newTab(url: nil, spaceID: space, select: false)
            let two = b.newTab(url: nil, spaceID: space, select: false)
            #expect(a.store === b.store)
            #expect(b.tab(with: one.id) === one)
            #expect(a.tab(with: two.id) === two)
            #expect(ids(a) == ids(b))
            #expect(Set(ids(a)) == [one.id, two.id])
        }
    }

    @Test func eachWindowHasItsOwnTabOnScreen() {
        shared { a, b in
            let one = a.newTab(url: nil, spaceID: space)
            let two = b.newTab(url: nil, spaceID: space)
            #expect(a.selectedTab === one)
            #expect(b.selectedTab === two)
            a.select(one)
            #expect(b.selectedTab === two)
            #expect(!a.isShownElsewhere(one) && !b.isShownElsewhere(two))
        }
    }

    @Test func choosingAPageShownInTheOtherWindowBringsItHere() {
        shared { a, b in
            let one = a.newTab(url: nil, spaceID: space)
            let two = b.newTab(url: nil, spaceID: space)
            b.select(one)
            // B shows it now; A says it's in another window.
            #expect(b.selectedTab === one)
            #expect(!b.isShownElsewhere(one))
            #expect(a.selectedTab === one)
            #expect(a.isShownElsewhere(one))
            #expect(!a.mayShow(one))
            // B moves on: A shows it again.
            b.select(two)
            #expect(!a.isShownElsewhere(one))
            #expect(a.mayShow(one))
        }
    }

    @Test func closingATabClosesItInBoth() {
        shared { a, b in
            let one = a.newTab(url: nil, spaceID: space, select: false)
            let two = a.newTab(url: nil, spaceID: space)
            b.select(two)
            a.select(one)
            b.close(two)
            #expect(two.isClosed)
            #expect(a.tab(with: two.id) == nil && b.tab(with: two.id) == nil)
            #expect(ids(a) == [one.id])
            // B moves to another tab, preferring one A isn't showing.
            #expect(b.selectedTab?.isClosed != true)
            // ⇧⌘T in the other window reopens it once.
            #expect(a.canReopenClosedTab)
            let back = a.reopenClosedTab(select: false)
            #expect(back != nil)
            #expect(Set(ids(b)) == Set([one.id, back?.id].compactMap { $0 }))
            #expect(!b.canReopenClosedTab)
        }
    }

    @Test func movesSplitsAndNestingShowInBoth() {
        shared { a, b in
            let tabs = (0..<4).map { _ in a.newTab(url: nil, spaceID: space, select: false) }
            a.move(tabs[0], to: 3)
            #expect(ids(b) == ids(a))
            a.makeSplit(tabs[1], with: tabs[2])
            #expect(b.split(for: tabs[1]) == a.split(for: tabs[1]))
            #expect(b.split(for: tabs[1]) != nil)
            let at = a.tabs(in: space).firstIndex { $0 === tabs[3] } ?? 0
            a.move(tabs[0], to: at + 1, nesting: .under(tabs[3].id))
            #expect(b.nestedTabs(under: tabs[3]).map(\.id) == [tabs[0].id])
            let group = b.makeGroup(with: [tabs[3]], name: "Reading")
            #expect(group != nil && a.group(group!) != nil)
            #expect(a.tabs(inGroup: group!).map(\.id) == b.tabs(inGroup: group!).map(\.id))
        }
    }

    @Test func historysRecentlyClosedListsEachClosedTabOnceInEveryWindow() {
        let store = TabStore()
        let a = TabManager(spaceID: space, store: store)
        let b = TabManager(spaceID: space, store: store)
        let hidden = TabManager(spaceID: space, isPrivate: true, store: store)
        defer {
            hidden.invalidate()
            b.invalidate()
            a.invalidate()
        }
        let one = a.newTab(url: URL(string: "about:blank#one"), spaceID: space, select: false)
        let two = b.newTab(url: URL(string: "about:blank#two"), spaceID: space, select: false)
        let secret = hidden.newTab(url: URL(string: "about:blank#secret"), spaceID: space, select: false)
        a.close(one)
        b.close(two)
        hidden.close(secret)
        // Recently Closed from either window: both tabs, newest first, once each; never private ones.
        #expect(a.recentlyClosedTabs.map(\.id) == [two.id, one.id])
        #expect(b.recentlyClosedTabs.map(\.id) == a.recentlyClosedTabs.map(\.id))
        #expect(!a.recentlyClosedTabs.contains { $0.id == secret.id })
        // Reopened from one window: removed from the list in both, open once.
        let back = b.reopenClosedTab(one.id, select: false)
        #expect(back != nil)
        #expect(a.recentlyClosedTabs.map(\.id) == [two.id])
        #expect(a.tabs(in: space).filter { $0.url == one.url }.count == 1)
        #expect(a.tab(with: back!.id) === back)
        // Closing one sharing window isn't a closed window to reopen.
        #expect(!b.isLastView)
    }

    @Test func closingOneWindowKeepsTheTabsInTheOther() {
        let store = TabStore()
        let a = TabManager(spaceID: space, store: store)
        let b = TabManager(spaceID: space, store: store)
        defer { a.invalidate() }
        let one = b.newTab(url: nil, spaceID: space)
        b.invalidate()
        #expect(!one.isClosed)
        #expect(a.tab(with: one.id) === one)
        #expect(a.isLastView)
        a.select(one)
        #expect(!a.isShownElsewhere(one))
    }

    @Test func privateWindowsNeverShare() {
        let store = TabStore()
        let a = TabManager(spaceID: space, store: store)
        let hidden = TabManager(spaceID: space, isPrivate: true, store: store)
        defer {
            hidden.invalidate()
            a.invalidate()
        }
        #expect(hidden.store !== store)
        #expect(hidden.isPrivate && !a.isPrivate)
        let secret = hidden.newTab(url: nil, spaceID: space, select: false)
        #expect(a.tab(with: secret.id) == nil)
        // Turning sharing on leaves it out too.
        let other = TabManager(spaceID: space)
        defer { other.invalidate() }
        TabStore.share([a, hidden, other])
        #expect(other.store === a.store)
        #expect(hidden.store !== a.store)
        #expect(a.tab(with: secret.id) == nil)
    }

    @Test func spacesKeepTheirOwnLists() {
        shared { a, b in
            guard let other = Library.shared.spaces.dropFirst().first?.id else { return }
            let here = a.newTab(url: nil, spaceID: space, select: false)
            let there = b.newTab(url: nil, spaceID: other, select: false)
            // Spaces belong to a profile; other profiles' windows never list these tabs.
            #expect(!a.tabs(in: other).contains { $0 === here })
            #expect(!b.tabs(in: space).contains { $0 === there })
            #expect(a.tabs(in: other).map(\.id) == [there.id])
        }
    }

    // MARK: Turning it on and off

    @Test func turningSharingOnJoinsTheListsAndLosesNoTab() {
        own { a, b in
            let mine = (0..<2).map { _ in a.newTab(url: nil, spaceID: space, select: false) }
            let theirs = (0..<2).map { _ in b.newTab(url: nil, spaceID: space, select: false) }
            a.select(mine[1])
            b.makeSplit(theirs[0], with: theirs[1])
            b.select(theirs[0])
            let before = ids(a) + ids(b)
            TabStore.share([a, b])
            #expect(a.store === b.store)
            // Each space's tabs, window by window.
            #expect(ids(a) == before)
            #expect(ids(b) == ids(a))
            #expect(a.selectedTab === mine[1])
            #expect(b.selectedTab === theirs[0])
            #expect(a.split(for: theirs[0]) != nil)
            #expect((mine + theirs).allSatisfy { !$0.isClosed })
            #expect(!a.isShownElsewhere(mine[1]) && !b.isShownElsewhere(theirs[0]))
        }
    }

    @Test func turningSharingOffGivesEachWindowItsTabsAndLosesNone() {
        shared { a, b in
            let tabs = (0..<5).map { _ in a.newTab(url: nil, spaceID: space, select: false) }
            a.select(tabs[0])
            b.select(tabs[2])
            b.makeSplit(tabs[3], with: tabs[4])
            b.select(tabs[2])
            let at = a.tabs(in: space).firstIndex { $0 === tabs[2] } ?? 0
            a.move(tabs[1], to: at + 1, nesting: .under(tabs[2].id))
            TabStore.unshare([a, b])
            #expect(a.store !== b.store)
            // Every tab once, in one window, none closed.
            let all = ids(a) + ids(b)
            #expect(all.count == tabs.count)
            #expect(Set(all) == Set(tabs.map(\.id)))
            #expect(tabs.allSatisfy { !$0.isClosed })
            // Each window keeps its selected tab.
            #expect(a.selectedTab === tabs[0] && a.tab(with: tabs[0].id) === tabs[0])
            #expect(b.selectedTab === tabs[2] && b.tab(with: tabs[2].id) === tabs[2])
            // A split stays in one window.
            let pairIn = [a, b].filter { $0.split(for: tabs[3]) != nil }
            #expect(pairIn.count == 1)
            #expect(pairIn.first?.tab(with: tabs[4].id) === tabs[4])
            // A child whose parent moved elsewhere goes to the top level.
            for manager in [a, b] {
                for tab in manager.tabs(in: space) { if let parent = tab.parentID { #expect(manager.tab(with: parent) != nil) } }
            }
        }
    }

    @Test func onAndOffAndOnAgainKeepsEveryTab() {
        own { a, b in
            let tabs = (0..<3).map { _ in a.newTab(url: nil, spaceID: space, select: false) } + (0..<2).map { _ in b.newTab(url: nil, spaceID: space, select: false) }
            TabStore.share([a, b])
            TabStore.unshare([a, b])
            TabStore.share([a, b])
            #expect(Set(ids(a)) == Set(tabs.map(\.id)))
            #expect(ids(a).count == tabs.count)
            #expect(tabs.allSatisfy { !$0.isClosed })
        }
    }

    // MARK: Sessions

    private func tabState(_ title: String) -> SessionState.TabState {
        SessionState.TabState(id: UUID(), url: URL(string: "https://example.com/\(title)"), title: title,
                              lastActivated: Date(timeIntervalSince1970: 1_800_000_000), createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func window(_ tabs: [SessionState.TabState], selected: UUID?, splits: [TabManager.SplitPair]? = nil) -> SessionState.WindowState {
        SessionState.WindowState(frame: [0, 100, 1200, 800], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
                                 spaces: [SessionState.SpaceTabs(spaceID: space, tabs: tabs, selectedTabID: selected)],
                                 bookmarkTabs: [], isFullScreen: false, splits: splits)
    }

    @Test func aSharedSessionComesBackWithEachTabOnce() {
        let tabs = ["mail", "docs", "left", "right"].map(tabState)
        var pair = TabManager.SplitPair(left: tabs[2].id, right: tabs[3].id)
        pair.ratio = 0.4
        // Saved while sharing: the first window has the list, the second only its selection.
        let first = window(tabs, selected: tabs[0].id, splits: [pair])
        let second = window([], selected: tabs[2].id)
        let store = TabStore()
        let (a, _) = WindowManager.shared.restoredTabs(first, store: store)
        let (b, _) = WindowManager.shared.restoredTabs(second, store: store)
        defer {
            b.invalidate()
            a.invalidate()
        }
        #expect(ids(a) == tabs.map(\.id))
        #expect(ids(b) == ids(a))
        #expect(a.selectedTab?.id == tabs[0].id)
        #expect(b.selectedTab?.id == tabs[2].id)
        #expect(store.splits.count == 1)
    }

    @Test func windowsSavedWithTabsOfTheirOwnComeBackSharingWithoutDuplicates() {
        let mine = ["mail", "docs"].map(tabState)
        let theirs = ["news", "recipes"].map(tabState)
        // A tab saved in both windows restores once.
        let first = window(mine + [theirs[0]], selected: mine[1].id)
        let second = window(theirs, selected: theirs[1].id, splits: [TabManager.SplitPair(left: theirs[0].id, right: theirs[1].id)])
        let store = TabStore()
        let (a, _) = WindowManager.shared.restoredTabs(first, store: store)
        let (b, _) = WindowManager.shared.restoredTabs(second, store: store)
        defer {
            b.invalidate()
            a.invalidate()
        }
        let listed = ids(a)
        #expect(listed.count == Set(listed).count)
        #expect(Set(listed) == Set((mine + theirs).map(\.id)))
        #expect(ids(b) == listed)
        #expect(a.selectedTab?.id == mine[1].id)
        #expect(b.selectedTab?.id == theirs[1].id)
        #expect(store.splits.count == 1)
    }

    @Test func withSharingOffASharedSessionStillGivesEveryWindowItsTab() {
        let tabs = ["mail", "docs", "news"].map(tabState)
        let state = SessionState(windows: [window(tabs, selected: tabs[0].id), window([], selected: tabs[2].id)])
        let own = state.givingWindowsTheirOwnTabs()
        let all = own.windows.flatMap { $0.spaces.flatMap(\.tabs) }.map(\.id)
        #expect(all.count == tabs.count && Set(all) == Set(tabs.map(\.id)))
        #expect(own.windows[1].spaces[0].tabs.map(\.id) == [tabs[2].id])
    }
}

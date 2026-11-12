import Foundation
import Testing
@testable import Zigzag

/// Open in Zigzag Mini (#164): which tabs can go, the tab leaving the list with its page still open, and ⌘Z putting
/// it back where it was.
@MainActor struct TabToMiniTests {
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

    private func ids(_ manager: TabManager) -> [UUID] { manager.tabs(in: space).map(\.id) }

    // MARK: Which tabs

    @Test func onlyAnOrdinaryTabsWebPageOrFile() {
        let web = URL(string: "https://example.com/a")!
        #expect(MiniWindowController.canTake(web, isPinned: false, isPrivate: false))
        #expect(MiniWindowController.canTake(URL(string: "http://example.com")!, isPinned: false, isPrivate: false))
        #expect(MiniWindowController.canTake(URL(fileURLWithPath: "/tmp/a.pdf"), isPinned: false, isPrivate: false))
        // Pinned pages and favorites belong to the sidebar.
        #expect(!MiniWindowController.canTake(web, isPinned: true, isPrivate: false))
        // Zigzag Mini isn't private: a private window's page stays there.
        #expect(!MiniWindowController.canTake(web, isPinned: false, isPrivate: true))
        // A tab with no page yet, and Zigzag's own pages, stay tabs.
        #expect(!MiniWindowController.canTake(nil, isPinned: false, isPrivate: false))
        #expect(!MiniWindowController.canTake(URL(string: "zigzag://settings")!, isPinned: false, isPrivate: false))
        #expect(!MiniWindowController.canTake(URL(string: "about:blank")!, isPinned: false, isPrivate: false))
    }

    // MARK: Leaving the list

    @Test func theTabLeavesEveryWindowWithoutClosing() {
        windows { a, b in
            let one = a.newTab(url: nil, spaceID: space, select: false)
            let two = a.newTab(url: nil, spaceID: space)
            b.select(one)
            let place = a.release(two)
            #expect(place != nil)
            #expect(!two.isClosed)
            #expect(a.tab(with: two.id) == nil && b.tab(with: two.id) == nil)
            // Not a closed tab: ⇧⌘T doesn't bring it back as a second copy.
            #expect(!a.canReopenClosedTab)
            // The window that was on it goes on to another tab.
            #expect(a.selectedTab !== two)
            #expect(b.selectedTab === one)
            two.close()
        }
    }

    @Test func aPinnedPagesTabIsNotReleased() {
        windows { a, _ in
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            tab.bookmarkID = UUID()
            #expect(a.release(tab) == nil)
            tab.bookmarkID = nil
        }
    }

    @Test func undoPutsItBackInItsPlace() {
        windows { a, b in
            let first = a.newTab(url: nil, spaceID: space, select: false)
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            a.move(tab, to: (a.tabs(in: space).firstIndex { $0 === first } ?? 0) + 1)
            let before = ids(a)
            a.select(tab)
            guard let place = a.release(tab) else { Issue.record("not released"); return }
            #expect(!ids(a).contains(tab.id))
            a.putBack(tab, at: place)
            #expect(ids(a) == before)
            #expect(ids(b) == before)
            #expect(a.selectedTab === tab)
            // Only once: putting back a tab that's in the list already does nothing.
            a.putBack(tab, at: place)
            #expect(ids(a) == before)
        }
    }

    @Test func theTabsUnderItMoveUpAndComeBackUnderIt() {
        windows { a, _ in
            let parent = a.newTab(url: nil, spaceID: space, select: false)
            let tab = a.newTab(url: nil, spaceID: space, select: false)
            let child = a.newTab(url: nil, spaceID: space, select: false)
            let at = { (t: Tab) in a.tabs(in: space).firstIndex { $0 === t } ?? 0 }
            a.move(tab, to: at(parent) + 1, nesting: .under(parent.id))
            a.move(child, to: at(tab) + 1, nesting: .under(tab.id))
            #expect(tab.parentID == parent.id && child.parentID == tab.id)
            guard let place = a.release(tab) else { Issue.record("not released"); return }
            // Away, the tab under it is a level up, under the tab's own parent.
            #expect(child.parentID == parent.id)
            a.putBack(tab, at: place)
            #expect(tab.parentID == parent.id)
            #expect(child.parentID == tab.id)
        }
    }

    @Test func aSplitClosesUpAndComesBack() {
        windows { a, _ in
            let left = a.newTab(url: nil, spaceID: space, select: false)
            let right = a.newTab(url: nil, spaceID: space, select: false)
            a.makeSplit(left, with: right)
            a.select(right)
            #expect(a.split(for: left) != nil)
            guard let place = a.release(right) else { Issue.record("not released"); return }
            // The other half is on its own, and shown.
            #expect(a.split(for: left) == nil)
            #expect(a.selectedTab === left)
            a.putBack(right, at: place)
            let pair = a.split(for: right)
            #expect(pair?.left == left.id && pair?.right == right.id)
        }
    }

    @Test func aTileGroupPageComesBackToItsPlace() {
        windows { a, _ in
            let pages = (0..<3).map { _ in a.newTab(url: nil, spaceID: space, select: false) }
            a.makeGroup(pages, shape: TileShape(regions: [.left, .topRight, .bottomRight]))
            let shape = a.split(for: pages[0])
            #expect(shape?.count == 3)
            guard let place = a.release(pages[1]) else { Issue.record("not released"); return }
            // The group closes up around it.
            #expect(a.split(for: pages[0])?.count == 2)
            a.putBack(pages[1], at: place)
            #expect(a.split(for: pages[1]) == shape)
        }
    }

    // MARK: Where it opens

    @Test func itOpensOverTheMiddleOfTheBrowserWindow() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let size = NSSize(width: 900, height: 640)
        let browser = NSRect(x: 100, y: 100, width: 1200, height: 780)
        let frame = MiniWindowController.frame(size: size, in: screen, taken: [], around: NSPoint(x: browser.midX, y: browser.midY))
        #expect(frame.midX == browser.midX && frame.midY == browser.midY)
        // A browser window near the screen's edge: as close to its middle as the screen allows.
        let edge = MiniWindowController.frame(size: size, in: screen, taken: [], around: NSPoint(x: 1400, y: 60))
        #expect(screen.contains(edge))
        #expect(edge.maxX == screen.maxX && edge.minY == screen.minY)
        // Another one already there: a step down and right.
        let next = MiniWindowController.frame(size: size, in: screen, taken: [frame], around: NSPoint(x: browser.midX, y: browser.midY))
        #expect(next.minX > frame.minX && next.maxY < frame.maxY)
    }
}

import AppKit
import Testing
@testable import Zigzag

/// Site Controls in a split is about one pane's page: the pane whose strip it opened from, or the pane you're in from
/// the sidebar, never the group's first (#160).
@MainActor struct PaneSiteControlsTests {
    private func group(_ count: Int) -> (TabManager, [Tab])? {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        let tabs = (0..<count).map { _ in manager.newTab(url: nil, spaceID: space, select: false) }
        let shape = count == 2 ? TileShape(regions: [.left, .right]) : TileShape(regions: [.left, .topRight, .bottomRight])
        guard let pair = TabManager.SplitPair(ids: tabs.map(\.id), shape: shape) else { return nil }
        manager.restoreSplit(pair)
        manager.select(tabs[0])
        return (manager, tabs)
    }

    @Test func fromAPaneItIsThatPanesPage() {
        for count in [2, 3] {
            guard let (manager, tabs) = group(count) else { Issue.record("no group"); return }
            defer { tabs.forEach { $0.close() }; manager.invalidate() }
            for (i, tab) in tabs.enumerated().reversed() {
                #expect(manager.siteControlsTab(from: tab) === tab, "pane \(i) of \(count)")
                // That pane is the one you're in now, as a click in it makes it.
                #expect(manager.selectedTab === tab)
                #expect(manager.split(for: tab) != nil)
            }
        }
    }

    @Test func fromTheSidebarItIsThePaneYouAreIn() {
        guard let (manager, tabs) = group(3) else { Issue.record("no group"); return }
        defer { tabs.forEach { $0.close() }; manager.invalidate() }
        manager.select(tabs[2])
        #expect(manager.siteControlsTab() === tabs[2])
        manager.select(tabs[1])
        #expect(manager.siteControlsTab() === tabs[1])
        #expect(manager.siteControlsTab() !== tabs[0])
    }

    @Test func aClosedPaneChangesNothing() {
        guard let (manager, tabs) = group(3) else { Issue.record("no group"); return }
        defer { tabs.forEach { $0.close() }; manager.invalidate() }
        manager.select(tabs[1])
        tabs[2].close()
        #expect(manager.siteControlsTab(from: tabs[2]) === tabs[1])
    }

    // MARK: The strip

    @Test func theButtonSitsInTheAddressWhileThereIsRoom() {
        #expect(PaneAddressView.showsButton(width: 200, fitting: 300, hasText: true))
        // Cut to a few letters: it goes into ⋯, leaving the address its room.
        #expect(!PaneAddressView.showsButton(width: 80, fitting: 300, hasText: true))
        #expect(!PaneAddressView.showsButton(width: 200, fitting: 300, hasText: false))
        // An address shown whole always has room for it.
        let address = PaneAddressView()
        address.text = "example.com"
        #expect(PaneAddressView.showsButton(width: address.fittingWidth, fitting: address.fittingWidth, hasText: true))
    }

    @Test func aNarrowStripMovesItIntoMore() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: PaneHeaderView.height))
        let space = Library.shared.spaces[0].id
        let tab = Tab(url: URL(string: "https://example.com/some/long/path/to/a/page")!, spaceID: space)
        header.show(tab)
        header.layoutSubtreeIfNeeded()
        header.address.layoutSubtreeIfNeeded()
        #expect(header.address.showsSiteControls)
        header.frame.size.width = 120
        header.layoutSubtreeIfNeeded()
        header.address.layoutSubtreeIfNeeded()
        #expect(!header.address.showsSiteControls)
        #expect(!header.more.isHidden)
    }
}

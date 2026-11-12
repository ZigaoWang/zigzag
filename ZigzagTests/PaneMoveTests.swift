import AppKit
import Testing
@testable import Zigzag

/// A pane dragged by its strip (#160): where it would go at each point of the page, how the group changes for each
/// move, and that ⌘Z's way back puts every pane where it was.
struct PaneMoveTests {
    typealias Pair = TabManager.SplitPair
    let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let gap: CGFloat = 8
    let sideBySide = TileShape(regions: [.left, .right])
    let stacked = TileShape(regions: [.top, .bottom])
    let three = TileShape(regions: [.left, .topRight, .bottomRight])
    let four = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])

    private func move(_ index: Int, _ x: CGFloat, _ y: CGFloat, in shape: TileShape) -> PaneMove? {
        PaneMove.target(moving: index, at: CGPoint(x: x, y: y), in: area, shape: shape, gap: gap)
    }

    // MARK: Where it goes

    @Test func overAnotherPaneTheTwoSwap() {
        #expect(move(0, 900, 400, in: sideBySide)?.kind == .swap(1))
        #expect(move(1, 300, 400, in: sideBySide)?.kind == .swap(0))
        #expect(move(0, 900, 200, in: four)?.kind == .swap(1))
        #expect(move(3, 300, 600, in: four)?.kind == .swap(2))
        // The hint covers the pane it would trade places with.
        let frames = four.frames(in: area, gap: gap)
        #expect(move(0, 900, 600, in: four)?.frame == frames[3])
    }

    @Test func overItsOwnPaneNothingChanges() {
        #expect(move(0, 300, 400, in: sideBySide) == nil)
        #expect(move(2, 300, 600, in: four) == nil)
        // Its own edge, where it already is: nothing either.
        #expect(move(0, 10, 400, in: sideBySide) == nil)
        #expect(move(0, 10, 400, in: three) == nil)
        // Off the page: nothing.
        #expect(move(0, 1300, 400, in: sideBySide) == nil)
    }

    @Test func twoPanesStackOnTheTopOrBottomEdge() {
        // The left half to the bottom edge: the right one goes on top.
        guard case .place(let region, let regions)? = move(0, 600, 790, in: sideBySide)?.kind else { Issue.record("no move"); return }
        #expect(region == .bottom && regions == [.bottom, .top])
        // And back side by side from stacked, on the left edge.
        guard case .place(_, let back)? = move(1, 10, 400, in: stacked)?.kind else { Issue.record("no move"); return }
        #expect(back == [.right, .left])
        // The other side's edge is a swap by another name: the two trade sides.
        guard case .place(_, let traded)? = move(0, 1190, 400, in: sideBySide)?.kind else { Issue.record("no move"); return }
        #expect(traded == [.right, .left])
    }

    @Test func twoPanesTakeTheNearerEdgeInACorner() {
        // A corner of a split of two has no quarter: the nearer edge's half.
        guard case .place(let low, _)? = move(0, 1190, 795, in: sideBySide)?.kind else { Issue.record("no move"); return }
        #expect(low == .bottom)
        guard case .place(let side, _)? = move(1, 5, 790, in: sideBySide)?.kind else { Issue.record("no move"); return }
        #expect(side == .left)
    }

    @Test func aCornerTakesAQuarterTheRestMakingRoom() {
        // The left half of three into the bottom right corner: the two quarters close up into halves, and the top
        // one's half keeps its top right corner.
        guard let moved = move(0, 1190, 790, in: three), case .place(let region, let regions) = moved.kind else { Issue.record("no move"); return }
        #expect(region == .bottomRight)
        #expect(TileShape.isValid(regions) && regions[0] == .bottomRight)
        #expect(Set(regions) == [.bottomRight, .top, .bottomLeft])
        var after = three
        after.regions = regions
        #expect(moved.frame == after.frames(in: area, gap: gap)[0])
    }

    @Test func anEdgeTakesAHalfInAGroupOfThree() {
        // A quarter to the left edge: the half there moves over into a quarter.
        guard case .place(let region, let regions)? = move(1, 10, 400, in: three)?.kind else { Issue.record("no move"); return }
        #expect(region == .left && TileShape.isValid(regions) && regions[1] == .left)
    }

    @Test func aGridHasNoHalfToGiveSoItsEdgesSwap() {
        // Four quarters: no half for a fifth of the room, so the edge is the pane under it.
        #expect(move(0, 1190, 200, in: four)?.kind == .swap(1))
        #expect(move(0, 600, 790, in: four)?.kind == .swap(2) || move(0, 600, 790, in: four)?.kind == .swap(3))
    }

    // MARK: The group after

    @Test func aSwapTradesPlacesAndKeepsTheLines() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var shape = four
        shape.column = 0.6
        guard let pair = Pair(ids: [a, b, c, d], shape: shape), let swapped = pair.moving(a, .swap(3)) else { Issue.record("no pair"); return }
        #expect(swapped.ids == [d, b, c, a])
        #expect(swapped.shape.regions == pair.shape.regions && swapped.shape.column == 0.6)
    }

    @Test func aSplitOfTwoSwapsAndStacks() {
        let a = UUID(), b = UUID()
        guard let pair = Pair(ids: [a, b], shape: TileShape.pair(ratio: 0.3, vertical: false)) else { Issue.record("no pair"); return }
        let swapped = pair.moving(a, .swap(1))
        #expect(swapped?.left == b && swapped?.right == a && swapped?.vertical == false)
        // Its place keeps its width: the left side is still 0.3 of it.
        #expect(swapped?.ratio == 0.3)
        let stacked = pair.moving(a, .place(region: .bottom, regions: [.bottom, .top]))
        #expect(stacked?.vertical == true && stacked?.left == b && stacked?.right == a)
    }

    @Test func aMoveToARegionReadsInItsNewOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        guard let pair = Pair(ids: [a, b, c], shape: three) else { Issue.record("no pair"); return }
        // a (the left half) into the bottom right corner: b on top reads first, then c, then a.
        let moved = pair.moving(a, .place(region: .bottomRight, regions: [.bottomRight, .top, .bottomLeft]))
        #expect(moved?.ids == [b, c, a])
        #expect(moved?.shape.regions == [.top, .bottomLeft, .bottomRight])
        // A move that doesn't add up is no move.
        #expect(pair.moving(a, .place(region: .left, regions: [.left, .right])) == nil)
        #expect(pair.moving(a, .swap(0)) == nil)
        #expect(pair.moving(UUID(), .swap(1)) == nil)
    }

    // MARK: The window's group, and ⌘Z

    @MainActor @Test func rearrangingAndPuttingBack() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false) }
        guard let before = Pair(ids: tabs.map(\.id), shape: three) else { Issue.record("no pair"); return }
        manager.restoreSplit(before)
        guard let after = before.moving(tabs[0].id, .swap(2)) else { Issue.record("no move"); return }
        #expect(manager.rearrange(before, to: after))
        #expect(manager.split(for: tabs[0]) == after)
        // ⌘Z's way back, and ⇧⌘Z's forward again.
        #expect(manager.rearrange(after, to: before))
        #expect(manager.split(for: tabs[0]) == before)
        #expect(manager.rearrange(before, to: after))
        // Changed since (a page left the group): nothing to put back.
        manager.leaveGroup(tabs[1])
        #expect(!manager.rearrange(after, to: before))
        tabs.forEach { $0.close() }
    }

    @MainActor @Test func theHintNamesTheMove() {
        let titles = TileRegion.allCases.map { SplitDropHint.title(forMove: .place(region: $0, regions: [])) }
        #expect(Set(titles).count == TileRegion.allCases.count && titles.allSatisfy { !$0.isEmpty })
        #expect(!titles.contains(SplitDropHint.title(forMove: .swap(0))))
        // Not a tab opening: a pane moving.
        #expect(titles[0] != SplitDropHint.title(for: TileDrop.Kind.place(region: .left, regions: [])))
    }

    // MARK: Zoom

    @Test func aPaneZoomsAndGoesBack() {
        let a = UUID(), b = UUID(), c = UUID()
        var zoom = PaneZoom()
        #expect(!zoom.isZoomed && zoom.index(in: [a, b, c]) == nil)
        zoom.toggle(b, in: [a, b, c])
        #expect(zoom.isZoomed && zoom.tabID == b && zoom.index(in: [a, b, c]) == 1)
        // The same pane again: back in its place.
        zoom.toggle(b, in: [a, b, c])
        #expect(!zoom.isZoomed)
        // Another pane while one is zoomed: that one instead.
        zoom.toggle(a, in: [a, b, c])
        zoom.toggle(c, in: [a, b, c])
        #expect(zoom.tabID == c)
        zoom.clear()
        #expect(!zoom.isZoomed)
    }

    @Test func onlyAPageOfASplitZooms() {
        let a = UUID(), b = UUID()
        var zoom = PaneZoom()
        zoom.toggle(a, in: [a])
        #expect(!zoom.isZoomed)
        zoom.toggle(UUID(), in: [a, b])
        #expect(!zoom.isZoomed)
    }

    @Test func theZoomFollowsItsPageAcrossASwap() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var zoom = PaneZoom()
        zoom.toggle(a, in: [a, b, c, d])
        // Places traded: the same page, now third.
        #expect(zoom.index(in: [c, b, a, d]) == 2)
        #expect(zoom.isZoomed)
    }

    @Test func theZoomEndsWhenTheGroupChanges() {
        let a = UUID(), b = UUID(), c = UUID()
        // A page closed or left the group.
        var zoom = PaneZoom()
        zoom.toggle(a, in: [a, b, c])
        #expect(zoom.index(in: [a, b]) == nil && !zoom.isZoomed)
        // A page came in.
        zoom.toggle(a, in: [a, b])
        #expect(zoom.index(in: [a, b, c]) == nil && !zoom.isZoomed)
        // The zoomed page itself closed.
        zoom.toggle(a, in: [a, b, c])
        #expect(zoom.index(in: [b, c]) == nil && !zoom.isZoomed)
        // No split on screen (the group ended, or its pages moved to another window).
        zoom.toggle(b, in: [a, b, c])
        #expect(zoom.index(in: nil) == nil && !zoom.isZoomed)
    }

    @MainActor @Test func theStripNamesTheZoom() {
        #expect(PaneHeaderView.zoomTitle(false) != PaneHeaderView.zoomTitle(true))
        let header = PaneHeaderView()
        #expect(header.zoom.toolTip == PaneHeaderView.zoomTitle(false))
        header.isZoomed = true
        #expect(header.zoom.toolTip == PaneHeaderView.zoomTitle(true))
        #expect(header.zoom.symbol != "arrow.up.left.and.arrow.down.right")
    }

    // MARK: The strip's ink

    @MainActor @Test func theStripsInkReadsOnItsPage() {
        #expect(PaneHeaderView.inkAppearance(on: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)) == .darkAqua)
        #expect(PaneHeaderView.inkAppearance(on: .white) == .aqua)
        #expect(PaneHeaderView.inkAppearance(on: NSColor(srgbRed: 0.98, green: 0.96, blue: 0.9, alpha: 1)) == .aqua)
        // No page color: the window's own.
        #expect(PaneHeaderView.inkAppearance(on: nil) == nil)
    }

    @Test func thePicturesShapeIsThePanes() {
        #expect(PaneDrag.pictureSize(for: CGSize(width: 800, height: 600)) == CGSize(width: 220, height: 165))
        // Very tall or very wide, it's cut to fit: never taller than wide, never under half as tall.
        #expect(PaneDrag.pictureSize(for: CGSize(width: 400, height: 1600)).height == 220)
        #expect(PaneDrag.pictureSize(for: CGSize(width: 1600, height: 200)).height == 110)
    }
}

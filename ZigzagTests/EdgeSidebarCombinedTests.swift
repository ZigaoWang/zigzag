import AppKit
import Testing
@testable import Zigzag

/// The edge panel with the page inside it (#365 prototype): one object whose card is the sidebar and whose other
/// third is the tab's own page, so both widen, slide and collapse together.
struct EdgeSidebarCombinedTests {
    let visible = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let inset: CGFloat = 8
    let sidebar: CGFloat = 280

    /// The page takes a third of the screen and the panel's whole height: portrait on a landscape screen.
    @Test func thePageIsAPortraitThirdOfTheScreen() {
        let third = EdgeSidebarLayout.pageWidth(in: visible)
        #expect(third == 426)
        let bounds = NSRect(x: 0, y: 0, width: EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: visible),
                            height: visible.height)
        let page = EdgeSidebarLayout.pageFrame(in: bounds, sidebar: sidebar, inset: inset, page: true, onRight: false)
        #expect(page.width == third)
        #expect(page.height == visible.height - 2 * inset)
        #expect(page.width < page.height)
    }

    /// The panel is the sidebar plus the page's third, plus the gutters that set both off the screen's edge.
    @Test func thePanelIsTheSidebarPlusTheThirdAndItsGutters() {
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: visible)
        #expect(wide == sidebar + 3 * inset + EdgeSidebarLayout.pageWidth(in: visible))
        let plain = EdgeSidebarLayout.width(sidebar: sidebar, page: false, inset: inset, in: visible)
        #expect(plain == sidebar + inset)
    }

    /// The card keeps the sidebar's own width, and the page sits beside it without overlapping, on either edge.
    @Test func thePageSitsInsideTheCardOnEitherSide() {
        for onRight in [false, true] {
            let bounds = NSRect(x: 0, y: 0, width: EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: visible),
                                height: visible.height)
            let card = EdgeSidebarLayout.cardFrame(in: bounds, sidebar: sidebar, inset: inset, page: true, onRight: onRight)
            let page = EdgeSidebarLayout.pageFrame(in: bounds, sidebar: sidebar, inset: inset, page: true, onRight: onRight)
            #expect(card.width == sidebar)
            #expect(page.width == EdgeSidebarLayout.pageWidth(in: visible))
            #expect(page.minX >= 0 && page.maxX <= bounds.width)
            #expect(!page.intersects(card))
        }
    }

    /// A screen too narrow for the sidebar and a third gives the page what is left, never a page off its edge.
    @Test func thePanelNeverWidensPastTheScreen() {
        let narrow = NSRect(x: 0, y: 0, width: 600, height: 800)
        let width = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: narrow)
        #expect(EdgeSidebarLayout.frame(in: narrow, width: width, onRight: false).width <= narrow.width)
    }

    /// The space editor sits in the same side area as the page, and the card keeps the sidebar's width while it is
    /// there: the panel is what widens, never the sidebar.
    @Test func theSpaceEditorTakesASideWithoutWideningTheCard() {
        let editor: CGFloat = 316
        let width = EdgeSidebarLayout.width(sidebar: sidebar, side: editor, inset: inset, in: visible)
        #expect(width == sidebar + 3 * inset + editor)
        let bounds = NSRect(x: 0, y: 0, width: width, height: visible.height)
        for onRight in [false, true] {
            let card = EdgeSidebarLayout.cardFrame(in: bounds, sidebar: sidebar, inset: inset, sideShowing: true, onRight: onRight)
            let side = EdgeSidebarLayout.sideFrame(in: bounds, sidebar: sidebar, inset: inset, sideShowing: true, onRight: onRight)
            #expect(card.width == sidebar)
            #expect(side.width == editor)
            #expect(!side.intersects(card))
        }
    }

    /// The page lays out once at the size it will have once the panel has widened, pinned to the card's side. The
    /// widening then reveals it; a live page is never resized through the animation.
    @Test func thePageHoldsItsFinalSizeAndSideWhileThePanelWidens() {
        let target = NSSize(width: EdgeSidebarLayout.pageWidth(in: visible), height: visible.height - 2 * inset)
        let open = NSRect(x: 0, y: 0, width: EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: visible),
                          height: visible.height)
        for onRight in [false, true] {
            let page = EdgeSidebarLayout.pageFrame(in: open, sidebar: sidebar, inset: inset, page: true, onRight: onRight)
            #expect(EdgeSidebarLayout.pageHolderFrame(in: page, target: target, onRight: onRight)
                    == NSRect(origin: .zero, size: target))
            // The area starts at no width: the holder is its whole width, off its far edge, and is clipped.
            let closed = EdgeSidebarLayout.pageHolderFrame(in: .zero, target: target, onRight: onRight)
            #expect(closed.size == target)
            #expect(closed.minX == (onRight ? -target.width : 0))
        }
    }

    /// AppKit's part: as the page area opens, the holder keeps its size and stays against the card's side.
    @Test @MainActor func thePageHolderStaysPutAsThePageAreaOpens() {
        let target = NSSize(width: 300, height: 600)
        for onRight in [false, true] {
            let area = NSView(frame: .zero)
            let holder = NSView(frame: EdgeSidebarLayout.pageHolderFrame(in: area.bounds, target: target, onRight: onRight))
            holder.autoresizingMask = EdgeSidebarLayout.pageHolderMask(onRight: onRight)
            area.addSubview(holder)
            area.setFrameSize(target)
            #expect(holder.frame == NSRect(origin: .zero, size: target))
            area.setFrameSize(NSSize(width: 450, height: target.height))
            #expect(holder.frame == NSRect(x: onRight ? 150 : 0, y: 0, width: target.width, height: target.height))
        }
    }

    /// While the panel widens, the page area is already its final size against the card: the window's growing edge
    /// uncovers it. Nothing resizes it frame by frame, so the live page's edge never steps.
    @Test func theWideningUncoversThePageRatherThanResizingIt() {
        let target = EdgeSidebarLayout.pageWidth(in: visible)
        let narrowWidth = EdgeSidebarLayout.width(sidebar: sidebar, page: false, inset: inset, in: visible)
        let wideWidth = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: visible)
        for onRight in [false, true] {
            let narrow = EdgeSidebarLayout.frame(in: visible, width: narrowWidth, onRight: onRight)
            let wide = EdgeSidebarLayout.frame(in: visible, width: wideWidth, onRight: onRight)
            let first = EdgeSidebarLayout.pageRevealFrame(in: NSRect(origin: .zero, size: narrow.size),
                                                          sidebar: sidebar, inset: inset, width: target, onRight: onRight)
            let last = EdgeSidebarLayout.pageRevealFrame(in: NSRect(origin: .zero, size: wide.size),
                                                         sidebar: sidebar, inset: inset, width: target, onRight: onRight)
            // Its size never changes; only the window's edge moves over it.
            #expect(first.size == NSSize(width: target, height: visible.height - 2 * inset))
            #expect(last.size == first.size)
            // Pinned to the card's side on screen, from the first frame to the last.
            #expect(narrow.minX + first.minX == wide.minX + last.minX)
            // Settled, it is exactly the page's ordinary place.
            #expect(last == EdgeSidebarLayout.pageFrame(in: NSRect(origin: .zero, size: wide.size),
                                                         sidebar: sidebar, inset: inset, page: true, onRight: onRight))
        }
    }

    /// Showing the panel again re-adds the card; Site Controls and the rest of the overlay must still draw over it.
    @Test @MainActor func theOverlayStaysAboveTheCardWhenThePanelIsShownAgain() {
        let host = EdgeSidebarHost(frame: NSRect(x: 0, y: 0, width: 500, height: 800))
        let container = SidebarContainer(sidebar: SidebarView(frame: .zero))
        host.set(container)
        host.set(container)
        #expect(host.subviews.last === host.overlay)
    }

    /// A page making way for the note stays in the side until the note's fold has covered it, rather than vanishing
    /// a frame before the note arrives.
    @Test @MainActor func aPageStaysUnderTheNoteUntilTheFoldEnds() {
        let host = EdgeSidebarHost(frame: NSRect(x: 0, y: 0, width: 500, height: 800))
        host.set(SidebarContainer(sidebar: SidebarView(frame: .zero)))
        host.pageShowing = true
        #expect(!host.pageArea.isHidden)
        host.beginPageFoldOut()
        #expect(host.pageFoldingOut)
        #expect(!host.pageArea.isHidden)
        host.endPageFoldOut()
        #expect(!host.pageFoldingOut)
        #expect(host.pageArea.isHidden)
    }
}

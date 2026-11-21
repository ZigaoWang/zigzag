import AppKit
import Testing
@testable import Zigzag

/// The edge lens (#365): the sidebar and the lens are one session, each dismissal says what it closes, and the card
/// keeps its page's shape inside the screen.
@MainActor
struct EdgeLensTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let sidebar = NSRect(x: 1160, y: 16, width: 264, height: 868)
    private let caption: CGFloat = 60

    // MARK: One session

    @Test func theSidebarCannotHideWhileTheLensIsOpen() {
        #expect(EdgeLensPolicy.blocksSidebarHide(lensOpen: true))
        #expect(!EdgeLensPolicy.blocksSidebarHide(lensOpen: false))
    }

    // MARK: Dismissals

    @Test func aSidebarActionClosesOnlyTheLens() {
        for reason in [EdgeLensReason.sameTab, .sidebarClick, .escape] {
            #expect(EdgeLensPolicy.dismissal(for: reason) == .lensOnly)
            #expect(!EdgeLensPolicy.hidesSidebar(after: reason, pointerInEdgeZone: false, panelCanShow: true))
        }
    }

    @Test func anOutsideClickLeavesTheSidebarToItsProximity() {
        #expect(EdgeLensPolicy.dismissal(for: .outsideClick) == .all)
        #expect(!EdgeLensPolicy.hidesSidebar(after: .outsideClick, pointerInEdgeZone: true, panelCanShow: true))
        #expect(EdgeLensPolicy.hidesSidebar(after: .outsideClick, pointerInEdgeZone: false, panelCanShow: true))
        #expect(EdgeLensPolicy.hidesSidebar(after: .outsideClick, pointerInEdgeZone: true, panelCanShow: false))
    }

    @Test func anotherAppOrSpaceAlsoLeavesTheSidebarToItsProximity() {
        for reason in [EdgeLensReason.altTab, .spaceChange, .browserFront] {
            #expect(EdgeLensPolicy.dismissal(for: reason) == .all)
            #expect(!EdgeLensPolicy.hidesSidebar(after: reason, pointerInEdgeZone: true, panelCanShow: true))
            #expect(EdgeLensPolicy.hidesSidebar(after: reason, pointerInEdgeZone: false, panelCanShow: true))
        }
    }

    @Test func aClosedWindowOrTheFeatureGoingOffTakesTheSidebarToo() {
        for reason in [EdgeLensReason.windowClose, .featureOff] {
            #expect(EdgeLensPolicy.dismissal(for: reason) == .all)
            #expect(EdgeLensPolicy.hidesSidebar(after: reason, pointerInEdgeZone: true, panelCanShow: true))
        }
    }

    // MARK: Size

    @Test func theLensIsSixtyPercentOfTheScreen() {
        #expect(abs(lens(aspect: 1.6).width - 864) < 0.5)
    }

    @Test func theLensIsAtLeast480Wide() {
        let frame = EdgeLensLayout.frame(beside: NSRect(x: 320, y: 16, width: 264, height: 568),
                                         in: NSRect(x: 0, y: 0, width: 600, height: 600),
                                         pageAspect: 1.6, caption: caption, onRight: true, rowMidY: 300)
        #expect(abs(frame.width - 480) < 0.5)
    }

    @Test func theLensIsAtMost1200Wide() {
        let frame = EdgeLensLayout.frame(beside: NSRect(x: 2660, y: 16, width: 264, height: 568),
                                         in: NSRect(x: 0, y: 0, width: 3000, height: 2000),
                                         pageAspect: 1.6, caption: caption, onRight: true, rowMidY: 1000)
        #expect(abs(frame.width - 1200) < 0.5)
    }

    @Test func aScreenNarrowerThanTheMinimumStillHoldsTheLens() {
        let visible = NSRect(x: 0, y: 0, width: 400, height: 600)
        let frame = EdgeLensLayout.frame(beside: NSRect(x: 120, y: 16, width: 264, height: 568),
                                         in: visible, pageAspect: 1.6, caption: caption,
                                         onRight: true, rowMidY: 300)
        #expect(frame.width <= visible.width)
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
    }

    @Test func thePageKeepsItsAspectUnderTheCaption() {
        let frame = lens(aspect: 1.6)
        #expect(abs((frame.height - caption) - frame.width / 1.6) < 0.5)
    }

    @Test func theLensNeverGrowsTallerThanSeventyPercentOfTheScreen() {
        // A portrait page would be taller than the screen; the cap shrinks the card, keeping the page's shape.
        let frame = lens(aspect: 0.5)
        #expect(abs(frame.height - screen.height * 0.7) < 0.5)
        #expect(abs((frame.height - caption) - frame.width / 0.5) < 0.5)
    }

    // MARK: Place

    @Test func theLensSitsBesideTheSidebarOnThePagesSide() {
        let right = lens(aspect: 1.6)
        #expect(abs(right.maxX - (sidebar.minX - Tokens.Space.x2)) < 0.5)

        let left = EdgeLensLayout.frame(beside: NSRect(x: 16, y: 16, width: 264, height: 868), in: screen,
                                        pageAspect: 1.6, caption: caption, onRight: false, rowMidY: 450)
        #expect(abs(left.minX - (16 + 264 + Tokens.Space.x2)) < 0.5)
    }

    @Test func theLensCentresOnItsRowAndStaysOnScreen() {
        #expect(abs(lens(aspect: 1.6).midY - 450) < 0.5)

        let top = EdgeLensLayout.frame(beside: sidebar, in: screen, pageAspect: 1.6, caption: caption,
                                       onRight: true, rowMidY: 30)
        #expect(top.minY >= screen.minY + Tokens.Space.x2 - 0.5)
        #expect(top.maxY <= screen.maxY - Tokens.Space.x2 + 0.5)

        let bottom = EdgeLensLayout.frame(beside: sidebar, in: screen, pageAspect: 1.6, caption: caption,
                                          onRight: true, rowMidY: 870)
        #expect(bottom.minY >= screen.minY + Tokens.Space.x2 - 0.5)
        #expect(bottom.maxY <= screen.maxY - Tokens.Space.x2 + 0.5)
    }

    private func lens(aspect: CGFloat) -> NSRect {
        EdgeLensLayout.frame(beside: sidebar, in: screen, pageAspect: aspect, caption: caption,
                             onRight: true, rowMidY: 450)
    }
}

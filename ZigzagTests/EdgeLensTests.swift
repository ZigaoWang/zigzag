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

    @Test func theEdgePreviewIsInstantWhileTheBrowsersPreviewWaits() {
        #expect(EdgePeekPreviewPolicy.delay == 0)
        #expect(Tokens.Motion.previewDelay > 0)
    }

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

    @Test func aPageOpenedFromTheLensReplacesItsPage() {
        #expect(EdgeLensPolicy.openAction(isVisible: false, replacing: false) == .open)
        #expect(EdgeLensPolicy.openAction(isVisible: true, replacing: true) == .replace)
        #expect(EdgeLensPolicy.openAction(isVisible: true, replacing: false) == .close)
    }

    @Test func theSidebarKeepsTheKeyboardOnlyAfterALensAction() {
        for reason in [EdgeLensReason.sameTab, .sidebarClick, .escape] {
            #expect(EdgeLensPolicy.keepsKey(after: reason))
        }
        for reason in [EdgeLensReason.outsideClick, .altTab, .spaceChange, .browserFront, .windowClose, .featureOff,
                       .selection] {
            #expect(!EdgeLensPolicy.keepsKey(after: reason))
        }
    }

    @Test func aSelectionChangeDoesNotPutThePageBack() {
        #expect(EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: true, reason: .escape))
        #expect(!EdgePeekRestorePolicy.canRestore(isClosed: false, hasOrigin: true, reason: .selection))
    }

    // MARK: Size

    @Test func theLensIsSixtyPercentOfTheScreen() {
        #expect(abs(lens(aspect: 1.6).width - 864) < 0.5)
    }

    @Test func theLensIsAtLeast480Wide() {
        // A screen with room for the minimum beside the sidebar, or the gap wins instead (see the narrow-screen test).
        let frame = EdgeLensLayout.frame(beside: NSRect(x: 520, y: 16, width: 264, height: 568),
                                         in: NSRect(x: 0, y: 0, width: 800, height: 600),
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

    @Test func theLensKeepsItsGapFromTheSidebarOnANarrowScreen() {
        let visible = NSRect(x: 0, y: 0, width: 760, height: 700)
        let leftSide = NSRect(x: 16, y: 16, width: 264, height: 668)
        let left = EdgeLensLayout.frame(beside: leftSide, in: visible, pageAspect: 1.6, caption: caption,
                                        onRight: false, rowMidY: 350)
        #expect(left.minX >= leftSide.maxX + Tokens.Space.x2 - 0.5)
        #expect(left.maxX <= visible.maxX + 0.5)
        #expect(!left.intersects(leftSide))

        let rightSide = NSRect(x: 480, y: 16, width: 264, height: 668)
        let right = EdgeLensLayout.frame(beside: rightSide, in: visible, pageAspect: 1.6, caption: caption,
                                         onRight: true, rowMidY: 350)
        #expect(right.maxX <= rightSide.minX - Tokens.Space.x2 + 0.5)
        #expect(right.minX >= visible.minX - 0.5)
        #expect(!right.intersects(rightSide))
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

    // MARK: The lens caption

    @Test func theBrowsersPreviewKeepsItsCaption() {
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 236, height: 176))
        card.show(tab: nil, bookmark: nil)
        card.layoutSubtreeIfNeeded()
        #expect(view("preview.lensControls", in: card)?.isHidden == true)
        #expect(view("preview.detail", in: card)?.isHidden == false)
    }

    @Test func theLensCaptionReplacesTheDetailLine() {
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        card.show(tab: nil, bookmark: nil)
        card.showsLensControls = true
        card.layoutSubtreeIfNeeded()
        #expect(view("preview.lensControls", in: card)?.isHidden == false)
        #expect(view("preview.detail", in: card)?.isHidden == true)
        let controls = view("preview.lensControls", in: card)
        #expect(controls?.frame.isEmpty == false)
        #expect((controls?.frame.maxY ?? .infinity) <= card.bounds.maxY + 0.5)
    }

    @Test func theLensCaptionShowsThePagesState() {
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        card.show(tab: nil, bookmark: nil)
        card.showsLensControls = true
        card.updateLens(address: "example.com/a", canGoBack: true, canGoForward: false, isLoading: true)
        #expect((view("preview.lensAddress", in: card) as? NSTextField)?.stringValue == "example.com/a")
        #expect((view("preview.lensBack", in: card) as? IconButton)?.isEnabled == true)
        #expect((view("preview.lensForward", in: card) as? IconButton)?.isEnabled == false)
        #expect((view("preview.lensReload", in: card) as? IconButton)?.isLoading == true)
    }

    @Test func theLensCaptionSubmitsTheTypedAddress() {
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        card.showsLensControls = true
        var submitted: String?
        card.onLensAddress = { submitted = $0 }
        (view("preview.lensAddress", in: card) as? NSTextField)?.stringValue = "example.com/b"
        card.submitLensAddress()
        #expect(submitted == "example.com/b")
    }

    @Test func theLivePageBringsItsShapeAndLeavesWithTheCard() {
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        card.showLive(holder: holder)
        #expect(abs(card.pageAspect - 2) < 0.01)
        #expect(view("preview.live", in: card)?.isHidden == false)
        #expect(holder.superview != nil)
        card.endLive()
        #expect(view("preview.live", in: card)?.isHidden == true)
        #expect(holder.superview == nil)
    }

    @Test func aRestoredPageIsNotTakenFromItsCardAgain() {
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 338))
        let origin = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 338))
        card.showLive(holder: holder)
        // The close puts the page back in its tab before the card stops being live.
        holder.removeFromSuperview()
        origin.addSubview(holder)
        card.endLive()
        #expect(holder.superview === origin)
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

    private func view(_ id: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == id { return root }
        for subview in root.subviews {
            if let found = view(id, in: subview) { return found }
        }
        return nil
    }
}

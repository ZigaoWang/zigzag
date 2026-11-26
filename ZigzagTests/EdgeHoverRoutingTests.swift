import Foundation
import Testing
@testable import Zigzag

/// The edge panel's hover and space behaviour (#545). A row reports its own hover, so crossing from one row to the next
/// sends a nil from the row being left; that nil must not close the page. A space switch with the box out is a handover
/// to the empty page, never a page of the new space shown unasked.
@MainActor
@Suite(.serialized)
struct EdgeHoverRoutingTests {
    @Test func aCrossingBetweenRowsDoesNotCloseThePage() {
        // Still in the list: a crossing, not leaving. The next row's report cancels the close anyway; this is what
        // makes a slow crossing, or a pause on the edge of a row, behave the same.
        #expect(!EdgeHoverRouting.closesAfterNilHover(pointerOverRows: true, pointerOverPreview: false))
    }

    @Test func restingOnThePageKeepsIt() {
        #expect(!EdgeHoverRouting.closesAfterNilHover(pointerOverRows: false, pointerOverPreview: true))
    }

    @Test func leavingTheRowsClosesIt() {
        #expect(EdgeHoverRouting.closesAfterNilHover(pointerOverRows: false, pointerOverPreview: false))
    }

    @Test func aBlankSlateIsNotClosedByANilHover() {
        // After a space switch the panel holds the empty page: there is no page to close, and closing would narrow
        // the panel and take away what the switch just put in place.
        #expect(!EdgeHoverKeep.closesOnNilHover(blankSlateShown: true))
        // With a page out, leaving the rows closes it as before.
        #expect(EdgeHoverKeep.closesOnNilHover(blankSlateShown: false))
    }

    @Test func theFoldFollowsTheSpaceList() {
        let first = UUID(), second = UUID(), third = UUID()
        let order = [first, second, third]
        // Picking a later space slides its list in from the right, so the box folds from the right.
        #expect(EdgePreviewRouting.spaceSlide(from: first, to: third, order: order) == 1)
        // Picking one before it slides in from the left.
        #expect(EdgePreviewRouting.spaceSlide(from: third, to: first, order: order) == -1)
        // The same space, or one whose order can't be read, folds from the panel's own side.
        #expect(EdgePreviewRouting.spaceSlide(from: second, to: second, order: order) == 0)
        #expect(EdgePreviewRouting.spaceSlide(from: nil, to: second, order: order) == 0)
        #expect(EdgePreviewRouting.spaceSlide(from: second, to: UUID(), order: order) == 0)
    }
}

import Foundation
import Testing
@testable import Zigzag

/// The edge panel's hover behaviour. A row reports its own hover, so crossing from one row to the next sends a nil
/// from the row being left; that nil must not close the page.
@MainActor
@Suite(.serialized)
struct EdgeHoverRoutingTests {
    @Test func aCrossingBetweenRowsDoesNotCloseThePage() {
        // Still in the list: a crossing, not leaving. The next row's report cancels the close anyway; this is what
        // makes a slow crossing, or a pause on the edge of a row, behave the same.
        #expect(!EdgeHoverRouting.closesAfterNilHover(pointerOverRows: true, pointerOverPreview: false, panelKept: false))
    }

    @Test func restingOnThePageKeepsIt() {
        #expect(!EdgeHoverRouting.closesAfterNilHover(pointerOverRows: false, pointerOverPreview: true, panelKept: false))
    }

    @Test func leavingTheRowsClosesIt() {
        #expect(EdgeHoverRouting.closesAfterNilHover(pointerOverRows: false, pointerOverPreview: false, panelKept: false))
    }

    @Test func aPageStaysWhileTheSidebarStays() {
        // Off the rows and off the page, but still where the sidebar keeps itself open: the page waits rather than
        // closing and coming back a moment later.
        #expect(!EdgeHoverRouting.closesAfterNilHover(pointerOverRows: false, pointerOverPreview: false, panelKept: true))
    }
}

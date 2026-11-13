import Foundation
import Testing
@testable import Zigzag

/// The page's width and height typed beside Page Size above the page (#141).
@MainActor
struct PageSizeInputTests {
    @Test func aNumberIsASide() {
        #expect(PageSizeInput.side(from: "440") == 440)
        #expect(PageSizeInput.side(from: "  956 ") == 956)
        #expect(PageSizeInput.side(from: "390px") == 390)
        #expect(PageSizeInput.side(from: "390 PX") == 390)
        #expect(PageSizeInput.side(from: "393.6") == 394)
    }

    @Test func nothingANumberIsNoSide() {
        for text in ["", "  ", "wide", "px", "12a", "nan", "inf"] {
            #expect(PageSizeInput.side(from: text) == nil, "\(text)")
        }
    }

    /// Kept within the sizes a page can have, as the Custom Page Size sheet keeps them.
    @Test func aSideIsKeptWithinTheLimits() {
        #expect(PageSizeInput.side(from: "50") == PageSizes.limits.lowerBound)
        #expect(PageSizeInput.side(from: "-400") == PageSizes.limits.lowerBound)
        #expect(PageSizeInput.side(from: "99999") == PageSizes.limits.upperBound)
        #expect(PageSizeInput.side(from: "200") == 200)
    }

    @Test func theArrowsStepByOneOrTenWithShift() {
        #expect(PageSizeInput.stepped(440, up: true, shift: false) == 441)
        #expect(PageSizeInput.stepped(440, up: false, shift: false) == 439)
        #expect(PageSizeInput.stepped(440, up: true, shift: true) == 450)
        #expect(PageSizeInput.stepped(440, up: false, shift: true) == 430)
        #expect(PageSizeInput.stepped(205, up: false, shift: true) == PageSizes.limits.lowerBound)
        #expect(PageSizeInput.stepped(PageSizes.limits.upperBound, up: true, shift: false) == PageSizes.limits.upperBound)
    }

    @Test func oneSideTypedKeepsTheOther() {
        let size = CGSize(width: 440, height: 956)
        #expect(PageSizeInput.size(size, width: 390) == CGSize(width: 390, height: 956))
        #expect(PageSizeInput.size(size, height: 844) == CGSize(width: 440, height: 844))
    }

    @Test func theScaleIsSaidOnlyWhenSmaller() {
        #expect(PageSizeReadout.scaleText(1) == nil)
        #expect(PageSizeReadout.scaleText(0.998) == nil)
        #expect(PageSizeReadout.scaleText(0.86) == "at 86%")
    }
}

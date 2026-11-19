import AppKit
import Testing
@testable import Zigzag

/// The edge Peek's card on the screen: the window Peek's proportions, centered, never off the edge.
@MainActor
struct EdgePeekTests {
    @Test func theCardSitsCenteredAndClearOfTheEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let card = EdgePeekLayout.frame(in: screen)
        #expect(card.midX == screen.midX)
        #expect(card.midY == screen.midY)
        #expect(card.width < screen.width)
        #expect(card.height < screen.height)
        #expect(card.width > 0)
        #expect(card.height > 0)
    }

    @Test func aSmallScreenStillGetsAPositiveCard() {
        let screen = NSRect(x: 0, y: 0, width: 400, height: 300)
        let card = EdgePeekLayout.frame(in: screen)
        #expect(card.width > 0)
        #expect(card.height > 0)
        #expect(card.width <= screen.width)
        #expect(card.height <= screen.height)
    }

    @Test func anOffsetScreenKeepsTheCardOnIt() {
        let screen = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        let card = EdgePeekLayout.frame(in: screen)
        #expect(screen.contains(card))
    }

    @Test func aRememberedFrameStaysWholeOnTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offEdge = NSRect(x: 1300, y: 850, width: 600, height: 400)
        let fitted = EdgePeekLayout.fit(offEdge, in: screen)
        #expect(screen.contains(fitted))
        #expect(fitted.width == 600)
        #expect(fitted.height == 400)
    }

    @Test func aTinyRememberedFrameGrowsToTheMinimum() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let tiny = NSRect(x: 100, y: 100, width: 50, height: 40)
        let fitted = EdgePeekLayout.fit(tiny, in: screen)
        #expect(fitted.width == EdgePeekLayout.minimumSize.width)
        #expect(fitted.height == EdgePeekLayout.minimumSize.height)
    }

    @Test func aFrameLargerThanTheScreenIsCutToIt() {
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let large = NSRect(x: -100, y: -50, width: 1200, height: 1000)
        let fitted = EdgePeekLayout.fit(large, in: screen)
        #expect(fitted == screen)
    }
}

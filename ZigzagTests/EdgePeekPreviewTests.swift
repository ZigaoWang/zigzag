import AppKit
import Testing
@testable import Zigzag

@MainActor
struct EdgePeekPreviewTests {
    @Test func thePreviewWaitsAndStaysAwayWhileThePeekIsOut() {
        #expect(EdgePeekPreviewPolicy.delay > 0)
        #expect(EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: false))
        #expect(!EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: true))
        #expect(!EdgePeekPreviewPolicy.shouldShow(hovered: false, peekVisible: false))
    }
}

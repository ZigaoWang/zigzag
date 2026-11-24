import AppKit
import Testing
@testable import Zigzag

@MainActor
struct EdgePeekPreviewTests {
    @Test func thePreviewStaysAwayWhileThePeekIsOut() {
        #expect(EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: false))
        #expect(!EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: true))
        #expect(!EdgePeekPreviewPolicy.shouldShow(hovered: false, peekVisible: false))
    }
}

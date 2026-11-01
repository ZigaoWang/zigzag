import Foundation
import Testing
@testable import Zigzag

/// A session save asks WebKit for back/forward data only for tabs that could have changed since the last one.
struct TabStateCacheTests {
    let a = UUID(), b = UUID(), c = UUID()

    /// Two tabs saved once, `a` on screen.
    private func savedOnce() -> TabStateCache {
        var cache = TabStateCache()
        _ = cache.update(a, with: Data([1]))
        _ = cache.update(b, with: Data([2]))
        cache.finish(keeping: [a, b], shown: [a])
        return cache
    }

    @Test func afterOneNavigationOnlyThatTabIsEncoded() {
        var cache = savedOnce()
        // a stops being shown (b is now), so it's checked once more; then only what navigates or shows.
        cache.finish(keeping: [a, b], shown: [b])
        #expect(!cache.needsEncoding(a, navigated: false, shown: false))
        #expect(cache.needsEncoding(a, navigated: true, shown: false))
        #expect(cache.needsEncoding(b, navigated: false, shown: true))
    }

    @Test func aTabJustLeftIsEncodedOnceMore() {
        let cache = savedOnce()
        // Scrolled while on screen, then switched away before the next save: that save still asks for it.
        #expect(cache.needsEncoding(a, navigated: false, shown: false))
        #expect(!cache.needsEncoding(b, navigated: false, shown: false))
    }

    @Test func aNewTabIsAlwaysEncoded() {
        #expect(savedOnce().needsEncoding(c, navigated: false, shown: false))
    }

    @Test func onlyChangedDataIsWritten() {
        var cache = savedOnce()
        let same = cache.update(a, with: Data([1]))
        // Same length, different bytes: going Back is a change.
        let back = cache.update(a, with: Data([9]))
        #expect(!same)
        #expect(back)
    }

    @Test func closedTabsAreForgotten() {
        var cache = savedOnce()
        cache.finish(keeping: [a], shown: [])
        #expect(cache.saved[b] == nil)
        #expect(cache.needsEncoding(b, navigated: false, shown: false))
    }
}

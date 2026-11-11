import Foundation
import Testing
@testable import Zigzag

/// A session save asks WebKit for back/forward data only for tabs that could have changed since the last one.
struct TabStateCacheTests {
    let a = UUID(), b = UUID(), c = UUID()

    /// Two tabs saved once.
    private func savedOnce() -> TabStateCache {
        var cache = TabStateCache()
        _ = cache.update(a, with: Data([1]))
        _ = cache.update(b, with: Data([2]))
        cache.finish(keeping: [a, b])
        return cache
    }

    @Test func afterOneNavigationOnlyThatTabIsEncoded() {
        let cache = savedOnce()
        #expect(!cache.needsEncoding(a, changed: false))
        #expect(cache.needsEncoding(a, changed: true))
        #expect(!cache.needsEncoding(b, changed: false))
    }

    @Test func thePageOnScreenIsntEncodedAgainUntilItChanges() {
        // It was encoded at every save before (#89), for a scroll that may never have happened: a scroll now says so.
        let cache = savedOnce()
        #expect(!cache.needsEncoding(a, changed: false))
    }

    @Test func aNewTabIsAlwaysEncoded() {
        #expect(savedOnce().needsEncoding(c, changed: false))
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
        cache.finish(keeping: [a])
        #expect(cache.saved[b] == nil)
        #expect(cache.needsEncoding(b, changed: false))
    }
}

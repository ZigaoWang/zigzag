import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A change of network makes WebKit forget the HTTP/3 it kept, once the change settles, and only for a real change.
struct NetworkChangesTests {
    nonisolated private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var current: Int { lock.withLock { value } }
    }

    private func detector(_ count: Count) -> (NetworkChangeDetector, DispatchQueue) {
        let queue = DispatchQueue(label: "test.network-watch")
        return (NetworkChangeDetector(settle: 0.1, queue: queue) { count.add() }, queue)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    @Test func firstLookIsOnlyNoted() async throws {
        let count = Count()
        let (detector, queue) = detector(count)
        queue.sync { detector.note("wifi", from: "path"); detector.note("no proxy", from: "settings") }
        try await settle()
        #expect(count.current == 0)
    }

    @Test func sameNetworkAgainIsNoChange() async throws {
        let count = Count()
        let (detector, queue) = detector(count)
        queue.sync { detector.note("wifi", from: "path"); detector.note("wifi", from: "path") }
        try await settle()
        #expect(count.current == 0)
    }

    /// A TUN coming up changes the path and the DNS a moment apart: one forgetting, after both.
    @Test func aBurstSettlesIntoOne() async throws {
        let count = Count()
        let (detector, queue) = detector(count)
        queue.sync {
            detector.note("en0", from: "path")
            detector.note("dns a", from: "settings")
            detector.note("utun4,en0", from: "path")
            detector.note("dns b", from: "settings")
        }
        try await settle()
        #expect(count.current == 1)
        queue.sync { detector.note("en0", from: "path") }
        try await settle()
        #expect(count.current == 2)
    }

    /// If WebKit ever drops the type, this says so, instead of the forgetting quietly doing nothing.
    @MainActor @Test func webKitKnowsTheType() throws {
        let selector = NSSelectorFromString("_allWebsiteDataTypesIncludingPrivate")
        let types = try #require((WKWebsiteDataStore.self as AnyObject).perform(selector)?.takeUnretainedValue() as? Set<String>)
        #expect(types.contains(NetworkChanges.alternativeServices))
    }
}

import Foundation
import Testing
@testable import Zigzag

/// History's own file: a damaged one is set aside and history goes on, rather than quietly stopping for good.
@MainActor
struct HistoryStoreTests {
    @Test func aSiteIsNamedWithoutItsWWW() {
        #expect("www.example.com".withoutWWW == "example.com")
        #expect("example.com".withoutWWW == "example.com")
        #expect("www2.example.com".withoutWWW == "www2.example.com")
        #expect("wwwexample.com".withoutWWW == "wwwexample.com")
        #expect(HistoryStore.normalizedHost(URL(string: "https://WWW.Example.com/a")!) == "example.com")
    }

    @Test func startsAfreshFromADamagedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("History.sqlite")
        try Data(repeating: 0x5A, count: 8192).write(to: file)

        let store = HistoryStore(path: file.path)
        store.recordVisit(url: URL(string: "https://example.com/")!, title: "Example", at: Date(), count: 1)
        #expect(store.search("example").count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("History.sqlite.damaged-") })
    }

    /// Each profile's history is a file of its own: what's visited in one isn't found in, or removed from, another.
    @Test func twoProfilesHistoriesStayApart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = UUID()
        let first = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        let second = HistoryStore(path: folder.appendingPathComponent("Work.sqlite").path, profile: work)
        let shared = URL(string: "https://example.com/both")!
        first.recordVisit(url: shared, title: "Both", at: Date(), count: 1)
        first.recordVisit(url: URL(string: "https://example.com/home")!, title: "Home", at: Date(), count: 1)
        second.recordVisit(url: shared, title: "Both", at: Date(), count: 1)
        second.recordVisit(url: URL(string: "https://example.com/office")!, title: "Office", at: Date(), count: 1)

        #expect(first.search("office").isEmpty && second.search("home").isEmpty)
        #expect(first.completionSites(for: "example").count == 1)

        let removal = second.remove([shared])
        #expect(removal.profile == work && removal.visits.map(\.url) == [shared])
        #expect(first.search("both").count == 1 && second.search("both").isEmpty)
        second.restore(removal)
        #expect(second.search("both").count == 1)
    }

    /// The History page searches off the main thread: the same answer as the command bar's search, and a search the
    /// same tab typed over answers nothing, while another tab's goes on.
    @Test func searchesOffTheMainThreadAndTheNewestWins() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("History.sqlite")
        let store = HistoryStore(path: file.path)
        store.recordVisit(url: URL(string: "https://example.com/a")!, title: "上海 天气", at: Date(), count: 3)
        store.recordVisit(url: URL(string: "https://example.com/b")!, title: "Example B", at: Date(), count: 1)
        store.recordVisit(url: URL(string: "https://other.org/")!, title: "Other", at: Date(), count: 1)

        let urls = await store.search("Example", limit: 10, asker: 1) { $0.map(\.url) }
        #expect(urls == store.search("Example", limit: 10).map(\.url))
        #expect(await store.search("上海", limit: 10, asker: 1) { $0.count } == 1)

        let reader = HistoryReader(path: file.path)
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let first = Task.detached {
            await reader.search(["example"], limit: 10, asker: 1) { found in started.signal(); proceed.wait(); return found.count }
        }
        await Task.detached { wait(for: started) }.value
        let second = Task.detached { await reader.search(["example"], limit: 10, asker: 1) { $0.count } }
        let otherTab = Task.detached { await reader.search(["other"], limit: 10, asker: 2) { $0.count } }
        try await Task.sleep(for: .milliseconds(200))
        proceed.signal()
        #expect(await first.value == nil)
        #expect(await second.value == 2)
        #expect(await otherTab.value == 1)
    }
}

/// Waits on a semaphore from a plain function: async code may not.
nonisolated private func wait(for semaphore: DispatchSemaphore) { semaphore.wait() }

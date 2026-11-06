import Foundation
import Testing
@testable import Zigzag

/// History's own file: a damaged one is set aside and history goes on, rather than quietly stopping for good.
@MainActor
struct HistoryStoreTests {
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
}

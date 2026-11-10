import Foundation
import Testing
@testable import Zigzag

/// The command bar reads History off the main thread (#29): what you typed and everything at hand shows at once however
/// big History is, and History's pages join a moment later, only for the text still typed.
@MainActor
struct CommandBarHistoryTests {
    /// A History of its own in a temporary folder, never yours, with `count` made-up pages: a few thousand sites, a
    /// year of visits, and the words "zqfox" in one page in 50 and "zqab" in one in 7.
    static func store(count: Int) throws -> (HistoryStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        let words = ["news", "github", "swift", "weather", "recipe", "travel", "music", "video", "docs", "api", "guide",
                     "review", "price", "map", "shanghai", "browser", "design", "photo", "game", "sport", "market", "code"]
        var seed: UInt64 = 29
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let now = Date().timeIntervalSince1970
        var pages: [(URL, String, Int, Date)] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            let host = "site\(next(5000)).\(["com", "org", "net", "io"][next(4)])"
            var title = (0..<4).map { _ in words[next(words.count)] }.joined(separator: " ")
            if i % 50 == 0 { title += " zqfox" }
            if i % 7 == 0 { title += " zqab" }
            pages.append((URL(string: "https://\(host)/\(words[next(words.count)])/\(i)")!, title, 1 + next(40),
                          Date(timeIntervalSince1970: now - Double(next(30_000_000)))))
        }
        store.importVisits(pages)
        return (store, folder)
    }

    /// Waits for the lookup's next answer after `ask` (which asks History something) returns.
    static func answer(_ lookup: HistoryLookup, sites: Bool = false, after ask: () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if sites { lookup.onSites = { lookup.onSites = nil; done.resume() } } else { lookup.onPages = { lookup.onPages = nil; done.resume() } }
            ask()
        }
    }

    @Test func firstResultsNeverWaitOnHistory() async throws {
        let count = 100_000
        let (store, folder) = try Self.store(count: count)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lookup = HistoryLookup(store: store)
        let limit = CommandRanker.historyLimit(historyOnly: false)
        let clock = ContinuousClock()

        // Taken before the clock starts: what's timed is the results, not the first use of the profile.
        let profile = Profiles.shared.default
        var instant: [CommandResult] = []
        var onMain = Duration.zero
        let start = clock.now
        await Self.answer(lookup) {
            onMain = clock.measure {
                let pages = lookup.pages(for: "zqfox", limit: limit)
                instant = CommandRanker.results(for: "zqfox", manager: nil, profile: profile, suggestions: [], history: pages, editingCurrent: false, historyOnly: false)
            }
        }
        let read = clock.now - start
        // What you typed is the first row at once, before History has a word to say.
        #expect(onMain < .milliseconds(5))
        #expect(instant.first?.kind == .search("zqfox"))

        // Then History's pages, the same ones as reading it right here, under what you typed.
        let pages = try #require(lookup.pages(for: "zqfox", limit: limit))
        let direct = clock.measure { #expect(pages.map(\.url) == store.search("zqfox", limit: limit).map(\.url)) }
        #expect(!pages.isEmpty)
        let merged = CommandRanker.results(for: "zqfox", manager: nil, profile: Profiles.shared.default, suggestions: [], history: pages, editingCurrent: false, historyOnly: false)
        #expect(merged.first?.kind == .search("zqfox"))
        #expect(merged.dropFirst().prefix(4).map(\.kind) == pages.prefix(4).map { .history($0.url) })
        print("History of \(count) pages: \(onMain) on the main thread, answer in \(read); reading it on the main thread takes \(direct)")
    }

    @Test func aLateAnswerForOlderTextIsDropped() async throws {
        let (store, folder) = try Self.store(count: 20_000)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lookup = HistoryLookup(store: store)
        var answers = 0
        await Self.answer(lookup) {
            _ = lookup.pages(for: "zqfox", limit: 8)
            // Typed over at once: only the newer text's pages ever arrive.
            #expect(lookup.pages(for: "zqab", limit: 8) == nil)
        }
        answers += 1
        lookup.onPages = { answers += 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(answers == 1)
        let pages = try #require(lookup.pages(for: "zqab", limit: 8))
        #expect(pages.map(\.url) == store.search("zqab", limit: 8).map(\.url))

        // One more letter: the pages showing that still match stay while the new answer is read.
        let meanwhile = try #require(lookup.pages(for: "zqab 0", limit: 8))
        #expect(meanwhile.allSatisfy { CommandRanker.matches(["zqab", "0"], $0.title, $0.url.absoluteString) })
        #expect(meanwhile.map(\.url) == pages.filter { CommandRanker.matches(["zqab", "0"], $0.title, $0.url.absoluteString) }.map(\.url))
    }

    @Test func aLetterTypedAndDeletedKeepsTheAnswerShowing() async throws {
        let (store, folder) = try Self.store(count: 20_000)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lookup = HistoryLookup(store: store)
        await Self.answer(lookup) { _ = lookup.pages(for: "zqab", limit: 8) }
        let shown = try #require(lookup.pages(for: "zqab", limit: 8))
        // A letter, and straight back: the answer for the letter, still coming, never replaces what's showing.
        _ = lookup.pages(for: "zqab 0", limit: 8)
        #expect(lookup.pages(for: "zqab", limit: 8)?.map(\.url) == shown.map(\.url))
        var answers = 0
        lookup.onPages = { answers += 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(answers == 0)
        #expect(lookup.pages(for: "zqab", limit: 8)?.map(\.url) == shown.map(\.url))
    }

    /// Searching history: no "Nothing in your history matches" while History is still being read.
    @Test func searchingHistorySaysNothingMatchesOnlyOnceItKnows() {
        let reading = CommandRanker.results(for: "zqnothing", manager: nil, profile: Profiles.shared.default, suggestions: [], history: nil, editingCurrent: false, historyOnly: true)
        #expect(reading.isEmpty)
        let read = CommandRanker.results(for: "zqnothing", manager: nil, profile: Profiles.shared.default, suggestions: [], history: [], editingCurrent: false, historyOnly: true)
        #expect(read.map(\.kind) == [.search("zqnothing")])
    }

    @Test func inlineCompletionSitesArriveOffTheMainThread() async throws {
        let (store, folder) = try Self.store(count: 20_000)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lookup = HistoryLookup(store: store)
        await Self.answer(lookup, sites: true) { #expect(lookup.completionSites(for: "site12") == nil) }
        let sites = try #require(lookup.completionSites(for: "site12"))
        #expect(sites.map(\.entry.url) == store.completionSites(for: "site12").map(\.entry.url))
        #expect(!sites.isEmpty)
        // No host starts with it: hosts where it starts a later label, as before.
        await Self.answer(lookup, sites: true) { #expect(lookup.completionSites(for: "com") == nil) }
        let later = try #require(lookup.completionSites(for: "com"))
        #expect(!later.isEmpty)
        #expect(later.map(\.entry.url) == store.completionSites(for: "com", afterSubdomain: true).map(\.entry.url))
    }
}

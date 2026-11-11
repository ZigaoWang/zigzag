import AppKit
import Foundation
import SQLite3
import Testing
@testable import Zigzag

/// Lets the main queue run what was put on it for `seconds`.
@MainActor private func settle(_ seconds: Double = 0.05) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// Work that came in bursts on the main thread (#89) runs once for the burst.
@MainActor struct CoalescerTests {
    @Test func aBurstRunsOnceAtTheNextTurn() async {
        let coalescer = Coalescer()
        var runs = 0
        for _ in 0..<200 { coalescer.schedule { runs += 1 } }
        #expect(runs == 0)
        #expect(coalescer.isPending)
        await settle()
        #expect(runs == 1)
        #expect(!coalescer.isPending)
    }

    @Test func aDelayedBurstRunsOnceAfterTheDelay() async {
        let coalescer = Coalescer()
        var runs = 0
        for _ in 0..<100 { coalescer.schedule(after: 0.1) { runs += 1 } }
        await settle(0.03)
        #expect(runs == 0)
        await settle(0.2)
        #expect(runs == 1)
    }

    @Test func askingForSoonerBringsItForward() async {
        let coalescer = Coalescer()
        var runs = 0
        coalescer.schedule(after: 5) { runs += 1 }
        coalescer.schedule { runs += 1 }
        await settle()
        #expect(runs == 1)
        // The later one was folded in, not left to run again.
        #expect(!coalescer.isPending)
    }

    @Test func aBurstThatNeverStopsStillRuns() async {
        let coalescer = Coalescer()
        var runs = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 0.35 {
            coalescer.schedule(after: 0.1) { runs += 1 }
            await settle(0.01)
        }
        // A Debouncer would still be waiting for a pause.
        #expect(runs >= 1)
    }

    @Test func cancelledNeverRuns() async {
        let coalescer = Coalescer()
        var runs = 0
        coalescer.schedule { runs += 1 }
        coalescer.cancel()
        await settle()
        #expect(runs == 0)
    }

    @available(macOS 15.4, *)
    @Test func aButtonUpdateConcernsOnlyTheTabShownOrEveryTab() {
        let shown = NSObject(), other = NSObject()
        #expect(ExtensionCenter.update(for: nil, concerns: shown))
        #expect(ExtensionCenter.update(for: shown, concerns: shown))
        #expect(!ExtensionCenter.update(for: other, concerns: shown))
        #expect(!ExtensionCenter.update(for: other, concerns: nil))
    }

    @available(macOS 15.4, *)
    @Test func manyChangesInOneTurnAreSaidOnce() async {
        var heard = 0
        let token = ExtensionCenter.changed.observe { heard += 1 }
        for _ in 0..<50 { ExtensionCenter.noteChanged() }
        #expect(heard == 0)
        await settle()
        #expect(heard == 1)
        token.cancel()
    }
}

/// What extensions' files say is read once and kept until Zigzag changes them (#89): every web view made and every
/// sign-in field focused asked again, a dozen file reads each.
@MainActor struct ExtensionReadCacheTests {
    private let packageKeys = ["version", "pendingVersion", "unpackedPath"]
    private let stateKeys = ["enabled", "grantedPermissions", "grantedMatchPatterns", "siteAccess", "accessSites"]

    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("state.json")
    }

    @Test func askingAgainReadsNothing() throws {
        let file = try file()
        ExtensionStore.write(ExtensionInstalls.State(enabled: true), keys: stateKeys, to: file)
        let before = ExtensionStore.reads
        for _ in 0..<100 { #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file)?.enabled == true) }
        #expect(ExtensionStore.reads == before + 1)
    }

    @Test func aMissingFileIsRememberedAsMissing() throws {
        let file = try file()
        let before = ExtensionStore.reads
        for _ in 0..<10 { #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file) == nil) }
        #expect(ExtensionStore.reads == before + 1)
    }

    @Test func eachKindOfRecordInOneFileIsItsOwn() throws {
        let file = try file()
        ExtensionStore.write(ExtensionStore.Package(version: "1.0"), keys: packageKeys, to: file)
        ExtensionStore.write(ExtensionInstalls.State(enabled: false), keys: stateKeys, to: file)
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.version == "1.0")
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file)?.enabled == false)
    }

    @Test func aWriteIsSeenAtOnce() throws {
        let file = try file()
        ExtensionStore.write(ExtensionInstalls.State(enabled: true), keys: stateKeys, to: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file)?.enabled == true)
        ExtensionStore.write(ExtensionInstalls.State(enabled: false), keys: stateKeys, to: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file)?.enabled == false)
    }

    @Test func removingIsSeenAtOnce() throws {
        let file = try file()
        ExtensionStore.write(ExtensionStore.Package(version: "1.0"), keys: packageKeys, to: file)
        ExtensionStore.write(ExtensionInstalls.State(), keys: stateKeys, to: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file) != nil)
        ExtensionStore.remove(keys: stateKeys, from: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file) == nil)
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.version == "1.0")
    }

    @Test func aChangeMadeElsewhereIsReadOnceForgotten() throws {
        let file = try file()
        ExtensionStore.write(ExtensionStore.Package(version: "1.0"), keys: packageKeys, to: file)
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.version == "1.0")
        try Data(#"{"version":"2.0"}"#.utf8).write(to: file)
        // Coming to the front, or Zigzag removing a folder, forgets what was read.
        ExtensionStore.forgetWhatWasRead()
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.version == "2.0")
    }

    @Test func anAnswerWorkedOutIsKeptUntilTheFilesChange() throws {
        var remembered = Remembered<Int>()
        var made = 0
        let generation = ExtensionStore.generation
        for _ in 0..<5 { _ = remembered.value(at: generation) { made += 1; return made } }
        #expect(made == 1)
        let file = try file()
        ExtensionStore.write(ExtensionInstalls.State(), keys: stateKeys, to: file)
        #expect(ExtensionStore.generation != generation)
        #expect(remembered.value(at: ExtensionStore.generation) { made += 1; return made } == 2)
    }
}

/// Tabs going to sleep together go a few at a time, in the order they were chosen (#89).
@MainActor struct StagedSleepTests {
    @Test func nothingRunsInsideTheCaller() {
        let queue = StagedQueue<Int>(perStep: 2, interval: 0.1)
        var ran: [Int] = []
        for i in 0..<5 { queue.add(i) { ran.append(i) } }
        #expect(ran.isEmpty)
        #expect(queue.pending == [0, 1, 2, 3, 4])
    }

    @Test func twoAtATimeInOrder() async {
        let queue = StagedQueue<Int>(perStep: 2, interval: 0.4)
        var ran: [Int] = []
        for i in 0..<7 { queue.add(i) { ran.append(i) } }
        await settle(0.1)
        #expect(ran == [0, 1])
        await settle(1.5)
        #expect(ran == Array(0..<7))
        #expect(queue.pending.isEmpty)
    }

    @Test func addedAgainKeepsItsPlaceAndRunsOnceWithTheNewerWork() async {
        let queue = StagedQueue<String>(perStep: 1, interval: 0.02)
        var ran: [String] = []
        queue.add("a") { ran.append("a1") }
        queue.add("b") { ran.append("b") }
        queue.add("a") { ran.append("a2") }
        #expect(queue.pending == ["a", "b"])
        await settle(0.2)
        #expect(ran == ["a2", "b"])
    }

    @Test func removedNeverRuns() async {
        let queue = StagedQueue<Int>(perStep: 2, interval: 0.02)
        var ran: [Int] = []
        for i in 0..<3 { queue.add(i) { ran.append(i) } }
        queue.remove(1)
        await settle(0.2)
        #expect(ran == [0, 2])
    }

    @Test func aRepeatedWarningLooksAgainOnlyAfterAWhileOrWhenMemoryGetsShorter() {
        let now = Date()
        #expect(TabSleep.looksAgain(at: now, lastLook: nil, lastLevel: .normal, level: .low))
        #expect(!TabSleep.looksAgain(at: now, lastLook: now.addingTimeInterval(-5), lastLevel: .low, level: .low))
        #expect(TabSleep.looksAgain(at: now, lastLook: now.addingTimeInterval(-5), lastLevel: .low, level: .critical))
        #expect(!TabSleep.looksAgain(at: now, lastLook: now.addingTimeInterval(-5), lastLevel: .critical, level: .critical))
        #expect(TabSleep.looksAgain(at: now, lastLook: now.addingTimeInterval(-31), lastLevel: .critical, level: .low))
    }

    @Test func cleaningTextStillCutsAddressesAndEmails() {
        let text = "Failed https://example.com/reset?token=abc for me@example.org"
        #expect(Diagnostics.clean(text) == "Failed example.com for (email)")
        // Made once, used many times: a thousand notes take no time to speak of.
        let start = Date()
        for _ in 0..<1000 { _ = Diagnostics.clean(text) }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

/// The session is written off the main thread, and only when it says something new (#89).
struct SessionSaveTests {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Session.json")
    }

    private func state(_ url: String, title: String = "Page") -> SessionState {
        let tab = SessionState.TabState(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, url: URL(string: url), title: title,
                                        lastActivated: Date(timeIntervalSince1970: 100), createdAt: Date(timeIntervalSince1970: 50))
        let space = SessionState.SpaceTabs(spaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, tabs: [tab], selectedTabID: tab.id)
        let window = SessionState.WindowState(frame: [0, 0, 800, 600], sidebarVisible: true, sidebarWidth: 240,
                                              currentSpaceID: space.spaceID, spaces: [space], bookmarkTabs: [])
        return SessionState(windows: [window])
    }

    @Test func theSameSessionIsWrittenOnce() throws {
        let file = try file(), writer = SessionFileWriter()
        #expect(writer.write(state("https://example.com/a"), to: file))
        #expect(!writer.write(state("https://example.com/a"), to: file))
        #expect(JSONStore.load(SessionState.self, from: file)?.windows.first?.spaces.first?.tabs.first?.url?.absoluteString == "https://example.com/a")
    }

    @Test func aChangedSessionIsWritten() throws {
        let file = try file(), writer = SessionFileWriter()
        writer.write(state("https://example.com/a"), to: file)
        #expect(writer.write(state("https://example.com/b"), to: file))
        #expect(writer.write(state("https://example.com/b", title: "Renamed"), to: file))
        #expect(JSONStore.load(SessionState.self, from: file)?.windows.first?.spaces.first?.tabs.first?.title == "Renamed")
    }

    @Test func aWriteThatFailedIsTriedAgain() throws {
        let writer = SessionFileWriter()
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Session.json")
        #expect(!writer.write(state("https://example.com/a"), to: nowhere))
        let file = try file()
        #expect(writer.write(state("https://example.com/a"), to: file))
    }

    @Test func writtenOffTheMainThreadInOrder() async throws {
        let file = try file(), writer = SessionFileWriter()
        let queue = DispatchQueue(label: "test.session")
        for i in 0..<20 {
            let next = state("https://example.com/\(i)")
            queue.async { writer.write(next, to: file) }
        }
        await withCheckedContinuation { done in queue.async { done.resume() } }
        #expect(JSONStore.load(SessionState.self, from: file)?.windows.first?.spaces.first?.tabs.first?.url?.absoluteString == "https://example.com/19")
    }
}

/// A site learned dark puts new scripts only into the pages going to that site (#89).
struct DarkPagesReinstallTests {
    @Test func onlyThePageGoingToASiteThatChangedGetsANewScript() {
        let given: Set<String> = ["dark.test"]
        // Some other site was learned: nothing the page going to example.com reads has changed.
        #expect(!DarkPages.siteChanged("example.com", given: given, now: ["dark.test", "other.test"]))
        // Its own site joined, or left, the list.
        #expect(DarkPages.siteChanged("other.test", given: given, now: ["dark.test", "other.test"]))
        #expect(DarkPages.siteChanged("dark.test", given: given, now: []))
        #expect(!DarkPages.siteChanged("dark.test", given: given, now: given))
        // A page with no site (a blank page) reads none of it.
        #expect(!DarkPages.siteChanged(nil, given: given, now: []))
    }
}

/// History is written on a queue of its own, in order, and read after what was written before (#89).
@MainActor struct HistoryQueueTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-history-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func whatWasJustRecordedIsFound() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        for i in 0..<50 { store.recordVisit(url: URL(string: "https://example.com/\(i)")!, title: "Page \(i)") }
        store.updateTitle("Renamed", for: URL(string: "https://example.com/7")!)
        #expect(store.search("example", limit: 100).count == 50)
        #expect(store.item(for: URL(string: "https://example.com/7")!)?.entry.title == "Renamed")
    }

    @Test func clearingComesAfterTheVisitsBeforeIt() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        for i in 0..<20 { store.recordVisit(url: URL(string: "https://example.com/\(i)")!, title: nil) }
        let removal = store.remove()
        // Every visit recorded before it went with it: none lands after and stays.
        #expect(removal.visits.count == 20)
        #expect(store.recent(limit: 50).isEmpty)
        store.recordVisit(url: URL(string: "https://example.com/after")!, title: nil)
        #expect(store.recent(limit: 50).map(\.url.absoluteString) == ["https://example.com/after"])
    }

    @Test func aVisitDoesntWaitForAnotherConnectionsLock() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("History.sqlite").path
        let store = HistoryStore(path: path)
        _ = store.recent()
        // Another Zigzag (an update relaunching) holding the file: the main thread used to wait up to two seconds.
        var other: OpaquePointer?
        #expect(sqlite3_open(path, &other) == SQLITE_OK)
        #expect(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let started = Date()
        for i in 0..<5 { store.recordVisit(url: URL(string: "https://example.com/\(i)")!, title: nil) }
        let took = Date().timeIntervalSince(started)
        #expect(took < 0.05, "recording took \(Int(took * 1000)) ms")
        sqlite3_exec(other, "COMMIT", nil, nil, nil)
        sqlite3_close(other)
        #expect(store.recent(limit: 10).count == 5)
    }

    @Test func anExtensionHearsOfAVisitOnceItCanBeLookedUp() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        var found: [String] = []
        store.onVisit = { url in if store.item(for: url) != nil { found.append(url.absoluteString) } }
        store.recordVisit(url: URL(string: "https://example.com/heard")!, title: "Heard")
        #expect(found.isEmpty)
        await settle(0.2)
        #expect(found == ["https://example.com/heard"])
        store.onVisit = nil
    }

    @Test func aSearchOffTheMainThreadFindsWhatWasJustRecorded() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        for i in 0..<10 { store.recordVisit(url: URL(string: "https://example.com/\(i)")!, title: nil) }
        #expect(await store.search("example", limit: 20, asker: 1) { $0.count } == 10)
    }
}

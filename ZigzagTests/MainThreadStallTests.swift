import AppKit
import Foundation
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
        #expect(runs >= 2)
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

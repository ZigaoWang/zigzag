import Foundation
import Testing
@testable import Zigzag

/// The install queue, with the store stubbed out: one at a time, in order, and a failure never stops the rest.
@MainActor
struct ExtensionImportQueueTests {
    final class Log {
        var calls: [String] = []
        var running = 0
        var mostAtOnce = 0
        var discarded: [String] = []
    }

    static func found(_ letter: Character, _ name: String) -> ChromiumExtensions.Found {
        ChromiumExtensions.Found(id: String(repeating: letter, count: 32), name: name, source: "Chrome")
    }

    static func steps(_ log: Log, failPrepare: [String: ExtensionStore.InstallError] = [:],
                      failFinish: [String: ExtensionStore.InstallError] = [:]) -> ExtensionImport.Steps<String> {
        ExtensionImport.Steps(
            prepare: { id in
                log.calls.append("prepare \(id.prefix(1))")
                log.running += 1
                log.mostAtOnce = max(log.mostAtOnce, log.running)
                await Task.yield()
                log.running -= 1
                if let error = failPrepare[id] { return .failure(error) }
                return .success(id)
            },
            finish: { id in
                log.calls.append("finish \(id.prefix(1))")
                log.running += 1
                log.mostAtOnce = max(log.mostAtOnce, log.running)
                await Task.yield()
                log.running -= 1
                if let error = failFinish[id] { return .failure(error) }
                return .success("Name \(id.prefix(1))")
            },
            discard: { log.discarded.append(String($0.prefix(1))) },
            pause: .zero)
    }

    @Test func preparesThenAddsOneAtATimeInOrder() async {
        let log = Log()
        let items = [Self.found("a", "A"), Self.found("b", "B"), Self.found("c", "C")]
        let steps = Self.steps(log)
        let prepared = await ExtensionImport.prepare(items, with: steps)
        #expect(prepared.ready.map(\.1) == items.map(\.id))
        let result = await ExtensionImport.install(prepared.ready, with: steps)
        #expect(log.calls == ["prepare a", "prepare b", "prepare c", "finish a", "finish b", "finish c"])
        #expect(log.mostAtOnce == 1)
        #expect(result.added.map(\.1) == ["Name a", "Name b", "Name c"])
        #expect(result.failed.isEmpty)
    }

    @Test func listsFailuresAndCarriesOn() async {
        let log = Log()
        let a = Self.found("a", "Gone"), b = Self.found("b", "Fine"), c = Self.found("c", "Unsupported")
        let steps = Self.steps(log, failPrepare: [a.id: .notListed], failFinish: [c.id: .unsupported])
        let prepared = await ExtensionImport.prepare([a, b, c], with: steps)
        #expect(prepared.ready.map(\.0) == [b, c])
        #expect(prepared.failed == [ExtensionImport.Failure(found: a, reason: ExtensionStore.InstallError.notListed.reason)])
        let result = await ExtensionImport.install(prepared.ready, with: steps)
        #expect(result.added.map(\.0) == [b])
        #expect(result.failed == [ExtensionImport.Failure(found: c, reason: ExtensionStore.InstallError.unsupported.reason)])
        // What failed to get ready is never added.
        #expect(!log.calls.contains("finish a"))
    }

    @Test func stoppingThrowsAwayWhatsNotAdded() async {
        let log = Log()
        let items = [Self.found("a", "A"), Self.found("b", "B"), Self.found("c", "C")]
        let steps = Self.steps(log)
        let ready = items.map { ($0, $0.id) }
        let task = Task { @MainActor in
            await ExtensionImport.install(ready, with: steps) { index, _ in if index == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        let result = await task.value
        // The one under way when it stopped finishes; the rest are thrown away, never half added.
        #expect(result.added.map(\.0.id) == [items[0].id, items[1].id])
        #expect(log.discarded == ["c"])
    }

    @Test func progressNamesEachInTurn() async {
        let log = Log()
        let items = [Self.found("a", "A"), Self.found("b", "B")]
        var seen: [String] = []
        _ = await ExtensionImport.install(items.map { ($0, $0.id) }, with: Self.steps(log)) { index, item in seen.append("\(index) \(item.name)") }
        #expect(seen == ["0 A", "1 B"])
    }
}

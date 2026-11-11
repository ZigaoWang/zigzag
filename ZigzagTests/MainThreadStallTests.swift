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

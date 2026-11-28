import AppKit
import Testing
@testable import Zigzag

/// The loading line tells the truth: it goes where the page goes and stops where the page stops (#548).
@MainActor
@Suite(.serialized)
struct LoadingLineTests {
    /// The line, on a card, on a Mac where motion isn't reduced, so nothing is left out for accessibility.
    private func line(_ body: (PageCardView) async throws -> Void) async rethrows {
        let saved = Tokens.Motion.debugReduceMotion
        Tokens.Motion.debugReduceMotion = false
        defer { Tokens.Motion.debugReduceMotion = saved }
        try await body(PageCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)))
    }

    /// A line that goes on by itself after the page stopped is a claim about a page that isn't moving: the one thing
    /// the line must never do.
    @Test func theLineStaysWhereThePageStopped() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.12)
            #expect(card.debugProgress == 0.12)
            try await Task.sleep(for: .milliseconds(1200))
            // Two of the old creep's steps at least: nothing arrived, so nothing moved.
            #expect(card.debugProgress == 0.12)
        }
    }

    /// A new request mid-load reports WebKit's starting 0.1 for a moment and then the load's own value again
    /// (measured: 0.50, 0.10, 0.50 within 5 ms). The line doesn't dip and bounce back for it.
    @Test func aMomentaryRestartDoesNotDipTheLine() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.5)
            card.debugShowLoading(true, progress: 0.1)
            #expect(card.debugProgress == 0.5)
            card.debugShowLoading(true, progress: 0.5)
            #expect(card.debugProgress == 0.5)
            try await Task.sleep(for: .milliseconds(300))
            #expect(card.debugProgress == 0.5)
        }
    }

    /// A new page opened while the last one is still finishing starts over at 0.1 and stays there until it answers
    /// (measured: 0.86, then 0.10 for 245 ms). The line goes back with it rather than keeping the old page's number.
    @Test func aNewPageMidLoadTakesTheLineBack() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.86)
            card.debugShowLoading(true, progress: 0.1)
            try await Task.sleep(for: .milliseconds(300))
            #expect(card.debugProgress == 0.1)
            card.debugShowLoading(true, progress: 0.23)
            #expect(card.debugProgress == 0.23)
        }
    }

    /// A page that never answers sits at the start and stays there. This is the case the line was lying about: a
    /// socket that is dead must not look like a page that is 90% done.
    @Test func aPageThatNeverAnswersStaysAtTheStart() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.1)
            try await Task.sleep(for: .milliseconds(1200))
            #expect(card.debugProgress == 0.1)
        }
    }

    /// Held still, the line shows it's waiting; the next visible step ends the wait.
    @Test func aStillLineShowsItsWaitingUntilThePageMoves() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.1)
            #expect(!card.debugIsWaiting)
            try await Task.sleep(for: .milliseconds(1300))
            #expect(card.debugIsWaiting)
            // Too little to see is still waiting.
            card.debugShowLoading(true, progress: 0.102)
            #expect(card.debugIsWaiting)
            card.debugShowLoading(true, progress: 0.3)
            #expect(!card.debugIsWaiting)
        }
    }

    /// A page that keeps moving never looks like it's waiting.
    @Test func aMovingLineNeverWaits() async throws {
        try await line { card in
            for step in 1...6 {
                card.debugShowLoading(true, progress: 0.1 + Double(step) * 0.1)
                try await Task.sleep(for: .milliseconds(400))
                #expect(!card.debugIsWaiting)
            }
        }
    }

    /// Done is the whole line, from wherever it was, and the wait is over.
    @Test func theLineFinishesWhereItWas() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.35)
            card.debugShowLoading(false, progress: 0.35)
            #expect(card.debugProgress == 1)
            #expect(!card.debugIsWaiting)
        }
    }
}

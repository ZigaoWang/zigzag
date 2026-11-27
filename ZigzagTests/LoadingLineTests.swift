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

    /// The page is the only thing that moves it, and it moves it both ways. WebKit's estimate only rises within one
    /// load, but a new request in the same tab starts it over (`ProgressTracker::progressStarted` sets
    /// `initialProgressValue`, 0.1), so a smaller value does arrive and the line shows it rather than keeping the
    /// larger one. A line that can't go back keeps a number nothing is at — which is what made the creep permanent.
    @Test func theLineFollowsThePageBackwardsToo() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.7)
            #expect(card.debugProgress == 0.7)
            card.debugShowLoading(true, progress: 0.2)
            #expect(card.debugProgress == 0.2)
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

    /// Done is the whole line, from wherever it was.
    @Test func theLineFinishesWhereItWas() async throws {
        try await line { card in
            card.debugShowLoading(true, progress: 0.35)
            card.debugShowLoading(false, progress: 0.35)
            #expect(card.debugProgress == 1)
        }
    }
}

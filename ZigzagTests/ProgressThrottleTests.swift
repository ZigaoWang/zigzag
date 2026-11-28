import Foundation
import Testing
@testable import Zigzag

/// The progress throttle reports at most four times a second, and always reports the last sample it was given.
/// A download that stops arriving is the case that matters: WebKit sends nothing more, so a folded sample has to
/// be sent on the throttle's own schedule or the row keeps a figure from before the stall.
struct ProgressThrottleTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private final class Scheduler {
        var blocks: [(TimeInterval, () -> Void)] = []
        func run() {
            let pending = blocks
            blocks = []
            for (_, block) in pending { block() }
        }
    }

    private func harness(interval: TimeInterval = 0.25)
        -> (ProgressThrottle, Clock, Scheduler, () -> [ProgressThrottle.Sample]) {
        let clock = Clock()
        let scheduler = Scheduler()
        var sent: [ProgressThrottle.Sample] = []
        let throttle = ProgressThrottle(
            interval: interval,
            now: { clock.now },
            schedule: { delay, work in scheduler.blocks.append((delay, work)) },
            deliver: { sent.append($0) }
        )
        return (throttle, clock, scheduler, { sent })
    }

    private func sample(_ fraction: Double, _ completed: Int64 = 0, _ total: Int64 = 100) -> ProgressThrottle.Sample {
        .init(fraction: fraction, completed: completed, total: total)
    }

    @Test func theFirstReportGoesAtOnce() {
        let (throttle, _, _, sent) = harness()
        throttle.report(sample(0.1))
        #expect(sent() == [sample(0.1)])
    }

    @Test func aReportInsideTheWindowWaitsForTheWindowToEnd() {
        let (throttle, clock, scheduler, sent) = harness()
        throttle.report(sample(0.1))
        clock.advance(0.1)
        throttle.report(sample(0.2))

        // Still only the leading report, and exactly one send has been scheduled.
        #expect(sent() == [sample(0.1)])
        #expect(scheduler.blocks.count == 1)

        clock.advance(0.15)
        scheduler.run()
        #expect(sent() == [sample(0.1), sample(0.2)])
    }

    @Test func theLastSampleOfAStallIsTheOneThatArrives() {
        let (throttle, clock, scheduler, sent) = harness()
        throttle.report(sample(0.1))
        clock.advance(0.1)
        throttle.report(sample(0.2))
        clock.advance(0.05)
        throttle.report(sample(0.3))
        clock.advance(0.05)
        throttle.report(sample(0.4))

        // No further report ever comes; the window ends and the newest folded sample is sent.
        clock.advance(0.1)
        scheduler.run()
        #expect(sent() == [sample(0.1), sample(0.4)])
    }

    @Test func aReportAfterTheWindowSendsAtOnceAndDropsTheFoldedOne() {
        let (throttle, clock, scheduler, sent) = harness()
        throttle.report(sample(0.1))
        clock.advance(0.1)
        throttle.report(sample(0.2))

        clock.advance(0.2)
        throttle.report(sample(0.3))
        #expect(sent() == [sample(0.1), sample(0.3)])

        // The trailing send that was scheduled for the folded sample must not deliver it afterwards.
        scheduler.run()
        #expect(sent() == [sample(0.1), sample(0.3)])
    }

    @Test func theFinishIsNeverHeldBack() {
        let (throttle, clock, _, sent) = harness()
        throttle.report(sample(0.9))
        clock.advance(0.01)
        throttle.report(sample(1, 100, 100))
        #expect(sent() == [sample(0.9), sample(1, 100, 100)])
    }

    @Test func onlyOneTrailingSendIsEverScheduled() {
        let (throttle, clock, scheduler, _) = harness()
        throttle.report(sample(0.1))
        clock.advance(0.05)
        throttle.report(sample(0.2))
        clock.advance(0.05)
        throttle.report(sample(0.3))
        #expect(scheduler.blocks.count == 1)
    }
}

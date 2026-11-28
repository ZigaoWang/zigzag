import Foundation
import os

/// Sends a download's progress at most once per interval, and never less than the last sample reported.
///
/// WebKit reports a download's progress hundreds of times a second while bytes arrive and then stops reporting
/// entirely when they stop. Sending every report would have the row, the Dock and every window redraw at that
/// rate, so reports inside the interval are folded into one; that one is sent when the interval ends even if
/// WebKit has gone quiet, which is the only way a stalled download can show the progress it actually reached.
nonisolated final class ProgressThrottle: @unchecked Sendable {
    struct Sample: Equatable {
        let fraction: Double
        let completed: Int64
        let total: Int64
    }

    private let interval: TimeInterval
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let deliver: (Sample) -> Void

    private struct State {
        var lastSent = Date.distantPast
        var pending: Sample?
        var trailingScheduled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - interval: the shortest gap between two sends.
    ///   - now: the clock, so a test can move it.
    ///   - schedule: runs its block after a delay, off the caller's thread; a test can keep the block and fire it.
    ///   - deliver: called with each sample that is due, in order, at most once per interval.
    init(
        interval: TimeInterval = 0.25,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        },
        deliver: @escaping (Sample) -> Void
    ) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
        self.deliver = deliver
    }

    func report(_ sample: Sample) {
        // Everything happens under the lock, and each delivery is enqueued inside it, so two threads reporting at
        // once cannot deliver out of order or leave a trailing send for a sample that has already been superseded.
        state.withLock { state in
            let stamp = now()
            let due = sample.fraction >= 1 || stamp.timeIntervalSince(state.lastSent) >= interval

            if due {
                state.lastSent = stamp
                state.pending = nil
                deliver(sample)
                return
            }

            state.pending = sample
            guard !state.trailingScheduled else { return }

            state.trailingScheduled = true
            let delay = max(0, interval - stamp.timeIntervalSince(state.lastSent))
            schedule(delay) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Sends the sample that was folded away, once its interval has ended.
    private func flush() {
        state.withLock { state in
            state.trailingScheduled = false
            guard let sample = state.pending else { return }
            state.pending = nil
            state.lastSent = now()
            deliver(sample)
        }
    }
}

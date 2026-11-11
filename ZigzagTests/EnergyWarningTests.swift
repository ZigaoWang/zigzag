import Foundation
import Testing
@testable import Zigzag

/// A busy background tab is warned about before it sleeps, never put to sleep at once.
struct EnergyWarningTests {
    let now = Date()

    @Test func busyLongEnoughWarnsFirst() {
        #expect(EnergyWatch.step(streak: 18, busy: true, deadline: nil, now: now) == .warn)
        #expect(EnergyWatch.step(streak: 17, busy: true, deadline: nil, now: now) == .none)
        #expect(EnergyWatch.step(streak: 30, busy: false, deadline: nil, now: now) == .none)
    }

    @Test func sleepsOnlyOnceTheWarningRunsOut() {
        let later = now.addingTimeInterval(EnergyWatch.grace)
        #expect(EnergyWatch.step(streak: 3, busy: true, deadline: later, now: now) == .none)
        #expect(EnergyWatch.step(streak: 3, busy: true, deadline: later, now: later) == .sleep)
    }

    @Test func calmingDownCancelsTheWarning() {
        let later = now.addingTimeInterval(EnergyWatch.grace)
        #expect(EnergyWatch.step(streak: 0, busy: false, deadline: later, now: later) == .calm)
    }

    @Test func warningGivesTwoMinutes() {
        #expect(EnergyWatch.grace == 120)
    }
}

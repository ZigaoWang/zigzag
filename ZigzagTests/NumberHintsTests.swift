import AppKit
import Testing
@testable import Zigzag

/// ⌘1–⌘9 and the numbers holding ⌘ shows on the sidebar's places: each shown number goes where it says, and only
/// ⌘ held alone a moment shows them.
struct NumberHintsTests {
    @Test func numbersGoToTheirPlaceAndNineToTheLast() {
        #expect(TabNumbers.index(for: 1, count: 0) == nil)
        #expect(TabNumbers.index(for: 1, count: 12) == 0)
        #expect(TabNumbers.index(for: 8, count: 12) == 7)
        #expect(TabNumbers.index(for: 9, count: 12) == 11)
        #expect(TabNumbers.index(for: 9, count: 3) == 2)
        // Past the end: the last, as before.
        #expect(TabNumbers.index(for: 5, count: 3) == 2)
        #expect(TabNumbers.index(for: 0, count: 3) == nil)
        #expect(TabNumbers.index(for: 10, count: 3) == nil)
    }

    @Test func labelsShowTheFirstEightAndNineOnTheLast() {
        #expect(TabNumbers.labels(count: 0).isEmpty)
        #expect(TabNumbers.labels(count: 3) == [1, 2, 3])
        #expect(TabNumbers.labels(count: 9) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(TabNumbers.labels(count: 11) == [1, 2, 3, 4, 5, 6, 7, 8, nil, nil, 9])
    }

    @Test func everyShownNumberGoesWhereItsShown() {
        for count in 0...20 {
            for (index, label) in TabNumbers.labels(count: count).enumerated() {
                guard let label else { continue }
                #expect(TabNumbers.index(for: label, count: count) == index)
            }
        }
    }

    @Test func holdingCommandAloneShowsAfterTheDelay() {
        var hold = CommandHold()
        hold.modifiersChanged(to: .command, at: 10)
        #expect(!hold.isDue(at: 10.3))
        #expect(hold.isDue(at: 10 + CommandHold.delay))
        // Caps Lock on doesn't count as another modifier.
        var capsOn = CommandHold()
        capsOn.modifiersChanged(to: [.command, .capsLock], at: 0)
        #expect(capsOn.isDue(at: 1))
        hold.modifiersChanged(to: [], at: 10.6)
        #expect(hold.dueAt == nil)
    }

    @Test func aShortcutTypedQuicklyNeverShows() {
        var hold = CommandHold()
        hold.modifiersChanged(to: .command, at: 0)
        // ⌘T pressed while ⌘ is down: no numbers, even if ⌘ stays held after.
        hold.interrupted(holding: .command)
        #expect(hold.dueAt == nil)
        hold.modifiersChanged(to: .command, at: 0.2)
        #expect(!hold.isDue(at: 5))
        // Let go and press ⌘ again: it counts afresh.
        hold.modifiersChanged(to: [], at: 1)
        hold.modifiersChanged(to: .command, at: 2)
        #expect(hold.isDue(at: 2.5))
    }

    @Test func anotherModifierSpoilsTheHoldUntilAllAreLetGo() {
        var hold = CommandHold()
        hold.modifiersChanged(to: [.command, .shift], at: 0)
        #expect(hold.dueAt == nil)
        // ⇧ let go, ⌘ still down: still nothing.
        hold.modifiersChanged(to: .command, at: 0.1)
        #expect(!hold.isDue(at: 3))
        hold.modifiersChanged(to: [], at: 3)
        hold.modifiersChanged(to: .command, at: 4)
        #expect(hold.isDue(at: 4.5))
        // ⌥ added on top of a held ⌘ ends it too.
        hold.modifiersChanged(to: [.command, .option], at: 4.6)
        #expect(hold.dueAt == nil)
    }

    @Test func aClickWithNothingHeldLeavesTheNextPressFree() {
        var hold = CommandHold()
        hold.modifiersChanged(to: .command, at: 0)
        // The window went to the back with ⌘ down; it came back with a plain click.
        hold.interrupted(holding: .command)
        hold.interrupted(holding: [])
        hold.modifiersChanged(to: .command, at: 1)
        #expect(hold.isDue(at: 1.5))
    }
}

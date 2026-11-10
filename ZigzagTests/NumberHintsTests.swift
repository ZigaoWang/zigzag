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
        var hold = ModifierHold(.command)
        hold.modifiersChanged(to: .command, at: 10)
        #expect(!hold.isDue(at: 10.3))
        #expect(hold.isDue(at: 10 + ModifierHold.delay))
        // Caps Lock on doesn't count as another modifier.
        var capsOn = ModifierHold(.command)
        capsOn.modifiersChanged(to: [.command, .capsLock], at: 0)
        #expect(capsOn.isDue(at: 1))
        hold.modifiersChanged(to: [], at: 10.6)
        #expect(hold.dueAt == nil)
    }

    @Test func aShortcutTypedQuicklyNeverShows() {
        var hold = ModifierHold(.command)
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
        var hold = ModifierHold(.command)
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
        var hold = ModifierHold(.command)
        hold.modifiersChanged(to: .command, at: 0)
        // The window went to the back with ⌘ down; it came back with a plain click.
        hold.interrupted(holding: .command)
        hold.interrupted(holding: [])
        hold.modifiersChanged(to: .command, at: 1)
        #expect(hold.isDue(at: 1.5))
    }

    @Test func holdingControlAloneShowsTheSpacesAfterTheDelay() {
        var hold = ModifierHold(.control)
        hold.modifiersChanged(to: .control, at: 10)
        #expect(!hold.isDue(at: 10.3))
        #expect(hold.isDue(at: 10 + ModifierHold.delay))
        #expect(hold.isAlone([.control, .capsLock]))
        #expect(!hold.isAlone([.control, .command]))
        hold.modifiersChanged(to: [], at: 10.6)
        #expect(hold.dueAt == nil)
    }

    @Test func eachHoldWaitsOnlyForItsOwnModifier() {
        var control = ModifierHold(.control), command = ModifierHold(.command)
        control.modifiersChanged(to: .command, at: 0)
        command.modifiersChanged(to: .control, at: 0)
        #expect(control.dueAt == nil)
        #expect(command.dueAt == nil)
        // ⌘ held first spoils ⌃ until both are up, even after ⌘ is let go with ⌃ still down.
        control.modifiersChanged(to: [.command, .control], at: 0.1)
        control.modifiersChanged(to: .control, at: 0.2)
        #expect(!control.isDue(at: 5))
        control.modifiersChanged(to: [], at: 5)
        control.modifiersChanged(to: .control, at: 6)
        #expect(control.isDue(at: 6.5))
        // ⌥ alone shows nothing for either.
        var underOption = ModifierHold(.control)
        underOption.modifiersChanged(to: .option, at: 0)
        #expect(underOption.dueAt == nil)
    }

    @Test func controlTabOrAControlClickNeverShowsTheSpaces() {
        var hold = ModifierHold(.control)
        hold.modifiersChanged(to: .control, at: 0)
        // ⌃Tab (the tab switcher), ⌃1, or a ⌃-click: spoiled while ⌃ stays down.
        hold.interrupted(holding: .control)
        #expect(hold.dueAt == nil)
        hold.modifiersChanged(to: .control, at: 0.2)
        #expect(!hold.isDue(at: 5))
        // ⇧ added and let go on the way back doesn't free it either.
        hold.modifiersChanged(to: [.control, .shift], at: 5)
        hold.modifiersChanged(to: .control, at: 5.1)
        #expect(!hold.isDue(at: 9))
        hold.modifiersChanged(to: [], at: 9)
        hold.modifiersChanged(to: .control, at: 10)
        #expect(hold.isDue(at: 10.5))
    }

    @Test func spaceNumbersGoToTheirOwnSpaceAndNinthIsTheNinth() {
        #expect(SpaceNumbers.index(for: 1, count: 0) == nil)
        #expect(SpaceNumbers.index(for: 1, count: 3) == 0)
        #expect(SpaceNumbers.index(for: 3, count: 3) == 2)
        // Unlike ⌘9, ⌃9 is the ninth space, and a number with no space goes nowhere.
        #expect(SpaceNumbers.index(for: 9, count: 12) == 8)
        #expect(SpaceNumbers.index(for: 9, count: 3) == nil)
        #expect(SpaceNumbers.index(for: 4, count: 3) == nil)
        #expect(SpaceNumbers.index(for: 0, count: 3) == nil)
        #expect(SpaceNumbers.index(for: 10, count: 12) == nil)
        #expect(SpaceNumbers.labels(count: 0).isEmpty)
        #expect(SpaceNumbers.labels(count: 3) == [1, 2, 3])
        #expect(SpaceNumbers.labels(count: 11) == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil, nil])
        for count in 0...14 {
            for (index, label) in SpaceNumbers.labels(count: count).enumerated() {
                guard let label else { continue }
                #expect(SpaceNumbers.index(for: label, count: count) == index)
            }
        }
    }
}

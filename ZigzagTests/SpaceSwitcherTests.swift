import AppKit
import Testing
@testable import Zigzag

/// ⌥⌘S's list of spaces: it starts on the space you're in, the keys move round it, and a number goes to its space.
struct SpaceSwitcherTests {
    @Test func startsOnTheSpaceYoureIn() {
        #expect(SpaceChoice(count: 3, current: 1).index == 1)
        #expect(SpaceChoice(count: 3, current: 0).index == 0)
        // A current space it can't find (gone a moment ago): the nearest end.
        #expect(SpaceChoice(count: 3, current: 7).index == 2)
        #expect(SpaceChoice(count: 3, current: -1).index == 0)
        #expect(SpaceChoice(count: 0, current: 0).index == 0)
    }

    @Test func stepsRunRoundPastEitherEnd() {
        var choice = SpaceChoice(count: 3, current: 2)
        choice.step(1)
        #expect(choice.index == 0)
        choice.step(-1)
        #expect(choice.index == 2)
        choice.step(-1)
        #expect(choice.index == 1)
        choice.step(7)
        #expect(choice.index == 2)
        choice.step(-5)
        #expect(choice.index == 0)
        var empty = SpaceChoice(count: 0, current: 0)
        empty.step(1)
        #expect(empty.index == 0)
    }

    @Test func numbersGoToTheirSpaceAndOnlyIfThereIsOne() {
        var choice = SpaceChoice(count: 4, current: 0)
        let went1 = choice.jump(to: 3)
        #expect(went1)
        #expect(choice.index == 2)
        let went2 = choice.jump(to: 5)
        #expect(!went2)
        #expect(choice.index == 2)
        let went3 = choice.jump(to: 0)
        #expect(!went3)
        var many = SpaceChoice(count: 12, current: 11)
        let went4 = many.jump(to: 9)
        #expect(went4)
        #expect(many.index == 8)
        let went5 = many.jump(to: 10)
        #expect(!went5)
    }

    @Test func keysMeanWhatTheySay() {
        #expect(SpaceChoice.key(code: 125, characters: nil, shift: false) == .step(1))
        #expect(SpaceChoice.key(code: 124, characters: nil, shift: false) == .step(1))
        #expect(SpaceChoice.key(code: 126, characters: nil, shift: false) == .step(-1))
        #expect(SpaceChoice.key(code: 123, characters: nil, shift: false) == .step(-1))
        #expect(SpaceChoice.key(code: 48, characters: "\t", shift: false) == .step(1))
        #expect(SpaceChoice.key(code: 48, characters: "\t", shift: true) == .step(-1))
        #expect(SpaceChoice.key(code: 36, characters: "\r", shift: false) == .choose)
        #expect(SpaceChoice.key(code: 76, characters: "\u{3}", shift: false) == .choose)
        #expect(SpaceChoice.key(code: 53, characters: "\u{1b}", shift: false) == .cancel)
        #expect(SpaceChoice.key(code: 18, characters: "1", shift: false) == .number(1))
        #expect(SpaceChoice.key(code: 25, characters: "9", shift: false) == .number(9))
        // 0, a letter, and ⇧ with a number (a symbol on most keyboards) do nothing.
        #expect(SpaceChoice.key(code: 29, characters: "0", shift: false) == nil)
        #expect(SpaceChoice.key(code: 0, characters: "a", shift: false) == nil)
        #expect(SpaceChoice.key(code: 18, characters: "1", shift: true) == nil)
    }
}

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

/// A space's dot carried along the sidebar's row: the gap under the pointer, and the place the space moves to.
struct SpaceReorderTests {
    /// Four dots 26 points wide, side by side from 0.
    let middles: [CGFloat] = [13, 39, 65, 91]

    @Test func theGapIsByWhichMiddlesThePointerIsPast() {
        #expect(SpaceReorder.slot(at: -20, middles: middles) == 0)
        #expect(SpaceReorder.slot(at: 12, middles: middles) == 0)
        #expect(SpaceReorder.slot(at: 14, middles: middles) == 1)
        #expect(SpaceReorder.slot(at: 52, middles: middles) == 2)
        #expect(SpaceReorder.slot(at: 92, middles: middles) == 4)
        #expect(SpaceReorder.slot(at: 400, middles: middles) == 4)
        #expect(SpaceReorder.slot(at: 10, middles: []) == 0)
    }

    @Test func eitherSideOfItselfItStays() {
        #expect(SpaceReorder.destination(slot: 1, from: 1) == nil)
        #expect(SpaceReorder.destination(slot: 2, from: 1) == nil)
        #expect(SpaceReorder.destination(slot: 0, from: 0) == nil)
        #expect(SpaceReorder.destination(slot: 4, from: 3) == nil)
    }

    @Test func leftwardTakesTheGapsPlace() {
        #expect(SpaceReorder.destination(slot: 0, from: 3) == 0)
        #expect(SpaceReorder.destination(slot: 1, from: 2) == 1)
    }

    @Test func rightwardCountsItselfOut() {
        // From the first to the end of four: last, index 3.
        #expect(SpaceReorder.destination(slot: 4, from: 0) == 3)
        // From the first to between the third and fourth: third, index 2.
        #expect(SpaceReorder.destination(slot: 3, from: 0) == 2)
        #expect(SpaceReorder.destination(slot: 3, from: 1) == 2)
    }

    @Test func aDropMovesTheSpaceWhereTheBarShowed() {
        // The first of A B C D carried just past C's middle: B C A D.
        var order = ["A", "B", "C", "D"]
        if let to = SpaceReorder.destination(slot: SpaceReorder.slot(at: 70, middles: middles), from: 0) { order.insert(order.remove(at: 0), at: to) }
        #expect(order == ["B", "C", "A", "D"])
        // And the last back to the front.
        order = ["A", "B", "C", "D"]
        if let to = SpaceReorder.destination(slot: SpaceReorder.slot(at: 5, middles: middles), from: 3) { order.insert(order.remove(at: 3), at: to) }
        #expect(order == ["D", "A", "B", "C"])
    }
}

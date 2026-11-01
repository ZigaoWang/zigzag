import Foundation
import Testing
@testable import Zigzag

/// Favorites are placed by tile, a split's two pages counting as one. These check where they land, away from the saved
/// library.
struct FavoriteTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test func placesBeforeATile() {
        let order = Library.placing([ids[4]], atSlot: 1, in: Array(ids[0..<4]), splits: [])
        #expect(order == [ids[0], ids[4], ids[1], ids[2], ids[3]])
    }

    @Test func pastTheEndGoesLast() {
        #expect(Library.placing([ids[0]], atSlot: nil, in: ids, splits: []).last == ids[0])
        #expect(Library.placing([ids[0]], atSlot: 99, in: ids, splits: []).last == ids[0])
    }

    @Test func aSplitCountsAsOneTile() {
        // Tiles: [0], [1|2], [3]. Slot 2 is the tile of 3, after the split's right page.
        let split = PinnedSplit(left: ids[1], right: ids[2])
        let order = Library.placing([ids[4]], atSlot: 2, in: Array(ids[0..<4]), splits: [split])
        #expect(order == [ids[0], ids[1], ids[2], ids[4], ids[3]])
    }

    @Test func movingASplitKeepsItTogether() {
        let split = PinnedSplit(left: ids[1], right: ids[2])
        let order = Library.placing([ids[1], ids[2]], atSlot: 0, in: Array(ids[0..<4]), splits: [split])
        #expect(order == [ids[1], ids[2], ids[0], ids[3]])
    }

    @Test func joiningAnEarlierFavoriteOntoALaterOne() {
        // [0, 1, 2]: 0 dropped on 1's middle lands where 1 is, not one tile past it.
        let order = Library.placing([ids[1], ids[0]], at: ids[1], in: Array(ids[0..<3]))
        #expect(order == [ids[1], ids[0], ids[2]])
    }

    @Test func joiningALaterFavoriteOntoAnEarlierOne() {
        let order = Library.placing([ids[2], ids[0]], at: ids[0], in: Array(ids[0..<3]))
        #expect(order == [ids[2], ids[0], ids[1]])
    }

    @Test func joiningANewPageKeepsTheOthersInPlace() {
        let new = UUID()
        let order = Library.placing([ids[1], new], at: ids[1], in: Array(ids[0..<3]) + [new])
        #expect(order == [ids[0], ids[1], new, ids[2]])
    }
}

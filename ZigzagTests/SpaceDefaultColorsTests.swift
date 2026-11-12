import Foundation
import Testing
@testable import Zigzag

/// Use Default Colors (#190): a space goes back to exactly the colors it was made with, and which those are stays
/// the same however the spaces change after.
struct SpaceDefaultColorsTests {
    /// Spaces made one after another, as `Library.addSpace` makes them.
    private func made(_ count: Int) -> [SpaceInfo] {
        var spaces: [SpaceInfo] = []
        for i in 0..<count {
            let pick = SpaceColor.next(unused: spaces.map(\.color))
            spaces.append(SpaceInfo(name: "Space \(i + 1)", color: pick, defaultColor: pick))
        }
        return spaces
    }

    @Test func defaultIsTheColorTheSpaceWasMadeWith() {
        let spaces = made(9)
        #expect(Library.defaultColors(of: spaces) == spaces.map(\.color))
        #expect(Array(spaces.prefix(3).map(\.color)) == [.sky, .sage, .sand])
    }

    @Test func useDefaultColorsPutsBackANewSpacesLook() {
        var space = SpaceInfo(name: "Work", color: .sage, defaultColor: .sage)
        space.icon = "star"
        space.bookmarks = [Bookmark(url: URL(string: "https://example.com")!, title: "Example")]
        let fresh = space
        #expect(space.hasDefaultColors(.sage))

        space.hue = 0.7
        space.tint = 0.4
        space.brightness = 0.8
        space.hue2 = 0.9
        space.brightness2 = 0.6
        space.angle = 90
        space.translucency = 0.5
        space.clearGlass = false
        space.grain = 0.3
        space.appearance = "dark"
        #expect(!space.hasDefaultColors(.sage))

        let back = space.withDefaultColors(.sage)
        #expect(back == fresh)
        #expect(back.hasDefaultColors(.sage))
        // Only the colors: its name, icon and pages stay.
        #expect(back.id == space.id && back.name == "Work" && back.icon == "star" && back.bookmarks.count == 1)
    }

    @Test func eachChangeCounts() {
        let fresh = SpaceInfo(name: "A", color: .rose, defaultColor: .rose)
        var changes: [SpaceInfo] = []
        var s = fresh; s.hue = 0.2; changes.append(s)
        s = fresh; s.brightness = 0.3; changes.append(s)
        s = fresh; s.grain = 0.4; changes.append(s)
        s = fresh; s.translucency = 0.5; changes.append(s)
        s = fresh; s.hue2 = 0.1; changes.append(s)
        s = fresh; s.color = .mint; changes.append(s)
        s = fresh; s.appearance = "light"; changes.append(s)
        for change in changes { #expect(!change.hasDefaultColors(.rose)) }
    }

    @Test func whatCantShowDoesntCount() {
        var space = SpaceInfo(name: "A", color: .sky, defaultColor: .sky)
        // A gradient's direction left from a second color that's gone, and the glass of a solid space.
        space.angle = 135
        space.clearGlass = false
        #expect(space.hasDefaultColors(.sky))
    }

    @Test func whiteGrayOrBlackDefaultMatchesAsSaved() {
        // A neutral color reads back with no tint (`upgraded`); fresh, it's the same space.
        let fresh = SpaceInfo(name: "A", color: .snow, defaultColor: .snow)
        #expect(fresh.hasDefaultColors(.snow))
        #expect(fresh.upgraded.hasDefaultColors(.snow))
    }

    @Test func presetThenDefaultGoesBack() {
        // White sets the space's color to graphite; the color it was made with is still the one that comes back.
        var spaces = made(3)
        let original = spaces[1]
        SpaceLook.presets[0].apply(to: &spaces[1])
        #expect(spaces[1].color == .graphite)
        let color = Library.defaultColors(of: spaces)[1]
        #expect(color == .sage)
        #expect(spaces[1].withDefaultColors(color) == original)
    }

    @Test func spacesFromBeforeItWasKept() {
        // Not kept: the color it still has, or once White took it, the one a space in its place would get.
        var old = [SpaceInfo(name: "A", color: .sky), SpaceInfo(name: "B", color: .sage), SpaceInfo(name: "C", color: .sand)]
        SpaceLook.presets[1].apply(to: &old[1])
        old[2].hue = 0.3
        #expect(Library.defaultColors(of: old) == [.sky, .sage, .sand])
    }

    @Test func keptOnceAndStable() {
        var old = [SpaceInfo(name: "A", color: .sky), SpaceInfo(name: "B", color: .sage), SpaceInfo(name: "C", color: .sand)]
        SpaceLook.presets[0].apply(to: &old[1])
        let kept = Library.keepingDefaultColors(old)
        #expect(kept.map(\.defaultColor) == [.sky, .sage, .sand])
        // Moved first, it keeps the one it was given, not the first space's.
        let moved = [kept[1], kept[0], kept[2]]
        #expect(Library.defaultColors(of: moved) == [.sage, .sky, .sand])
        #expect(Library.keepingDefaultColors(moved).map(\.defaultColor) == [.sage, .sky, .sand])
    }

    @Test func keptColorSurvivesSaving() throws {
        let space = SpaceInfo(name: "A", color: .graphite, brightness: 0.1, defaultColor: .peach)
        let read = try JSONDecoder().decode(SpaceInfo.self, from: JSONEncoder().encode(space))
        #expect(read.defaultColor == .peach)
        #expect(Library.defaultColors(of: [read]) == [.peach])
        // A library from before has none, and still opens.
        let older = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"A","color":"mint","bookmarks":[]}"#.utf8))
        #expect(older.defaultColor == nil)
        #expect(Library.defaultColors(of: [older]) == [.mint])
    }
}

import AppKit
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

    /// The space editor shows a system-following space at its current shade and updates on appearance change; chosen colors stay.
    @MainActor @Test func editorShowsTheShadeTheSpaceHasNow() {
        let space = SpaceInfo(name: "Personal", color: .sky, defaultColor: .sky)
        let editor = SpaceLookEditor(space: space, defaultColor: .sky, dark: true)
        #expect(editor.shownDepth > 0.5)
        editor.follow(dark: false)
        #expect(editor.shownDepth < 0.5)
        #expect(SpaceLookEditor(space: space, defaultColor: .sky, dark: false).shownDepth == editor.shownDepth)

        var chosen = space
        chosen.brightness = 0.8
        let mine = SpaceLookEditor(space: chosen, defaultColor: .sky, dark: true)
        mine.follow(dark: false)
        #expect(abs(mine.shownDepth - 0.8) < 0.001)
    }
}

/// The color wheel's two knobs, for a gradient: each one takes a press and follows a drag.
@MainActor
struct ColorWheelDragTests {
    private func wheel(_ spots: [ColorWheel.Spot], selected: Int = 0) -> ColorWheel {
        let wheel = ColorWheel(frame: NSRect(x: 0, y: 0, width: 276, height: 200))
        wheel.show(spots, depths: spots.map { _ in 0.3 }, selected: selected, animated: false)
        return wheel
    }

    private let gradient = [ColorWheel.Spot(hue: 0.9, amount: 0.5), ColorWheel.Spot(hue: 0.6, amount: 1)]

    @Test func eitherKnobTakesThePress() {
        for index in 0..<2 {
            let wheel = wheel(gradient)
            let grab = wheel.press(at: wheel.point(gradient[index]))
            #expect(grab.index == index)
            #expect(!grab.moved)
            #expect(wheel.selected == index)
        }
    }

    /// Pale colors sit near the middle, their knobs close together: a press on either one takes that one.
    @Test func closeKnobsEachTakeTheirPress() {
        let close = [ColorWheel.Spot(hue: 0.6, amount: 0.1), ColorWheel.Spot(hue: 0.82, amount: 0.1)]
        for selected in 0..<2 {
            for index in 0..<2 {
                let wheel = wheel(close, selected: selected)
                let a = wheel.point(close[index]), b = wheel.point(close[1 - index])
                // On its center, and on its far side from the other knob.
                let far = CGPoint(x: a.x + (a.x - b.x) * 0.4, y: a.y + (a.y - b.y) * 0.4)
                #expect(wheel.press(at: a).index == index)
                #expect(self.wheel(close, selected: selected).press(at: far).index == index)
            }
        }
    }

    @Test func theSecondKnobFollowsADrag() {
        let wheel = wheel(gradient)
        var changes: [(Int, ColorWheel.Spot, Bool)] = []
        wheel.onChange = { changes.append(($0, $1, $2)) }
        let start = wheel.point(gradient[1])
        // Grabbed a little off its center.
        var grab = wheel.press(at: CGPoint(x: start.x + 4, y: start.y - 3))
        let target = wheel.point(ColorWheel.Spot(hue: 0.25, amount: 0.6))
        wheel.drag(&grab, to: CGPoint(x: target.x + 4, y: target.y - 3))
        wheel.release(grab, at: CGPoint(x: target.x + 4, y: target.y - 3))
        #expect(abs(wheel.spots[1].hue - 0.25) < 0.01)
        #expect(abs(wheel.spots[1].amount - 0.6) < 0.01)
        #expect(wheel.spots[0] == gradient[0])
        #expect(changes.allSatisfy { $0.0 == 1 })
        #expect(changes.last?.2 == true)
    }

    @Test func aDragStaysOnTheWheel() {
        let wheel = wheel(gradient, selected: 1)
        var grab = wheel.press(at: wheel.point(gradient[1]))
        wheel.drag(&grab, to: CGPoint(x: -500, y: 900))
        #expect(wheel.spots[1].amount == 1)
        #expect(wheel.bounds.insetBy(dx: 12, dy: 12).contains(wheel.point(wheel.spots[1])))
    }

    @Test func aClickOffTheKnobsBringsTheSelectedOne() {
        let wheel = wheel(gradient, selected: 1)
        let spot = ColorWheel.Spot(hue: 0.1, amount: 0.8)
        let grab = wheel.press(at: wheel.point(spot))
        #expect(grab.index == 1 && grab.moved)
        wheel.release(grab, at: wheel.point(spot))
        #expect(abs(wheel.spots[1].hue - 0.1) < 0.01)
        #expect(wheel.spots[0] == gradient[0])
    }

    /// In the editor, dragging the second knob changes the gradient's second color and keeps it there.
    @Test func theEditorKeepsTheSecondColor() throws {
        var space = SpaceInfo(name: "School", color: .sky)
        space.hue = 0.9
        space.tint = 0.5
        space.brightness = 0.2
        space.hue2 = 0.6
        space.brightness2 = 0.36
        let editor = SpaceLookEditor(space: space, defaultColor: .sky, dark: false)
        editor.frame = NSRect(x: 0, y: 0, width: 276, height: 600)
        editor.toggleCustom()
        editor.layoutSubtreeIfNeeded()
        let wheel = try #require(editor.subviews.compactMap { $0 as? ColorWheel }.first)
        var grab = wheel.press(at: wheel.point(wheel.spots[1]))
        #expect(grab.index == 1)
        let target = wheel.point(ColorWheel.Spot(hue: 0.3, amount: 0.7))
        wheel.drag(&grab, to: target)
        wheel.release(grab, at: target)
        #expect(abs((editor.look.hue2 ?? 0) - 0.3) < 0.01)
        #expect(abs(wheel.spots[1].hue - 0.3) < 0.01)
        #expect(abs((editor.look.hue ?? 0) - 0.9) < 0.001)
    }

    /// Clicking Custom again keeps the wheel out.
    @Test func customAlwaysShowsTheWheel() {
        let editor = SpaceLookEditor(space: SpaceInfo(name: "School", color: .sky), defaultColor: .sky, dark: false)
        let folded = editor.preferredHeight
        editor.showCustom()
        let shown = editor.preferredHeight
        editor.showCustom()
        #expect(shown > folded)
        #expect(editor.preferredHeight == shown)
    }
}

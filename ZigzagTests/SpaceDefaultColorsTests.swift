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
            spaces.append(SpaceInfo(name: "Space \(i + 1)", color: pick, defaultColor: pick).withDefaultColors(pick))
        }
        return spaces
    }

    @Test func defaultIsTheColorTheSpaceWasMadeWith() {
        let spaces = made(9)
        #expect(Library.defaultColors(of: spaces) == spaces.map(\.color))
        #expect(Array(spaces.prefix(3).map(\.color)) == [.slate, .fern, .coral])
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
        SpaceLook.white.apply(to: &spaces[1])
        #expect(spaces[1].color == .graphite)
        let color = Library.defaultColors(of: spaces)[1]
        #expect(color == .fern)
        #expect(spaces[1].withDefaultColors(color) == original)
    }

    @Test func spacesFromBeforeItWasKept() {
        // Not kept: the color it still has, or once White took it, the one a space in its place would get.
        var old = [SpaceInfo(name: "A", color: .sky), SpaceInfo(name: "B", color: .sage), SpaceInfo(name: "C", color: .sand)]
        SpaceLook.black.apply(to: &old[1])
        old[2].hue = 0.3
        #expect(Library.defaultColors(of: old) == [.sky, .sage, .sand])
    }

    @Test func keptOnceAndStable() {
        var old = [SpaceInfo(name: "A", color: .sky), SpaceInfo(name: "B", color: .sage), SpaceInfo(name: "C", color: .sand)]
        SpaceLook.white.apply(to: &old[1])
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

/// The palette new spaces and the editor's presets take, and the older colors existing spaces keep.
@MainActor
struct SpacePaletteTests {
    private func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    /// `top` laid over an opaque `ground`.
    private func laid(_ top: NSColor, over ground: NSColor) -> NSColor {
        let a = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * a + ground.redComponent * (1 - a), green: top.greenComponent * a + ground.greenComponent * (1 - a),
                       blue: top.blueComponent * a + ground.blueComponent * (1 - a), alpha: 1)
    }

    /// What the glass shows under the color, blurred, over a light desktop and over a dark, busy one.
    private func glassGrounds(dark: Bool) -> [NSColor] {
        (dark ? [0.09, 0.5] : [0.96, 0.3]).map { NSColor(srgbRed: $0, green: $0, blue: $0, alpha: 1) }
    }

    @Test func aFreshSpaceIsSlateGlass() {
        let first = SpaceColor.newSpaceOrder[0]
        #expect(first == .slate)
        let space = SpaceInfo(name: "Personal", color: first, defaultColor: first).withDefaultColors(first)
        #expect(space.isSeeThrough && space.clearGlass == nil)
        #expect(abs(space.seeThrough - first.paletteLook!.seeThrough) < 0.001)
        // It follows the Mac: a clear, barely cool glass by day, deep slate at night.
        #expect(space.brightness == nil && space.readableAppearance == nil && space.appearance == nil)
        #expect(space.dayDepth == 0.16 && space.nightDepth == 0.93 && space.hue2 == nil)
        let day = resolved(space.background, dark: false), night = resolved(space.background, dark: true)
        #expect(Brand.relativeLuminance(day) > 0.6 && Brand.relativeLuminance(night) < 0.06)
        #expect(day.saturationComponent > 0.02 && day.saturationComponent < 0.12)
        #expect(day.blueComponent > day.redComponent)
        #expect(space.hasDefaultColors(first))
        #expect(SpaceLook.curated(first).matches(space))
        // The Slate in the row keeps one depth, a choice of its own.
        #expect(!SpaceLook.presets.contains { $0.matches(space) })
        #expect(first.look!.space.readableAppearance == "light")
    }

    /// A palette color that is deep by day too keeps a dark window, one light at night too keeps a light one (a deep
    /// coral or yellow reads as brown); the rest follow the Mac.
    @Test func aNewSpaceTakesItsColorsModeWhereItHasOne() {
        func fresh(_ color: SpaceColor) -> SpaceInfo { SpaceInfo(name: "S", color: color, defaultColor: color).withDefaultColors(color) }
        #expect(fresh(.red).readableAppearance == "dark" && fresh(.smoke).readableAppearance == "dark")
        #expect(fresh(.citron).readableAppearance == "light" && fresh(.coral).readableAppearance == "light")
        #expect(fresh(.fern).readableAppearance == nil)
        // Richer than a custom color goes, and saved that way.
        #expect(fresh(.red).tintAmount > 1.3)
    }

    /// The 0.9.4 betas' palette names read as the colors that took their place.
    @Test func theBetasPaletteNamesReadAsTheNewColors() throws {
        for (old, new) in ["lagoon": SpaceColor.slate, "sunset": .coral, "dusk": .navy, "citrus": .citron, "midnight": .navy,
                           "petrol": .pine, "forest": .pine, "merlot": .red, "watermelon": .coral, "fuchsia": .pink, "volt": .fern,
                           "lilac": .iris, "seafoam": .seafoam, "dune": .stone] {
            #expect(SpaceColor.named(old) == new, "\(old)")
            let json = #"{"name":"A","color":"sky","paletteColor":"\#(old)","paletteDefaultColor":"\#(old)","bookmarks":[]}"#
            let space = try JSONDecoder().decode(SpaceInfo.self, from: Data(json.utf8))
            #expect(space.color == new && space.defaultColor == new, "\(old)")
        }
    }

    @Test func existingSpacesKeepTheirColors() throws {
        // A space saved before the palette reads back exactly as it was: the same color, solid.
        let json = #"{"id":"\#(UUID().uuidString)","name":"A","color":"sky","bookmarks":[]}"#
        let old = try JSONDecoder().decode(SpaceInfo.self, from: Data(json.utf8)).upgraded
        let kept = Library.keepingDefaultColors([old])[0]
        #expect(kept.color == .sky && kept.defaultColor == .sky && !kept.isSeeThrough && kept.brightness == nil)
        for dark in [false, true] {
            let tone = dark ? SpaceColor.tone(hue: 0.585, lightness: Tokens.Frame.darkLightness, chroma: Tokens.Frame.darkChroma * 0.78)
                : SpaceColor.tone(hue: 0.585, lightness: Tokens.Frame.lightness, chroma: Tokens.Frame.chroma * 0.78)
            #expect(resolved(kept.background, dark: dark) == resolved(tone, dark: false))
        }
        // Use Default Colors on an older color stays one solid color following the Mac.
        let back = SpaceInfo(name: "B", color: .sage).withDefaultColors(.sage)
        #expect(!back.isSeeThrough && back.brightness == nil && back.hue == nil)
        for color in SpaceColor.legacyAll { #expect(color.look == nil) }
        // Older spaces whose color is gone still get back what they were made with then.
        var spaces = [SpaceInfo(name: "A", color: .sky), SpaceInfo(name: "B", color: .sage)]
        SpaceLook.black.apply(to: &spaces[1])
        #expect(Library.defaultColors(of: spaces) == [.sky, .sage])
    }

    @Test func profilesKeepTheOlderColors() {
        #expect(ProfileDirectory.ownColor(for: .sage, used: []) == .sage)
        #expect(SpaceColor.legacy.contains(ProfileDirectory.ownColor(for: .slate, used: [])))
        #expect(SpaceColor.legacyNext(unused: []) == .sky)
    }

    @Test func thePaletteIsDistinctGlass() {
        let looks = SpaceColor.palette.compactMap(\.look)
        #expect(looks.count == 17)
        #expect(looks.allSatisfy { (0.35...0.55).contains($0.seeThrough) })
        // Deep ones and light ones, and at most three gradients, each a small drift of one hue.
        let spaces = looks.map(\.space)
        #expect(spaces.filter { $0.readableAppearance == "dark" }.count >= 3)
        #expect(spaces.filter { $0.readableAppearance == "light" }.count >= 6)
        let gradients = looks.filter { $0.hue2 != nil }
        #expect(gradients.count <= 3)
        func okHue(_ h: Double) -> Double { SpaceColor.okHue(h) * 180 / .pi }
        for look in gradients {
            let d = abs(okHue(look.hue) - okHue(look.hue2!)).truncatingRemainder(dividingBy: 360)
            #expect(min(d, 360 - d) <= 20, "\(look.name)")
        }
        // Neutrals lead the editor's row, white among them, then the washes.
        #expect(SpaceLook.presets.prefix(4).map(\.name) == SpaceColor.neutrals.map(\.name) + [SpaceLook.white.name])
        #expect(SpaceLook.presets.dropFirst(4).prefix(SpaceColor.washes.count).map(\.name) == SpaceColor.washes.map(\.name))
        func lab(_ c: NSColor) -> (l: Double, a: Double, b: Double) {
            OKLab.lab(r: OKLab.decode(c.redComponent), g: OKLab.decode(c.greenComponent), b: OKLab.decode(c.blueComponent))
        }
        for (a, b) in zip(spaces, spaces.dropFirst()) {
            // Both ends, so a gradient that starts at a neighbor's color still tells apart by where it goes.
            var distance = 0.0
            for (x, y) in [(a.background, b.background), (a.background2 ?? a.background, b.background2 ?? b.background)] {
                let p = lab(resolved(x, dark: false)), q = lab(resolved(y, dark: false))
                distance += ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
            }
            #expect(distance > 0.03, "\(a.name) and \(b.name): \(distance)")
        }
    }

    /// The washes are near-white glass with a faint tint of their own, for a preset only: new spaces don't get them.
    @Test func theWashesAreFaintTintsNearWhite() {
        for color in SpaceColor.washes {
            let space = color.look!.space
            let day = resolved(space.background, dark: false)
            #expect(Brand.relativeLuminance(day) > 0.75, "\(color)")
            #expect(day.saturationComponent > 0.03 && day.saturationComponent < 0.15, "\(color)")
            #expect(space.readableAppearance == "light", "\(color)")
            #expect(!SpaceColor.newSpaceOrder.contains(color))
        }
    }

    /// The editor's swatches, Default and the picture and Custom with the presets, fill whole rows.
    @Test func theEditorsSwatchesFillWholeRows() {
        #expect(SpaceLookEditor.tileCount % SpaceLookEditor.columns == 0)
    }

    /// Primary text at 4.5:1 or more on every preset, in the mode its window takes, and on what new spaces get in both
    /// modes: on the solid color, on the glass over a light and a dark desktop, and on the selected tab's card.
    @Test func everyPresetKeepsTextReadable() {
        let looks = SpaceLook.presets.map { ($0, $0.space.readableAppearance == "dark") }
            + SpaceColor.palette.compactMap(\.defaultLook).flatMap { look in
                look.space.readableAppearance.map { [(look, $0 == "dark")] } ?? [(look, false), (look, true)]
            }
        for (look, dark) in looks {
            let space = look.space
            let text = resolved(Brand.Theme.of(space).rowInk, dark: dark)
            var grounds = [resolved(space.background, dark: dark)] + (space.background2.map { [resolved($0, dark: dark)] } ?? [])
            if look.seeThrough > 0 {
                // Solid with Reduce Transparency: the space's own ink on its own color.
                var opaque = space
                opaque.translucency = nil
                let ink = resolved(Brand.Theme.of(opaque).rowInk, dark: dark)
                for ground in grounds { #expect(Brand.contrast(laid(ink, over: ground), ground) >= 4.5, "\(look.name) solid \(dark)") }
                grounds = [space.frameColor, space.frameColor2].compactMap { $0 }.flatMap { tint in
                    glassGrounds(dark: dark).map { laid(resolved(tint, dark: dark), over: $0) }
                }
            }
            let card = resolved(Tokens.Chrome.card, dark: dark)
            for ground in grounds {
                let ratio = Brand.contrast(laid(text, over: ground), ground)
                #expect(ratio >= 4.5, "\(look.name) \(dark ? "dark" : "light"): \(String(format: "%.2f", ratio)):1")
                let tab = laid(card, over: ground)
                #expect(Brand.contrast(laid(text, over: tab), tab) >= 4.5, "\(look.name) tab \(dark)")
            }
        }
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

/// Where the space editor opens: at what opened it, always inside the window.
@MainActor
struct SpaceEditorPlacementTests {
    @Test func risesFromTheBottomAndHangsFromTheTop() {
        // The space's name near the top, a space dot or the + at the bottom.
        #expect(!SpaceEditorPanel.rises(from: NSRect(x: 0, y: 120, width: 200, height: 40), in: 820))
        #expect(SpaceEditorPanel.rises(from: NSRect(x: 0, y: 780, width: 20, height: 20), in: 820))
    }

    @Test func staysInTheWindow() {
        let top = SpaceEditorPanel.topMargin, bottom = SpaceEditorPanel.bottomMargin
        #expect(SpaceEditorPanel.clampedTop(100, height: 300, in: 820) == 100)
        // Hanging from a row near the bottom, it moves up to fit.
        #expect(SpaceEditorPanel.clampedTop(700, height: 300, in: 820) == 820 - 300 - bottom)
        // Rising from a dot past the top, it moves down.
        #expect(SpaceEditorPanel.clampedTop(-200, height: 600, in: 820) == top)
        // Taller than the window: the top shows.
        #expect(SpaceEditorPanel.clampedTop(50, height: 900, in: 820) == top)
    }

    @Test func theWheelShrinksInAShortWindow() {
        #expect(SpaceEditorPanel.wheelHeight(overflow: -50) == ColorWheel.fullHeight)
        #expect(SpaceEditorPanel.wheelHeight(overflow: 30) == ColorWheel.fullHeight - 30)
        #expect(SpaceEditorPanel.wheelHeight(overflow: 500) == ColorWheel.minimumHeight)
    }
}

/// A space with a palette color is still readable by a Zigzag from before the palette, which knows only the older colors.
@MainActor struct SpaceColorCompatibilityTests {
    /// What 0.9.3 knew: its colors, and a space made of them.
    private enum OldColor: String, Decodable { case snow, graphite, ink, sky, sage, sand, rose, lavender, mint, peach }
    private struct OldSpace: Decodable { var name: String; var color: OldColor; var defaultColor: OldColor? }

    private func encoded(_ space: SpaceInfo) throws -> Data { try JSONEncoder().encode(space) }

    @Test func anOlderZigzagReadsAPaletteSpace() throws {
        let space = SpaceInfo(name: "Work", color: .slate, defaultColor: .slate).withDefaultColors(.slate)
        let old = try JSONDecoder().decode(OldSpace.self, from: encoded(space))
        #expect(old.name == "Work")
        #expect(old.color.rawValue == SpaceColor.slate.nearestLegacy.rawValue)
        #expect(old.defaultColor?.rawValue == SpaceColor.slate.nearestLegacy.rawValue)
        // Every palette color has an older one to stand in for it.
        for color in SpaceColor.palette {
            #expect(SpaceColor.legacyAll.contains(color.nearestLegacy))
            let data = try encoded(SpaceInfo(name: "S", color: color, defaultColor: color))
            #expect((try? JSONDecoder().decode(OldSpace.self, from: data)) != nil, "\(color)")
        }
    }

    @Test func aPaletteColorComesBack() throws {
        var space = SpaceInfo(name: "Work", color: .coral, defaultColor: .pine).withDefaultColors(.coral)
        space.icon = "star"
        space.defaultColor = .pine
        let back = try JSONDecoder().decode(SpaceInfo.self, from: encoded(space))
        #expect(back == space)
        #expect(back.color == .coral)
        #expect(back.defaultColor == .pine)
        #expect(back.dayDepth == 0.28 && back.nightDepth == 0.28 && back.tint == 1.25)
    }

    @Test func anOlderColorIsWrittenAsBefore() throws {
        let space = SpaceInfo(name: "Home", color: .sage, defaultColor: .sage)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded(space)) as? [String: Any])
        #expect(json["color"] as? String == "sage")
        #expect(json["paletteColor"] == nil)
        #expect(json["paletteDefaultColor"] == nil)
        #expect(try JSONDecoder().decode(SpaceInfo.self, from: encoded(space)) == space)
    }

    /// The beta that wrote "lagoon" into `color` reads as Slate, the color that took its place, keeping the look it
    /// has, and its next save is one an older Zigzag reads.
    @Test func aBetaFileWithAPaletteColorMigrates() throws {
        let id = UUID()
        let beta = #"{"id":"\#(id.uuidString)","name":"Personal","color":"lagoon","defaultColor":"lagoon","bookmarks":[],"hue":0.5,"intensity":0.8,"hue2":0.6,"intensity2":0.8,"angle":90,"translucency":0.45}"#
        let space = try JSONDecoder().decode(SpaceInfo.self, from: Data(beta.utf8))
        #expect(space.id == id)
        #expect(space.color == .slate)
        #expect(space.defaultColor == .slate)
        #expect(space.hue == 0.5 && space.hue2 == 0.6 && space.translucency == 0.45)
        let old = try JSONDecoder().decode(OldSpace.self, from: encoded(space))
        #expect(old.color.rawValue == SpaceColor.slate.nearestLegacy.rawValue)
        #expect(try JSONDecoder().decode(SpaceInfo.self, from: encoded(space)) == space)
    }

    /// A color from a newer Zigzag doesn't make the space, and the whole library with it, unreadable.
    @Test func anUnknownColorReadsAsGraphite() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Later","color":"aurora","bookmarks":[]}"#
        #expect(try JSONDecoder().decode(SpaceInfo.self, from: Data(json.utf8)).color == .graphite)
    }
}

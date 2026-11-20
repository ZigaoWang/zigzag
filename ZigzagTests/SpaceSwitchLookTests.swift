import AppKit
import Testing
@testable import Zigzag

/// Switching spaces: the window takes the new space's color as the switch happens, before its page comes in, and
/// mid-swipe the color follows the fingers from one space's to the next.
@MainActor
struct SpaceSwitchLookTests {
    private func rgba(_ color: NSColor, in appearance: NSAppearance) -> [CGFloat] {
        var c = color
        appearance.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB) ?? color }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private func rgba(_ color: CGColor?) -> [CGFloat] {
        let c = color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) } ?? .clear
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.01 } }

    /// A space key answers the pointer as the toolbar's buttons do: the hover and pressed washes, and a press around
    /// its middle, never a move down.
    @Test func aSpaceKeyHoversAndPressesInPlace() {
        let key = SpaceDotView(spaceID: UUID())
        key.frame = NSRect(x: 0, y: 0, width: Tokens.Sidebar.button, height: Tokens.Sidebar.button)
        key.icon = "🔥"
        let light = NSAppearance(named: .aqua)!
        key.appearance = light
        #expect(key.pressScales && !key.pressSinks)
        #expect(key.layer?.backgroundColor == nil || rgba(key.layer?.backgroundColor)[3] == 0)
        key.isHovered = true
        #expect(close(rgba(key.layer?.backgroundColor), rgba(Tokens.Chrome.buttonWash(pressed: false), in: light)))
        key.isPressed = true
        #expect(close(rgba(key.layer?.backgroundColor), rgba(Tokens.Chrome.buttonWash(pressed: true), in: light)))
        let layer = key.layer!
        // Scaled around its middle: the middle stays where it was.
        let t = layer.transform
        let center = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        let anchor = CGPoint(x: layer.anchorPoint.x * key.bounds.width, y: layer.anchorPoint.y * key.bounds.height)
        let moved = CGPoint(x: anchor.x + (center.x - anchor.x) * t.m11 + t.m41, y: anchor.y + (center.y - anchor.y) * t.m22 + t.m42)
        #expect(abs(moved.x - center.x) < 0.01 && abs(moved.y - center.y) < 0.01, "\(moved)")
        key.isPressed = false
        key.isHovered = false
    }

    /// Symbols and emoji alike: one square, one size, ink in the middle.
    @Test func spaceIconsShareOneCenterAndSize() {
        let side: CGFloat = 18
        for icon in ["flame.fill", "book.fill", "star.fill", "heart.fill", "music.note", "🔥", "🍎", "📚"] {
            let image = IconChoice.mark(icon, side: side)
            #expect(image.size == NSSize(width: side, height: side))
            let key = "test mark \(icon)"
            let ink = Tokens.Symbol.inkOffset(of: image, key: key, scale: 2)
            #expect(abs(ink.width) <= 0.5 && abs(ink.height) <= 0.5, "\(icon) \(ink)")
            let size = Tokens.Symbol.inkSize(of: image, key: key, scale: 2)
            #expect(max(size.width, size.height) <= side, "\(icon) \(size)")
            #expect(abs((size.width * size.height).squareRoot() - IconChoice.markInk * side) <= 1.5, "\(icon) \(size)")
        }
    }

    /// Tall and wide ink come out alike, never longer than the square.
    @Test func markScaleEvensOutTallAndWide() {
        let side: CGFloat = 18, target = IconChoice.markInk * side
        for ink in [CGSize(width: 12, height: 16), CGSize(width: 16, height: 12), CGSize(width: 14, height: 14)] {
            let k = IconChoice.markScale(ink: ink, side: side)
            #expect(abs((ink.width * k * ink.height * k).squareRoot() - target) < 0.001)
        }
        #expect(IconChoice.markScale(ink: CGSize(width: 6, height: 24), side: side) == 0.75)
        #expect(IconChoice.markScale(ink: .zero, side: side) == 1)
    }

    /// An icon's key draws no dot under it.
    @Test func aSpaceKeyWithAnIconHidesItsDot() {
        let key = SpaceDotView(spaceID: UUID())
        key.frame = NSRect(x: 0, y: 0, width: Tokens.Sidebar.button, height: Tokens.Sidebar.button)
        key.icon = "star.fill"
        key.layout()
        let dots = key.layer?.sublayers?.filter { !($0 is CATextLayer) && $0.delegate == nil && $0.frame.height == 2 } ?? []
        #expect(dots.allSatisfy { $0.opacity == 0 })
    }

    @Test func mixGoesPartWayInLightAndDark() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        let mixed = SpaceInfo.mix(red, blue, by: 0.25)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(close(rgba(mixed, in: NSAppearance(named: name)!), [0.75, 0, 0.25, 0.875]))
        }
        #expect(SpaceInfo.mix(red, blue, by: 0) === red)
        #expect(SpaceInfo.mix(red, blue, by: 1.5) === blue)
    }

    @Test func aSwitchSaysTheSpaceBeforeThePage() {
        let first = Library.shared.spaces[0].id
        let added = Library.shared.addSpace(name: "Look test")
        defer { Library.shared.removeSpace(added.id) }
        let manager = TabManager(spaceID: first)
        let tab = manager.newTab(url: nil, spaceID: added.id, select: false)
        defer { tab.close(); manager.invalidate() }
        // The window paints the space's look on `.space` and shows the page on `.selection`.
        var seen: [(TabManager.Change, UUID)] = []
        let token = manager.changed.observe { seen.append(($0, manager.currentSpaceID)) }
        manager.switchToSpace(added.id)
        _ = token
        let space = seen.firstIndex { $0.0 == .space }
        let page = seen.firstIndex { $0.0 == .selection }
        #expect(space != nil)
        #expect(page != nil)
        if let space, let page { #expect(space < page) }
        // The look painted is the new space's.
        #expect(space.map { seen[$0].1 } == added.id)
    }

    @Test func theFrameBlendsTowardTheSpaceComingIn() {
        let a = SpaceInfo(name: "A", color: .sky), b = SpaceInfo(name: "B", color: .sage, grain: 1)
        let frame = SpaceFrameView()
        frame.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        frame.paint(a, isPrivate: false, animated: false)
        let appearance = frame.effectiveAppearance
        #expect(close(rgba(frame.layer?.backgroundColor), rgba(a.frameColor, in: appearance)))
        for share in [0.25, 0.5, 0.9] as [CGFloat] {
            let (color, _) = frame.paint(a, toward: b, share: share)
            let expected = rgba(SpaceInfo.mix(a.frameColor, b.frameColor, by: share), in: appearance)
            #expect(close(rgba(frame.layer?.backgroundColor), expected), "at \(share)")
            #expect(close(rgba(color, in: appearance), expected))
        }
        // None of the way is the space's own.
        frame.paint(a, toward: b, share: 0)
        #expect(close(rgba(frame.layer?.backgroundColor), rgba(a.frameColor, in: appearance)))
    }

    private func scroll(_ dx: Double, phase: Int64) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        cg.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        return NSEvent(cgEvent: cg)
    }

    @Test func aSwipeBlendsWithTheFingersAndCallingItOffGoesBack() throws {
        guard !Tokens.Motion.reduceMotion else { return }
        let added = Library.shared.addSpace(name: "Swipe test")
        defer { Library.shared.removeSpace(added.id) }
        let spaces = Library.shared.spaces
        let here = try #require(spaces.firstIndex { $0.id == added.id }).advanced(by: -1)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
        sidebar.currentSpaceID = spaces[here].id
        sidebar.onSwipeSpace = { _ in false }
        var looks: [(UUID?, CGFloat)] = []
        sidebar.onSwipeLook = { looks.append(($0, $1)) }
        for (dx, phase) in [(0.0, Int64(1)), (-20, 2), (-40, 2)] {
            _ = sidebar.handleSwipe(try #require(scroll(dx, phase: phase)))
        }
        // Fingers moving left pull in the next space, the color as far along as the list.
        let pulled = try #require(looks.last)
        #expect(pulled.0 == added.id)
        #expect(abs(pulled.1 - 60 / sidebar.bounds.width) < 0.01)
        #expect(looks.map(\.1) == looks.map(\.1).sorted())
        _ = sidebar.handleSwipe(try #require(scroll(0, phase: 8)))
        let back = try #require(looks.last)
        #expect(back.0 == nil)
        #expect(back.1 == 0)
    }

    @Test func theDebugFlickSpeedsUpLiftsAndCoasts() {
        let steps = DebugBridge.flick(width: 260, seconds: 0.4)
        #expect(steps.first?.phase == 1)
        #expect(abs((steps.last?.time ?? 0) - 0.4) < 0.03)
        let fingers = steps.filter { $0.phase == 2 }
        // Ease-in: each step at least as far as the one before.
        #expect(zip(fingers, fingers.dropFirst()).allSatisfy { $1.dx >= $0.dx })
        #expect(abs(fingers.map(\.dx).reduce(0, +) - 260 * 0.42) < 0.5)
        #expect(steps.contains { $0.phase == 4 })
        let coast = steps.filter { $0.momentum != 0 }
        #expect(coast.first?.momentum == 1 && coast.last?.momentum == 3)
        #expect(zip(coast, coast.dropFirst()).allSatisfy { $1.dx <= $0.dx })
    }
}

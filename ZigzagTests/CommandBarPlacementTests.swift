import AppKit
import Foundation
import Testing
@testable import Zigzag

/// ⌘T bar placement: default, snapping, clamping to the window, saved as window fractions.
struct CommandBarPlacementTests {
    private static let minimum: CGFloat = 200

    /// A `width` x `height` window with a left sidebar of `sidebar` points and the page inset 8pt.
    private func placement(_ width: CGFloat, _ height: CGFloat, sidebar: CGFloat = 240) -> CommandBarPlacement {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let page = NSRect(x: sidebar + 8, y: 8, width: width - sidebar - 16, height: height - 16)
        return CommandBarPlacement(bounds: bounds, page: page, minimumHeight: Self.minimum)
    }

    @Test func defaultIsCenteredOnTheWindowAndHighOnThePage() {
        let p = placement(1440, 900)
        let origin = p.origin(for: .standard)
        #expect(p.width == Tokens.Metric.commandBarWidth)
        #expect(origin.x == floor(720 - p.width / 2))
        // 18% of the 884pt page from its top.
        #expect(origin.y == CGFloat(167))
        #expect(p.guideX == CGFloat(720))
        #expect(p.guideY == origin.y)
    }

    @Test func narrowWindowKeepsTheDefaultBesideTheSidebar() {
        let p = placement(900, 700)
        let origin = p.origin(for: .standard)
        // 644pt page: 32pt margins, right of the sidebar.
        #expect(p.width == CGFloat(580))
        #expect(origin.x == CGFloat(280))
    }

    @Test func shortWindowKeepsTheMinimumTop() {
        let p = placement(1200, 200)
        #expect(p.origin(for: .standard).y == 8 + Tokens.Space.x12)
    }

    @Test func sidebarHiddenCentersOnThePage() {
        let p = placement(1200, 800, sidebar: 0)
        #expect(p.origin(for: .standard).x == floor(600 - p.width / 2))
    }

    @Test func nearAGuideSnapsOntoIt() {
        let p = placement(1440, 900)
        let home = p.origin(for: .standard)
        let near = p.drag(to: NSPoint(x: home.x + 7, y: home.y - 8))
        #expect(near.snappedX && near.snappedY)
        #expect(near.origin == home)
        #expect(near.position.isStandard)
        let far = p.drag(to: NSPoint(x: home.x + 9, y: home.y + 9))
        #expect(!far.snappedX && !far.snappedY)
        #expect(far.origin == NSPoint(x: home.x + 9, y: home.y + 9))
    }

    @Test func oneAxisSnapsOnItsOwn() {
        let p = placement(1440, 900)
        let home = p.origin(for: .standard)
        let drag = p.drag(to: NSPoint(x: home.x + 3, y: home.y + 300))
        #expect(drag.snappedX && !drag.snappedY)
        #expect(drag.position.centerX == nil)
        #expect(drag.position.top != nil)
        #expect(p.origin(for: drag.position) == drag.origin)
    }

    @Test func draggedBarCanCoverTheSidebarButStaysInTheWindow() {
        let p = placement(1440, 900)
        let left = p.drag(to: NSPoint(x: -500, y: -500))
        #expect(left.origin == NSPoint(x: CommandBarPlacement.edgeMargin, y: CommandBarPlacement.edgeMargin))
        let right = p.drag(to: NSPoint(x: 5000, y: 5000))
        #expect(right.origin.x == 1440 - CommandBarPlacement.edgeMargin - p.width)
        #expect(right.origin.y == 900 - CommandBarPlacement.edgeMargin - Self.minimum)
        // Moved down, the list may extend to the window bottom.
        #expect(p.bottom(for: right.position) == 900)
        #expect(p.bottom(for: .standard) == 892)
    }

    @Test func positionFollowsTheWindowsSize() {
        let small = placement(1000, 700)
        let drag = small.drag(to: NSPoint(x: 100, y: 400))
        let large = placement(2000, 1400)
        let there = large.origin(for: drag.position)
        // Same fractions of the window across sizes.
        #expect(abs((there.x + large.width / 2) / 2000 - (drag.origin.x + small.width / 2) / 1000) < 0.001)
        #expect(abs(there.y / 1400 - drag.origin.y / 700) < 0.001)
        // Too low for a shorter window: clamped.
        let short = placement(1000, 300)
        #expect(short.origin(for: CommandBarPlacement.Position(centerX: 0.5, top: 0.95)).y == 300 - CommandBarPlacement.edgeMargin - Self.minimum)
    }

    @Test func savesFractionsAndForgetsTheDefault() throws {
        let suite = "CommandBarPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeScratchSuite(suite) }
        #expect(CommandBarPlacement.load(from: defaults) == .standard)
        let moved = CommandBarPlacement.Position(centerX: 0.25, top: 0.6)
        CommandBarPlacement.save(moved, to: defaults)
        #expect(CommandBarPlacement.load(from: defaults) == moved)
        CommandBarPlacement.save(CommandBarPlacement.Position(centerX: nil, top: 0.4), to: defaults)
        #expect(CommandBarPlacement.load(from: defaults) == CommandBarPlacement.Position(centerX: nil, top: 0.4))
        CommandBarPlacement.save(.standard, to: defaults)
        #expect(defaults.object(forKey: CommandBarPlacement.defaultsKey) == nil)
        // Invalid values fall back to the default.
        defaults.set(["x": 7.0, "top": -1.0], forKey: CommandBarPlacement.defaultsKey)
        #expect(CommandBarPlacement.load(from: defaults) == .standard)
    }
}

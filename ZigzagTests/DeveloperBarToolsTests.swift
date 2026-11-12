import AppKit
import Testing
@testable import Zigzag

/// The developer tools' buttons (#141): which page gets them, how they give way, and their place in the bar above
/// the page.
@MainActor
struct DeveloperBarToolsTests {
    @Test func onlyADevelopmentTabOnItsOwnGetsTheTools() {
        #expect(DeveloperBarTools.shows(isDevelopment: true, showsInBar: true, inSplit: false))
        #expect(!DeveloperBarTools.shows(isDevelopment: false, showsInBar: true, inSplit: false))
        // Tools above the page off, or a split, whose panes have the row for their own strips: the tools are in
        // Site Controls.
        #expect(!DeveloperBarTools.shows(isDevelopment: true, showsInBar: false, inSplit: false))
        #expect(!DeveloperBarTools.shows(isDevelopment: true, showsInBar: true, inSplit: true))
    }

    @Test func theButtonsGiveWayOneAtATimeAndMoreAlwaysShows() {
        let b = Tokens.Sidebar.button
        let count = DeveloperBarTools.parts.count
        let all = DeveloperBarTools.width(shown: count)
        #expect(all == CGFloat(count + 1) * b)
        #expect(DeveloperBarTools.fit(width: 1200, count: count) == count)
        #expect(DeveloperBarTools.fit(width: all, count: count) == count)
        // A point less, and the last gives way; then one for each button's width.
        #expect(DeveloperBarTools.fit(width: all - 1, count: count) == count - 1)
        #expect(DeveloperBarTools.fit(width: all - b, count: count) == count - 1)
        #expect(DeveloperBarTools.fit(width: all - b - 1, count: count) == count - 2)
        // Room for ⋯ alone: none of them, never fewer.
        #expect(DeveloperBarTools.fit(width: b, count: count) == 0)
        #expect(DeveloperBarTools.fit(width: 0, count: count) == 0)
    }

    @Test func theyAskForTheRoomTheyNeedAndNoMore() {
        let tools = DeveloperBarTools()
        let b = Tokens.Sidebar.button, count = DeveloperBarTools.parts.count
        #expect(tools.width(fitting: 2000) == DeveloperBarTools.width(shown: count))
        // Less room: fewer buttons, and ⋯.
        #expect(tools.width(fitting: b * 3 + 5) == b * 3)
        #expect(tools.width(fitting: b) == b)
        // No room for ⋯ even: nothing.
        #expect(tools.width(fitting: b - 1) == 0)
    }

    @Test func theySitAtTheTrailingEndOfTheRoomTheyAreGiven() {
        let tools = DeveloperBarTools(frame: NSRect(x: 0, y: 0, width: 400, height: TopBarView.height))
        tools.layoutSubtreeIfNeeded()
        #expect(tools.shown == DeveloperBarTools.parts.count)
        let buttons = tools.subviews.compactMap { $0 as? IconButton }.filter { !$0.isHidden }
        // ⋯ ends where the room does, the others run up to it, all on the bar's middle line.
        #expect(buttons.map(\.frame.maxX).max() == 400)
        #expect(buttons.map(\.frame.minX).min() == 400 - DeveloperBarTools.width(shown: DeveloperBarTools.parts.count))
        #expect(Set(buttons.map(\.frame.midY)) == [TopBarView.height / 2])
        // Narrower than they need: the last ones are under ⋯.
        tools.frame.size.width = Tokens.Sidebar.button * 2
        tools.needsLayout = true
        tools.layoutSubtreeIfNeeded()
        #expect(tools.shown == 1)
    }

    @Test func everyToolIsReachable() {
        // A button's tools and what ⋯ holds are all the tools, each once.
        let placed = DeveloperBarTools.parts.flatMap(\.tools) + DeveloperBarTools.moreTools
        #expect(Set(placed).count == placed.count)
        #expect(Set(placed) == Set(DeveloperTool.allCases))
        // A button with several tools says what it is.
        for part in DeveloperBarTools.parts where part.tools.count > 1 { #expect(part.title?.isEmpty == false) }
    }

    @Test func theBarGivesAPagesToolsItsTrailingEnd() {
        let plain = TopBarView.frames(width: 900, buttons: 3, trafficLightsWidth: 0, trailingInset: 12)
        let tools = TopBarView.frames(width: 900, buttons: 3, trafficLightsWidth: 0, trailingInset: 12, accessory: 160)
        #expect(plain.accessory == nil)
        // The tools end where the address did, the bar's whole height; the address ends a gap before them.
        #expect(tools.accessory == NSRect(x: plain.address.maxX - 160, y: 0, width: 160, height: TopBarView.height))
        #expect(tools.address.minX == plain.address.minX)
        #expect(tools.address.maxX == plain.address.maxX - 160 - Tokens.Space.x2)
        #expect(tools.buttons == plain.buttons)
        // With no buttons and no address to keep room for (the address in the sidebar), they're at the trailing end still.
        let alone = TopBarView.frames(width: 900, buttons: 0, trafficLightsWidth: 0, trailingInset: 12, accessory: 160)
        #expect(alone.accessory.map { abs($0.maxX - 888) < 0.01 } == true)
        // Before the sidebar's toggle, for a sidebar on the right.
        let right = TopBarView.frames(width: 900, buttons: 0, sidebarButton: true, onRight: true, trafficLightsWidth: 0, trailingInset: 12, accessory: 160)
        #expect((right.accessory?.maxX ?? 0) < (right.sidebarButton?.minX ?? 0))
    }

    @Test func theAddressKeepsItsRoomBesideTheTools() {
        let bar = TopBarView(frame: NSRect(x: 0, y: 0, width: 440, height: TopBarView.height))
        let address = NSView()
        bar.hold(buttons: [NSView(), NSView(), NSView()], address: address)
        let tools = DeveloperBarTools()
        bar.accessory = tools
        bar.layoutSubtreeIfNeeded()
        // Too narrow for every button beside the address: the address keeps its least, the buttons give way.
        #expect(address.frame.width >= TopBarView.addressMinWidth)
        #expect(tools.shown < DeveloperBarTools.parts.count)
        #expect(tools.frame.minX >= address.frame.maxX)
        // Wide enough: all of them.
        bar.frame.size.width = 1200
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        #expect(tools.shown == DeveloperBarTools.parts.count)
        // Taken away, the address has the bar to itself again.
        bar.accessory = nil
        bar.layoutSubtreeIfNeeded()
        #expect(tools.superview == nil)
        #expect(address.frame.maxX == TopBarView.frames(width: 1200, buttons: 3, trafficLightsWidth: 0, trailingInset: Tokens.Sidebar.edge).address.maxX)
    }
}

import AppKit
import Testing
@testable import Zigzag

/// The developer tools' buttons (#141): which page gets them, how they give way, and their place in the bar above
/// the page.
@MainActor
struct DeveloperBarToolsTests {
    @Test func aDevelopmentTabHasTheToolsInTheBarOrInItsPanesStrip() {
        #expect(DeveloperBarTools.place(isDevelopment: true, showsInBar: true, inSplit: false) == .bar)
        // In a split, whose panes have the row for their own strips: in its pane's ⋯.
        #expect(DeveloperBarTools.place(isDevelopment: true, showsInBar: true, inSplit: true) == .pane)
        // Not a development tab: none.
        #expect(DeveloperBarTools.place(isDevelopment: false, showsInBar: true, inSplit: false) == nil)
        #expect(DeveloperBarTools.place(isDevelopment: false, showsInBar: true, inSplit: true) == nil)
        // Tools above the page off: none above it, and Site Controls has them.
        #expect(DeveloperBarTools.place(isDevelopment: true, showsInBar: false, inSplit: false) == nil)
        #expect(DeveloperBarTools.place(isDevelopment: true, showsInBar: false, inSplit: true) == nil)
    }

    @Test func aPanesMenuHasEveryToolOfferedInASplitAndNoOther() {
        let placed = DeveloperBarTools.paneParts.flatMap(\.tools) + DeveloperBarTools.moreTools
        #expect(Set(placed).count == placed.count)
        let offered = DeveloperTool.allCases.filter {
            DeveloperTool.isOffered($0, isOn: true, isDevelopment: true, url: URL(string: "http://localhost:3000/"), isPrivate: false, inSplit: true)
        }
        #expect(Set(placed) == Set(offered))
        // Its ⋯ says a look chosen is in effect, as everything is under it there.
        var state = DeveloperState()
        state.appearance = .dark
        #expect(DeveloperTool.hasChoiceInEffect(among: placed, in: state))
        #expect(!DeveloperTool.hasChoiceInEffect(among: placed, in: DeveloperState()))
    }

    /// With the address in the bar: the tools alone, as wide as they need, groups a line apart.
    private var all: CGFloat {
        let b = Tokens.Sidebar.button
        // Console, Inspect | Appearance, Size | Reload, ⋯
        return CGFloat(DeveloperBarTools.parts.count + 1) * b + 2 * DeveloperBarTools.lineRoom
    }

    @Test func theButtonsGiveWayOneAtATimeAndMoreAlwaysShows() {
        let b = Tokens.Sidebar.button
        let count = DeveloperBarTools.parts.count
        let full = DeveloperBarTools.layout(width: 1200, address: false)
        #expect(full.shown == count && full.width == all)
        #expect(full.lines.count == 2)
        #expect(DeveloperBarTools.layout(width: all, address: false).shown == count)
        // A point less, and the last gives way, its group's line staying before ⋯.
        #expect(DeveloperBarTools.layout(width: all - 1, address: false).shown == count - 1)
        // Room for ⋯ alone: none of them, never fewer.
        #expect(DeveloperBarTools.layout(width: b, address: false).shown == 0)
        #expect(DeveloperBarTools.layout(width: b - 1, address: false).width == 0)
    }

    /// With the address in the sidebar the bar has the page's whole address from its leading end, Copy Link after
    /// it, a line, then the tools at the trailing end; the address gives up its room before any button gives way.
    @Test func theWholeAddressTakesTheRoomTheToolsLeave() {
        let b = Tokens.Sidebar.button
        let layout = DeveloperBarTools.layout(width: 900, address: true)
        #expect(layout.width == 900)
        let address = try! #require(layout.address)
        #expect(address.minX == 0)
        #expect(layout.copy.map { $0.minX > address.maxX } == true)
        #expect(layout.shown == DeveloperBarTools.parts.count)
        #expect(layout.lines.count == 3)
        #expect(layout.more.maxX == 900)
        #expect(address.width == 900 - all - b - DeveloperBarTools.lineRoom - Tokens.Space.x1)
        // Narrow: the address keeps its least, and the buttons give way.
        let narrow = DeveloperBarTools.layout(width: DeveloperBarTools.addressMinWidth + 4 * b, address: true)
        #expect((narrow.address?.width ?? 0) >= DeveloperBarTools.addressMinWidth)
        #expect(narrow.shown < DeveloperBarTools.parts.count)
    }

    /// The page's size follows its button: with its name where there's room, then without, then not at all.
    @Test func theSizeGivesUpItsNameBeforeItsPlace() {
        let readout = (named: CGFloat(240), bare: CGFloat(140))
        let wide = DeveloperBarTools.layout(width: 1200, address: false, readout: readout)
        #expect(wide.readout?.width == 240 && wide.readoutNamed)
        let size = try! #require(DeveloperBarTools.parts.firstIndex { $0.tools.contains(.sizeFill) })
        #expect(wide.readout?.minX == wide.buttons[size].maxX)
        let less = DeveloperBarTools.layout(width: all + 200, address: false, readout: readout)
        #expect(less.readout?.width == 140 && !less.readoutNamed && less.shown == DeveloperBarTools.parts.count)
        let none = DeveloperBarTools.layout(width: all + 20, address: false, readout: readout)
        #expect(none.readout == nil && none.shown == DeveloperBarTools.parts.count)
    }

    @Test func theAddressSaysTheWholeAddress() {
        #expect(DeveloperAddressView.shown(URL(string: "https://www.google.com/")) == "https://www.google.com")
        #expect(DeveloperAddressView.shown(URL(string: "http://localhost:3000/admin?tab=2")) == "http://localhost:3000/admin?tab=2")
        #expect(DeveloperAddressView.shown(URL(string: "https://example.com/?q=dev%20mode")) == "https://example.com/?q=dev mode")
        #expect(DeveloperAddressView.shown(nil) == "")
    }

    @Test func theyAskForTheRoomTheyNeedAndNoMore() {
        let tools = DeveloperBarTools()
        // Not in a bar: as with the address in it, the tools alone.
        #expect(tools.width(fitting: 2000) == all)
        #expect(tools.width(fitting: Tokens.Sidebar.button - 1) == 0)
    }

    @Test func theySitAtTheTrailingEndOfTheRoomTheyAreGiven() {
        let tools = DeveloperBarTools(frame: NSRect(x: 0, y: 0, width: 400, height: TopBarView.height))
        tools.layoutSubtreeIfNeeded()
        #expect(tools.shown == DeveloperBarTools.parts.count)
        let buttons = tools.subviews.compactMap { $0 as? IconButton }.filter { !$0.isHidden }
        // ⋯ ends where the room does, the others run up to it, all on the bar's middle line.
        #expect(buttons.map(\.frame.maxX).max() == 400)
        #expect(buttons.map(\.frame.minX).min() == 400 - all)
        #expect(Set(buttons.map(\.frame.midY)) == [TopBarView.height / 2])
        // Narrower than they need: the last ones are under ⋯.
        tools.frame.size.width = Tokens.Sidebar.button * 2 + DeveloperBarTools.lineRoom
        tools.needsLayout = true
        tools.layoutSubtreeIfNeeded()
        #expect(tools.shown == 1)
    }

    @Test func aCountIsOneBadgeOnTheButtonThatHoldsIt() {
        let console = NSView(), more = NSView()
        // Nothing to say: no badge.
        #expect(BadgeView.show("", on: console, replacing: nil) == nil)
        let badge = try! #require(BadgeView.show("3", on: console, replacing: nil))
        #expect(badge.superview === console && badge.text == "3")
        // The same badge, saying more, moved onto ⋯ when the console's button gave way into it.
        let moved = BadgeView.show("12", on: more, replacing: badge)
        #expect(moved === badge && badge.superview === more && badge.text == "12" && console.subviews.isEmpty)
        // Gone once the count is.
        #expect(BadgeView.show("", on: more, replacing: badge) == nil && more.subviews.isEmpty)
    }

    @Test func everyToolIsReachable() {
        // A button's tools and what ⋯ holds are all the tools this Mac's WebKit has, each once.
        let placed = DeveloperBarTools.parts.flatMap(\.tools) + DeveloperBarTools.moreTools
        #expect(Set(placed).count == placed.count)
        #expect(Set(placed) == Set(DeveloperTool.allCases.filter(\.isAvailable)))
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

import AppKit
import Testing
@testable import Zigzag

/// Sidebar on the right (#166): every frame is the left layout's mirror image, the page leaves the traffic lights
/// a strip at the window's top left, and the edges that resize and reveal the sidebar are on its side.
@MainActor
struct SidebarSideTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width: CGFloat = 240
    let inset = Tokens.Metric.cardInset

    private func mirror(_ rect: NSRect) -> NSRect { BrowserRootView.mirrored(rect, in: window, if: true) }

    @Test func mirroringTurnsAFrameOverTheWindowsMiddle() {
        let rect = NSRect(x: 10, y: 20, width: 100, height: 50)
        #expect(BrowserRootView.mirrored(rect, in: window, if: false) == rect)
        #expect(mirror(rect) == NSRect(x: 1170, y: 20, width: 100, height: 50))
        #expect(mirror(mirror(rect)) == rect)
    }

    @Test func theDockedSidebarRunsDownTheRightEdge() {
        let left = BrowserRootView.sidebarFrame(in: window, width: width, visible: true, revealed: false, onRight: false)
        let right = BrowserRootView.sidebarFrame(in: window, width: width, visible: true, revealed: false, onRight: true)
        #expect(left == NSRect(x: 0, y: 0, width: width, height: 800))
        #expect(right == NSRect(x: 1040, y: 0, width: width, height: 800))
    }

    @Test func hiddenItWaitsPastTheRightEdgeAndSlidesOutAnInsetIn() {
        let hidden = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: false, onRight: true)
        let revealed = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: true, onRight: true)
        #expect(hidden.minX > window.maxX)
        #expect(revealed.maxX == window.maxX - inset)
        #expect(revealed.minY == inset && revealed.height == 800 - inset * 2)
    }

    @Test func thePageSitsLeftOfTheSidebarUnderTheLightsStrip() {
        let room = BrowserRootView.lightsStripHeight
        for borderless in [false, true] {
            let left = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: borderless, topBar: false)
            let right = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: borderless, topBar: false,
                                                 onRight: true, lightsRoom: room)
            // The left layout's mirror image, only starting under the strip the traffic lights sit in.
            #expect(right.minX == window.maxX - left.maxX && right.width == left.width)
            #expect(right.maxX == window.maxX - width)
            #expect(right.minY == room && right.maxY == left.maxY)
        }
    }

    @Test func theStripLinesThePageUpWithTheSidebarsAddress() {
        #expect(BrowserRootView.lightsStripHeight == Tokens.Sidebar.addressTop)
        // The lights' center line is well inside it.
        #expect(Tokens.Sidebar.lightsCenter + 7 < BrowserRootView.lightsStripHeight)
    }

    @Test func hiddenOrUnderTheBarThePageIsTheSameOnEitherSide() {
        for edgeToEdge in [false, true] {
            let left = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: width, edgeToEdge: edgeToEdge, borderless: true, topBar: false)
            let right = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: width, edgeToEdge: edgeToEdge, borderless: true, topBar: false, onRight: true)
            #expect(left == right)
        }
        // The bar above the page holds the lights itself: no strip, and the page under the bar as on the left.
        let left = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true)
        let right = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true,
                                             onRight: true, lightsRoom: BrowserRootView.lightsStripHeight)
        #expect(right == mirror(left))
    }

    @Test func theBarAboveThePageRunsFromTheWindowsLeftEdgeToTheSidebar() {
        let bar = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: width, onRight: true)
        #expect(bar.minX == 0 && bar.maxX == window.maxX - width && bar.height == TopBarView.height)
        let hidden = BrowserRootView.topBarFrame(in: window, sidebarVisible: false, sidebarWidth: width, onRight: true)
        #expect(hidden == BrowserRootView.topBarFrame(in: window, sidebarVisible: false, sidebarWidth: width))
    }

    @Test func theBarsControlsKeepClearOfTheWindowsLeftEdge() {
        let bar = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: width, onRight: true)
        let page = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true, onRight: true)
        // Borderless, the page meets the window's left edge: the controls start an edge in from it, as they end an
        // edge in from the right one with the sidebar on the left.
        #expect(TopBarView.edgeInset(page: page, window: window) == Tokens.Sidebar.edge)
        let ends = TopBarView.insets(bar: bar, page: page, window: window)
        #expect(ends.leading == Tokens.Sidebar.edge)
    }

    @Test func theResizeHandleIsOnTheSidebarsEdgeByThePage() {
        let handle = Tokens.Metric.resizeHandleWidth
        let left = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: false)
        let right = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: true)
        #expect(left.midX == width && left.width == handle)
        #expect(right.midX == window.maxX - width && right.width == handle && right.height == window.height)
    }

    @Test func draggingTheEdgeMeasuresFromTheSidebarsSide() {
        #expect(BrowserRootView.reach(of: 300, in: window, onRight: false) == 300)
        #expect(BrowserRootView.reach(of: 980, in: window, onRight: true) == 300)
    }

    @Test func aHiddenSidebarComesOutAtItsOwnEdge() {
        let middle = window.midY
        func zone(onRight: Bool) -> SidebarEdgeZone {
            let out = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: true, onRight: onRight)
            return SidebarEdgeZone(bounds: window, sidebar: out, onRight: onRight)
        }
        #expect(zone(onRight: false).opens(at: NSPoint(x: 2, y: middle)))
        #expect(!zone(onRight: false).opens(at: NSPoint(x: 1278, y: middle)))
        #expect(zone(onRight: true).opens(at: NSPoint(x: 1278, y: middle)))
        #expect(!zone(onRight: true).opens(at: NSPoint(x: 2, y: middle)))
        #expect(!zone(onRight: true).opens(at: NSPoint(x: 640, y: middle)))
    }

    @Test func theMiniPlayerFirstGoesToTheCornerAwayFromTheSidebar() {
        #expect(MiniPlayerLayout.firstCorner(sidebarOnRight: false) == .bottomRight)
        #expect(MiniPlayerLayout.firstCorner(sidebarOnRight: true) == .bottomLeft)
    }

    @Test func theSettingIsOffUntilTurnedOn() {
        let key = "sidebarOnRight"
        let saved = UserDefaults.standard.object(forKey: key) as? Bool
        defer {
            // Back as it was, windows included.
            BrowserRootView.sidebarOnRight = saved ?? false
            if saved == nil { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!BrowserRootView.sidebarOnRight)
        nonisolated final class Count: @unchecked Sendable { var heard = 0 }
        let count = Count()
        let token = NotificationCenter.default.addObserver(forName: BrowserRootView.sidebarSideChanged, object: nil, queue: nil) { _ in count.heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        BrowserRootView.sidebarOnRight = true
        #expect(BrowserRootView.sidebarOnRight && count.heard == 1)
    }

    @Test func theBarsShowSidebarButtonSitsAtItsTrailingEndOnTheRight() throws {
        let lights: CGFloat = 52, b = Tokens.Sidebar.button, edge = Tokens.Sidebar.edge
        for (lightsWidth, lead, trail) in [(lights, CGFloat(0), edge), (0, inset, inset)] {
            let left = TopBarView.frames(width: 1280, buttons: 3, sidebarButton: true, trafficLightsWidth: lightsWidth,
                                         leadingInset: lead, trailingInset: trail)
            let right = TopBarView.frames(width: 1280, buttons: 3, sidebarButton: true, onRight: true, trafficLightsWidth: lightsWidth,
                                          leadingInset: lead, trailingInset: trail)
            let leftToggle = try #require(left.sidebarButton), rightToggle = try #require(right.sidebarButton)
            // On the left it leads the row; on the right it ends it, an edge in from the window's, on the same line.
            #expect(left.buttons[0].minX == leftToggle.maxX)
            #expect(rightToggle.maxX == 1280 - edge && rightToggle.width == b && rightToggle.midY == leftToggle.midY)
            #expect(right.address.maxX <= 1280 - trail)
            // Back, forward and reload take the toggle's place after the lights, as with no toggle at all.
            let none = TopBarView.frames(width: 1280, buttons: 3, trafficLightsWidth: lightsWidth, leadingInset: lead, trailingInset: trail)
            #expect(right.buttons == none.buttons)
            // The address keeps the same gap before the toggle as after the buttons.
            #expect(right.address.minX == none.address.minX)
            #expect(rightToggle.minX - right.address.maxX == right.address.minX - right.buttons[2].maxX)
        }
        // Without a toggle, the side changes nothing.
        let shown = TopBarView.frames(width: 1280, buttons: 3, onRight: true, trafficLightsWidth: lights, trailingInset: edge)
        #expect(shown == TopBarView.frames(width: 1280, buttons: 3, trafficLightsWidth: lights, trailingInset: edge))
    }

    @Test func inSplitViewTheLastStripEndsBeforeTheToggleOnTheRight() throws {
        let lights: CGFloat = 52, edge = Tokens.Sidebar.edge
        let panes: [ClosedRange<CGFloat>] = [0...639, 640...1280]
        let strips = TopBarView.stripFrames(panes: panes, sidebarButton: true, onRight: true, width: 1280, trafficLightsWidth: lights,
                                            leadingInset: 0, inset: edge)
        let own = TopBarView.frames(width: 1280, buttons: 3, sidebarButton: true, onRight: true, trafficLightsWidth: lights, trailingInset: edge)
        let toggle = try #require(own.sidebarButton)
        // The first starts where the bar's own back button is, right after the lights; the last ends at the toggle.
        #expect(strips[0].frame.minX == own.buttons[0].minX && strips[0].frame.maxX == 639 - edge)
        #expect(strips[1].frame.minX == 640 + edge && strips[1].frame.maxX == toggle.minX)
        #expect(strips[1].frame.minX + strips[1].addressCenter == 960)
    }

    @Test func theTogglesGlyphShowsThePanelOnTheSidebarsSide() {
        #expect(SidebarView.toggleSymbol(onRight: false) == "sidebar.left")
        #expect(SidebarView.toggleSymbol(onRight: true) == "sidebar.right")
        let topBar = TopBarView()
        #expect(topBar.sidebarButton.symbol == "sidebar.left")
        topBar.sidebarOnRight = true
        #expect(topBar.sidebarButton.symbol == "sidebar.right")
        topBar.sidebarOnRight = false
        #expect(topBar.sidebarButton.symbol == "sidebar.left")
    }

    @Test func onTheRightTheSidebarsTopRowIsTheLeftOnesMirrorImage() {
        let b = SidebarView.toolbarButton
        let left = SidebarView.topRowFrames(width: width, trafficLightsWidth: 0, onRight: false)
        let right = SidebarView.topRowFrames(width: width, trafficLightsWidth: 0, onRight: true)
        func flipped(_ rect: NSRect) -> CGFloat { width - rect.maxX }
        // The toggle at the outer end, as far in as it is from the left edge on the left.
        #expect(flipped(right.toggle) == left.toggle.minX)
        // Back, forward and reload toward the page, in reading order, a button apart, back's ink as far from the left
        // edge as reload's from the right one on the left.
        #expect(right.buttons[1].minX == right.buttons[0].maxX && right.buttons[2].minX == right.buttons[1].maxX)
        let backInk = Tokens.Symbol.inkSize("chevron.left", size: Tokens.Sidebar.glyph).width
        let reloadInk = Tokens.Symbol.inkSize("arrow.clockwise", size: Tokens.Sidebar.glyph).width
        #expect(abs((right.buttons[0].midX - backInk / 2) - (width - left.buttons[2].midX - reloadInk / 2)) <= 1)
        #expect(right.buttons[2].maxX < right.toggle.minX && right.toggle.width == b)
        // With the lights in it (slid out over the page with no bar) it keeps the left's order, clear of them.
        let lit = SidebarView.topRowFrames(width: width, trafficLightsWidth: 52, onRight: true)
        #expect(lit.toggle.minX > Tokens.Sidebar.lightsX + 52 && lit.buttons[2].maxX > lit.toggle.maxX)
    }

    @Test func theToggleStaysPutAsARightSidebarComesAndGoes() throws {
        // Hidden, the bar spans the window and keeps the toggle at its end; docked, the sidebar's own is there too.
        let row = SidebarView.topRowFrames(width: width, trafficLightsWidth: 0, onRight: true)
        let docked = BrowserRootView.sidebarFrame(in: window, width: width, visible: true, revealed: false, onRight: true)
        for (lead, trail) in [(CGFloat(14), CGFloat(14)), (6, 6), (inset, inset)] {
            let bar = TopBarView.frames(width: window.width, buttons: 3, sidebarButton: true, onRight: true, trafficLightsWidth: 52,
                                        leadingInset: lead, trailingInset: trail)
            let toggle = try #require(bar.sidebarButton)
            #expect(toggle.minX == docked.minX + row.toggle.minX && toggle.width == row.toggle.width)
        }
    }

    @Test func theSidebarsToggleGlyphFollowsItsSide() {
        let sidebar = SidebarView()
        #expect(sidebar.sidebarButton.symbol == "sidebar.left")
        sidebar.isOnRight = true
        #expect(sidebar.sidebarButton.symbol == "sidebar.right")
        sidebar.isOnRight = false
        #expect(sidebar.sidebarButton.symbol == "sidebar.left")
    }
}

import AppKit
import Testing
@testable import Zigzag

/// Sidebar on the right (#166): every frame is the left layout's mirror image, the traffic lights ride in the
/// sidebar's top row as on the left, and the edges that resize and reveal the sidebar are on its side.
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

    @Test func aMirrorHidesItsAddressButtonsWhileTheBarHoldsTheAddress() {
        let mirror = SidebarView(frame: .zero)
        mirror.hasTopBar = false
        mirror.holdsAddress = false
        #expect(mirror.addressButtons.allSatisfy { $0.isHidden })
        mirror.holdsAddress = true
        #expect(mirror.addressButtons.allSatisfy { !$0.isHidden })
        // The window's sidebar keeps them: they leave for the bar above the page, they don't hide.
        let windowSidebar = SidebarView(frame: .zero)
        windowSidebar.holdsAddress = false
        #expect(windowSidebar.addressButtons.allSatisfy { !$0.isHidden })
    }

    @Test func aMirrorTracksHoverWhileAnotherAppIsInFront() {
        let mirror = SidebarView(frame: .zero)
        #expect(!mirror.backButton.tracksHoverWhileInactive)
        mirror.hoversWhileInactive = true
        #expect(mirror.backButton.tracksHoverWhileInactive)
        // A window's sidebar keeps the window's own hover rules.
        #expect(!SidebarView(frame: .zero).backButton.tracksHoverWhileInactive)
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

    @Test func thePageSitsLeftOfTheSidebarRunningToTheTop() {
        for borderless in [false, true] {
            let left = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: borderless, topBar: false)
            let right = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: borderless, topBar: false,
                                                 onRight: true)
            // The left layout's mirror image, top included: no strip above it for the traffic lights, which are in
            // the sidebar.
            #expect(right == mirror(left))
            #expect(right.maxX == window.maxX - width)
            #expect(right.minY == left.minY)
        }
    }

    @Test func hiddenOrUnderTheBarThePageIsTheSameOnEitherSide() {
        for edgeToEdge in [false, true] {
            let left = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: width, edgeToEdge: edgeToEdge, borderless: true, topBar: false)
            let right = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: width, edgeToEdge: edgeToEdge, borderless: true, topBar: false, onRight: true)
            #expect(left == right)
        }
        // The page under the bar above it as on the left.
        let left = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true)
        let right = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true,
                                             onRight: true)
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
        let left = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: false)
        let right = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: true)
        #expect(left.minX < width && left.maxX > width)
        #expect(right.minX < window.maxX - width && right.maxX > window.maxX - width && right.height == window.height)
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

    @Test func withTheBarHoldingTheLightsTheRightSidebarsTopRowIsTheLeftOnesMirrorImage() {
        let b = SidebarView.toolbarButton
        let left = SidebarView.topRowFrames(width: width, trafficLightsWidth: 0, onRight: false)
        let right = SidebarView.topRowFrames(width: width, trafficLightsWidth: 0, onRight: true, mirrored: true)
        func flipped(_ rect: NSRect) -> CGFloat { width - rect.maxX }
        // The toggle at the outer end, as far in as it is from the left edge on the left.
        #expect(flipped(right.toggle) == left.toggle.minX)
        // Back, forward and reload toward the page, in reading order, a button apart, back where reload is on the
        // left, mirrored; and reload on the left centered over the address field's Site Controls button.
        #expect(right.buttons[1].minX == right.buttons[0].maxX && right.buttons[2].minX == right.buttons[1].maxX)
        #expect(right.buttons[0].minX == width - left.buttons[2].maxX)
        let controlsMid = width - Tokens.Sidebar.edge - AddressView.buttonInset - AddressView.buttonSide / 2
        #expect(abs(left.buttons[2].midX - controlsMid) <= 0.5)
        #expect(right.buttons[2].maxX < right.toggle.minX && right.toggle.width == b)
    }

    /// Without the bar above the page, a sidebar on the right has the left one's top row, traffic lights and all, as
    /// Arc's does: the lights, the toggle after them, back, forward and reload at the trailing end; in full screen
    /// (no lights) the toggle starts the row as on the left.
    @Test func withoutTheBarTheRightSidebarsTopRowIsTheLeftOnes() {
        for lights: CGFloat in [52, 0] {
            let left = SidebarView.topRowFrames(width: width, trafficLightsWidth: lights, onRight: false)
            let right = SidebarView.topRowFrames(width: width, trafficLightsWidth: lights, onRight: true)
            #expect(right.toggle == left.toggle && right.buttons == left.buttons)
        }
        let lit = SidebarView.topRowFrames(width: width, trafficLightsWidth: 52, onRight: true)
        #expect(lit.toggle.minX > Tokens.Sidebar.lightsX + 52 && lit.buttons[0].minX > lit.toggle.maxX)
    }

    @Test func theToggleStaysPutAsARightSidebarComesAndGoes() throws {
        // Hidden, the bar spans the window and keeps the toggle at its end; docked, the sidebar's own is there too.
        let row = SidebarView.topRowFrames(width: width, trafficLightsWidth: 0, onRight: true, mirrored: true)
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

    /// Settings › Appearance › Sidebar position (#360): Left and Right in Zigzag's own menu, on the same preference.
    @Test func sidebarPositionIsALeftRightMenuOnTheSamePreference() throws {
        #expect(SettingsView.sidebarSides == [false, true])
        let settings = SettingsView(pane: .appearance)
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let row = try #require(all(settings).compactMap { $0 as? FormRow }.first { $0.titleText == String(localized: "Sidebar position") })
        let menu = try #require(all(row).compactMap { $0 as? DropdownButton }.first)
        #expect(menu.options.map(\.title) == [String(localized: "Left"), String(localized: "Right")])
        #expect(SettingsView.sidebarSides[menu.selectedIndex] == BrowserRootView.sidebarOnRight)
        #expect(!all(row).contains { $0 is Toggle })
    }
}

/// The space name stays at the top while scrolling, as in Arc.
struct PinnedSpaceNameTests {
    @Test func atTheTopTheNameIsTheFirstRow() {
        #expect(SidebarListView.pinnedHeaderOffset(scrolled: 0) == 0)
        // Overscrolled past the top, it moves with the rows.
        #expect(SidebarListView.pinnedHeaderOffset(scrolled: -40) == 0)
    }

    @Test func scrolledTheNameStaysAtTheTop() {
        #expect(SidebarListView.pinnedHeaderOffset(scrolled: 1) == 1)
        #expect(SidebarListView.pinnedHeaderOffset(scrolled: 320) == 320)
    }
}

/// Row titles never shift or truncate when the hover button appears; the button covers the faded end.
@MainActor struct RowHoverTests {
    private func row(pinned: Bool, away: Bool) -> (TabRowView, Tab) {
        let tab = Tab(url: URL(string: "https://video.example.com/watch")!, title: "A very long page title that runs past the row's end", spaceID: UUID())
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 220, height: Tokens.Sidebar.rowHeight))
        row.isBookmark = pinned
        row.configure(tab: tab)
        if away {
            row.pinName = "A pinned page with a long name of its own"
            row.isAway = true
        }
        return (row, tab)
    }

    private func frames(_ row: TabRowView) -> [NSRect] {
        row.layout()
        return row.subviews.compactMap { $0 as? Label }.filter { !$0.isHidden }.map(\.frame)
    }

    @Test func aMovedOnPinnedRowShowsItsOwnIconUntilThePagesIsKnown() {
        let tab = Tab(url: URL(string: "https://no-icon-yet.example.com/watch")!, title: "Video", spaceID: UUID())
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 220, height: Tokens.Sidebar.rowHeight))
        row.isBookmark = true
        row.bookmarkIcon = IconChoice.pageIcon("star")
        row.isAway = true
        row.configure(tab: tab)
        // The page has no icon yet: the pinned page's, never the globe.
        #expect(row.icon.image === row.bookmarkIcon)
        _ = tab
    }

    @Test func aTabsTitleStaysPutUnderThePointer() {
        let (row, tab) = row(pinned: false, away: false)
        let rest = frames(row)
        row.isHovered = true
        #expect(!row.closeButton.isHidden)
        #expect(frames(row) == rest)
        _ = tab
    }

    @Test func aMovedOnPinnedRowStaysPutUnderThePointer() {
        let (row, tab) = row(pinned: true, away: true)
        let rest = frames(row)
        row.isHovered = true
        #expect(frames(row) == rest)
        _ = tab
    }

    @Test func theTabYouAreOnKeepsRoomForItsCloseButton() {
        let (row, tab) = row(pinned: false, away: false)
        row.isSelected = true
        #expect(!row.closeButton.isHidden)
        // The title ends before the always-visible close button.
        let title = frames(row).first { $0.minX > 0 }
        #expect((title?.maxX ?? .infinity) <= row.closeButton.frame.minX)
        _ = tab
    }
}

/// The sidebar's hot screen edge (#363): the panel against the screen's edge on the sidebar's side, the pointer read
/// top-down as in a window, and only the screen under the pointer considered.
@MainActor
struct EdgeSidebarLayoutTests {
    /// A visible frame below the menu bar, beside the Dock's side of the screen left alone.
    let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let width: CGFloat = 240

    @Test func thePanelRunsDownTheScreensEdgeOnTheSidebarsSide() {
        let left = EdgeSidebarLayout.frame(in: screen, width: width, onRight: false)
        let right = EdgeSidebarLayout.frame(in: screen, width: width, onRight: true)
        #expect(left == NSRect(x: 0, y: 25, width: 240, height: 875))
        #expect(right == NSRect(x: 1200, y: 25, width: 240, height: 875))
        // The visible frame's whole height: never over the menu bar or the Dock.
        #expect(left.minY == screen.minY && left.height == screen.height)
    }

    @Test func thePanelIsNeverWiderThanTheScreen() {
        #expect(EdgeSidebarLayout.frame(in: screen, width: 2000, onRight: true) == screen)
        #expect(EdgeSidebarLayout.frame(in: screen, width: -40, onRight: false).width == 0)
    }

    @Test func thePointerIsReadTopDownFromTheTopOfTheScreen() {
        // The visible frame's top-left corner is the zone's origin; over the menu bar it's above the top.
        #expect(EdgeSidebarLayout.point(NSPoint(x: 0, y: 900), in: screen) == NSPoint(x: 0, y: 0))
        #expect(EdgeSidebarLayout.point(NSPoint(x: 10, y: 25), in: screen) == NSPoint(x: 10, y: 875))
        #expect(EdgeSidebarLayout.point(NSPoint(x: 10, y: 930), in: screen).y == -30)
        // A screen away from the origin keeps its own left edge at zero.
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(EdgeSidebarLayout.point(NSPoint(x: 2000, y: 1080), in: second) == NSPoint(x: 560, y: 0))
    }

    @Test func theEdgeOpensInItsStripAndKeepsOnlyWhatItSummoned() {
        // Top-down, in the zone's own terms: y measured down from the screen's top.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
        let left = EdgeSidebarLayout.zone(in: screen, width: width, onRight: false)
        #expect(left.opens(at: point(2, 400)))
        #expect(!left.opens(at: point(400, 400)))
        #expect(left.keeps(at: point(2, 400)))
        #expect(left.keeps(at: point(120, 400)))
        #expect(!left.keeps(at: point(300, 400)))
        #expect(left.isPast(point(-1000, 400)))
        #expect(!left.isPast(point(120, 400)))

        // On the right the strip is at the screen's right edge, and the sidebar's own side counts as kept.
        let right = EdgeSidebarLayout.zone(in: screen, width: width, onRight: true)
        #expect(right.opens(at: point(1438, 400)))
        #expect(!right.opens(at: point(2, 400)))
        #expect(right.keeps(at: point(1438, 400)))
        #expect(right.keeps(at: point(1300, 400)))
        #expect(!right.keeps(at: point(1000, 400)))
    }

    @Test func onlyTheScreenUnderThePointerIsConsidered() {
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let screens = [screen, second]
        #expect(EdgeSidebarLayout.screen(containing: NSPoint(x: 100, y: 100), in: screens) == 0)
        #expect(EdgeSidebarLayout.screen(containing: NSPoint(x: 2000, y: 100), in: screens) == 1)
        // Over the menu bar, where no visible frame reaches: on none, so no edge.
        #expect(EdgeSidebarLayout.screen(containing: NSPoint(x: 2000, y: 1100), in: screens) == nil)
    }

    @Test func thePanelComesOutForAnotherAppInFrontWhateverTheWindowSidebarShows() {
        // Another app in front: the panel comes out whether the browser's own sidebar is docked, floating or away,
        // because none of that is on screen while the browser is behind another app.
        #expect(EdgeSidebarLayout.canShow(appIsActive: false))
        // Zigzag itself: its own sidebar already comes out at its edge.
        #expect(!EdgeSidebarLayout.canShow(appIsActive: true))
        // The browser window is already on this desktop and not minimized: its own sidebar is there, so no panel.
        #expect(!EdgeSidebarLayout.canShow(appIsActive: false, browserHere: true))
        #expect(EdgeSidebarLayout.canShow(appIsActive: false, browserHere: false))
    }

    @Test func thePanelAndItsBarTakeKeysWithoutTakingTheWindow() {
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        let bar = EdgeCommandBarPopup(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(bar.canBecomeKey)
        #expect(!bar.canBecomeMain)
    }
}

/// The hot screen edge's switch (#363): off until turned on, one change heard per actual change, and the key left as
/// it was found.
@Suite(.serialized)
@MainActor
struct EdgeSidebarSettingTests {
    private func restoring(_ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: EdgeSidebar.defaultsKey) as? Bool
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: EdgeSidebar.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: EdgeSidebar.defaultsKey) }
        }
        body()
    }

    @Test func theSwitchIsOffUntilTurnedOn() {
        restoring {
            UserDefaults.standard.removeObject(forKey: EdgeSidebar.defaultsKey)
            #expect(!EdgeSidebar.isOn)
            EdgeSidebar.isOn = true
            #expect(EdgeSidebar.isOn)
            #expect(UserDefaults.standard.bool(forKey: EdgeSidebar.defaultsKey))
        }
    }

    @Test func aChangeIsHeardOnceAndOnlyWhenItChanges() {
        restoring {
            UserDefaults.standard.removeObject(forKey: EdgeSidebar.defaultsKey)
            nonisolated final class Count: @unchecked Sendable { var heard = 0 }
            let count = Count()
            let token = NotificationCenter.default.addObserver(forName: EdgeSidebar.changed, object: nil, queue: nil) { _ in count.heard += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            EdgeSidebar.isOn = true
            #expect(count.heard == 1)
            EdgeSidebar.isOn = true
            #expect(count.heard == 1)
            EdgeSidebar.isOn = false
            #expect(count.heard == 2)
            EdgeSidebar.isOn = false
            #expect(count.heard == 2)
        }
    }
}

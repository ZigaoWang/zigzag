import AppKit
import Testing
@testable import Zigzag

/// The address bar above the page (Settings › Appearance): where the bar, its buttons and the page go, with the
/// sidebar shown or hidden, framed or borderless.
@MainActor
struct TopBarTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let bar = TopBarView.height
    let inset = Tokens.Metric.cardInset

    @Test func barSitsOnTheTrafficLightsLine() {
        #expect(bar / 2 == Tokens.Sidebar.lightsCenter)
        let frames = TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: 0, trailingInset: 6)
        for rect in frames.buttons + [frames.address] { #expect(rect.midY == Tokens.Sidebar.lightsCenter) }
        #expect(frames.address.height == Tokens.Sidebar.addressHeight)
    }

    @Test func buttonsThenTheAddressToThePagesEdge() {
        let frames = TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: 0, trailingInset: inset)
        #expect(frames.buttons.count == 3)
        #expect(frames.buttons[0].minX == Tokens.Sidebar.edge)
        #expect(frames.buttons[1].minX == frames.buttons[0].maxX && frames.buttons[2].minX == frames.buttons[1].maxX)
        #expect(frames.address.minX > frames.buttons[2].maxX)
        #expect(frames.address.maxX == 1000 - inset)
    }

    @Test func withTheLightsTheButtonsStartAfterThem() {
        let lights: CGFloat = 52
        let frames = TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: lights, trailingInset: 6)
        #expect(frames.buttons[0].minX > Tokens.Sidebar.lightsX + lights)
        // Same room as the sidebar's toggle after them: under a full gap away.
        #expect(frames.buttons[0].minX < Tokens.Sidebar.lightsX + lights + Tokens.Sidebar.lightsGap)
    }

    @Test func withTheSidebarHiddenItsToggleComesFirstAfterTheLights() throws {
        let lights: CGFloat = 52
        let frames = TopBarView.frames(width: 1000, buttons: 3, sidebarButton: true, trafficLightsWidth: lights, trailingInset: 6)
        let toggle = try #require(frames.sidebarButton)
        // Spaced from the lights exactly as the sidebar's own toggle is in its top row.
        let ink = Tokens.Symbol.inkSize("sidebar.left", size: Tokens.Sidebar.glyph).width
        let b = Tokens.Sidebar.button
        #expect(toggle.minX == round(Tokens.Sidebar.lightsX + lights + Tokens.Sidebar.lightsGap - (b - ink) / 2))
        #expect(toggle.midY == Tokens.Sidebar.lightsCenter && toggle.width == b && toggle.height == b)
        #expect(frames.buttons[0].minX == toggle.maxX)
        // Without the lights (full screen), it starts the row.
        let fullScreen = TopBarView.frames(width: 1000, buttons: 3, sidebarButton: true, trafficLightsWidth: 0, leadingInset: inset, trailingInset: inset)
        #expect(fullScreen.sidebarButton?.minX == inset)
        // With the sidebar shown, the sidebar keeps its own: none here.
        #expect(TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: 0, trailingInset: 6).sidebarButton == nil)
    }

    @Test func theSidebarsToggleIsInTheBarOnlyWhileTheSidebarIsHidden() {
        let topBar = TopBarView()
        #expect(topBar.sidebarButton.superview === topBar && topBar.sidebarButton.isHidden)
        topBar.showsSidebarButton = true
        #expect(!topBar.sidebarButton.isHidden)
        topBar.showsSidebarButton = false
        #expect(topBar.sidebarButton.isHidden)
    }

    @Test func theControlsRunFromThePagesLeftEdgeToItsRight() {
        let shown = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: 240)
        // Framed: the back button's edge on the page's left edge, the address's end on its right.
        let framed = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: false, topBar: true)
        var ends = TopBarView.insets(bar: shown, page: framed, window: window)
        var frames = TopBarView.frames(width: shown.width, buttons: 3, trafficLightsWidth: 0, leadingInset: ends.leading, trailingInset: ends.trailing)
        #expect(shown.minX + frames.buttons[0].minX == framed.minX)
        #expect(shown.minX + frames.address.maxX == framed.maxX)
        // Borderless, the page meets the window: the same inset in from both of its edges, clear of the window's.
        let borderless = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: true, topBar: true)
        ends = TopBarView.insets(bar: shown, page: borderless, window: window)
        frames = TopBarView.frames(width: shown.width, buttons: 3, trafficLightsWidth: 0, leadingInset: ends.leading, trailingInset: ends.trailing)
        let lead = shown.minX + frames.buttons[0].minX - borderless.minX, trail = borderless.maxX - (shown.minX + frames.address.maxX)
        #expect(lead == trail && lead == Tokens.Sidebar.edge)
        // The sidebar hidden, framed: the same rule with the page a frame's inset in on both sides.
        let hiddenBar = BrowserRootView.topBarFrame(in: window, sidebarVisible: false, sidebarWidth: 240)
        let hidden = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: 240, edgeToEdge: false, borderless: false, topBar: true)
        ends = TopBarView.insets(bar: hiddenBar, page: hidden, window: window)
        #expect(ends.leading == hidden.minX && hiddenBar.maxX - ends.trailing == hidden.maxX)
    }

    @Test func asTheSidebarGoesTheControlsStartWhereTheyWere() {
        // The sidebar hides: the bar holds still over the whole width, and its controls start from where they were.
        let parent = NSView(frame: window)
        let topBar = TopBarView(frame: NSRect(x: 240, y: 0, width: 1040, height: bar))
        parent.addSubview(topBar)
        let buttons = (0..<3).map { _ in NSView() }, address = NSView()
        topBar.hold(buttons: buttons, address: address)
        topBar.layoutSubtreeIfNeeded()
        let before = topBar.controlPositions
        #expect(before[ObjectIdentifier(buttons[0])]?.minX == 240 + Tokens.Sidebar.edge)
        topBar.frame = NSRect(x: 0, y: 0, width: 1280, height: bar)
        topBar.trafficLightsWidth = 52
        topBar.showsSidebarButton = true
        topBar.slideControls(from: before, curve: Tokens.Motion.slide)
        for view in buttons + [address] {
            #expect(view.frame.offsetBy(dx: topBar.frame.minX, dy: 0) == before[ObjectIdentifier(view)])
        }
        // The toggle, new, appears where it goes and stays there: by the lights, as in the sidebar.
        let frames = TopBarView.frames(width: 1280, buttons: 3, sidebarButton: true, trafficLightsWidth: 52, trailingInset: Tokens.Sidebar.edge)
        #expect(!topBar.sidebarButton.isHidden && topBar.sidebarButton.frame == frames.sidebarButton)
        // Layout leaves them to the slide until it ends.
        topBar.layoutSubtreeIfNeeded()
        #expect(buttons[0].frame.minX == 240 + Tokens.Sidebar.edge)
    }

    @Test func narrowBarNeverGivesTheAddressANegativeWidth() {
        let frames = TopBarView.frames(width: 40, buttons: 3, trafficLightsWidth: 52, trailingInset: 6)
        #expect(frames.address.width == 0)
    }

    @Test func barStartsAtThePageBesideTheSidebarAndAtTheWindowWithoutIt() {
        let shown = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: 240)
        #expect(shown == NSRect(x: 240, y: 0, width: 1040, height: bar))
        let hidden = BrowserRootView.topBarFrame(in: window, sidebarVisible: false, sidebarWidth: 240)
        #expect(hidden == NSRect(x: 0, y: 0, width: 1280, height: bar))
    }

    @Test func framedTheBarIsTheTopOfThePagesCard() {
        // Its buttons and address sit in the card's middle: the bar starts the inset down, the page right under it.
        let barFrame = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: 240, inset: inset)
        #expect(barFrame == NSRect(x: 240, y: inset, width: 1040, height: bar))
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: false, topBar: true, barInset: inset).minY
                == barFrame.maxY)
    }

    @Test func thePagesColorTurnsTheBarsIconsToMatch() {
        let topBar = TopBarView()
        topBar.pageColor = .black
        #expect(topBar.appearance?.name == .darkAqua)
        topBar.pageColor = .white
        #expect(topBar.appearance?.name == .aqua)
        topBar.pageColor = nil
        #expect(topBar.appearance == nil)
    }

    @Test func thePagesColorTakesTheNeutralFills() {
        let topBar = TopBarView()
        let back = SidebarView.chromeButton("chevron.left", toolTip: "")
        let address = AddressView()
        topBar.hold(buttons: [back], address: address)
        topBar.pageColor = .white
        #expect(back.isOnPage && address.isOnPage && topBar.sidebarButton.isOnPage)
        topBar.pageColor = nil
        #expect(!back.isOnPage && !address.isOnPage)
        // Light or dark controls, whichever contrasts more: a mid gray keeps dark ones.
        #expect(TopBarView.isDark(.black) && !TopBarView.isDark(.white))
        #expect(TopBarView.isDark(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)))
        #expect(TopBarView.isDark(NSColor(srgbRed: 0.18, green: 0.44, blue: 0.31, alpha: 1)))
        #expect(!TopBarView.isDark(NSColor(srgbRed: 0.54, green: 0.56, blue: 0.6, alpha: 1)))
    }

    @Test func underThePagesColorTheCardReachesUpUnderTheBar() {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = window
        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.showsTopBar = true
        root.layoutSubtreeIfNeeded()
        let page = root.cardFrame
        #expect(root.card.frame == page && root.card.band == 0)

        root.paintTopBar(.black)
        root.layoutSubtreeIfNeeded()
        // One card: its top is the bar's, in the page's color, and the page itself stays where it was.
        #expect(root.card.frame.minY == root.topBar.frame.minY && root.card.frame.maxY == page.maxY)
        #expect(root.card.frame.minX == page.minX && root.card.frame.width == page.width)
        #expect(root.card.band == page.minY - root.topBar.frame.minY)
        #expect(root.card.bandColor == .black && root.topBar.pageColor == .black)
        #expect(root.cardFrame == page)

        // Two panes have two colors: the plain bar.
        root.splitRatio = 0.5
        root.layoutSubtreeIfNeeded()
        #expect(root.card.band == 0 && root.topBar.pageColor == nil)
        root.splitRatio = nil
        root.layoutSubtreeIfNeeded()
        #expect(root.card.band > 0)

        // No color, or the setting off: as before.
        root.paintTopBar(nil)
        root.layoutSubtreeIfNeeded()
        #expect(root.card.frame == page && root.card.band == 0 && root.card.bandColor == nil)
        root.paintTopBar(.white)
        root.showsTopBar = false
        root.layoutSubtreeIfNeeded()
        #expect(root.card.band == 0 && root.topBar.pageColor == nil)
    }

    @Test func offTheLayoutIsUnchanged() {
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: true, topBar: false)
                == NSRect(x: 240, y: 0, width: 1040, height: 800))
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: false, topBar: false)
                == NSRect(x: 240, y: inset, width: 1040 - inset, height: 800 - inset * 2))
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: 240, edgeToEdge: true, borderless: true, topBar: false) == window)
    }

    @Test func pageStartsUnderTheBar() {
        // Borderless beside the sidebar: flush under the bar, to the window's other edges.
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: true, topBar: true)
                == NSRect(x: 240, y: bar, width: 1040, height: 800 - bar))
        // Framed: the bar stands in for the gap above; the sides and bottom keep theirs.
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: 240, edgeToEdge: false, borderless: false, topBar: true)
                == NSRect(x: 240, y: bar, width: 1040 - inset, height: 800 - bar - inset))
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: 240, edgeToEdge: false, borderless: false, topBar: true)
                == NSRect(x: inset, y: bar, width: 1280 - inset * 2, height: 800 - bar - inset))
        // Edge to edge: everything under the bar.
        #expect(BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: 240, edgeToEdge: true, borderless: true, topBar: true)
                == NSRect(x: 0, y: bar, width: 1280, height: 800 - bar))
    }

    @Test func theAddressMovesBetweenTheSidebarAndTheBar() {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = window
        root.layoutSubtreeIfNeeded()
        #expect(sidebar.address.superview === sidebar)

        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.showsTopBar = true
        root.layoutSubtreeIfNeeded()
        #expect(sidebar.address.superview === root.topBar)
        #expect(sidebar.addressButtons.allSatisfy { $0.superview === root.topBar })
        #expect(!root.topBar.isHidden)
        #expect(root.topBar.frame.minX == root.sidebarWidth)
        #expect(root.card.frame.minY == root.topBar.frame.maxY)
        // The favorites start where the page does: as far under the top row as the page.
        #expect(sidebar.favorites.frame.minY == root.card.frame.minY)
        // The back button starts and the address ends the same inset in from the page's edges.
        let address = sidebar.address.convert(sidebar.address.bounds, to: root)
        let back = sidebar.backButton.convert(sidebar.backButton.bounds, to: root)
        #expect(back.minX - root.cardFrame.minX == root.cardFrame.maxX - address.maxX)
        #expect(address.maxX == root.bounds.maxX - max(Tokens.Sidebar.edge, root.bounds.maxX - root.cardFrame.maxX))
        // All of the top row on one line, the bar's middle: the sidebar's toggle (and the lights) too.
        let line = root.topBar.frame.minY + Tokens.Sidebar.lightsCenter
        let toggle = sidebar.sidebarButton.convert(sidebar.sidebarButton.bounds, to: root)
        #expect(back.midY == line && address.midY == line && toggle.midY == line)
        #expect(sidebar.trafficLightCenterY == line)

        sidebar.holdsAddress = true
        root.showsTopBar = false
        root.layoutSubtreeIfNeeded()
        #expect(sidebar.address.superview === sidebar)
        #expect(sidebar.addressButtons.allSatisfy { $0.superview === sidebar })
        #expect(root.topBar.isHidden)
        #expect(sidebar.address.frame.minY == Tokens.Sidebar.addressTop)
    }
}

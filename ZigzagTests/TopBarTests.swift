import AppKit
import JavaScriptCore
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
        // The bar as the top of the page's card: the address ends an inset before the card's right edge, never on it.
        ends = TopBarView.insets(bar: shown, page: framed, window: window, onCard: true)
        frames = TopBarView.frames(width: shown.width, buttons: 3, trafficLightsWidth: 0, leadingInset: ends.leading, trailingInset: ends.trailing)
        #expect(shown.minX + frames.buttons[0].minX == framed.minX)
        #expect(shown.minX + frames.address.maxX == framed.maxX - Tokens.Sidebar.edge)
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
        ends = TopBarView.insets(bar: hiddenBar, page: hidden, window: window, onCard: true)
        #expect(hiddenBar.maxX - ends.trailing == hidden.maxX - Tokens.Sidebar.edge)
        // Borderless, on the card or not, it's the same inset from the window's edge.
        #expect(TopBarView.insets(bar: shown, page: borderless, window: window, onCard: true).trailing == Tokens.Sidebar.edge)
    }

    /// Where a control gliding to its place (`Motion.glide`) is shown starting from, in its superview's terms; its
    /// own frame when it isn't gliding.
    private func glideStart(_ view: NSView) -> NSRect {
        var start = view.frame
        if let move = view.layer?.animation(forKey: "glide") as? CABasicAnimation, let from = (move.fromValue as? NSValue)?.caTransform3DValue {
            start.origin.x += from.m41
            start.origin.y += from.m42
        }
        if let grow = view.layer?.animation(forKey: "glideSize") as? CABasicAnimation, let from = grow.fromValue as? NSValue {
            start.size = from.sizeValue
        }
        return start
    }

    @Test func heldOverBothPlacesTheRowIsWhereTheBarWillBe() {
        // Full screen, framed: the sidebar comes back and the frame with it, so the bar moves the inset down. While
        // it's held over both places its row is already at the lower one: the controls glide down with the page,
        // and nothing drops when the bar takes its own frame at the end.
        let parent = NSView(frame: window)
        parent.wantsLayer = true
        let topBar = TopBarView(frame: NSRect(x: 0, y: 0, width: 1280, height: bar))
        parent.addSubview(topBar)
        let buttons = (0..<3).map { _ in NSView() }, address = NSView()
        (buttons + [address]).forEach { $0.wantsLayer = true }
        topBar.hold(buttons: buttons, address: address)
        topBar.layoutSubtreeIfNeeded()
        let before = topBar.controlPositions
        topBar.frame = NSRect(x: 0, y: 0, width: 1280, height: bar + inset)
        topBar.rowTop = inset
        topBar.slideControls(from: before, curve: Tokens.Motion.edgeSlide)
        // In their new places at once, the inset lower, and shown starting from where they were.
        let held = buttons[0].frame.minY
        #expect(held == before[ObjectIdentifier(buttons[0])]!.minY + inset)
        if !Tokens.Motion.reduceMotion {
            for view in buttons + [address] { #expect(glideStart(view) == before[ObjectIdentifier(view)]) }
        }
        // The bar in its own frame, the inset down: the same place in the window.
        topBar.frame = NSRect(x: 0, y: inset, width: 1280, height: bar)
        topBar.rowTop = 0
        topBar.layoutSubtreeIfNeeded()
        #expect(topBar.frame.minY + buttons[0].frame.minY == held)
    }

    @Test func theHeldToggleStaysWhereTheSidebarsLands() {
        // Full screen, framed: the sidebar comes back and the bar's row moves down with the frame. The toggle held
        // for the sidebar's own keeps to where that one lands in the window, not to the row.
        let topBar = TopBarView(frame: NSRect(x: 0, y: 0, width: 1280, height: bar + inset))
        topBar.rowTop = inset
        topBar.heldSidebarButtonOrigin = NSPoint(x: 6, y: 9)
        topBar.layoutSubtreeIfNeeded()
        #expect(!topBar.sidebarButton.isHidden && topBar.sidebarButton.frame.origin == NSPoint(x: 6, y: 9))
        // The bar in its own frame, the inset down: the same place in the window.
        topBar.frame = NSRect(x: 240, y: inset, width: 1040, height: bar)
        topBar.rowTop = 0
        topBar.layoutSubtreeIfNeeded()
        #expect(topBar.sidebarButton.frame.offsetBy(dx: 240, dy: inset).origin == NSPoint(x: 6, y: 9))
        topBar.heldSidebarButtonOrigin = nil
        #expect(topBar.sidebarButton.isHidden)
    }

    @Test func asTheSidebarGoesTheControlsStartWhereTheyWere() {
        // The sidebar hides: the bar holds still over the whole width, and its controls start from where they were.
        let parent = NSView(frame: window)
        parent.wantsLayer = true
        let topBar = TopBarView(frame: NSRect(x: 240, y: 0, width: 1040, height: bar))
        parent.addSubview(topBar)
        let buttons = (0..<3).map { _ in NSView() }, address = NSView()
        (buttons + [address]).forEach { $0.wantsLayer = true }
        topBar.hold(buttons: buttons, address: address)
        topBar.layoutSubtreeIfNeeded()
        let before = topBar.controlPositions
        #expect(before[ObjectIdentifier(buttons[0])]?.minX == 240 + Tokens.Sidebar.edge)
        topBar.frame = NSRect(x: 0, y: 0, width: 1280, height: bar)
        topBar.trafficLightsWidth = 52
        topBar.showsSidebarButton = true
        topBar.slideControls(from: before, curve: Tokens.Motion.edgeSlide)
        // Each is in its new place at once, so layout and clicks see the truth, and is shown gliding there from
        // where it was: the address from its old width too.
        let frames = TopBarView.frames(width: 1280, buttons: 3, sidebarButton: true, trafficLightsWidth: 52, trailingInset: Tokens.Sidebar.edge)
        #expect(buttons.map(\.frame) == frames.buttons && address.frame == frames.address)
        if !Tokens.Motion.reduceMotion {
            for view in buttons + [address] {
                #expect(glideStart(view).offsetBy(dx: topBar.frame.minX, dy: 0) == before[ObjectIdentifier(view)])
            }
        }
        // The toggle, new, appears where it goes and stays there: by the lights, as in the sidebar.
        #expect(!topBar.sidebarButton.isHidden && topBar.sidebarButton.frame == frames.sidebarButton)
        #expect(topBar.sidebarButton.layer?.animation(forKey: "glide") == nil)
        // Layout in the middle of it changes nothing.
        topBar.layoutSubtreeIfNeeded()
        #expect(buttons.map(\.frame) == frames.buttons)
    }

    @Test func theSiteIsInAPillOverThePagesMiddleWithTheButtonsAtTheEnd() throws {
        // #275: address buttons trailing, pill sized to the site and centered over the page, like a split pane's strip.
        let frames = TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: 0, trailingInset: inset,
                                       addressWidth: 54, pill: 120, pillCenter: 480)
        let pill = try #require(frames.pill)
        #expect(frames.address.maxX == 1000 - inset && frames.address.width == 54)
        #expect(pill.width == 120 && pill.midX == 480)
        #expect(pill.height == Tokens.Pane.addressHeight && pill.midY == Tokens.Sidebar.lightsCenter)
        #expect(pill.minX > frames.buttons[2].maxX && pill.maxX < frames.address.minX)
        #expect(pill == PaneHeaderView.pillFrame(center: 480, room: frames.buttons[2].maxX + Tokens.Space.x2...frames.address.minX - Tokens.Space.x2,
                                                 fitting: 120, overCard: false, midY: Tokens.Sidebar.lightsCenter))
        // On the card: field width, like a pane over its card.
        let onCard = TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: 0, trailingInset: inset,
                                       addressWidth: 54, pill: 120, pillCenter: 480, onCard: true)
        #expect(onCard.pill?.width == PaneHeaderView.addressMaxWidth && onCard.pill?.midX == 480)
        // Centered near the buttons: nudged clear instead of cut.
        let nudged = try #require(TopBarView.frames(width: 1000, buttons: 3, trafficLightsWidth: 0, trailingInset: inset,
                                                    addressWidth: 54, pill: 300, pillCenter: 900).pill)
        #expect(nudged.width == 300 && nudged.maxX == frames.address.minX - Tokens.Space.x2)
    }

    @Test func theBarKeepsTheAddressesButtonsAndTheSidebarGetsItsFieldBack() {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = window
        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.showsTopBar = true
        root.topBar.showPage(url: URL(string: "https://fontsinuse.com"), notSecure: false)
        root.layoutSubtreeIfNeeded()
        let bar = root.topBar, address = sidebar.address
        #expect(address.buttonsOnly && address.frame.width == address.buttonsWidth)
        #expect(!bar.pill.isHidden && bar.pill.frame.width == bar.pill.fittingWidth)
        // Centered over the page.
        #expect(abs(bar.frame.minX + bar.pill.frame.midX - root.cardFrame.midX) <= 0.5)
        // Site Controls is the address's own button, last, at the page's right edge.
        #expect(address.siteControlsButton.superview === address && !address.siteControlsButton.isHidden)
        #expect(address.frame.maxX == bar.bounds.width - bar.trailingInset)
        #expect(address.siteControlsButton.frame.maxX == address.bounds.width)
        // Back in the sidebar: the field again.
        sidebar.holdsAddress = true
        #expect(!address.buttonsOnly)
        root.layoutSubtreeIfNeeded()
        #expect(bar.pill.isHidden)
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
        #expect(PageBar.isDark(.black) && !PageBar.isDark(.white))
        #expect(PageBar.isDark(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)))
        #expect(PageBar.isDark(NSColor(srgbRed: 0.18, green: 0.44, blue: 0.31, alpha: 1)))
        #expect(!PageBar.isDark(NSColor(srgbRed: 0.54, green: 0.56, blue: 0.6, alpha: 1)))
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
        #expect(root.topBar.pageColor == .black)
        #expect(root.cardFrame == page && root.card.pageFrame == page)

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
        #expect(root.card.frame == page && root.card.band == 0)
        root.paintTopBar(.white)
        root.showsTopBar = false
        root.layoutSubtreeIfNeeded()
        #expect(root.card.band == 0 && root.topBar.pageColor == nil)
    }

    @Test func underABarOnThePagesCardTheGlassStaysBesideTheSidebar() {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = window
        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.layoutSubtreeIfNeeded()
        let withoutBar = root.glassFrame
        #expect(withoutBar.width < window.width / 2)

        // The bar in the page's color is the card's top: no glass behind the page or the bar.
        root.showsTopBar = true
        root.paintTopBar(.black)
        root.layoutSubtreeIfNeeded()
        #expect(root.glassFrame == withoutBar)
        #expect(!root.glassFrame.contains(NSPoint(x: root.card.frame.midX, y: root.topBar.frame.midY)))

        // A bar on the frame, or a see-through color, still has glass under it.
        root.paintTopBar(nil)
        root.layoutSubtreeIfNeeded()
        #expect(root.glassFrame.contains(root.topBar.frame))
        root.paintTopBar(NSColor.black.withAlphaComponent(0.5))
        root.layoutSubtreeIfNeeded()
        #expect(root.glassFrame.contains(root.topBar.frame))
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
        #expect(sidebar.favoritesScroll.frame.minY + FavoriteTile.badgeOverhang == root.card.frame.minY)
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

    // MARK: Split view (#97)

    @Test func inSplitViewEachPanesStripIsTheBarOverItsPane() throws {
        let lights: CGFloat = 52
        let panes: [ClosedRange<CGFloat>] = [0...639, 640...1280]
        let strips = TopBarView.stripFrames(panes: panes, sidebarButton: true, trafficLightsWidth: lights,
                                            leadingInset: 0, inset: Tokens.Sidebar.edge)
        #expect(strips.count == 2)
        // The bar's height, on the lights' line.
        for strip in strips { #expect(strip.frame.minY == 0 && strip.frame.height == bar && strip.frame.midY == Tokens.Sidebar.lightsCenter) }
        // The first starts after the lights and the sidebar's toggle, where the bar's own back button would be.
        let own = TopBarView.frames(width: 1280, buttons: 3, sidebarButton: true, trafficLightsWidth: lights, trailingInset: Tokens.Sidebar.edge)
        let toggle = try #require(own.sidebarButton)
        #expect(strips[0].frame.minX == toggle.maxX && strips[0].frame.minX == own.buttons[0].minX)
        #expect(strips[0].frame.maxX == 639 - Tokens.Sidebar.edge)
        // The second keeps the inset from its pane's edges, the window's edge included.
        #expect(strips[1].frame.minX == 640 + Tokens.Sidebar.edge && strips[1].frame.maxX == 1280 - Tokens.Sidebar.edge)
        // Each address centers over its pane's middle, not the strip's.
        #expect(strips[0].frame.minX + strips[0].addressCenter == 319.5)
        #expect(strips[1].frame.minX + strips[1].addressCenter == 960)
        // With the sidebar shown there's nothing at the row's leading end: the first starts at its pane, framed.
        let framed = TopBarView.stripFrames(panes: [0...500, 508...1032], trafficLightsWidth: 0, leadingInset: 0, inset: 0)
        #expect(framed[0].frame.minX == 0 && framed[1].frame.minX == 508 && framed[1].frame.maxX == 1032)
    }

    private func splitRoot(vertical: Bool = false) -> (BrowserRootView, SidebarView) {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = window
        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.showsTopBar = true
        root.splitRatio = 0.5
        root.splitVertical = vertical
        root.card.showsHeader = true
        root.secondCard.showsHeader = true
        root.layoutSubtreeIfNeeded()
        return (root, sidebar)
    }

    @Test func inSplitViewThePanesStripsTakeTheBarsRow() {
        let (root, sidebar) = splitRoot()
        let panes = root.paneFrames
        #expect(root.stripsInBar)
        // The bar's own back, forward, reload and address step aside: one set of controls per page.
        #expect(sidebar.addressButtons.allSatisfy(\.isHidden) && sidebar.address.isHidden)
        for (card, pane) in [(root.card, panes.left), (root.secondCard, panes.right!)] {
            let strip = card.header
            #expect(strip.superview === root.topBar && strip.isInBar && !strip.isHidden)
            let frame = strip.convert(strip.bounds, to: root)
            // In the bar's row, over its own pane, on the lights' line.
            #expect(frame.minY == root.topBar.frame.minY && frame.height == bar)
            #expect(frame.midY == root.topBar.frame.minY + Tokens.Sidebar.lightsCenter)
            #expect(frame.minX >= pane.minX && frame.maxX <= pane.maxX)
            // The page starts right under the bar, with no strip of its own: the row the bar gave up.
            #expect(card.frame.minY == root.topBar.frame.maxY && card.pageFrame.minY == root.topBar.frame.maxY)
        }
        // A click on a strip picks its pane.
        #expect(root.paneTargets.left.minY == root.topBar.frame.minY && root.paneTargets.right?.minY == root.topBar.frame.minY)
    }

    @Test func aZoomedPaneTakesItsStripWithIt() {
        let (root, _) = splitRoot()
        root.setZoomedPane(0, animated: false)
        root.layoutSubtreeIfNeeded()
        // Enlarged over the rest, its strip is on its card, at its top, not left behind in the bar.
        let strip = root.card.header
        #expect(strip.isDescendant(of: root.card) && !strip.isHidden && !strip.isInBar)
        #expect(root.card.frame == root.zoomFrame)
        // The other pane's strip stays up in the bar.
        #expect(root.secondCard.header.superview === root.topBar && root.stripsInBar)
        // Back in its place, its strip goes up again.
        root.setZoomedPane(nil, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(root.card.header.superview === root.topBar && root.card.header.isInBar)
    }

    @Test func stackedOnlyTheTopPanesStripGoesUp() {
        let (root, sidebar) = splitRoot(vertical: true)
        #expect(root.card.header.superview === root.topBar)
        // The bottom pane has no row above it: it keeps its strip on its card.
        #expect(root.secondCard.header.superview !== root.topBar && root.secondCard.header.isDescendant(of: root.secondCard))
        #expect(!root.secondCard.header.isHidden && !root.secondCard.header.isInBar)
        #expect(sidebar.address.isHidden)
        #expect(root.paneTargets.right == root.paneFrames.right)
    }

    @Test func stackedTheZoomedTopPaneLeavesTheBarsControlsAside() {
        let (root, sidebar) = splitRoot(vertical: true)
        root.setZoomedPane(0, animated: false)
        root.layoutSubtreeIfNeeded()
        // The top pane took the only strip in the bar with it; the bar's own controls stay out all the same.
        #expect(root.card.header.isDescendant(of: root.card) && !root.card.header.isInBar)
        #expect(sidebar.addressButtons.allSatisfy(\.isHidden) && sidebar.address.isHidden)
        #expect(root.stripsInBar)
        root.setZoomedPane(nil, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(root.card.header.superview === root.topBar && sidebar.address.isHidden)
    }

    @Test func outOfSplitOrWithTheBarOffTheStripsGoBack() {
        var (root, sidebar) = splitRoot()
        root.splitRatio = nil
        root.card.showsHeader = false
        root.secondCard.showsHeader = false
        root.layoutSubtreeIfNeeded()
        #expect(!root.stripsInBar)
        #expect(root.card.header.isDescendant(of: root.card) && root.card.header.isHidden && !root.card.header.isInBar)
        #expect(sidebar.addressButtons.allSatisfy { !$0.isHidden && $0.alphaValue == 1 } && !sidebar.address.isHidden)
        #expect(root.card.header.alphaValue == 1)

        // The setting turned off while split: the strips go back on their cards, and the sidebar's controls show again.
        (root, sidebar) = splitRoot()
        sidebar.holdsAddress = true
        root.showsTopBar = false
        root.layoutSubtreeIfNeeded()
        for card in [root.card, root.secondCard] {
            #expect(card.header.isDescendant(of: card) && !card.header.isHidden && !card.header.isInBar)
            #expect(card.header.frame.height == PaneHeaderView.height)
        }
        #expect(sidebar.address.superview === sidebar && !sidebar.address.isHidden)
        #expect(sidebar.addressButtons.allSatisfy { !$0.isHidden })
        // And on again.
        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.showsTopBar = true
        root.layoutSubtreeIfNeeded()
        #expect(root.card.header.superview === root.topBar && sidebar.address.isHidden)
    }

    @Test func theStripOfThePaneYoureNotInDimsInTheBarToo() {
        let (root, _) = splitRoot()
        root.secondCard.isUnfocusedPane = true
        #expect(root.secondCard.header.alphaValue == Tokens.Color.unfocusedPaneAlpha && root.card.header.alphaValue == 1)
    }

    @Test func withTheSidebarHiddenTheFirstStripStartsAfterTheLightsAndToggle() {
        let (root, _) = splitRoot()
        root.setSidebarVisible(false, animated: false)
        root.topBar.trafficLightsWidth = 52
        root.topBar.showsSidebarButton = true
        root.layoutSubtreeIfNeeded()
        let strip = root.card.header.convert(root.card.header.bounds, to: root)
        let toggle = root.topBar.sidebarButton.convert(root.topBar.sidebarButton.bounds, to: root)
        #expect(strip.minX == toggle.maxX && toggle.minX > Tokens.Sidebar.lightsX + 52)
        #expect(root.card.frame.minX == 0 && root.card.frame.minY == root.topBar.frame.maxY)
    }

    /// Runs `body` with Borderless page set to `borderless` for this process only (the arguments domain, never saved),
    /// then as it was.
    private func withBorderless(_ borderless: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = before
        arguments["borderlessPage"] = borderless
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(before, forName: UserDefaults.argumentDomain) }
        body()
    }

    /// Framed, each pane whose strip is up in the bar is one card with it: the card reaches up to the bar's top, its
    /// page starts under the bar, and the gap between the panes stays open up to the window's top.
    @Test func framedEachPaneInTheBarIsOneCardWithItsStrip() {
        withBorderless(false) {
            let (root, _) = splitRoot()
            let barTop = root.topBarFrame.minY
            #expect(barTop == inset)
            let panes = root.tileFrames
            for (card, pane) in zip([root.card, root.secondCard], panes) {
                #expect(card.frame == NSRect(x: pane.minX, y: barTop, width: pane.width, height: pane.maxY - barTop))
                #expect(card.pageFrame == pane && card.band == pane.minY - barTop)
                #expect(card.header.isInBar && card.header.isOnCard)
            }
            #expect(root.secondCard.frame.minX - root.card.frame.maxX == root.paneGap)
            // The bar has no color of its own across the gap.
            #expect(root.topBar.pageColor == nil)
        }
    }

    @Test func framedStackedOnlyTheTopPaneJoinsTheBar() {
        withBorderless(false) {
            let (root, _) = splitRoot(vertical: true)
            let panes = root.tileFrames
            #expect(root.card.frame.minY == root.topBarFrame.minY && root.card.pageFrame == panes[0])
            #expect(root.secondCard.frame == panes[1] && root.secondCard.band == 0)
            #expect(!root.secondCard.header.isOnCard)
        }
    }

    @Test func framedTheTopRowOfFourJoinsTheBar() {
        withBorderless(false) {
            let (root, _) = splitRoot()
            root.thirdCard.showsHeader = true
            root.fourthCard.showsHeader = true
            root.setTiles(TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight]), animated: false)
            root.layoutSubtreeIfNeeded()
            let panes = root.tileFrames, barTop = root.topBarFrame.minY
            for i in 0..<2 { #expect(root.paneCards[i].frame.minY == barTop && root.paneCards[i].pageFrame == panes[i]) }
            for i in 2..<4 { #expect(root.paneCards[i].frame == panes[i] && root.paneCards[i].band == 0) }
        }
    }

    @Test func framedAZoomedPaneLeavesTheBarAndComesBack() {
        withBorderless(false) {
            let (root, _) = splitRoot()
            root.setZoomedPane(1, animated: false)
            root.layoutSubtreeIfNeeded()
            #expect(root.secondCard.frame == root.zoomFrame && root.secondCard.band == 0)
            #expect(root.card.frame.minY == root.topBarFrame.minY)
            root.setZoomedPane(nil, animated: false)
            root.layoutSubtreeIfNeeded()
            #expect(root.secondCard.frame.minY == root.topBarFrame.minY && root.secondCard.pageFrame == root.tileFrames[1])
        }
    }

    @Test func framedTheSidebarHiddenOrOnTheRightKeepsThePanesJoined() {
        withBorderless(false) {
            let (root, _) = splitRoot()
            for (visible, onRight) in [(false, false), (true, true), (false, true)] {
                root.setSidebarVisible(visible, animated: false)
                root.setSidebarOnRight(onRight, animated: false)
                root.layoutSubtreeIfNeeded()
                for (card, pane) in zip([root.card, root.secondCard], root.tileFrames) {
                    #expect(card.frame.minY == root.topBarFrame.minY && card.pageFrame == pane, "visible \(visible), right \(onRight)")
                }
            }
        }
    }

    @Test func splitAutohideMovesOnlyItsOwnPane() {
        withBorderless(false) {
            let (root, _) = splitRoot()
            root.autohidesBar = true
            root.barHoldsAddress = true
            root.layoutSubtreeIfNeeded()
            let panes = root.tileFrames, barTop = root.topBarFrame.minY
            let other = (frame: root.secondCard.frame, band: root.secondCard.band, page: root.secondCard.pageFrame)
            let travel = root.autohideTravel(at: 0)
            #expect(travel == root.topBarFrame.maxY)
            let half = travel / 2
            root.setAutohideOffset(half, at: 0)
            root.layoutSubtreeIfNeeded()
            #expect(root.autohideOffset(at: 0) == half)
            #expect(root.autohideOffset(at: 1) == 0)
            #expect(!root.barPutAway && root.barOnScreen)
            // The other pane keeps its strip and its page exactly as they were.
            #expect(root.secondCard.frame == other.frame)
            #expect(root.secondCard.band == other.band && root.secondCard.pageFrame == other.page)
            // This pane's card still reaches the bar's top, its page rises under it, and its strip rides up.
            #expect(root.card.frame.minY == barTop)
            #expect(root.card.band == panes[0].minY - barTop - min(half, bar))
            #expect(root.card.pageFrame.minY == panes[0].minY - min(half, bar))
            #expect(root.card.header.isInBar && !root.card.header.isHidden)
            #expect(root.topBar.stripOffsets == [half, 0])
            #expect(root.card.header.convert(root.card.header.bounds, to: root).minY == root.topBar.frame.minY - half)
        }
    }

    @Test func aSplitBarFullyAwayStaysAwayWithoutTakingTheOtherWithIt() {
        withBorderless(false) {
            let (root, _) = splitRoot()
            root.autohidesBar = true
            root.barHoldsAddress = true
            root.layoutSubtreeIfNeeded()
            let other = root.secondCard.frame
            root.setAutohideOffset(root.autohideTravel(at: 0), at: 0)
            root.layoutSubtreeIfNeeded()
            #expect(root.autohideOffset(at: 0) == root.autohideTravel(at: 0))
            #expect(root.autohideOffset(at: 1) == 0)
            #expect(!root.barPutAway && root.barOnScreen)
            #expect(root.secondCard.frame == other)
            #expect(root.card.pageFrame.minY == root.topBarFrame.minY)
            // Fully out, its strip is above the window, not handed back to the card beneath it.
            #expect(root.card.header.isInBar)
            #expect(root.card.header.convert(root.card.header.bounds, to: root).maxY <= 0)
            // Only when every pane's own bar is away is the row put away.
            root.setAutohideOffset(root.autohideTravel(at: 1), at: 1)
            root.layoutSubtreeIfNeeded()
            #expect(root.barPutAway && !root.barOnScreen)
            #expect(root.secondCard.header.isInBar)
            for i in 0..<2 { #expect(root.paneCards[i].pageFrame.minY == root.topBarFrame.minY) }
            // The bar back: each pane has its own again.
            root.setBarPutAway(false, animated: false)
            root.layoutSubtreeIfNeeded()
            #expect(!root.barPutAway && root.barOnScreen)
            for i in 0..<2 { #expect(root.paneCards[i].pageFrame == root.tileFrames[i]) }
        }
    }

    @Test func aStackedPaneKeepsItsBarOnItsOwnCardWhenThatBarGoes() {
        withBorderless(false) {
            let (root, _) = splitRoot(vertical: true)
            root.autohidesBar = true
            root.barHoldsAddress = true
            root.layoutSubtreeIfNeeded()
            let top = (frame: root.card.frame, band: root.card.band)
            let lower = root.secondCard.frame
            #expect(!root.secondCard.header.isInBar)
            #expect(root.secondCard.pageTop == PaneHeaderView.height)
            #expect(root.autohideTravel(at: 1) == PaneHeaderView.height)
            root.setAutohideOffset(10, at: 1)
            root.layoutSubtreeIfNeeded()
            #expect(root.autohideOffset(at: 1) == 10)
            #expect(root.autohideOffset(at: 0) == 0)
            // The card stays where it is; its strip slides up inside it and the page grows into the room.
            #expect(root.secondCard.frame == lower)
            #expect(root.secondCard.pageTop == PaneHeaderView.height - 10)
            #expect(root.secondCard.header.frame.minY == root.secondCard.bounds.height - PaneHeaderView.height + 10)
            #expect(root.card.frame == top.frame && root.card.band == top.band)
        }
    }

    /// The scroll report knows which pane its page is in: a split's other bar stays exactly where it was.
    @Test func aSplitScrollHidesOnlyItsOwnBar() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = [Tab(url: URL(string: "https://example.com/autohide/0")!, title: "A", spaceID: space),
                    Tab(url: URL(string: "https://example.com/autohide/1")!, title: "B", spaceID: space)]
        manager.adopt(tabs, in: space)
        manager.makeSplit(tabs[0], with: tabs[1])
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.setTiles(manager.split(for: tabs[0])?.shape, animated: false)
        root.layoutSubtreeIfNeeded()
        let other = root.secondCard.frame

        // The page's first report sets its place; the next one scrolls it far down.
        controller.pageScrolled(to: 0, trusted: true, editing: false, inPane: 0, tab: tabs[0])
        controller.pageScrolled(to: 500, trusted: true, editing: false, inPane: 0, tab: tabs[0])
        #expect(root.autohideOffset(at: 0) > 0)
        #expect(root.autohideOffset(at: 1) == 0)
        #expect(root.secondCard.frame == other)

        // The other pane scrolls: its own bar goes, and the first pane's is left where it was.
        let first = root.autohideOffset(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false, inPane: 1, tab: tabs[1])
        controller.pageScrolled(to: 500, trusted: true, editing: false, inPane: 1, tab: tabs[1])
        #expect(root.autohideOffset(at: 1) > 0)
        #expect(root.autohideOffset(at: 0) == first)
    }

    /// A page's scroll bar is one gesture from press to release: once that drag has taken the bar fully out, dragging
    /// the same bar back up leaves it out. A fresh drag is a new gesture and brings it back.
    @Test func aScrollBarDragThatClosedTheBarDoesNotReopenIt() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/autohide/scrollbar")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)

        // The drag starts at the top, then takes the bar all the way out.
        controller.pageScrolled(to: 0, trusted: true, editing: false, dragging: true, inPane: 0, tab: tab)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false, dragging: true, inPane: 0, tab: tab)
        #expect(root.autohideOffset(at: 0) == travel)

        // The same drag comes back up: the bar stays out.
        controller.pageScrolled(to: travel, trusted: true, editing: false, dragging: true, inPane: 0, tab: tab)
        #expect(root.autohideOffset(at: 0) == travel)

        // The drag ends; a fresh drag is a new gesture, and the same upward travel now brings it back.
        controller.pageScrolled(to: travel, trusted: true, editing: false, dragging: false, inPane: 0, tab: tab)
        controller.pageScrolled(to: travel, trusted: true, editing: false, dragging: true, inPane: 0, tab: tab)
        controller.pageScrolled(to: travel - 12, trusted: true, editing: false, dragging: true, inPane: 0, tab: tab)
        #expect(root.autohideOffset(at: 0) == travel - 12)
    }

    /// The bar comes back whole, not just its controls: the page card reaches up under it again, in the page's color,
    /// and the bar itself is there. Both a jump and the pointer's animated reveal end in that state.
    @Test func theBarComesBackWholeAfterAHide() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/autohide/whole")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.paintTopBar(.systemRed)
        root.layoutSubtreeIfNeeded()
        let openFrame = root.card.frame
        let openBand = root.card.band
        let openBar = root.topBar.frame
        #expect(openBand > 0 && root.topBar.pageColor == .systemRed)

        root.setBarPutAway(true, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(root.card.band == 0)

        root.setBarPutAway(false, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(root.card.frame == openFrame)
        #expect(root.card.band == openBand)
        #expect(root.topBar.frame == openBar && !root.topBar.isHidden)
        #expect(root.topBar.pageColor == .systemRed)

        // And the reveal the pointer asks for, which animates, leaves the same state behind.
        root.setBarPutAway(true, animated: false)
        root.setBarPutAway(false, animated: true)
        root.layoutSubtreeIfNeeded()
        #expect(root.card.band == openBand)
        #expect(root.topBar.frame == openBar && !root.topBar.isHidden)
        #expect(root.topBar.pageColor == .systemRed)
    }

    /// The page's reports are coalesced to one per display frame, keeping the last place and any real gesture.
    @Test func theScrollScriptKeepsOneReportPerFrame() {
        let script = ScrollMessages.script.source
        #expect(script.contains("requestAnimationFrame"))
        #expect(script.contains("pending = next"))
        #expect(script.contains("pending = null"))
    }

    /// A window with one page and an Autohide bar, for the scroll rules.
    private func autohideWindow(_ path: String) -> (BrowserWindowController, TabManager, Tab) {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        let tab = Tab(url: URL(string: "https://example.com/\(path)")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        return (controller, manager, tab)
    }

    /// The bar's travel takes its part of the scroll: the page scrolls back by it, and that scroll back is not the
    /// person's, so the page's own movement is what moves the bar.
    @Test func thePagesOwnMovementMovesTheBar() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let (controller, manager, _) = autohideWindow("own-movement")
        defer { controller.window?.close(); manager.invalidate() }
        let root = controller.root
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: 10, by: 10, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == 10)
        // The scroll back to the top that the travel took: no movement of the person's, and not a trip to the top.
        controller.pageScrolled(to: 0, by: 0, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == 10)
        controller.pageScrolled(to: 10, by: 10, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == 20)
    }

    /// The pointer at the window's top brings the bar back; lower down it leaves it away.
    @Test func thePointerAtTheTopBringsTheBarBack() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let (controller, manager, _) = autohideWindow("pointer-top")
        defer { controller.window?.close(); manager.invalidate() }
        let root = controller.root
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        controller.pointerMoved(to: NSPoint(x: 450, y: 40))
        #expect(root.autohideOffset(at: 0) == travel)
        controller.pointerMoved(to: NSPoint(x: 450, y: 2))
        #expect(root.autohideOffset(at: 0) == 0)
    }

    /// Another tab is shown with its bar there, whatever the last one's scroll did.
    @Test func switchingTabsBringsTheBarBack() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let (controller, manager, tab) = autohideWindow("switch-a")
        defer { controller.window?.close(); manager.invalidate() }
        let other = Tab(url: URL(string: "https://example.com/switch-b")!, title: "B", spaceID: tab.spaceID)
        manager.adopt([other], in: tab.spaceID)
        manager.select(tab)
        let root = controller.root
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false, tab: tab)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false, tab: tab)
        #expect(root.autohideOffset(at: 0) == travel)
        manager.select(other)
        #expect(root.autohideOffset(at: 0) == 0)
    }

    /// A bar left part way out when the scroll stops goes to the nearer end; a finger still on the trackpad keeps it.
    @Test func aBarLeftPartWayOutSettles() throws {
        #expect(BrowserWindowController.settledOffset(10, travel: 50) == 0)
        #expect(BrowserWindowController.settledOffset(25, travel: 50) == 50)
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let (controller, manager, _) = autohideWindow("settle")
        defer { controller.window?.close(); manager.invalidate() }
        let root = controller.root
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel / 4, trusted: true, editing: false)
        controller.settleAutohide()
        #expect(root.autohideOffset(at: 0) == 0)
        controller.pageScrolled(to: travel, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel * 3 / 4)
        // Fingers still down: it stays where they left it.
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        controller.noteScrollGesture(try #require(NSEvent(cgEvent: cg)), inPane: 0)
        controller.settleAutohide()
        #expect(root.autohideOffset(at: 0) == travel * 3 / 4)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        controller.noteScrollGesture(try #require(NSEvent(cgEvent: cg)), inPane: 0)
        controller.settleAutohide()
        #expect(root.autohideOffset(at: 0) == travel)
    }

    /// The Whole Screen owns the bar: Autohide stands down while it lasts, with the bar's offset gone.
    @Test func theWholeScreenSuppressesAutohide() {
        let before = Library.shared.snapshot
        let place = BrowserRootView.addressBarPlace
        defer { Library.shared.restore(before); BrowserRootView.addressBarPlace = place }
        BrowserRootView.addressBarPlace = .autohide
        let (controller, manager, tab) = autohideWindow("immersive")
        defer { controller.window?.close(); manager.invalidate() }
        let root = controller.root
        controller.placeAddress()
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false, tab: tab)
        controller.pageScrolled(to: travel / 2, trusted: true, editing: false, tab: tab)
        #expect(root.autohideOffset(at: 0) == travel / 2)
        root.isImmersive = true
        controller.placeAddress()
        #expect(!root.autohidesBar && root.autohideOffset(at: 0) == 0)
        controller.pageScrolled(to: travel * 3, trusted: true, editing: false, tab: tab)
        controller.pointerMoved(to: NSPoint(x: 450, y: 2))
        controller.settleAutohide()
        #expect(root.autohideOffset(at: 0) == 0, "no follow while the page has the screen")
    }

    /// Leaving The Whole Screen gives Autohide back from a clean start: the bar there, the next scroll down its own.
    @Test func leavingTheWholeScreenRestoresAutohide() {
        let before = Library.shared.snapshot
        let place = BrowserRootView.addressBarPlace
        defer { Library.shared.restore(before); BrowserRootView.addressBarPlace = place }
        BrowserRootView.addressBarPlace = .autohide
        let (controller, manager, tab) = autohideWindow("leave-immersive")
        defer { controller.window?.close(); manager.invalidate() }
        let root = controller.root
        controller.placeAddress()
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false, tab: tab)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false, tab: tab)
        #expect(root.autohideOffset(at: 0) == travel)
        root.isImmersive = true
        controller.placeAddress()
        controller.pageScrolled(to: travel * 5, trusted: true, editing: false, tab: tab)
        root.isImmersive = false
        controller.placeAddress()
        #expect(root.autohidesBar && root.autohideOffset(at: 0) == 0)
        // The first report after is only a starting place; the next one moves the bar from there, unlocked.
        controller.pageScrolled(to: travel * 5, trusted: true, editing: false, tab: tab)
        #expect(root.autohideOffset(at: 0) == 0)
        controller.pageScrolled(to: travel * 5 + 10, trusted: true, editing: false, tab: tab)
        #expect(root.autohideOffset(at: 0) == 10)
    }

    /// Only the shown page reports its scrolls, and only with Autohide on; the page script sends nothing otherwise.
    @Test func scrollReportsOnlyWithAutohide() throws {
        let before = Library.shared.snapshot
        let place = BrowserRootView.addressBarPlace
        defer { Library.shared.restore(before); BrowserRootView.addressBarPlace = place }
        BrowserRootView.addressBarPlace = .always
        let (controller, manager, tab) = autohideWindow("reports")
        defer { controller.window?.close(); manager.invalidate() }
        controller.placeAddress()
        #expect(controller.debugScrollReporters.isEmpty)
        BrowserRootView.addressBarPlace = .autohide
        controller.placeAddress()
        if let webView = tab.webView { #expect(controller.debugScrollReporters == [webView]) }
        BrowserRootView.addressBarPlace = .off
        controller.placeAddress()
        #expect(controller.debugScrollReporters.isEmpty)

        // The script itself, run against a stand-in page: silent until the window turns it on.
        let context = try #require(JSContext())
        context.evaluateScript("""
        var handlers = {}, posted = [], frames = [];
        var window = this;
        var document = { documentElement: { clientWidth: 800 }, activeElement: null };
        document.scrollingElement = document.documentElement;
        window.scrollY = 0;
        window.addEventListener = function (type, f) { handlers[type] = f; };
        var requestAnimationFrame = function (f) { frames.push(f); return frames.length; };
        var flush = function () { var q = frames; frames = []; q.forEach(function (f) { f(); }); };
        window.webkit = { messageHandlers: { \(ScrollMessages.messageName): { postMessage: function (m) { posted.push(m); } } } };
        """)
        context.evaluateScript(ScrollMessages.script.source)
        context.evaluateScript("window.scrollY = 40; handlers.scroll({ target: document }); flush();")
        #expect(context.evaluateScript("posted.length").toInt32() == 0)
        context.evaluateScript("window.__zigzagAutohide = true; window.scrollY = 60; handlers.scroll({ target: document }); flush();")
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
        #expect(context.evaluateScript("posted[0].dy").toInt32() == 0, "turned on, the first report is a starting place")
        context.evaluateScript("window.scrollY = 75; handlers.scroll({ target: document }); flush();")
        #expect(context.evaluateScript("posted[1].dy").toInt32() == 15)
    }

    /// ⌘L brings the bar back to edit the address there, and the next scroll down can take it again.
    @Test func openLocationBringsTheBarBack() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let (controller, manager, _) = autohideWindow("open-location")
        defer { controller.commandBar.dismiss(); controller.window?.close(); manager.invalidate() }
        let root = controller.root
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        controller.openLocation(nil)
        #expect(root.autohideOffset(at: 0) == 0)
        // While the address is being edited the bar stays.
        controller.pageScrolled(to: travel * 3, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == 0)
        controller.commandBar.dismiss()
        controller.pageScrolled(to: travel * 3 + 10, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == 10)
    }

    /// With the page already at its top, a scroll up has nothing to report: the wheel itself brings the bar back.
    @Test func aScrollUpAtThePagesTopBringsTheBarBack() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let (controller, manager, _) = autohideWindow("top-wheel")
        defer { controller.window?.close(); manager.invalidate() }
        let root = controller.root
        let travel = root.autohideTravel(at: 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        // The page takes itself to the top: the bar stays away.
        controller.pageScrolled(to: 0, trusted: false, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        func wheel(_ dy: Int32) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
            return try #require(NSEvent(cgEvent: cg))
        }
        controller.noteScrollGesture(try wheel(-4), inPane: 0)
        #expect(root.autohideOffset(at: 0) == travel, "a scroll down there leaves it")
        controller.noteScrollGesture(try wheel(4), inPane: 0)
        #expect(root.autohideOffset(at: 0) == 0)
    }

    /// In full screen the pointer at the screen's top brings down the menu bar only; the address bar does not follow.
    @Test func fullScreenGivesTheScreenTopToTheMenuBar() {
        #expect(!BrowserWindowController.topPointerRevealsBar(fullScreen: true))
        #expect(BrowserWindowController.topPointerRevealsBar(fullScreen: false))
    }

    /// A finger where the bar went brings it back and does nothing else; one in the page, or on the bar, is theirs.
    @Test func aFingerWhereTheBarWentBringsItBack() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/touch-reveal")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        root.fingerLanded(at: NSPoint(x: 450, y: 300))
        #expect(root.autohideOffset(at: 0) == travel, "a finger in the page is the page's")
        root.fingerLanded(at: NSPoint(x: 450, y: travel - 4))
        #expect(root.autohideOffset(at: 0) == 0, "a finger where the bar was brings it back")
        // Partly out, a finger on what's left of the bar is the bar's.
        root.setBarOffset(travel / 2, animated: false)
        #expect(!root.isWhereBarWent(NSPoint(x: 450, y: travel / 2 - 4)))
        #expect(root.isWhereBarWent(NSPoint(x: 450, y: travel - 4)))
    }

    /// Typing in a field holds the bar where it is, including away; it must not pop back to the top on every report.
    @Test func typingInAFieldHoldsTheBarWhereItIs() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/editing")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        controller.pageScrolled(to: travel * 2.5, trusted: true, editing: true)
        #expect(root.autohideOffset(at: 0) == travel, "editing must hold it away, not pop it back")
        controller.pageScrolled(to: 0, trusted: true, editing: true)
        #expect(root.autohideOffset(at: 0) == travel, "editing holds it even at the page's top")
    }

    /// A new main-frame document starts with the bar down; a navigation change such as an SPA's pushState must not
    /// pop it back mid-scroll.
    @Test func aNewDocumentResetsTheBarButANavigationChangeDoesNot() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/document")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        tab.changed.send(.navigation)
        #expect(root.autohideOffset(at: 0) == travel, "a navigation change is not a new page")
        tab.changed.send(.document)
        #expect(root.autohideOffset(at: 0) == 0, "a new document starts with the bar down")
    }

    /// A trackpad scroll can close the bar and lock it, but the next key scroll is a new gesture: an arrow or space
    /// back up the page brings it back.
    @Test func aKeyScrollAfterATrackpadCloseBringsTheBarBack() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/key-reveal")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        controller.pageScrolled(to: travel, trusted: true, editing: false, key: true)
        #expect(root.autohideOffset(at: 0) < travel, "a key scroll is a new gesture")
    }

    /// The page's very top always puts the bar back, even after a scroll down locked it away; an untrusted report
    /// from the page's own script still does not move it.
    @Test func theVeryTopAlwaysBringsTheBarBack() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/top-reveal")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.layoutSubtreeIfNeeded()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        controller.pageScrolled(to: travel * 2, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel)
        controller.pageScrolled(to: 0, trusted: false, editing: false)
        #expect(root.autohideOffset(at: 0) == travel, "the page's own scroll to the top is not the person's")
        controller.pageScrolled(to: travel, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == travel, "the same gesture leaves it away")
        controller.pageScrolled(to: 0, trusted: true, editing: false)
        #expect(root.autohideOffset(at: 0) == 0, "the top always brings the bar back")
    }

    /// With the sidebar docked on the left, the window buttons stay in its row for the whole travel.
    @Test func aDockedSidebarKeepsTheLightsInItsRowWhileTheBarTravels() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/docked-lights")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.setSidebarVisible(true, animated: false)
        root.setSidebarOnRight(false, animated: false)
        root.layoutSubtreeIfNeeded()
        controller.layoutTrafficLights()
        func lightTopLeft() -> NSPoint? {
            guard let window = controller.window, let close = window.standardWindowButton(.closeButton) else { return nil }
            let r = close.convert(close.bounds, to: nil)
            return NSPoint(x: r.minX, y: (window.contentView?.frame.height ?? 0) - r.maxY)
        }
        let docked = lightTopLeft()
        let travel = root.autohideTravel(at: 0)
        #expect(travel > 0)
        for offset in [travel / 2, travel] {
            root.setBarOffset(offset, animated: false)
            root.layoutSubtreeIfNeeded()
            controller.layoutTrafficLights()
            #expect(lightTopLeft() == docked, "offset \(offset)")
        }
    }

    /// With the sidebar hidden, the window buttons ride in the bar as it travels and go with it.
    @Test func theLightsGoWithAnAutohideBar() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/hidden-lights")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        guard let window = controller.window as? BrowserWindow else { Issue.record("no window"); return }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.showsTopBar = true
        root.barHoldsAddress = true
        root.autohidesBar = true
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        controller.layoutTrafficLights()
        #expect(!window.trafficLightsHidden)
        let shown = window.trafficLightOrigin?.y ?? 0
        let travel = root.autohideTravel(at: 0)
        root.setBarOffset(travel / 2, animated: false)
        controller.layoutTrafficLights()
        #expect(!window.trafficLightsHidden)
        #expect(abs((window.trafficLightOrigin?.y ?? 0) - (shown - travel / 2)) < 0.5, "they ride up with the bar")
        root.setBarOffset(travel, animated: false)
        controller.layoutTrafficLights()
        #expect(window.trafficLightsHidden, "nothing over the page while the bar is away")
        root.setBarOffset(0, animated: false)
        controller.layoutTrafficLights()
        #expect(!window.trafficLightsHidden && window.trafficLightOrigin?.y == shown)
    }

    /// A page that gives no color of its own (`underPageBackgroundColor` clear) still has a bar: its band is the
    /// card's ground, never a hole where the page would show through behind the controls.
    @Test func aClearPageColorLeavesTheBarItsSurface() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/clear-color")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        tab.webView?.underPageBackgroundColor = .clear
        withBorderless(false) {
            root.showsTopBar = true
            root.barHoldsAddress = true
            root.setSidebarVisible(true, animated: false)
            root.paintTopBar(root.card.pageColor)
            root.layoutSubtreeIfNeeded()
            #expect(root.card.band > 0)
            let shown = root.card.debugSurface.layer?.backgroundColor
            #expect((shown?.alpha ?? 0) > 0.99, "the bar's band must not be see-through")
            #expect(root.topBar.pageColor?.alphaComponent ?? 0 > 0.99)
        }
        withBorderless(true) {
            root.setSidebarVisible(false, animated: false)
            root.paintTopBar(.clear)
            root.layoutSubtreeIfNeeded()
            let ground = root.card.debugSurface.layer?.backgroundColor
            #expect((ground?.alpha ?? 0) > 0.99, "the page's card must still have a ground")
        }
    }

    /// Borderless, the panes meet the bar in a straight line as ever, and the strips keep the bar's ink.
    @Test func borderlessThePanesStartUnderTheBar() {
        withBorderless(true) {
            let (root, _) = splitRoot()
            for (card, pane) in zip([root.card, root.secondCard], root.tileFrames) {
                #expect(card.frame == pane && card.band == 0 && !card.header.isOnCard)
            }
        }
    }

    /// With the address above the page, the pin star sits inside the URL pill's end (#437). The pill shows it
    /// itself, even when the field handed it over hidden, and gives the address its room back when there is
    /// nothing to pin (#444).
    @Test func thePillShowsTheStarItselfAndHidesItWithNothingToPin() {
        let pill = PaneAddressView()
        pill.hasSiteControls = false
        pill.text = "example.com"
        let star = PaneHeaderView.button("star", toolTip: "Pin Page")
        // Straight from a field that never drew it: the star's own hidden flag is still true.
        star.isHidden = true
        pill.pin = star
        pill.frame = NSRect(x: 0, y: 0, width: 220, height: Tokens.Pane.addressHeight)
        pill.layoutSubtreeIfNeeded()
        // The pill's rule, not the leftover flag, decides.
        #expect(star.superview === pill && !star.isHidden)
        #expect(star.frame.maxX <= pill.bounds.maxX - PaneAddressView.buttonInset + 0.5)
        #expect(abs(star.frame.midY - pill.bounds.midY) <= 0.5)
        // The pill's rounded end, and the field's rim pressing it too.
        #expect(star.radius == Tokens.Radius.control - PaneAddressView.buttonInset)
        #expect(star.pressOutset.top == PaneAddressView.buttonInset)
        #expect(star.pressOutset.bottom == PaneAddressView.buttonInset)
        #expect(star.pressOutset.left == 1 && star.pressOutset.right == PaneAddressView.buttonInset)
        let withStar = pill.fittingWidth
        // A new tab has nothing to pin: the star goes, and the address takes exactly its room back.
        pill.showsPin = false
        pill.layoutSubtreeIfNeeded()
        #expect(star.isHidden)
        #expect(abs(withStar - pill.fittingWidth - PaneAddressView.buttonRoom) < 0.5)
        // And it comes back when there is a page to pin again.
        pill.showsPin = true
        pill.layoutSubtreeIfNeeded()
        #expect(!star.isHidden)
        #expect(abs(pill.fittingWidth - withStar) < 0.5)
    }

    /// The address gives the star up when the pill takes it, and takes it back after.
    @Test func theAddressGivesTheStarToThePillAndBack() {
        let address = AddressView()
        address.frame = NSRect(x: 0, y: 0, width: 400, height: Tokens.Sidebar.addressHeight)
        address.setSaved(false, canSave: true)
        address.layoutSubtreeIfNeeded()
        let wide = address.buttonsWidth
        address.starInPill = true
        #expect(address.saveButton.superview == nil)
        #expect(address.buttonsWidth < wide)
        // The pill left it hidden; back in the field, on a page that can be pinned, it draws again.
        address.saveButton.isHidden = true
        address.starInPill = false
        address.layoutSubtreeIfNeeded()
        #expect(address.saveButton.superview === address)
        #expect(!address.saveButton.isHidden)
        #expect(address.buttonsWidth == wide)
        // With nothing to pin, it stays out of the field (#442).
        address.starInPill = true
        address.setSaved(false, canSave: false)
        address.saveButton.isHidden = false
        address.starInPill = false
        address.layoutSubtreeIfNeeded()
        #expect(address.saveButton.isHidden)
        #expect(address.buttonsWidth < wide)
    }

    // MARK: Autohide (#359)

    @Test func autohideIsBoundToThePagesPosition() {
        let travel = TopBarView.height + inset
        // The bar is the page's top edge: from the page's first point it travels with the page, so half the travel is
        // half the bar out. There is no dead zone to scroll through first.
        let half = AddressBarAutohide.step(offset: 0, pageDelta: travel / 2, travel: travel, locked: false)
        #expect(half.offset == travel / 2 && !half.locked)
        // Fully out and no further; reaching the end locks.
        let away = AddressBarAutohide.step(offset: 0, pageDelta: travel * 2, travel: travel, locked: false)
        #expect(away.offset == travel && away.locked)
        #expect(AddressBarAutohide.step(offset: travel, pageDelta: 50, travel: travel, locked: false).offset == travel)
        // A gesture that only opened it can bring it back at the same speed.
        #expect(AddressBarAutohide.step(offset: 20, pageDelta: -12, travel: travel, locked: false).offset == 8)
        #expect(AddressBarAutohide.step(offset: 20, pageDelta: -50, travel: travel, locked: false).offset == 0)
        // A rubber-band above the top never puts it above its place.
        #expect(AddressBarAutohide.step(offset: 0, pageDelta: -20, travel: travel, locked: false).offset == 0)
    }

    @Test func aGestureThatClosedTheBarDoesNotReopenIt() {
        let travel = TopBarView.height + inset
        let closed = AddressBarAutohide.step(offset: 0, pageDelta: travel * 2, travel: travel, locked: false)
        #expect(closed.offset == travel && closed.locked)
        // The same gesture leaves it out on the way back, however far the page comes up.
        let stillOut = AddressBarAutohide.step(offset: closed.offset, pageDelta: -travel, travel: travel,
                                               locked: closed.locked)
        #expect(stillOut.offset == travel && stillOut.locked)
        // A new gesture unlocks it: the next upward travel brings it back at the same speed.
        let reopened = AddressBarAutohide.step(offset: travel, pageDelta: -12, travel: travel, locked: false)
        #expect(reopened.offset == travel - 12 && !reopened.locked)
    }

    @Test func autohidePutsTheBarAwayAndTakesItsRoomOutOfThePage() {
        withBorderless(false) {
            let sidebar = SidebarView()
            let root = BrowserRootView(sidebar: sidebar)
            root.frame = window
            sidebar.holdsAddress = false
            root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
            root.barHoldsAddress = true
            root.autohidesBar = true
            root.showsTopBar = true
            root.layoutSubtreeIfNeeded()
            let shownPage = root.cardFrame
            let shownFavorites = sidebar.favorites.frame.minY
            #expect(root.barOnScreen && root.topBar.frame.minY == inset)

            root.setBarPutAway(true, animated: false)
            root.layoutSubtreeIfNeeded()
            #expect(root.barPutAway && !root.barOnScreen)
            // The bar sits just above the window; the page takes the row it had.
            #expect(root.topBar.frame.maxY == 0)
            // Its controls travel with it: the URL pill and the buttons don't stay over the page.
            #expect(root.topBar.convert(root.topBar.pill.frame, to: root).maxY <= 0)
            #expect(root.topBar.convert(sidebar.addressButtons[0].frame, to: root).maxY <= 0)
            #expect(root.cardFrame.minY == inset && root.cardFrame.height == shownPage.height + bar)
            // The sidebar's rows stay where they were: its top row is not under the pointer's reach any more than before.
            #expect(sidebar.favorites.frame.minY == shownFavorites)

            root.setBarPutAway(false, animated: false)
            root.layoutSubtreeIfNeeded()
            #expect(root.barOnScreen && root.cardFrame == shownPage)
            #expect(sidebar.favorites.frame.minY == shownFavorites)
        }
    }

    @Test func turningAutohideOffBringsTheBarBack() {
        withBorderless(false) {
            let sidebar = SidebarView()
            let root = BrowserRootView(sidebar: sidebar)
            root.frame = window
            sidebar.holdsAddress = false
            root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
            root.barHoldsAddress = true
            root.autohidesBar = true
            root.showsTopBar = true
            root.layoutSubtreeIfNeeded()
            root.setBarPutAway(true, animated: false)
            #expect(root.barPutAway)
            // The setting goes back to Off or Always while the bar is away: the bar comes back with it.
            root.autohidesBar = false
            root.layoutSubtreeIfNeeded()
            #expect(!root.barPutAway && root.barOnScreen)
            #expect(root.topBar.frame.minY == inset)
            // The same when the address goes back to the sidebar first, as the setting changes it.
            root.autohidesBar = true
            root.setBarPutAway(true, animated: false)
            root.barHoldsAddress = false
            root.autohidesBar = false
            root.layoutSubtreeIfNeeded()
            #expect(!root.barPutAway)
        }
    }

    @Test func autohideIsOnlyForABarThatHoldsTheAddress() {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = window
        root.autohidesBar = true
        root.barHoldsAddress = false
        root.showsTopBar = true
        root.layoutSubtreeIfNeeded()
        root.setBarPutAway(true, animated: false)
        #expect(!root.barPutAway)
        root.barHoldsAddress = true
        root.autohidesBar = false
        root.setBarPutAway(true, animated: false)
        #expect(!root.barPutAway)
    }

    @Test func theThreeAddressBarChoicesPlaceTheBar() {
        let before = BrowserRootView.addressBarPlace
        defer { BrowserRootView.addressBarPlace = before }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/places")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        BrowserRootView.addressBarPlace = .off
        controller.placeAddress()
        #expect(!root.barHoldsAddress && !root.autohidesBar && !root.showsTopBar)
        BrowserRootView.addressBarPlace = .autohide
        controller.placeAddress()
        #expect(root.barHoldsAddress && root.autohidesBar && root.showsTopBar)
        BrowserRootView.addressBarPlace = .always
        controller.placeAddress()
        #expect(root.barHoldsAddress && !root.autohidesBar && root.showsTopBar)
    }

    @Test func theOldSwitchIsAlwaysAndStillWrittenForAnOlderZigzag() throws {
        let name = "TopBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removeScratchSuite(name) }
        #expect(BrowserRootView.addressBarPlace(in: defaults) == .off)
        defaults.set(true, forKey: "addressAbovePage")
        #expect(BrowserRootView.addressBarPlace(in: defaults) == .always)
        BrowserRootView.setAddressBarPlace(.autohide, in: defaults)
        #expect(BrowserRootView.addressBarPlace(in: defaults) == .autohide)
        #expect(defaults.bool(forKey: "addressAbovePage"))
        BrowserRootView.setAddressBarPlace(.off, in: defaults)
        #expect(defaults.object(forKey: "addressAbovePage") as? Bool == false)
    }
}

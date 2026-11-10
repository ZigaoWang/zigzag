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
        // The favorites and tabs take the address's place.
        #expect(sidebar.favorites.frame.minY == Tokens.Sidebar.addressTop)
        // The address ends where the page does.
        let address = sidebar.address.convert(sidebar.address.bounds, to: root)
        #expect(address.maxX == root.bounds.maxX - max(Tokens.Sidebar.edge, root.bounds.maxX - root.cardFrame.maxX))

        sidebar.holdsAddress = true
        root.showsTopBar = false
        root.layoutSubtreeIfNeeded()
        #expect(sidebar.address.superview === sidebar)
        #expect(sidebar.addressButtons.allSatisfy { $0.superview === sidebar })
        #expect(root.topBar.isHidden)
        #expect(sidebar.address.frame.minY == Tokens.Sidebar.addressTop)
    }
}

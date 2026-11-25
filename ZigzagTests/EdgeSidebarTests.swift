import AppKit
import Testing
@testable import Zigzag

/// The sidebar at the screen's edge (#363): where the edge opens, what it leaves to macOS, and the panel's shape.
@MainActor
struct EdgeSidebarTests {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    /// Below a 25pt menu bar, no Dock at the bottom.
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)

    private func opens(_ x: CGFloat, _ y: CGFloat, onRight: Bool = false, screens: [NSRect]? = nil) -> Bool {
        EdgeSidebarLayout.opens(at: NSPoint(x: x, y: y), screen: screen, visible: visible, onRight: onRight,
                                screens: screens ?? [screen])
    }

    @Test func onlyThePointerPushedAgainstTheSidebarsEdgeOpensIt() {
        #expect(opens(0, 400))
        #expect(opens(1, 400))
        // A few points in is a window's edge or a scroll bar, not the screen's edge.
        #expect(!opens(4, 400))
        #expect(!opens(1439, 400))
        #expect(opens(1439, 400, onRight: true))
        #expect(!opens(0, 400, onRight: true))
    }

    @Test func theCornersMenuBarAndBottomDockAreLeftToMacOS() {
        // Hot corners at the top and bottom.
        #expect(!opens(0, 2))
        #expect(!opens(0, EdgeSidebarLayout.cornerReserve - 1))
        #expect(opens(0, EdgeSidebarLayout.cornerReserve + 1))
        // The menu bar is above the visible frame.
        #expect(!opens(0, 880))
        // A Dock at the bottom: below the visible frame doesn't open.
        let docked = NSRect(x: 0, y: 70, width: 1440, height: 805)
        #expect(!EdgeSidebarLayout.opens(at: NSPoint(x: 0, y: 50), screen: screen, visible: docked, onRight: false, screens: [screen]))
        #expect(EdgeSidebarLayout.opens(at: NSPoint(x: 0, y: 400), screen: screen, visible: docked, onRight: false, screens: [screen]))
    }

    @Test func anEdgeSharedWithAnotherDisplayIsAWayAcross() {
        let beside = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(!opens(0, 400, screens: [screen, beside]))
        // Level with the other display only partway: below it, the edge is the screen's own.
        let short = NSRect(x: -1280, y: 500, width: 1280, height: 400)
        #expect(!opens(0, 600, screens: [screen, short]))
        #expect(opens(0, 300, screens: [screen, short]))
        // A display on the other side leaves this edge alone.
        let right = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(opens(0, 400, screens: [screen, right]))
        #expect(!opens(1439, 400, onRight: true, screens: [screen, right]))
    }

    @Test func theDockAndStageManagerKeepTheirSide() {
        #expect(EdgeSidebarLayout.sideIsFree(onRight: false, dockSide: "bottom", stageManager: false))
        #expect(!EdgeSidebarLayout.sideIsFree(onRight: false, dockSide: "left", stageManager: false))
        #expect(!EdgeSidebarLayout.sideIsFree(onRight: true, dockSide: "right", stageManager: false))
        // Stage Manager's strip is on the left, or on the right when the Dock is on the left.
        #expect(!EdgeSidebarLayout.sideIsFree(onRight: false, dockSide: "bottom", stageManager: true))
        #expect(EdgeSidebarLayout.sideIsFree(onRight: true, dockSide: "bottom", stageManager: true))
        #expect(!EdgeSidebarLayout.sideIsFree(onRight: true, dockSide: "left", stageManager: true))
    }

    @Test func itComesOutOnlyOverAnotherAppWithNoButtonDown() {
        #expect(EdgeSidebarLayout.canShow(appIsActive: false, buttonsPressed: false))
        #expect(!EdgeSidebarLayout.canShow(appIsActive: true, buttonsPressed: false))
        // A drag or a window's edge being pulled.
        #expect(!EdgeSidebarLayout.canShow(appIsActive: false, buttonsPressed: true))
    }

    @Test func thePanelRunsDownTheScreensEdgeAndStaysWhileThePointerIsOnIt() {
        let left = EdgeSidebarLayout.frame(in: visible, width: 248, onRight: false)
        let right = EdgeSidebarLayout.frame(in: visible, width: 248, onRight: true)
        #expect(left == NSRect(x: 0, y: 0, width: 248, height: 875))
        #expect(right == NSRect(x: 1192, y: 0, width: 248, height: 875))
        #expect(EdgeSidebarLayout.frame(in: visible, width: 4000, onRight: true) == visible)
        #expect(EdgeSidebarLayout.keeps(at: NSPoint(x: 250, y: 400), panel: left))
        #expect(!EdgeSidebarLayout.keeps(at: NSPoint(x: 300, y: 400), panel: left))
    }

    @Test func thePreviewWidensThePanelAndLeavesTheSidebarWhereItIs() {
        let inset = Tokens.Metric.cardInset
        let sidebar: CGFloat = 240
        let page = EdgeSidebarLayout.pageWidth(in: visible)
        let narrow = EdgeSidebarLayout.width(sidebar: sidebar, page: false, inset: inset, in: visible)
        let wide = EdgeSidebarLayout.width(sidebar: sidebar, page: true, inset: inset, in: visible)
        #expect(narrow == sidebar + inset)
        #expect(wide == sidebar + inset + page + inset * 2)
        for onRight in [false, true] {
            let narrowPanel = EdgeSidebarLayout.frame(in: visible, width: narrow, onRight: onRight)
            let widePanel = EdgeSidebarLayout.frame(in: visible, width: wide, onRight: onRight)
            let narrowCard = EdgeSidebarLayout.cardFrame(in: NSRect(origin: .zero, size: narrowPanel.size),
                                                         sidebar: sidebar, inset: inset, page: false, onRight: onRight)
            let card = EdgeSidebarLayout.cardFrame(in: NSRect(origin: .zero, size: widePanel.size),
                                                   sidebar: sidebar, inset: inset, page: true, onRight: onRight)
            let pageFrame = EdgeSidebarLayout.pageFrame(in: NSRect(origin: .zero, size: widePanel.size),
                                                        sidebar: sidebar, inset: inset, page: true, onRight: onRight)
            // The sidebar keeps its width and its place on screen; the page grows inward.
            #expect(card.width == sidebar)
            #expect(narrowPanel.minX + narrowCard.minX == widePanel.minX + card.minX)
            #expect(pageFrame.width == page)
            #expect(card.union(pageFrame).width == widePanel.width - inset * 2)
            #expect(card.union(pageFrame).height == widePanel.height - inset * 2)
        }
    }

    @Test func thePreviewIsItsOwnFloorToCeilingPill() {
        let inset = Tokens.Metric.cardInset
        let host = EdgeSidebarHost(frame: visible)
        let container = SidebarContainer(sidebar: SidebarView(frame: .zero))
        host.cardWidth = 240
        host.set(container)
        host.pageShowing = true
        host.placeCard()
        // The sidebar stays its own card, exactly where it was; the page is a separate pill beside it.
        #expect(container.frame == host.cardFrame)
        #expect(host.pageFrame.minY == inset)
        #expect(host.pageFrame.height == visible.height - inset * 2)
        #expect(!host.pageFrame.intersects(host.cardFrame))
        // The docked Mini takes the page pill whole: no page-card inset, the old large corners and shadow.
        let page = host.pageFrame
        #expect(EdgeSidebar.shared.dockCardFrame(in: page) == page)
        #expect(EdgeSidebar.shared.dockCardRadius == Tokens.Radius.large)
        #expect(EdgeSidebar.shared.dockCardColor == Tokens.Color.cardBackground)
        #expect(EdgeSidebar.shared.dockHasShadow)
    }

    @Test func theEdgePreviewRestsLikeTheOneItReplaces() {
        #expect(EdgePreviewHoverPolicy.dwell == 0.2)
        #expect(EdgePreviewHoverPolicy.check == 0.05)
        #expect(EdgePreviewHoverPolicy.rests(now: 0.25, since: 0, moved: false))
        #expect(!EdgePreviewHoverPolicy.rests(now: 0.25, since: 0, moved: true))
    }

    @Test func theSwitchIsOffUntilTurnedOn() {
        let saved = UserDefaults.standard.object(forKey: EdgeSidebar.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: EdgeSidebar.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: EdgeSidebar.defaultsKey)
        #expect(!EdgeSidebar.isOn)
    }

    @Test func thePanelTakesTheKeyboardOnlyAsAPanel() {
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func theEdgesSidebarIsAListWithoutTheAddressRow() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        sidebar.showsAddressRow = false
        #expect(!sidebar.holdsAddress)
        let row: [NSView] = sidebar.addressButtons + [sidebar.address, sidebar.sidebarButton]
        #expect(row.allSatisfy { $0.isHidden })
        // A window's sidebar keeps its row.
        let window = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        #expect(window.holdsAddress && !window.address.isHidden)
    }

    @Test func itsControlsAnswerHoverWithAnotherAppInFront() {
        let mirror = SidebarView(frame: .zero)
        #expect(!mirror.backButton.tracksHoverWhileInactive)
        mirror.hoversWhileInactive = true
        #expect(mirror.backButton.tracksHoverWhileInactive)
        #expect(!SidebarView(frame: .zero).backButton.tracksHoverWhileInactive)
    }

    /// The panel lends the tab's own page, so Zigzag's own pages (Settings, History, the archive) have nothing to
    /// lend: their rows grey out and take no pick. A web page, local or not, is taken.
    @Test func thePanelTakesWebPagesAndNotZigzagsOwn() {
        #expect(EdgeLensPolicy.takesPage(url: URL(string: "https://example.com/page")))
        #expect(EdgeLensPolicy.takesPage(url: URL(string: "http://localhost:8080")))
        #expect(EdgeLensPolicy.takesPage(url: URL(string: "file:///Users/me/page.html")))
        #expect(!EdgeLensPolicy.takesPage(url: URL(string: "zigzag://settings")))
        #expect(!EdgeLensPolicy.takesPage(url: URL(string: "zigzag://history")))
        #expect(!EdgeLensPolicy.takesPage(url: URL(string: "zigzag://archive")))
        // No address at all is not one of Zigzag's pages; the callers' scheme guard still keeps a blank tab out.
        #expect(EdgeLensPolicy.takesPage(url: nil))
    }

    /// A running page is lent to the preview; a sleeping or not-yet-loaded one shows its snapshot instead, so a hover
    /// never wakes it. The card says why and how to wake it, and leaves the tab unloaded.
    @Test func aPagePreviewsItsSnapshotWhileItIsNotRunning() {
        #expect(EdgeLensPolicy.previewKind(isLoaded: true, isAsleep: false) == .live)
        #expect(EdgeLensPolicy.previewKind(isLoaded: false, isAsleep: false) == .snapshot)
        #expect(EdgeLensPolicy.previewKind(isLoaded: false, isAsleep: true) == .snapshot)
        #expect(EdgeLensPolicy.previewKind(isLoaded: true, isAsleep: true) == .snapshot)

        let tab = Tab(url: URL(string: "https://example.com/quiet")!, title: "Quiet page", spaceID: UUID())
        #expect(!tab.isLoaded)
        let card = EdgeAsleepPageView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        card.show(tab: tab)
        #expect(card.shownTitle == "Quiet page")
        #expect(!card.shownNote.isEmpty)
        // Showing the card did not wake the tab.
        #expect(tab.webView == nil)
    }

    /// A screen too narrow for the sidebar and the page's third: the panel stops at the screen, and the page takes
    /// what is left rather than being cut off.
    @Test func thePanelAndPageNeverWidenPastTheScreen() {
        let inset = Tokens.Metric.cardInset
        for onRight in [false, true] {
            let narrow = NSRect(x: 0, y: 0, width: 380, height: visible.height)
            let width = EdgeSidebarLayout.width(sidebar: 240, page: true, inset: inset, in: narrow)
            let panel = EdgeSidebarLayout.frame(in: narrow, width: width, onRight: onRight)
            #expect(panel.width == narrow.width)
            let bounds = NSRect(origin: .zero, size: panel.size)
            let card = EdgeSidebarLayout.cardFrame(in: bounds, sidebar: 240, inset: inset, page: true, onRight: onRight)
            let page = EdgeSidebarLayout.pageFrame(in: bounds, sidebar: 240, inset: inset, page: true, onRight: onRight)
            #expect(card.minX >= 0)
            #expect(page.maxX <= bounds.width)
            #expect(page.width > 0)
        }
    }

    /// A split's or a tile group's parts are pages of their own: the row reports the page under the pointer, and
    /// only when the pointer moves to another part.
    @Test func aMultiPageRowReportsThePartUnderThePointer() throws {
        let space = Library.shared.spaces[0].id
        let left = Tab(url: URL(string: "https://example.com/left")!, title: "Left", spaceID: space)
        let right = Tab(url: URL(string: "https://example.com/right")!, title: "Right", spaceID: space)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: Tokens.Sidebar.rowHeight))
        window.contentView?.addSubview(row)
        row.configure(tab: left)
        row.configure(parts: [TabRowView.Part(page: right)])
        #expect(row.isSplit)

        var reported: [Tab?] = []
        row.onHoverPart = { reported.append($0) }
        func move(to x: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: row.bounds.midY),
                                                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            row.mouseMoved(with: event)
        }
        try move(to: 60)
        try move(to: 100)
        try move(to: 180)
        #expect(reported.count == 2)
        #expect(reported[0] === left)
        #expect(reported[1] === right)

        // The split closes under the pointer: the row has no parts left, so no stale part stays lit or under the
        // edge panel's preview.
        row.debugPoint(atPart: 1)
        #expect(row.debugPointedPart == 1)
        row.configure(parts: [])
        #expect(!row.isSplit)
        #expect(row.debugPointedPart == nil)
    }
}


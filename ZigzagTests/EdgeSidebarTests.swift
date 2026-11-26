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

    @Test func aSpaceSwitchKeepsThePreviewAndKnowsWhichWayItSlides() {
        #expect(EdgePreviewRouting.keepsPreviewOnSpaceChange(previewOpen: true))
        #expect(!EdgePreviewRouting.keepsPreviewOnSpaceChange(previewOpen: false))
        let one = UUID(), two = UUID(), three = UUID()
        let order = [one, two, three]
        #expect(EdgePreviewRouting.spaceSlide(from: one, to: two, order: order) == 1)
        #expect(EdgePreviewRouting.spaceSlide(from: two, to: one, order: order) == -1)
        #expect(EdgePreviewRouting.spaceSlide(from: one, to: three, order: order) == 1)
        #expect(EdgePreviewRouting.spaceSlide(from: one, to: one, order: order) == 0)
        #expect(EdgePreviewRouting.spaceSlide(from: nil, to: two, order: order) == 0)
        #expect(EdgePreviewRouting.spaceSlide(from: one, to: UUID(), order: order) == 0)
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

    @Test func theAddressRowCanBeHiddenForAList() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        sidebar.showsAddressRow = false
        #expect(!sidebar.holdsAddress)
        let row: [NSView] = sidebar.addressButtons + [sidebar.address, sidebar.sidebarButton]
        #expect(row.allSatisfy { $0.isHidden })
        // A window's sidebar keeps its row.
        let window = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        #expect(window.holdsAddress && !window.address.isHidden)
        // The edge panel keeps the row but has no window sidebar to show or hide.
        let edge = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        edge.showsSidebarButton = false
        #expect(edge.holdsAddress && !edge.address.isHidden)
        #expect(edge.sidebarButton.isHidden)
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
    @Test func aPageShowsItsCardWhileItIsNotRunning() {
        #expect(EdgeLensPolicy.previewKind(isLoaded: true, isAsleep: false) == .live)
        #expect(EdgeLensPolicy.previewKind(isLoaded: false, isAsleep: false) == .card)
        #expect(EdgeLensPolicy.previewKind(isLoaded: false, isAsleep: true) == .card)
        #expect(EdgeLensPolicy.previewKind(isLoaded: true, isAsleep: true) == .card)

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

    /// A row clicked in the panel: the browser selects the tab, and the panel's page pill is the Mini's whole frame.
    /// The page is laid out once, at the pill's size, instead of at the Mini's remembered window size.
    @Test func aClickedRowShowsItsPageInThePagePillAtItsFinalSize() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://example.test/second"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }

        // The click's own path, as the list's delegate calls it.
        controller.listSelect(second)

        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        let host = try #require(panel.contentView as? EdgeSidebarHost)
        let wide = EdgeSidebarLayout.width(sidebar: controller.edgeSidebarWidth, page: true, inset: host.inset, in: visible)
        #expect(panel.frame == EdgeSidebarLayout.frame(in: visible, width: wide, onRight: controller.edgeSidebarOnRight))
        #expect(host.pageShowing)
        #expect(host.container?.frame == host.cardFrame)

        let mini = try #require(MiniWindowController.all.first { $0.tab === second })
        let window = try #require(mini.window)
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        #expect(window.frame == pill)
        // The page fills the pill: the browser's page did not lend it its own, larger size.
        let webView = try #require(second.webView)
        #expect(webView.frame.size == pill.size)
    }

    /// The flow the panel is used in: rest on a row until its page is out, then click another row. The page keeps the
    /// pill's size through the swap; the browser's card that showed it for an instant doesn't lend it a larger one.
    @Test func clickingAnotherRowAfterAHoverKeepsThePagePillSize() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://example.test/second"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }

        EdgeSidebar.shared.previewNow(first, in: controller)
        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        let host = try #require(panel.contentView as? EdgeSidebarHost)
        let hovered = try #require(MiniWindowController.all.first { $0.tab === first })
        #expect(hovered.window?.frame == panel.convertToScreen(host.convert(host.pageFrame, to: nil)))

        controller.listSelect(second)
        let clicked = try #require(MiniWindowController.all.first { $0.tab === second })
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        #expect(clicked.window?.frame == pill)
        #expect(second.webView?.frame.size == pill.size)
    }

    /// The panel and its preview hand the menu bar's tab and sidebar keys to the browser window, so ⌘W, ⌘1–9 and the
    /// rest act on its tabs from either one.
    @Test func thePanelAndItsPreviewHandTabKeysToTheBrowserWindow() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://example.test/second"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }

        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        #expect(panel.nextResponder === controller)
        controller.listSelect(second)
        let mini = try #require(MiniWindowController.all.first { $0.tab === second })
        let target = #selector(BrowserWindowController.selectNextTab(_:))
        #expect(mini.supplementalTarget(forAction: target, sender: nil) as? BrowserWindowController === controller)
    }

    /// The address row is the page beside the panel: its back, forward, reload, star and site controls must answer
    /// for the previewed tab, not for whichever tab was selected behind the panel.
    @Test func theAddressRowAnswersForThePreviewedPage() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://first.test/one"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://second.test/two"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }
        let mirror = try #require(controller.edgeSidebar)

        EdgeSidebar.shared.previewNow(first, in: controller)
        let firstMini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(EdgeSidebar.shared.displayedTab === first)
        #expect(mirror.address.debugText == "first.test")

        EdgeSidebar.shared.previewNow(second, in: controller)
        let secondMini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(EdgeSidebar.shared.displayedTab === second)
        #expect(mirror.address.debugText == "second.test")
        // The page being left stays under the new one's fold, so the swap is a transition rather than a fresh fold
        // over an empty page area.
        #expect(secondMini !== firstMini)
        #expect(firstMini.window?.isVisible == true)
        #expect(secondMini.root.layer?.mask != nil)
    }

    /// The panel goes out from under the pointer, so its rows never get the exit that would put their hover away.
    /// A row left lit looks like a selection that cannot be cleared.
    @Test func hidingThePanelClearsTheRowsHover() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: "https://example.test/hover"), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        let mirror = try #require(controller.edgeSidebar)
        let row = try #require(mirror.list.row(for: tab) as? SidebarRowView)
        row.isHovered = true
        EdgeSidebar.shared.hide(animated: false)
        #expect(!row.isHovered)
    }

    /// A tile group's part must be previewed at the page pill's size from its first layout: the page may not be
    /// laid out at its pane's size (or the Mini's remembered window size) and then adjusted, moving its content.
    @Test func aTileGroupPreviewStartsAtThePagePillSize() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let pages = (0..<4).map { i in
            manager.newTab(url: URL(string: "https://tile.test/\(i)"), spaceID: space)
        }
        manager.makeGroup(pages, shape: TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight],
                                                  column: 0.5, row: 0.5))
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1200, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }
        // The pointer is not really on the panel in a test: keep it out while the frames are watched.
        EdgeSidebar.debugHoldsOpen = true
        defer { EdgeSidebar.debugHoldsOpen = false }
        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        let host = try #require(panel.contentView as? EdgeSidebarHost)
        let paneSize = try #require(pages[2].pageHolder?.frame.size)
        var seen: [NSSize] = []
        let watch = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: pages[2].webView,
                                                           queue: .main) { _ in
            MainActor.assumeIsolated {
                if let size = pages[2].webView?.frame.size { seen.append(size) }
            }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        EdgeSidebar.shared.previewNow(pages[2], in: controller)
        let mini = try #require(MiniWindowController.all.first { $0.tab === pages[2] })
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        // Exactly one size change, straight to the pill: the page never believes it has the pane's or the Mini's
        // remembered window size and then has to lay itself out again.
        #expect(!seen.isEmpty)
        #expect(seen.last == pill.size, "sizes \(seen); pill \(pill.size)")
        #expect(seen.allSatisfy { $0 == pill.size }, "sizes \(seen); pane \(paneSize); pill \(pill.size)")

        // Across the fold, the window and its card keep the one frame: a later resize would show as a jerk even
        // though the page's own layout is already final.
        var frames: [NSRect] = []
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if let frame = mini.window?.frame { frames.append(frame) }
        }
        let sizes = Set(frames.map { NSStringFromRect($0) })
        #expect(sizes.count == 1, "window frames \(sizes)")
        // No run loop yet: this is the frame the page is first laid out in.
        #expect(mini.window?.frame == pill, "mini window \(String(describing: mini.window?.frame)) pill \(pill)")
        #expect(mini.root.card.frame.size == pill.size, "card \(mini.root.card.frame) pill \(pill)")
        #expect(pages[2].pageHolder?.frame.size == pill.size, "holder \(String(describing: pages[2].pageHolder?.frame)) pill \(pill)")
        #expect(pages[2].webView?.frame.size == pill.size, "web \(String(describing: pages[2].webView?.frame)) pill \(pill)")
    }

    /// The + menu's actions work from the panel: New Tab opens the panel's own command bar, New Folder lands in the
    /// panel's list, and New Space names the space in an editor over the panel rather than in the window behind.
    @Test func thePlusMenuActsInThePanel() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        let panelWindow = try #require(EdgeSidebar.shared.sheetHost?.window)

        let entries = controller.sidebarAddMenu()
        let items = entries.compactMap { entry -> MenuPanel.Item? in
            if case .item(let item) = entry { return item }
            return nil
        }

        // New Tab: the bar over the screen, not the one in the window behind.
        let newTab = try #require(items.first { $0.title == SidebarMenus.title(of: .newTab) })
        newTab.action()
        #expect(EdgeSidebar.shared.isCommandBarOpen)

        // New Folder: in the current space, and the panel's list reloads for it.
        let folders = Library.shared.folders(in: space).count
        let newFolder = try #require(items.first { $0.title == SidebarMenus.title(of: .newFolder) })
        newFolder.action()
        #expect(Library.shared.folders(in: space).count == folders + 1)

        // New Space: its editor is a card on the panel, so the browser stays behind.
        let madeBefore = Library.shared.spaces.count
        let newSpace = try #require(items.first { $0.title == SidebarMenus.title(of: .newSpace) })
        newSpace.action()
        #expect(Library.shared.spaces.count == madeBefore + 1)
        #expect(Library.shared.space(manager.currentSpaceID) != nil)
        let editor = try #require(SpaceEditorPanel.current)
        #expect(editor.superview === EdgeSidebar.shared.sheetHost)
        #expect(editor.window === panelWindow)
    }

    /// A sleeping row is the same pill a running page is: the Mini is there, with the card over its room. Resting on
    /// it never wakes the tab, and clicking wakes it in place — the card goes, the Mini stays.
    @Test func aSleepingRowIsThePagePillWithItsCardOverIt() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://example.test/second"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        second.ensureWebView()
        second.suspend(because: "test", chosen: true)
        #expect(await until { second.isAsleep && !second.isLoaded })

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        EdgeSidebar.shared.previewNow(second, in: controller)

        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        let host = try #require(panel.contentView as? EdgeSidebarHost)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        #expect(mini.tab === second)
        #expect(mini.asleepCardTitle == second.displayTitle)
        #expect(mini.window?.frame == pill)
        #expect(host.pageShowing)
        // Resting made no page for it.
        #expect(!second.isLoaded)

        // The click wakes it: the card goes and the page is there.
        controller.listSelect(second)
        #expect(await until { second.isLoaded })
        #expect(await until { mini.asleepCardTitle == nil })
        #expect(mini.tab === second)
        // The panel is a shared singleton: another test's window becoming key hides it (as another window's does in
        // the app), so what it shows is only meaningful while it is still out. Either way, no second Mini takes the
        // page over: the one that had it keeps it.
        if EdgeSidebar.shared.isShowing {
            #expect(EdgeSidebar.shared.pagePreview === mini)
        }
        #expect(MiniWindowController.all.filter { $0.isDockedInPage && $0.tab === second }.count <= 1)
    }

    /// Moving between a sleeping row and a running one keeps the panel at its one wide frame: the card and the page
    /// are the same pill, so neither swap narrows it or folds a new Mini over an empty page area.
    @Test func movingBetweenACardAndAPageKeepsThePanelWide() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://example.test/second"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        second.ensureWebView()
        second.suspend(because: "test", chosen: true)
        #expect(await until { second.isAsleep && !second.isLoaded })

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        let host = try #require(panel.contentView as? EdgeSidebarHost)
        let wide = EdgeSidebarLayout.frame(in: visible,
                                           width: EdgeSidebarLayout.width(sidebar: controller.edgeSidebarWidth,
                                                                          page: true, inset: host.inset, in: visible),
                                           onRight: controller.edgeSidebarOnRight)

        EdgeSidebar.shared.previewNow(second, in: controller)
        #expect(panel.frame == wide)
        EdgeSidebar.shared.previewNow(first, in: controller)
        #expect(panel.frame == wide)
        let page = try #require(EdgeSidebar.shared.pagePreview)
        #expect(page.tab === first)
        #expect(page.window?.frame == panel.convertToScreen(host.convert(host.pageFrame, to: nil)))
    }

    /// New Tab from the panel is the spotlight over the screen, in the middle: not a bar squeezed into the sidebar's
    /// width when no page is out beside it.
    @Test func newTabFromThePanelCentersOverTheScreen() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        controller.newTab(nil)

        #expect(EdgeSidebar.shared.isCommandBarOpen)
        #expect(controller.commandBar.isVisible)
        let card = try #require(EdgeSidebar.shared.commandBarPageFrame)
        #expect(card.width == visible.width)
        let bar = controller.commandBar.panelView.frame
        #expect(abs(bar.midX - visible.midX) <= 2)
        #expect(bar.width >= Tokens.Metric.commandBarWidth * 0.9)
    }

    /// Choosing a result in the panel's bar is the panel doing its job: the window stays behind and the panel stays
    /// out, where the page it opened becomes the page beside the sidebar.
    @Test func choosingAResultKeepsThePanelOut() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        EdgeSidebar.shared.newTabInPlace()
        controller.commandBarChoseResult()
        #expect(EdgeSidebar.shared.isShowing)
        #expect(EdgeSidebar.shared.isCommandBarOpen)
    }

    /// Clicking the card standing in for the previewed page is a click on the tab: the page wakes in the same Mini,
    /// the panel stays out, and the tab becomes the browser's selected one.
    @Test func clickingTheCardInThePreviewWakesTheTab() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: "https://example.test/first"), spaceID: space)
        let second = manager.newTab(url: URL(string: "https://example.test/second"), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        second.ensureWebView()
        second.suspend(because: "test", chosen: true)
        #expect(await until { second.isAsleep && !second.isLoaded })

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        EdgeSidebar.shared.previewNow(second, in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(mini.asleepCardTitle == second.displayTitle)
        #expect(!second.isLoaded)

        mini.clickAsleepCard()
        #expect(await until { second.isLoaded })
        #expect(await until { mini.asleepCardTitle == nil })
        #expect(manager.selectedTab === second)
        #expect(EdgeSidebar.shared.pagePreview === mini)
        #expect(MiniWindowController.all.filter { $0.isDockedInPage && $0.tab === second }.count == 1)
    }

    /// Activation changes are judged a grace later: a blink of focus keeps the panel the pointer is on, while a
    /// real switch of app still puts it away.
    @Test func anActivationBlinkKeepsThePanelUnderThePointer() {
        #expect(EdgeSidebarLayout.keepsAfterActivation(appIsActive: true, panelIsKey: false, previewIsKey: false,
                                                      pointerOnPanel: true))
        #expect(EdgeSidebarLayout.keepsAfterActivation(appIsActive: true, panelIsKey: true, previewIsKey: false,
                                                      pointerOnPanel: false))
        #expect(EdgeSidebarLayout.keepsAfterActivation(appIsActive: true, panelIsKey: false, previewIsKey: true,
                                                      pointerOnPanel: false))
        #expect(!EdgeSidebarLayout.keepsAfterActivation(appIsActive: false, panelIsKey: true, previewIsKey: true,
                                                       pointerOnPanel: true))
        #expect(!EdgeSidebarLayout.keepsAfterActivation(appIsActive: true, panelIsKey: false, previewIsKey: false,
                                                       pointerOnPanel: false))
    }

    /// Expand in the preview's strip takes the page out of the row and leaves a Mini of its own: the panel goes, the
    /// window stays, and the tab lives outside the browser's list.
    @Test func expandingTheEdgePreviewLeavesAnIndependentMini() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { EdgeSidebar.shared.hide(animated: false); manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: "https://example.test/expand"), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        tab.ensureWebView()
        #expect(tab.isLoaded)

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        EdgeSidebar.shared.show(on: visible, for: controller)
        EdgeSidebar.shared.previewNow(tab, in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(mini.isDockedInPage)
        #expect(mini.window?.parent != nil)

        mini.promoteFromPage()
        #expect(await until { !mini.isDockedInPage })
        #expect(mini.window?.isVisible == true)
        #expect(manager.tab(with: tab.id) == nil)
        #expect(tab.isOutsideTabList)
        #expect(tab.host === mini)
        #expect(!EdgeSidebar.shared.isShowing)
        mini.window?.close()
    }

    private func until(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
}

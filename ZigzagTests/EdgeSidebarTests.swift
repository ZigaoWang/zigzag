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

    // MARK: The preview

    /// A window with these tabs, the first selected, and the panel out for it.
    private func panelWithTabs(_ paths: [String]) -> (BrowserWindowController, TabManager, [Tab], () -> Void) {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        let tabs = paths.map { manager.newTab(url: URL(string: $0), spaceID: space) }
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        controller.window?.layoutIfNeeded()
        // The pointer isn't on the panel in a test: keep it out.
        EdgeSidebar.debugHoldsOpen = true
        EdgeSidebar.shared.show(on: visible, for: controller)
        return (controller, manager, tabs, {
            EdgeSidebar.debugHoldsOpen = false
            EdgeSidebar.shared.hide(animated: false)
            controller.window?.close()
            manager.invalidate()
            Library.shared.restore(before)
        })
    }

    private func panelParts() throws -> (NSWindow, EdgeSidebarHost) {
        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        return (panel, try #require(panel.contentView as? EdgeSidebarHost))
    }

    /// The page comes out beside the sidebar as its own pill: the sidebar keeps its width and place on screen, and
    /// the page is laid out once, at the pill's size.
    @Test func aPreviewWidensThePanelBesideTheSidebar() throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/first", "https://example.test/second"])
        defer { done() }
        let (panel, host) = try panelParts()
        let cardOnScreen = panel.convertToScreen(host.convert(host.cardFrame, to: nil))

        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        let wide = EdgeSidebarLayout.width(sidebar: controller.edgeSidebarWidth, page: true, inset: host.inset, in: visible)
        #expect(panel.frame == EdgeSidebarLayout.frame(in: visible, width: wide, onRight: controller.edgeSidebarOnRight))
        #expect(panel.convertToScreen(host.convert(host.cardFrame, to: nil)) == cardOnScreen)
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        #expect(!host.pageFrame.intersects(host.cardFrame))
        #expect(host.pageFrame.height == host.cardFrame.height)
        #expect(mini.window?.frame == pill)
        #expect(tabs[1].webView?.frame.size == pill.size)
        #expect(mini.isBorrowingPage)
        #expect(tabs[1].host === mini)
        // The row's tab stays in the browser's list.
        #expect(controller.tabManager.tab(with: tabs[1].id) === tabs[1])
    }

    /// Esc in the panel puts the page away and leaves the sidebar out.
    @Test func escPutsThePageAwayFirst() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/first", "https://example.test/second"])
        defer { done() }
        let (panel, host) = try panelParts()
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        #expect(EdgeSidebar.shared.dismissPreview())
        #expect(EdgeSidebar.shared.isShowing)
        #expect(EdgeSidebar.shared.pagePreview == nil)
        // Once its fold is done, the page is the browser's again.
        #expect(await until(3) { tabs[1].host === controller })
        #expect(panel.frame.width == host.cardWidth + host.inset)
    }

    /// A click on a row brings the window forward with that tab, as it did before the preview: the panel and its page
    /// go, and the page that was beside the panel is back in the window's card.
    @Test func clickingAPreviewedRowShowsItsPageInTheWindow() throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/first", "https://example.test/second"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[1])

        controller.listSelect(tabs[1])
        EdgeSidebar.shared.hide(animated: false)
        #expect(!EdgeSidebar.shared.isShowing)
        #expect(EdgeSidebar.shared.pagePreview == nil)
        #expect(manager.selectedTab === tabs[1])
        #expect(tabs[1].host === controller)
        #expect(controller.root.card.webView === tabs[1].webView)
        // The page is on screen in the window, not left out of the card.
        #expect(tabs[1].webView?.window === controller.window)
        #expect(MiniWindowController.all.allSatisfy { $0.tab !== tabs[1] })
    }

    /// A page Zigzag serves itself stays the window's: resting on its row shows nothing beside the panel, and a click
    /// opens it in the window as any row's does.
    @Test func zigzagsOwnPagesOpenInTheWindow() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/first", "zigzag://history"])
        defer { done() }
        EdgeSidebar.shared.hover(tabs[0], in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview?.tab === tabs[0] })
        EdgeSidebar.shared.hover(tabs[1], in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview == nil })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(EdgeSidebar.shared.pagePreview == nil)

        controller.listSelect(tabs[1])
        #expect(!EdgeSidebar.shared.isShowing)
        #expect(manager.selectedTab === tabs[1])
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
    }

    /// A tile group's part is previewed at the pill's size from its first layout, never at its pane's size first.
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

        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }
        EdgeSidebar.debugHoldsOpen = true
        defer { EdgeSidebar.debugHoldsOpen = false }
        let (panel, host) = try panelParts()
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
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0 == pill.size }, "sizes \(seen); pill \(pill.size)")
        #expect(mini.window?.frame == pill)
        #expect(pages[2].webView?.frame.size == pill.size)
    }

    /// A row whose page is asleep shows its card in the pill, and resting on it never wakes the page.
    @Test func anAsleepRowShowsItsCardAndStaysAsleep() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/first", "https://example.test/second"])
        defer { done() }
        tabs[1].ensureWebView()
        tabs[1].suspend(because: "test", chosen: true)
        #expect(await until { tabs[1].isAsleep && !tabs[1].isLoaded })

        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let (panel, host) = try panelParts()
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(mini.tab === tabs[1])
        #expect(mini.asleepCardTitle == tabs[1].displayTitle)
        #expect(mini.window?.frame == panel.convertToScreen(host.convert(host.pageFrame, to: nil)))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!tabs[1].isLoaded)

        // From the card to a running page, the panel keeps its one wide frame.
        let wide = panel.frame
        EdgeSidebar.shared.previewNow(tabs[0], in: controller)
        #expect(panel.frame == wide)
        #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[0])
        // The card preview gave the tab back as it was.
        #expect(await until { tabs[1].host === controller })
        #expect(!tabs[1].isLoaded)
    }

    /// Expand in the preview's strip takes the page out of the row into a Mini of its own; the panel goes.
    @Test func expandingTheEdgePreviewLeavesAnIndependentMini() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/expand"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[0], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(mini.isDockedInPage)

        mini.promoteFromPage()
        #expect(await until { !mini.isDockedInPage })
        #expect(mini.window?.isVisible == true)
        #expect(manager.tab(with: tabs[0].id) == nil)
        #expect(tabs[0].isOutsideTabList)
        #expect(tabs[0].host === mini)
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

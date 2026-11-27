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

    /// The AI Apps window, shown to watch or parked again, is never the window whose sidebar comes out, nor is a
    /// private one; your windows are.
    @Test func theAIAppsWindowNeverHasTheEdgesSidebar() throws {
        let opened = Headless.openWindow()
        defer { Headless.closeWindow() }
        let profile = try #require(Library.shared.directory.headless)
        defer {
            if Library.shared.removeProfile(profile.id) { Library.shared.finishedRemovingProfile(profile.id) }
        }
        #expect(!EdgeSidebar.comesOut(for: opened))
        Headless.unpark(opened)
        #expect(!EdgeSidebar.comesOut(for: opened))
        Headless.park(opened)
        #expect(!EdgeSidebar.comesOut(for: opened))
        if let yours = WindowManager.shared.controllers.first(where: { !$0.tabManager.isPrivate }) {
            #expect(EdgeSidebar.comesOut(for: yours))
        }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space, isPrivate: true)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 600, height: 400))
        defer { controller.window?.close() }
        #expect(!EdgeSidebar.comesOut(for: controller))
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
        // The pointer isn't on the panel in a test: keep it out, and keep the real mouse's moves out of it.
        EdgeSidebar.debugHoldsOpen = true
        EdgeSidebar.debugPointer = offScreen
        EdgeSidebar.shared.show(on: visible, for: controller)
        return (controller, manager, tabs, {
            EdgeSidebar.debugHoldsOpen = false
            EdgeSidebar.debugPointer = nil
            EdgeSidebar.shared.hide(animated: false)
            controller.window?.close()
            manager.invalidate()
            Library.shared.restore(before)
        })
    }

    /// Where a test's pointer is when it isn't anywhere in particular: off every screen.
    private let offScreen = NSPoint(x: -100_000, y: -100_000)

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

    /// Zigzag's own pages are pages: resting on a row of Settings, History or Archive brings it out beside the panel
    /// like any other, Settings with its own view, and a click still opens it in the window.
    @Test func zigzagsOwnPagesPreviewLikeAnyPage() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["zigzag://settings", "zigzag://history",
                                                               "zigzag://archive", "https://example.test/first"])
        defer { done() }
        #expect(EdgeLensPolicy.previews(url: SettingsPage.url))
        #expect(EdgeLensPolicy.previews(url: HistoryPage.url))
        #expect(EdgeLensPolicy.previews(url: ArchivePage.url))
        #expect(await until { tabs[0].settingsView != nil })
        EdgeSidebar.shared.hover(tabs[0], in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview?.tab === tabs[0] })
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(tabs[0].settingsView?.window === mini.window)
        // Folded back, Settings is in its window's tab again.
        #expect(EdgeSidebar.shared.dismissPreview())
        #expect(await until(3) { tabs[0].host === controller })
        #expect(tabs[0].settingsView?.window === controller.window)

        tabs[1].ensureWebView()
        EdgeSidebar.shared.hover(tabs[1], in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview?.tab === tabs[1] })
        #expect(tabs[1].webView?.window === EdgeSidebar.shared.pagePreview?.window)

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

        EdgeSidebar.debugHoldsOpen = true
        EdgeSidebar.debugPointer = offScreen
        defer { EdgeSidebar.debugHoldsOpen = false; EdgeSidebar.debugPointer = nil }
        EdgeSidebar.shared.show(on: visible, for: controller)
        defer { EdgeSidebar.shared.hide(animated: false) }
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

    /// A page out in the preview is seen, so it isn't put to sleep; one that sleeps anyway shows its card, not an
    /// empty pill.
    @Test func aPreviewedPageStaysAwakeAndShowsItsCardIfItSleeps() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/first", "https://example.test/second"])
        defer { done() }
        tabs[1].ensureWebView()
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(mini.tab === tabs[1] && mini.asleepCardTitle == nil)
        #expect(!TabManager.mayStillSleep(tabs[1]))
        // As a crash or a busy page's sleep would, without asking whether it may.
        tabs[1].suspend(because: EnergyWatch.sleepReason)
        #expect(await until { tabs[1].isAsleep && !tabs[1].isLoaded })
        #expect(await until { mini.asleepCardTitle == tabs[1].displayTitle })
    }

    /// A click on a sleeping row's card does what a click on its row does: the panel goes and the window comes forward
    /// with that tab, its page woken there.
    @Test func clickingAnAsleepCardOpensItsTabInTheWindow() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/first", "https://example.test/second"])
        defer { done() }
        tabs[1].ensureWebView()
        tabs[1].suspend(because: "test", chosen: true)
        #expect(await until { tabs[1].isAsleep && !tabs[1].isLoaded })
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        let window = try #require(mini.window)
        let content = try #require(window.contentView)
        window.layoutIfNeeded()
        // The window behind another app, as the panel's page is: the click is its first.
        let center = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                             clickCount: 1, pressure: 1)))
        }
        #expect(await until(3) { !EdgeSidebar.shared.isShowing })
        #expect(manager.selectedTab === tabs[1])
        #expect(await until(3) { tabs[1].host === controller && !tabs[1].isAsleep })
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

    /// A tab's row in the panel, on screen.
    private func rowOnScreen(_ tab: Tab, in controller: BrowserWindowController) throws -> NSRect {
        let row = try #require(controller.edgeSidebar?.list.row(for: tab))
        let window = try #require(row.window)
        #expect(EdgeSidebar.shared.isPanel(window))
        // The list places its rows in its own layout pass: measured before it, a row is where it was made.
        window.contentView?.layoutSubtreeIfNeeded()
        let frame = window.convertToScreen(row.convert(row.bounds, to: nil))
        try #require(frame.width > 0)
        return frame
    }

    /// Crossing from one row to the next, the row left says so before the next one speaks, and the pointer can rest on
    /// the gap between them: the page stays, and the row the pointer is on is the one that counts.
    @Test func aCrossingBetweenRowsKeepsThePage() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b",
                                                         "https://example.test/c"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let b = try rowOnScreen(tabs[1], in: controller), c = try rowOnScreen(tabs[2], in: controller)
        // Between the two rows, no row under the pointer.
        EdgeSidebar.debugPointer = NSPoint(x: b.midX, y: (max(b.minY, c.minY) + min(b.maxY, c.maxY)) / 2)
        EdgeSidebar.shared.hover(nil, in: controller)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[1])
        // On the next row, its report lost to the one before: that row's page comes out after the rest.
        EdgeSidebar.debugPointer = NSPoint(x: c.midX, y: c.midY)
        EdgeSidebar.shared.hover(nil, in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview?.tab === tabs[2] })
    }

    /// Off the rows and the page, even with no row saying so, the page folds back and the sidebar stays out.
    @Test func leavingTheRowsAndThePageFoldsItBack() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let (panel, host) = try panelParts()
        let b = try rowOnScreen(tabs[1], in: controller)
        let card = panel.convertToScreen(host.convert(host.cardFrame, to: nil))
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        // On the page it stays.
        EdgeSidebar.debugPointer = NSPoint(x: pill.midX, y: pill.midY)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[1])
        // From the page to the sidebar's empty part, below the rows.
        EdgeSidebar.debugPointer = NSPoint(x: card.midX, y: min(b.minY - 120, card.midY))
        #expect(await until(3) { EdgeSidebar.shared.pagePreview == nil })
        #expect(EdgeSidebar.shared.isShowing)
    }

    /// On its way from the page to a row the pointer crosses the gap and the sidebar's empty part: the page stays
    /// out while it moves, and folds back once it stops off the rows.
    @Test func aPointerOnItsWayToARowKeepsThePage() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let (panel, host) = try panelParts()
        let b = try rowOnScreen(tabs[1], in: controller)
        let card = panel.convertToScreen(host.convert(host.cardFrame, to: nil))
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let pill = panel.convertToScreen(host.convert(host.pageFrame, to: nil))
        EdgeSidebar.debugPointer = NSPoint(x: pill.midX, y: pill.midY)
        try? await Task.sleep(for: .milliseconds(200))
        // Slowly across the sidebar's empty part, below the rows, a few points every tick.
        let y = min(b.minY - 120, card.midY)
        var x = controller.edgeSidebarOnRight ? card.minX + 4 : card.maxX - 4
        for _ in 0..<16 {
            EdgeSidebar.debugPointer = NSPoint(x: x, y: y)
            x += controller.edgeSidebarOnRight ? 6 : -6
            try? await Task.sleep(for: .milliseconds(50))
            #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[1])
        }
        // Stopped there, off the rows: the page goes.
        #expect(await until(3) { EdgeSidebar.shared.pagePreview == nil })
        #expect(EdgeSidebar.shared.isShowing)
    }

    /// A row with no page of its own puts the page away, even though the pointer is on the panel: there is nothing
    /// for that row to show beside the sidebar.
    @Test func aRowWithNoPagePutsThePageAway() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[0], in: controller)
        #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[0])
        let blank = manager.newTab(url: nil, spaceID: Library.shared.spaces[0].id)
        EdgeSidebar.shared.hover(blank, in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview == nil })
    }

    // MARK: Switching spaces

    /// A space switch while a page is out: the page goes back to its tab at once and the sidebar stays out with the
    /// new space's list. A row of the space left, reported late or still under the pointer, brings nothing out; the
    /// next rest on one of the new space's rows brings its page out as before.
    @Test func aSpaceSwitchPutsThePageAwayAndNeverShowsTheOldSpace() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let other = Library.shared.addSpace(name: "Edge switch").id
        let there = manager.newTab(url: URL(string: "https://example.test/there"), spaceID: other, select: false)
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        #expect(EdgeSidebar.shared.pagePreview?.tab === tabs[1])
        // A rest begun on the other row of this space, not done yet.
        EdgeSidebar.shared.hover(tabs[0], in: controller)

        manager.switchToSpace(other)
        #expect(EdgeSidebar.shared.isShowing)
        #expect(EdgeSidebar.shared.pagePreview == nil)
        #expect(tabs[1].host === controller)
        #expect(MiniWindowController.all.allSatisfy { $0.tab !== tabs[1] })
        // An old row's report, as the list slides away under the pointer.
        EdgeSidebar.shared.hover(tabs[1], in: controller)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(EdgeSidebar.shared.pagePreview == nil)
        #expect(tabs[0].host === controller && tabs[1].host === controller)

        EdgeSidebar.shared.hover(there, in: controller)
        #expect(await until(3) { EdgeSidebar.shared.pagePreview?.tab === there })
    }

    /// With no page out, a rest begun on a row just before a space switch brings nothing out after it.
    @Test func aRestBegunBeforeASpaceSwitchShowsNothing() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let other = Library.shared.addSpace(name: "Edge rest").id
        _ = manager.newTab(url: URL(string: "https://example.test/there"), spaceID: other, select: false)
        EdgeSidebar.shared.hover(tabs[1], in: controller)
        manager.switchToSpace(other)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(EdgeSidebar.shared.pagePreview == nil)
        #expect(tabs[1].host === controller)
    }

    /// A page still folding back when the space changes goes home at once, not after its fold.
    @Test func aSpaceSwitchDuringTheFoldGivesThePageBackAtOnce() throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let other = Library.shared.addSpace(name: "Edge fold").id
        _ = manager.newTab(url: URL(string: "https://example.test/there"), spaceID: other, select: false)
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(EdgeSidebar.shared.dismissPreview())
        manager.switchToSpace(other)
        #expect(tabs[1].host === controller)
        #expect(mini.window?.isVisible != true)
        #expect(EdgeSidebar.shared.isShowing)
    }

    // MARK: Keys and menus in the panel

    /// A shortcut as the keyboard sends it to a window.
    private func keys(_ key: String, code: UInt16, _ flags: NSEvent.ModifierFlags = .command, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    /// The menu bar's keys work in the panel: ⌘W closes the tab whose row is lit and the panel stays; ⌘L edits the
    /// address in the window, which comes forward to do it, as ⌘T does.
    @Test func theMenuBarsKeysActOnThePanelsBrowser() throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let (panel, _) = try panelParts()
        #expect(panel.performKeyEquivalent(with: try keys("w", code: 13, in: panel)))
        #expect(manager.tab(with: tabs[0].id) == nil)
        #expect(EdgeSidebar.shared.isShowing)
        #expect(!controller.commandBar.isVisible)

        #expect(panel.performKeyEquivalent(with: try keys("l", code: 37, in: panel)))
        #expect(!EdgeSidebar.shared.isShowing)
        #expect(controller.commandBar.isVisible && controller.commandBar.mode == .editCurrent)
        controller.commandBar.dismiss()
    }

    /// Keys pressed in the page beside the panel are the page's Mini's first: ⌘W puts the page away, its tab still in
    /// the list, and ⌘L edits the page's own address, not the window's.
    @Test func keysInThePreviewActOnThePanel() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        let window = try #require(mini.window)
        #expect(window.performKeyEquivalent(with: try keys("w", code: 13, in: window)))
        #expect(await until(3) { EdgeSidebar.shared.pagePreview == nil && tabs[1].host === controller })
        #expect(manager.tab(with: tabs[0].id) === tabs[0])
        #expect(manager.tab(with: tabs[1].id) === tabs[1])
        #expect(EdgeSidebar.shared.isShowing)

        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let again = try #require(EdgeSidebar.shared.pagePreview?.window)
        #expect(again.performKeyEquivalent(with: try keys("l", code: 37, in: again)))
        #expect(!controller.commandBar.isVisible)
        #expect(EdgeSidebar.shared.isShowing)
    }

    /// A tab or space command the preview does not do itself reaches the browser its page belongs to, rather than
    /// whichever window is behind the panel or nothing at all. The window cannot be made key in a test host, so the
    /// contract is checked where it lives: the preview's supplemental target is its page's window for actions it
    /// doesn't answer itself, and stays itself for the ones it does.
    @Test func thePreviewHandsUnansweredCommandsToItsPagesWindow() async throws {
        let (controller, manager, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        // A second window in the same space: the answer must be the page's window, not this one.
        let other = BrowserWindowController(tabManager: TabManager(spaceID: tabs[0].spaceID),
                                            frame: NSRect(x: 900, y: 100, width: 700, height: 500))
        defer { other.window?.close(); other.tabManager.invalidate() }
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        // ⌘1–9: this preview doesn't answer it, so the page's own window does.
        let numbered = #selector(BrowserWindowController.selectTabByNumber(_:))
        #expect(controller.responds(to: numbered))
        #expect(other.responds(to: numbered))
        #expect(mini.supplementalTarget(forAction: numbered, sender: nil) as? BrowserWindowController === controller)
        // And once routed there, the command really selects the page's window's second tab.
        manager.select(tabs[0])
        #expect(manager.selectedTab === tabs[0])
        manager.select(tabs[1])
        #expect(manager.selectedTab === tabs[1])
        #expect(other.tabManager.selectedTab !== tabs[1])
    }

    /// The + menu's New Folder, New Live Folder and New Space are done in the panel, where the list is: the panel
    /// stays out and the browser window stays where it was.
    @Test func thePlusMenuIsDoneInThePanel() async throws {
        let (controller, _, _, done) = panelWithTabs(["https://example.test/a"])
        defer { done() }
        let (panel, _) = try panelParts()
        let sidebar = try #require(controller.edgeSidebar)
        func choose(_ title: String) throws {
            let entries = SidebarMenus.addPanel(controller: controller)
            try #require(MenuPanel.show(entries, from: sidebar.newSpaceButton) != nil)
            let menu = try #require(MenuPanel.current)
            let index = try #require(menu.itemTitles.firstIndex(of: title))
            for _ in 0...index { menu.debugKey(125) }
            menu.debugKey(36)
        }
        let space = controller.tabManager.currentSpaceID
        let folders = Library.shared.folders(in: space).count
        try choose(SidebarMenus.title(of: .newFolder))
        #expect(EdgeSidebar.shared.isShowing)
        #expect(Library.shared.folders(in: space).count == folders + 1)
        // Its name is ready to type in the panel's list.
        #expect(await until(3) { (panel.firstResponder as? NSView)?.isDescendant(of: sidebar) == true })

        try choose(SidebarMenus.title(of: .newLiveFolder))
        #expect(EdgeSidebar.shared.isShowing)
        let sheet = try #require(await waitFor { panel.contentView.flatMap { Self.find(FormSheet.self, in: $0) } })
        #expect(sheet.window === panel)
        sheet.removeFromSuperview()

        let spaces = Library.shared.spaces.count
        try choose(SidebarMenus.title(of: .newSpace))
        #expect(EdgeSidebar.shared.isShowing)
        #expect(Library.shared.spaces.count == spaces + 1)
        let editor = try #require(SpaceEditorPanel.current)
        #expect(editor.window === panel)
        editor.close()
        #expect(controller.window?.isKeyWindow != true)
    }

    /// A sheet over the panel is centered on the card with its dim inside it; a space's editor from the + stands
    /// above the + inside the card, the same margin on either side, the button still in sight.
    @Test func sheetsAndEditorsFitThePanelsCard() async throws {
        let (controller, _, _, done) = panelWithTabs(["https://example.test/a"])
        defer { done() }
        let (_, host) = try panelParts()
        let sidebar = try #require(controller.edgeSidebar)
        host.layoutSubtreeIfNeeded()
        let card = host.cardFrame

        controller.newLiveFolder()
        let sheet = try #require(Self.find(FormSheet.self, in: host))
        #expect(sheet.convert(sheet.bounds, to: host) == card)
        sheet.layoutSubtreeIfNeeded()
        let form = try #require(sheet.subviews.first { $0 is FloatingPanelView })
        #expect(form.frame.minX == Tokens.Space.x2 && sheet.bounds.width - form.frame.maxX == Tokens.Space.x2,
                "form \(form.frame) sheet \(sheet.bounds)")
        sheet.close()

        controller.newSpace(sidebar.newSpaceButton)
        let editor = try #require(SpaceEditorPanel.current)
        let frame = editor.convert(editor.bounds, to: host)
        let button = sidebar.newSpaceButton.convert(sidebar.newSpaceButton.bounds, to: host)
        #expect(card.contains(frame), "editor \(frame) card \(card)")
        #expect(frame.minX - card.minX == card.maxX - frame.maxX, "editor \(frame) card \(card)")
        #expect(frame.maxY <= button.minY, "editor \(frame) button \(button)")
        editor.close()
    }

    /// The panel's Downloads button opens the list in the panel, over the sidebar's lane; the panel stays out.
    @Test func downloadsOpenOverThePanel() throws {
        let (controller, _, _, done) = panelWithTabs(["https://example.test/a"])
        defer { done(); DownloadsPanel.closeCurrent() }
        let (panel, host) = try panelParts()
        let sidebar = try #require(controller.edgeSidebar)
        // The panel places its card's parts in its own layout pass.
        host.layoutSubtreeIfNeeded()
        controller.sidebarShowDownloads(from: sidebar.downloadsButton)
        #expect(EdgeSidebar.shared.isShowing)
        #expect(DownloadsPanel.isOpen(in: panel))
        let list = try #require(Self.find(DownloadsPanelView.self, in: host))
        #expect(host.cardFrame.contains(list.frame), "list \(list.frame) card \(host.cardFrame)")
        // Its edges are the rows' edges, as in the window, against the side the sidebar is on.
        let lane = host.cardFrame.insetBy(dx: Tokens.Sidebar.edge, dy: 0)
        #expect(list.frame.minX == lane.minX && list.frame.maxX == lane.maxX, "list \(list.frame) lane \(lane)")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private func waitFor<T>(_ seconds: Double = 3, _ value: () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return value()
    }

    /// A page clicked into has the keyboard: when it folds back and the panel stays out, the panel takes the keyboard,
    /// not the browser window behind it.
    @Test func aPageFoldingBackGivesTheKeyboardToThePanel() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let (panel, _) = try panelParts()
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        EdgeSidebar.debugPageHasKeyboard = true
        defer { EdgeSidebar.debugPageHasKeyboard = nil }
        #expect(EdgeSidebar.shared.dismissPreview())
        #expect(await until(3) { mini.window?.isVisible != true && tabs[1].host === controller })
        #expect(EdgeSidebar.shared.isShowing)
        #expect(panel.isKeyWindow)
        #expect(controller.window?.isKeyWindow == false)
    }

    /// A page that never had the keyboard leaves it where it is when it folds back.
    @Test func aPageFoldingBackUnclickedLeavesTheKeyboard() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        let (panel, _) = try panelParts()
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        #expect(EdgeSidebar.shared.pagePreview?.window?.isKeyWindow == false)
        #expect(EdgeSidebar.shared.dismissPreview())
        #expect(await until(3) { tabs[1].host === controller })
        #expect(!panel.isKeyWindow)
    }

    /// The page is a window above the panel and would cover a menu opened in it: while a menu from the panel is open
    /// the page is ordered out, and it comes back once the menu closes.
    @Test func aMenuFromThePanelIsNeverUnderThePage() async throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a", "https://example.test/b"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[1], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(mini.window?.isVisible == true)
        let (panel, host) = try panelParts()
        let sidebar = try #require(controller.edgeSidebar)
        // A right-click by the card's inner edge: the menu runs on into the page's room.
        let inner = host.convert(NSPoint(x: controller.edgeSidebarOnRight ? host.cardFrame.minX + 10 : host.cardFrame.maxX - 10,
                                         y: host.cardFrame.midY), to: nil)
        let items: [MenuPanel.Entry] = ["Open", "Copy Link", "Close"].map { .item(.init(title: $0) {}) }
        try #require(MenuPanel.show(items, from: sidebar.list, placement: .at(inner)) != nil)
        let menu = try #require(MenuPanel.current)
        #expect(EdgeSidebar.shared.isPanel(menu.window))
        let menuOnScreen = panel.convertToScreen(menu.convert(menu.bounds, to: nil))
        #expect(menuOnScreen.intersects(try #require(mini.window?.frame)))
        #expect(mini.window?.isVisible == false)
        menu.close(animated: false)
        #expect(await until(3) { mini.window?.isVisible == true })
        #expect(EdgeSidebar.shared.pagePreview === mini)
    }

    /// Extensions hear nothing of the preview: its Mini is no window of theirs, as a Zigzag Mini of its own is.
    @Test func thePreviewIsNoWindowForExtensions() throws {
        let (controller, _, tabs, done) = panelWithTabs(["https://example.test/a"])
        defer { done() }
        EdgeSidebar.shared.previewNow(tabs[0], in: controller)
        let mini = try #require(EdgeSidebar.shared.pagePreview)
        #expect(!mini.isExtensionWindow)
        mini.promoteFromPage()
        #expect(mini.isExtensionWindow)
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

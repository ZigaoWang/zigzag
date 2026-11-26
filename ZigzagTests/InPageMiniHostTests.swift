import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

@MainActor
private final class SlidingDockHost: MiniDockHosting {
    let browser: BrowserWindowController
    let pageFrame: NSRect?
    init(browser: BrowserWindowController, pageFrame: NSRect? = nil) {
        self.browser = browser
        self.pageFrame = pageFrame
    }
    var dockParentWindow: NSWindow? { browser.window }
    var dockPageView: NSView { browser.root }
    var dockPageFrame: NSRect { pageFrame ?? browser.root.cardFrame }
    var dockHasShadow: Bool { true }
    var dockSlidesPage: Bool { true }
    var dockPageOnRight: Bool { false }
    var dockIsCovered: Bool { false }
    var dockIsFullScreen: Bool { false }
    func dockShowDim(owner: AnyObject, onClick: @escaping () -> Void) -> MiniPeekDimView? { nil }
    func dockHideDim(owner: AnyObject) {}
    func dockFocusPage() {}
}

@MainActor
struct InPageMiniHostTests {
    private func inWindow(_ body: (BrowserWindowController, Tab) throws -> Void) rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: "about:blank"), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        try body(controller, tab)
    }

    private func inWindowAsync(_ body: (BrowserWindowController, Tab) async throws -> Void) async rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: "about:blank"), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        try await body(controller, tab)
    }

    private func inWindow(pageAt url: String, _ body: (BrowserWindowController, Tab) throws -> Void) rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: url), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        try body(controller, tab)
    }

    private func inWindowAsync(pageAt url: String, _ body: (BrowserWindowController, Tab) async throws -> Void) async rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: url), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        try await body(controller, tab)
    }

    private func inWindowAsync(pageAt url: URL, _ body: (BrowserWindowController, Tab) async throws -> Void) async rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: url, spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        try await body(controller, tab)
    }

    private func inWindow(pageAt url: String, and second: String,
                          _ body: (BrowserWindowController, Tab, Tab) throws -> Void) rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: URL(string: url), spaceID: space)
        let other = manager.newTab(url: URL(string: second), spaceID: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        try body(controller, first, other)
    }

    private func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// A wheel turn at a point in `window`, handed to it as one would arrive.
    private func scroll(at pointInWindow: NSPoint, in window: NSWindow, dy: Int32) throws -> NSEvent {
        let onScreen = window.convertPoint(toScreen: pointInWindow)
        let flippedY = (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                     wheel1: dy, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.location = CGPoint(x: onScreen.x, y: flippedY)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func aDockedMiniIsABorderlessChildOfTheBrowserWindow() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let window = try #require(mini.window)
            #expect(mini.isDockedInPage)
            // The Mini's real window, root and page stay its own; only the presentation is a child of the browser's.
            #expect(window.parent === browser.window)
            #expect(window.contentView === mini.root)
            #expect(window.styleMask == [.borderless])
            #expect(window.canBecomeMain == false)
            #expect(window.isExcludedFromWindowsMenu == true)
            // The dim is the only part drawn by the browser window.
            #expect(browser.root.hasInPageMini)
            #expect(browser.root.inPageMiniDim != nil)
            #expect(browser.root.inPageMiniDim?.superview === browser.root)
            // Bound to the page card, in screen coordinates.
            let card = MiniDockLayout.frame(in: browser.root.cardFrame)
            let expected = try #require(browser.window).convertToScreen(browser.root.convert(card, to: nil))
            #expect(window.frame == expected)
            mini.closeInPage(animated: false)
            #expect(!browser.root.hasInPageMini)
            #expect(browser.root.inPageMiniDim == nil)
        }
    }

    @Test func theDockedMiniFollowsThePageCard() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let window = try #require(mini.window)
            mini.layoutInDock()
            let card = MiniDockLayout.frame(in: browser.root.cardFrame)
            let expected = try #require(browser.window).convertToScreen(browser.root.convert(card, to: nil))
            #expect(window.frame == expected)
            #expect(browser.root.inPageMiniDim?.frame == browser.root.cardFrame)
            mini.closeInPage(animated: false)
        }
    }

    @Test func browserChromeOverTheCardOrdersTheChildOut() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            #expect(!mini.isCoveredInDock)
            browser.root.sidebarVisible = false
            browser.root.reveal(true)
            #expect(browser.root.coversInPageMini)
            mini.layoutInDock()
            #expect(mini.isCoveredInDock)
            browser.root.reveal(false)
            #expect(!browser.root.coversInPageMini)
            mini.layoutInDock()
            #expect(!mini.isCoveredInDock)
            mini.closeInPage(animated: false)
        }
    }

    @Test func thePeekWaitsForTheSidebarToTuckAway() async throws {
        try await inWindowAsync { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            // Out it goes before the slide's first frame; back only after the tuck has finished.
            mini.sidebarSlid(show: true, duration: 0.02)
            #expect(mini.isCoveredInDock)
            mini.sidebarSlid(show: false, duration: 0.02)
            mini.layoutInDock()
            #expect(mini.isCoveredInDock)
            try await Task.sleep(for: .milliseconds(150))
            #expect(!mini.isCoveredInDock)
            mini.closeInPage(animated: false)
        }
    }

    @Test func dockedChromeStartsHiddenAndComesDownAtTheTop() {
        inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            #expect(mini.root.chromeOverlay)
            #expect(!mini.root.chromeRevealed)
            mini.root.pointerMoved(to: NSPoint(x: 4, y: 1))
            #expect(mini.root.chromeRevealed)
            mini.closeInPage(animated: false)
        }
    }

    @Test func theStripGoesBackUpWhileThePointerRestsAway() async throws {
        try await inWindowAsync { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            #expect(!mini.root.chromeRevealed)
            mini.root.pointerMoved(to: NSPoint(x: 4, y: 1))
            #expect(mini.root.chromeRevealed)
            // The edge sidebar follows the pointer every 0.05 s. Resting away from the top must not push the hide back
            // each time, or the strip would stay down for as long as the sidebar is open.
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(50))
                mini.root.pointerMoved(to: NSPoint(x: 4, y: 300))
            }
            #expect(!mini.root.chromeRevealed)
            mini.closeInPage(animated: false)
        }
    }

    @Test func theEdgePreviewBorrowsTheRowsLivePage() throws {
        try inWindow(pageAt: "https://example.test/live") { browser, tab in
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            let holder = try #require(tab.pageHolder)
            // The row's own tab, not a second load: the Mini shows the page the browser already has.
            #expect(mini.tab === tab)
            #expect(tab.host === mini)
            #expect(mini.root.card.webView === tab.webView)
            #expect(browser.root.card.webView === tab.webView)
            #expect(holder.superview != nil)
            #expect(!tab.isOutsideTabList)
            mini.closeInPage(focusBack: false, animated: false)
            // Closing the preview gives the page back; the tab is still in the browser's list, unclosed.
            #expect(!tab.isClosed)
            #expect(tab.host === browser)
            #expect(!tab.isOutsideTabList)
            #expect(tab.pageHolder === holder)
            #expect(browser.root.card.webView === tab.webView)
            #expect(holder.superview != nil)
            #expect(!MiniWindowController.all.contains { $0 === mini })
        }
    }

    @Test func aBorrowedPageComesBackToACardThatHadClearedIt() throws {
        try inWindow(pageAt: "https://example.test/cleared") { browser, tab in
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            let holder = try #require(tab.pageHolder)
            // While the Mini has the page, the card can clear it — the “shown in another window” state, or a card
            // left with no page. Returning has to go through the card so that state goes too; re-adding the holder
            // behind its back left the active page dead until another tab and back.
            browser.root.card.showElsewhere(tab)
            #expect(browser.root.card.webView == nil)
            mini.closeInPage(focusBack: false, animated: false)
            #expect(tab.pageHolder === holder)
            #expect(holder.superview != nil)
            #expect(browser.root.card.webView === tab.webView)
            #expect(browser.root.card.shownElsewhere == nil)
            #expect(tab.host === browser)
        }
    }

    @Test func aCardLayoutDoesNotStealAPageDockedInAMini() throws {
        try inWindow(pageAt: "https://example.test/docked") { browser, tab in
            let host = SlidingDockHost(browser: browser)
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: host))
            let holder = try #require(tab.pageHolder)
            // A space switch lays the browser's cards out again while the preview has the page. The card must keep
            // saying which page it is for, but must not move the holder out of the Mini and leave the preview blank.
            #expect(holder.window === mini.window)
            browser.root.card.show(nil)
            #expect(holder.window === mini.window)
            #expect(mini.root.card.webView === tab.webView)
            browser.root.card.show(tab.webView)
            #expect(browser.root.card.webView === tab.webView)
            #expect(mini.root.card.webView === tab.webView)
            #expect(holder.window === mini.window)
            #expect(holder.superview != nil)
            mini.closeInPage(focusBack: false, animated: false)
            #expect(holder.window === browser.window)
            #expect(holder.superview != nil)
        }
    }

    @Test func aCardLayoutDoesNotResizeAPageDockedInAMini() throws {
        try inWindow(pageAt: "https://example.test/room") { browser, tab in
            // The edge's page pill is narrower than the browser's card, as it is on screen.
            let card = browser.root.cardFrame
            let host = SlidingDockHost(browser: browser, pageFrame: NSRect(x: card.minX, y: card.minY,
                                                                           width: card.width / 2, height: card.height))
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: host))
            let holder = try #require(tab.pageHolder)
            let page = try #require(tab.webView)
            let room = holder.frame
            #expect(holder.window === mini.window)
            #expect(room.width < card.width)
            // The row's tab becomes the browser's while the Mini has its page: the card lays out again for it.
            browser.root.card.show(nil)
            browser.root.card.show(tab.webView)
            // The card says the page is its own; the Mini keeps the page's room, so the page is not laid out
            // for the card and clipped by the Mini.
            #expect(browser.root.card.webView === page)
            #expect(mini.root.card.webView === page)
            #expect(holder.window === mini.window)
            #expect(holder.frame == room)
            mini.closeInPage(focusBack: false, animated: false)
        }
    }

    @Test func aBorrowedPreviewKeepsTheSpaceChipHidden() throws {
        try inWindow(pageAt: "https://example.test/space-chip") { browser, tab in
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            #expect(mini.isBorrowingPage)
            // The tab still belongs to the browser's list: moving it from the preview would move it there without
            // that list knowing.
            #expect(mini.root.strip.spaceChip.isHidden)
            mini.closeInPage(focusBack: false, animated: false)
        }
    }

    @Test func reopeningDuringTheFoldOutEndsTheOldBorrowFirst() throws {
        try inWindow(pageAt: "https://example.test/reopen") { browser, tab in
            let first = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            // Start the fold-out without waiting for it: the leaving Mini still has the page for a moment.
            first.closeInPage(focusBack: false, animated: true)
            #expect(first.isLeavingDock)
            #expect(tab.host === first)
            // Reopening the same row must take the page back from the leaving Mini now. Left to finish on its own, it
            // records itself as the page's host after the new Mini borrowed it, and then gives the page back under
            // the new one, leaving the tab with no host and a blank page.
            let second = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            #expect(tab.host === second)
            #expect(second.root.card.webView === tab.webView)
            #expect(!MiniWindowController.all.contains { $0 === first })
            second.closeInPage(focusBack: false, animated: false)
            #expect(tab.host === browser)
            #expect(browser.root.card.webView === tab.webView)
            #expect(tab.pageHolder?.superview != nil)
            #expect(!tab.isClosed)
        }
    }

    @Test func swappingThePreviewBorrowsTheNextPageAndGivesTheFirstBack() throws {
        try inWindow(pageAt: "https://example.test/one", and: "https://example.test/two") { browser, first, second in
            let mini = try #require(MiniWindowController.openPreview(of: first, from: browser, dockedIn: browser))
            let firstHolder = try #require(first.pageHolder)
            let window = mini.window
            #expect(mini.loadPreview(second, fromRight: true))
            #expect(mini.window === window)
            #expect(mini.tab === second)
            #expect(mini.lastRevealFromRight == true)
            #expect(second.host === mini)
            #expect(mini.root.card.webView === second.webView)
            // The first page is back in the card it came from, still the browser's page.
            #expect(first.host === browser)
            #expect(browser.root.card.webView === first.webView)
            #expect(firstHolder.superview != nil)
            let secondHolder = try #require(second.pageHolder)
            mini.closeInPage(focusBack: false, animated: false)
            #expect(!second.isClosed)
            #expect(second.host === browser)
            // It was never the browser's page, so its holder waits for the row to be shown rather than painting over.
            #expect(secondHolder.superview == nil)
            browser.tabManager.select(second)
            browser.window?.layoutIfNeeded()
            #expect(browser.root.card.webView === second.webView)
            #expect(secondHolder.superview != nil)
        }
    }

    @Test func openInZigzagGivesTheBorrowedPageBackToItsTab() throws {
        try inWindow(pageAt: "https://example.test/open") { browser, tab in
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            // Nothing on screen to fade: Open in Zigzag runs at once.
            mini.window?.alphaValue = 0
            mini.openInZigzag()
            #expect(!tab.isClosed)
            #expect(tab.host === browser)
            #expect(browser.tabManager.selectedTab === tab)
            #expect(browser.root.card.webView === tab.webView)
            #expect(!MiniWindowController.all.contains { $0 === mini })
            #expect(!MiniWindowController.all.contains { $0.tab === tab })
        }
    }

    @Test func expandingThePreviewTakesTheRowsTabOutOfTheList() throws {
        try inWindow(pageAt: "https://example.test/expand") { browser, tab in
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: browser))
            mini.promoteFromPage()
            #expect(!mini.isDockedInPage)
            // Expanded, the page is a Mini of its own: its row leaves the browser and the Mini owns it.
            #expect(browser.tabManager.tab(with: tab.id) == nil)
            #expect(tab.isOutsideTabList)
            #expect(tab.host === mini)
            mini.window?.close()
            #expect(tab.isClosed)
        }
    }

    @Test func theEdgePreviewSlidesInAndOutFromTheSidebarsSide() async throws {
        try await inWindowAsync(pageAt: "https://example.test/slide") { browser, tab in
            let host = SlidingDockHost(browser: browser)
            let mini = try #require(MiniWindowController.openPreview(of: tab, from: browser, dockedIn: host))
            // Coming in: the page is already at its final layout, masked from the sidebar's side.
            #expect(mini.root.layer?.mask != nil)
            #expect(mini.window?.hasShadow == false)
            try await Task.sleep(for: .milliseconds(400))
            #expect(mini.root.layer?.mask == nil)
            #expect(mini.window?.hasShadow == true)
            // Going: covered again from the sidebar's side, then the window closes.
            mini.closeInPage(focusBack: false, animated: true)
            #expect(mini.root.layer?.mask != nil)
            #expect(mini.window?.hasShadow == false)
            try await Task.sleep(for: .milliseconds(400))
            #expect(!mini.isDockedInPage)
            #expect(mini.window?.isVisible != true)
            #expect(!tab.isClosed)
            #expect(tab.host === browser)
        }
    }

    @Test func automaticNewWindowLinksStayInThePeek() {
        #expect(MiniWindowController.keepsDockedLink(navigationType: .linkActivated, opensInBackground: false,
                                                     hasWindowFeatures: false, hasPendingCommand: false, loads: true))
        #expect(MiniWindowController.keepsDockedLink(navigationType: .other, opensInBackground: false,
                                                     hasWindowFeatures: false, hasPendingCommand: false, loads: true))
        // Not ours to keep: a background tab, another window, a menu command, a sized popup, or an address a page may
        // not open.
        #expect(!MiniWindowController.keepsDockedLink(navigationType: .linkActivated, opensInBackground: true,
                                                      hasWindowFeatures: false, hasPendingCommand: false, loads: true))
        #expect(!MiniWindowController.keepsDockedLink(navigationType: .linkActivated, opensInBackground: false,
                                                      hasWindowFeatures: false, hasPendingCommand: true, loads: true))
        #expect(!MiniWindowController.keepsDockedLink(navigationType: .linkActivated, opensInBackground: false,
                                                      hasWindowFeatures: true, hasPendingCommand: false, loads: true))
        #expect(!MiniWindowController.keepsDockedLink(navigationType: .linkActivated, opensInBackground: false,
                                                      hasWindowFeatures: false, hasPendingCommand: false, loads: false))
    }

    @Test func backgroundTabRequestsStillOpenATab() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let before = browser.tabManager.tabs(in: browser.tabManager.currentSpaceID).count
            mini.tab(mini.tab, openURL: URL(string: "about:blank#next")!, disposition: .backgroundTab, by: .page)
            #expect(browser.tabManager.tabs(in: browser.tabManager.currentSpaceID).count == before + 1)
            mini.closeInPage(animated: false)
        }
    }

    @Test func aForegroundTabRequestStaysInThePeek() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let before = browser.tabManager.tabs(in: browser.tabManager.currentSpaceID).count
            mini.tab(mini.tab, openURL: URL(string: "about:blank#next")!, disposition: .foregroundTab, by: .page)
            #expect(browser.tabManager.tabs(in: browser.tabManager.currentSpaceID).count == before)
            #expect(mini.holdsPage)
            mini.closeInPage(animated: false)
        }
    }

    @Test func promotingTakesTheMiniOutIntoAWindowOfItsOwn() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let window = try #require(mini.window)
            let card = window.frame
            mini.promoteFromPage()
            #expect(!mini.isDockedInPage)
            #expect(window.parent == nil)
            #expect(window.styleMask.contains(.titled))
            #expect(window.styleMask.contains(.closable))
            #expect(window.isExcludedFromWindowsMenu == false)
            #expect(window.frame.height > card.height)
            #expect(!browser.root.hasInPageMini)
            #expect(browser.root.inPageMiniDim == nil)
            mini.window?.close()
        }
    }

    // MARK: Closing while docked

    @Test func performCloseClosesTheDockedMiniAndItsPage() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let window = try #require(mini.window)
            browser.inPageMini.debugAdopt(mini, from: tab)
            #expect(browser.hasInPageMiniEscMonitor)
            // No fade to wait for: the borderless child's close is synchronous, as ⌘W's is.
            window.alphaValue = 0
            window.performClose(nil)
            #expect(!mini.isDockedInPage)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.hasInPageMiniEscMonitor)
            #expect(!browser.root.hasInPageMini)
            #expect(browser.root.inPageMiniDim == nil)
            #expect(!MiniWindowController.all.contains { $0 === mini })
        }
    }

    @Test func aTabsCloseRequestClosesTheDockedMini() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            try #require(mini.window).alphaValue = 0
            browser.inPageMini.debugAdopt(mini, from: tab)
            mini.tabDidRequestClose(mini.tab)
            #expect(!mini.isDockedInPage)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.root.hasInPageMini)
        }
    }

    @Test func closingTheWindowItselfLetsGoOfTheHostAndDim() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            mini.window?.close()
            #expect(!mini.isDockedInPage)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.hasInPageMiniEscMonitor)
            #expect(!browser.root.hasInPageMini)
        }
    }

    @Test func closingReleasesTheHostRecordAndTheController() async throws {
        try await inWindowAsync { browser, tab in
            weak var weakMini: MiniWindowController?
            var mini: MiniWindowController? = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                                       in: browser, by: .page, dockedIn: browser)
            weakMini = mini
            browser.inPageMini.debugAdopt(try #require(mini), from: tab)
            #expect(browser.inPageMini.record?.controller === mini)
            mini?.window?.alphaValue = 0
            mini?.closeInPage()
            #expect(browser.inPageMini.record == nil)
            #expect(!MiniWindowController.all.contains { $0 === mini })
            mini = nil
            // The record no longer owns it, and its callbacks hold it weakly; AppKit finishes letting the window go.
            try await Task.sleep(for: .milliseconds(200))
            #expect(weakMini == nil)
        }
    }

    // MARK: Undocking and full screen

    @Test func expandingFromAKeptOnTopBrowserGivesANormalWindow() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let window = try #require(mini.window)
            // A child inherits a Keep on Top parent's level, and keeps it after it is removed.
            window.level = .floating
            mini.promoteFromPage()
            #expect(window.level == .normal)
            #expect(!mini.isDockedInPage)
            window.close()
        }
    }

    @Test func aFailedFullScreenTransitionBringsTheDockedMiniBack() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            let window = try #require(browser.window)
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            #expect(mini.isWaitingForParentFullScreen)
            browser.windowDidFailToEnterFullScreen(window)
            #expect(!mini.isWaitingForParentFullScreen)
            NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
            #expect(mini.isWaitingForParentFullScreen)
            browser.windowDidFailToExitFullScreen(window)
            #expect(!mini.isWaitingForParentFullScreen)
            mini.window?.alphaValue = 0
            mini.closeInPage()
        }
    }

    @Test func aDockedMiniIsNotSavedForAnUpdatesRestart() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: URL(string: "https://example.com/"), configuration: nil,
                                                opener: tab, in: browser, by: .page, dockedIn: browser)
            #expect(mini.savedForRelaunch == nil)
            mini.promoteFromPage()
            #expect(mini.savedForRelaunch != nil)
            mini.window?.close()
        }
    }

    // MARK: The off path

    @Test func theStandaloneViewOrderIsTheSameAsMain() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab, in: browser)
            let root = mini.root
            func index(_ view: NSView) -> Int? { root.subviews.firstIndex { $0 === view } }
            // Front to back: bar, strip, page, overlay, then the glow and the command bar over all of it.
            let order = [root.bar, root.strip, root.card, root.overlay, root.attentionEdge, root.barLayer].compactMap(index)
            #expect(order.count == 6)
            #expect(order == order.sorted())
            mini.window?.close()
        }
    }

    @Test func theStandaloneViewOrderComesBackAfterDocking() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let root = mini.root
            func index(_ view: NSView) -> Int { root.subviews.firstIndex { $0 === view } ?? -1 }
            // Docked, the page fills the card under the strip.
            #expect(index(root.card) < index(root.bar))
            #expect(index(root.bar) < index(root.strip))
            mini.promoteFromPage()
            // Standalone again, the strip is above the page as in main.
            #expect(index(root.bar) < index(root.strip))
            #expect(index(root.strip) < index(root.card))
            mini.window?.close()
        }
    }

    @Test func theEscMonitorIsOnlyInstalledWhileAMiniIsDocked() throws {
        try inWindow { browser, tab in
            #expect(!browser.hasInPageMiniEscMonitor)
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            #expect(browser.hasInPageMiniEscMonitor)
            mini.window?.alphaValue = 0
            mini.closeInPage()
            #expect(!browser.hasInPageMiniEscMonitor)
        }
    }

    // MARK: ⌘W and window.close() through the Mini's own actions

    @Test func commandWClosesTheDockedMini() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            // No fade to wait for, so a locked screen's stalled animations can't hold the close.
            try #require(mini.window).alphaValue = 0
            // ⌘W in the Mini is its own Close Tab, which presses the borderless window's close.
            mini.closeTab(nil)
            #expect(!mini.isDockedInPage)
            #expect(mini.window?.isVisible != true)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.root.hasInPageMini)
        }
    }

    @Test func aPagesWindowCloseClosesTheDockedMini() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            try #require(mini.window).alphaValue = 0
            mini.tabDidRequestClose(mini.tab)
            #expect(!mini.isDockedInPage)
            #expect(mini.window?.isVisible != true)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
        }
    }

    @Test func commandWOnAStandaloneMiniStillClosesItsWindow() async throws {
        try await inWindowAsync { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab, in: browser, by: .page)
            #expect(!mini.isDockedInPage)
            #expect(mini.window?.styleMask.contains(.closable) == true)
            mini.closeTab(nil)
            try await Task.sleep(for: .milliseconds(800))
            #expect(mini.window?.isVisible != true)
            #expect(mini.tab.isClosed)
            #expect(!MiniWindowController.all.contains { $0 === mini })
        }
    }

    @Test func performCloseOnABrowserWindowStillClosesIt() throws {
        try inWindow { browser, _ in
            let window = try #require(browser.window)
            window.performClose(nil)
            #expect(browser.windowClosed)
            #expect(!window.isVisible)
        }
    }

    @Test func closeWindowStaysOnForADockedMini() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let window = try #require(mini.window)
            let item = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
            #expect(window.validateMenuItem(item))
            mini.closeInPage(animated: false)
        }
    }

    // MARK: What puts it away

    @Test func commandTOpensTheBrowsersNewTabBarAndDropsTheDockedMini() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            try #require(mini.window).alphaValue = 0
            // The menu bar's ⌘T reaches the Mini, which hands it to the browser rather than letting it act behind
            // the page it's over.
            mini.newTab(nil)
            #expect(!mini.isDockedInPage)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.root.hasInPageMini)
            #expect(browser.commandBar.isVisible)
            #expect(browser.commandBar.mode == .newTab)
        }
    }

    @Test func theDockedMiniTakesEscFromThePageButNotFromPickedRows() throws {
        try inWindow { browser, tab in
            let other = browser.tabManager.newTab(url: URL(string: "about:blank"), select: false)
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            let window = try #require(browser.window)
            let page = try #require(browser.root.paneCards.compactMap(\.webView).first)
            window.makeFirstResponder(page)
            #expect(browser.inPageMiniPageHasKeyboard)
            // Picked rows keep Esc to clear the pick, rather than closing the Mini first.
            browser.sidebar.list.mark(pages: [tab, other])
            #expect(!browser.inPageMiniPageHasKeyboard)
            mini.closeInPage(animated: false)
        }
    }

    @Test func escClosesTheDockedMini() async throws {
        try await inWindowAsync { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            try #require(mini.window).alphaValue = 0
            #expect(browser.inPageMini.escapePressed(esc))
            // The page is asked first whether it keeps Esc, so the close can come a moment later.
            for _ in 0..<50 where mini.isDockedInPage { try await Task.sleep(for: .milliseconds(100)) }
            #expect(!mini.isDockedInPage)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.root.hasInPageMini)
        }
    }

    @Test func aScrollOverTheDimLeavesThePageBehindStill() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("peek-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tall.html")
        try "<style>body{height:4000px}p{font:20px sans-serif}</style><p>top</p>".write(to: url, atomically: true, encoding: .utf8)
        try await inWindowAsync(pageAt: url) { browser, tab in
            let page = try #require(tab.webView)
            let loaded = await until { !page.isLoading }
            #expect(loaded)
            try await page.evaluateJavaScript("window.scrollTo(0, 600)")
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await page.evaluateJavaScript("window.scrollY") as? Double == 600)
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            let window = try #require(browser.window)
            let pane = browser.root.cardFrame
            // On the dim, outside the Mini's own card.
            let point = NSPoint(x: pane.minX + 8, y: pane.midY)
            #expect(browser.root.hitTest(point) === browser.root.inPageMiniDim)
            window.sendEvent(try scroll(at: browser.root.convert(point, to: nil), in: window, dy: 200))
            try await Task.sleep(for: .milliseconds(400))
            let moved = try await page.evaluateJavaScript("window.scrollY") as? Double
            #expect(moved == 600, "the page behind the dim scrolled to \(moved ?? -1)")
            mini.closeInPage(animated: false)
        }
    }

    @Test func aClickOnTheDimClosesTheDockedMini() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            let dim = try #require(browser.root.inPageMiniDim as? MiniPeekDimView)
            try #require(mini.window).alphaValue = 0
            dim.onClick?()
            #expect(!mini.isDockedInPage)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.root.hasInPageMini)
        }
    }

    @Test func aTabSwitchClosesTheDockedMini() throws {
        try inWindow { browser, tab in
            let other = browser.tabManager.newTab(url: URL(string: "about:blank"), select: false)
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            browser.inPageMini.debugAdopt(mini, from: tab)
            try #require(mini.window).alphaValue = 0
            browser.tabManager.select(other)
            #expect(!mini.isDockedInPage)
            #expect(mini.tab.isClosed)
            #expect(browser.inPageMini.record == nil)
        }
    }

    @Test func expandKeepsTheSameLivePage() throws {
        try inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: URL(string: "about:blank#kept"), configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            let page = try #require(mini.tab.webView)
            mini.promoteFromPage()
            #expect(!mini.isDockedInPage)
            #expect(mini.tab.webView === page)
            #expect(!mini.tab.isClosed)
            mini.window?.close()
        }
    }

    @Test func withTheSettingOffAShiftClickIsTheStandaloneMini() throws {
        try inWindow { browser, tab in
            let before = InPageMiniSettings.isEnabled
            InPageMiniSettings.isEnabled = false
            defer { InPageMiniSettings.isEnabled = before }
            let count = MiniWindowController.all.count
            #expect(!browser.openInPageMini(URL(string: "about:blank#off")!, configuration: nil, opener: tab))
            #expect(MiniWindowController.all.count == count)
            #expect(browser.inPageMini.record == nil)
            #expect(!browser.hasInPageMiniEscMonitor)
        }
    }
}


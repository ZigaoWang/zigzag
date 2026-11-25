import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

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
            let pane = NSRect(x: 40, y: 30, width: 620, height: 420)
            mini.layoutInDock(pane: pane)
            let card = MiniDockLayout.frame(in: pane)
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
            mini.layoutInDock(pane: browser.root.cardFrame)
            #expect(mini.isCoveredInDock)
            browser.root.reveal(false)
            #expect(!browser.root.coversInPageMini)
            mini.layoutInDock(pane: browser.root.cardFrame)
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
            mini.layoutInDock(pane: browser.root.cardFrame)
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

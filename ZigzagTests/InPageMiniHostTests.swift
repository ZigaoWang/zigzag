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
}


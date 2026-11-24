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

    @Test func aDockedMiniEmbedsAndCloses() {
        inWindow { browser, tab in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: tab,
                                                in: browser, by: .page, dockedIn: browser)
            #expect(mini.isDockedInPage)
            #expect(browser.root.inPageMini === mini.root)
            #expect(browser.root.inPageMiniDim != nil)
            mini.closeInPage(animated: false)
            #expect(browser.root.inPageMini == nil)
            #expect(browser.root.inPageMiniDim == nil)
        }
    }

    @Test func theHostOpensOneAndClosesIt() {
        inWindow { browser, tab in
            browser.inPageMini.enabledProvider = { true }
            browser.inPageMini.shouldDock = { _, _, _, _, _ in true }
            NSApp.activate(ignoringOtherApps: true)
            browser.window?.makeKeyAndOrderFront(nil)
            #expect(browser.inPageMini.openURL(url: URL(string: "about:blank"), configuration: nil, opener: tab, by: .page))
            #expect(browser.inPageMini.record != nil)
            #expect(browser.inPageMini.record?.controller.isDockedInPage == true)
            browser.inPageMini.closeShown(animated: false)
            #expect(browser.inPageMini.record == nil)
            #expect(browser.root.inPageMini == nil)
        }
    }
}

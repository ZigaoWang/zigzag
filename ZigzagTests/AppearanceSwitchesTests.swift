import AppKit
import Testing
@testable import Zigzag

/// Settings › Appearance's switches from #537, #538 and #539: each keeps today's look until turned, and is kept.
@MainActor
struct AppearanceSwitchesTests {
    /// Runs `body` with `key` cleared, as on a new install, and puts back what was there.
    private func fresh(_ key: String, _ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        try body()
    }

    // MARK: Show link address on hover (#537)

    @Test func theLinkAddressShowsUntilTurnedOff() {
        fresh(LinkStatusController.defaultsKey) {
            #expect(LinkStatusController.showsOnHover)
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            status.show(URL(string: "https://example.com/a"), in: overlay.bounds)
            #expect(status.isShowing)
            #expect(!overlay.subviews.isEmpty)
        }
    }

    @Test func offNoLinkAddressShowsAndTheChoiceIsKept() {
        fresh(LinkStatusController.defaultsKey) {
            LinkStatusController.showsOnHover = false
            #expect(UserDefaults.standard.object(forKey: LinkStatusController.defaultsKey) as? Bool == false)
            #expect(!LinkStatusController.showsOnHover)
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            status.show(URL(string: "https://example.com/a"), in: overlay.bounds)
            #expect(!status.isShowing)
            #expect(overlay.subviews.isEmpty)
            LinkStatusController.showsOnHover = true
            status.show(URL(string: "https://example.com/a"), in: overlay.bounds)
            #expect(status.isShowing)
        }
    }

    // MARK: Shorter floating sidebar (#538)

    @Test func theFloatingSidebarIsFullHeightUntilTurnedOn() {
        fresh(BrowserRootView.shortFloatingKey) {
            #expect(!BrowserRootView.shortFloatingSidebar)
            let bounds = NSRect(x: 0, y: 0, width: 1200, height: 900)
            let inset = Tokens.Metric.cardInset
            let out = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: true, onRight: false)
            #expect(out == NSRect(x: inset, y: inset, width: 260, height: 900 - inset * 2))
        }
    }

    @Test func onTheFloatingSidebarIsTwoThirdsHighInTheMiddle() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let inset = Tokens.Metric.cardInset
        for onRight in [false, true] {
            let out = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: true, onRight: onRight, short: true)
            #expect(out.height == 600)
            #expect(out.minY == 150 && bounds.maxY - out.maxY == 150)
            #expect(onRight ? out.maxX == 1200 - inset : out.minX == inset)
            // Away past the edge it keeps the same height, so it slides straight in and out.
            let away = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: false, onRight: onRight, short: true)
            #expect(away.minY == out.minY && away.height == out.height)
        }
        // Docked, it runs the window's height as always.
        let docked = BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: true, revealed: false, onRight: false, short: true)
        #expect(docked == NSRect(x: 0, y: 0, width: 260, height: 900))
    }

    @Test func theShorterFloatingSidebarIsKept() {
        fresh(BrowserRootView.shortFloatingKey) {
            BrowserRootView.shortFloatingSidebar = true
            #expect(UserDefaults.standard.bool(forKey: BrowserRootView.shortFloatingKey))
            #expect(BrowserRootView.shortFloatingSidebar)
            let bounds = NSRect(x: 0, y: 0, width: 1200, height: 600)
            #expect(BrowserRootView.sidebarFrame(in: bounds, width: 260, visible: false, revealed: true, onRight: false).height == 400)
        }
    }
}

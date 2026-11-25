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
}

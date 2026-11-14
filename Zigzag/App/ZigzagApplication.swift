import AppKit

/// Zigzag's application object. In Debug builds, a test copy started with `ZIGZAG_STAY_BEHIND=1` never brings itself
/// forward, so checking a change in it doesn't take the screen or the keyboard from whatever you're doing.
final class ZigzagApplication: NSApplication {
    /// A key an AI app pressed in a page (press_key) that the page didn't take comes back here from WebKit on its
    /// way to the menus, as keys do. It stops here: it never runs a Zigzag shortcut or reaches anything but the page.
    override func sendEvent(_ event: NSEvent) {
        if MCPKeyDelivery.stopsOnTheWayBack(event) { return }
        super.sendEvent(event)
    }

    #if DEBUG
    static let staysBehind = ProcessInfo.processInfo.environment["ZIGZAG_STAY_BEHIND"] == "1"

    override func activate() {
        guard !Self.staysBehind else { return }
        super.activate()
    }

    override func activate(ignoringOtherApps flag: Bool) {
        guard !Self.staysBehind else { return }
        super.activate(ignoringOtherApps: flag)
    }
    #endif
}

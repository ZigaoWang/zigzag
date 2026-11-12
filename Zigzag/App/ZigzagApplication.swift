import AppKit

/// Zigzag's application object. In Debug builds, a test copy started with `ZIGZAG_STAY_BEHIND=1` never brings itself
/// forward, so checking a change in it doesn't take the screen or the keyboard from whatever you're doing.
final class ZigzagApplication: NSApplication {
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

import Testing
@testable import Zigzag

/// When a link wakes Zigzag, its browser windows wait unseen unless the wake was plainly something else: ⌘Tab, a key,
/// the Dock, a notification or a click on Zigzag itself must bring them back as always, however slow Zigzag is to hear.
struct MiniLinkWakeTests {
    private func waits(click: Double, key: Double, modifier: Double, _ owner: (Bool, String)?) -> Bool {
        MiniLinkWake.reasonNotToWait(sinceClick: click, sinceKey: key, sinceModifier: modifier, under: owner) == nil
    }

    @Test func aLinkClickedInAnotherAppWaits() {
        #expect(waits(click: 0.05, key: 30, modifier: 40, (false, "WeChat")))
    }

    @Test func aLinkClickedWhileZigzagWasBusyStillWaits() {
        // Zigzag heard it woke a second and a half after the click.
        #expect(waits(click: 1.5, key: 30, modifier: 40, (false, "Mail")))
    }

    @Test func commandTabNeverWaits() {
        // ⌘Tab wakes Zigzag as ⌘ is let go: that's the latest thing, after any click.
        #expect(!waits(click: 2, key: 0.3, modifier: 0.02, (false, "WeChat")))
        #expect(!waits(click: 0.4, key: 0.3, modifier: 0.02, (false, "WeChat")))
    }

    @Test func aKeyNeverWaits() {
        // Return in Spotlight, a shortcut, a link opened from the keyboard.
        #expect(!waits(click: 0.3, key: 0.05, modifier: 10, (false, "Spotlight")))
    }

    @Test func theDockNotificationsAndZigzagItselfNeverWait() {
        #expect(!waits(click: 0.05, key: 30, modifier: 40, (false, "Dock")))
        #expect(!waits(click: 0.05, key: 30, modifier: 40, (false, "NotificationCenter")))
        #expect(!waits(click: 0.05, key: 30, modifier: 40, (true, "Zigzag")))
    }
}

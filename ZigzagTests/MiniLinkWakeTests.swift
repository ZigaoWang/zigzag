import Testing
@testable import Zigzag

/// When a link wakes Zigzag, its browser windows wait unseen only if a click in another app did it: ⌘Tab, the Dock,
/// a notification or a click on Zigzag itself must bring them back as always.
struct MiniLinkWakeTests {
    @Test func aLinkClickedInAnotherAppWaits() {
        #expect(MiniLinkWake.wokenByClick(sinceClick: 0.05, sinceKey: 30, sinceModifier: 40, under: (false, "WeChat")))
    }

    @Test func commandTabNeverWaits() {
        // ⌘Tab wakes Zigzag as ⌘ is let go: that's the latest thing, after any click.
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 2, sinceKey: 0.3, sinceModifier: 0.02, under: (false, "WeChat")))
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 0.4, sinceKey: 0.3, sinceModifier: 0.02, under: (false, "WeChat")))
    }

    @Test func aKeyNeverWaits() {
        // Return in Spotlight, a shortcut, a link opened from the keyboard.
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 0.3, sinceKey: 0.05, sinceModifier: 10, under: (false, "Spotlight")))
    }

    @Test func theDockNotificationsAndZigzagItselfNeverWait() {
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 0.05, sinceKey: 30, sinceModifier: 40, under: (false, "Dock")))
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 0.05, sinceKey: 30, sinceModifier: 40, under: (false, "NotificationCenter")))
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 0.05, sinceKey: 30, sinceModifier: 40, under: (true, "Zigzag")))
    }

    @Test func anOldClickOrNoWindowNeverWaits() {
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 1.5, sinceKey: 30, sinceModifier: 40, under: (false, "WeChat")))
        #expect(!MiniLinkWake.wokenByClick(sinceClick: 0.05, sinceKey: 30, sinceModifier: 40, under: nil))
    }
}

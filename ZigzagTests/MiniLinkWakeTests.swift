import AppKit
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

    /// Where the windows sat as Zigzag went to the background is kept until the next time: a window closed meanwhile
    /// isn't kept alive by it, and drops out of the places a wake puts back.
    @MainActor @Test func theSettledPlacesHoldTheirWindowsWeakly() {
        let kept = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        weak var closed: NSWindow?
        var settled: [MiniLinkWake.SettledPlace] = []
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            closed = window
            settled = MiniLinkWake.settledPlaces([(window, 7), (kept, 8)])
            #expect(MiniLinkWake.places(of: [window, kept], in: settled).map(\.below) == [7, 8])
        }
        #expect(closed == nil && settled[0].window == nil)
        let places = MiniLinkWake.places(of: [kept], in: settled)
        #expect(places.count == 1 && places[0].window === kept && places[0].below == 8)
    }

    /// A browser window shown off screen, as the windows a wake would hold.
    @MainActor private func inWindow(_ body: (BrowserWindowController, NSWindow) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/lock")!, title: "Lock", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 900, height: 600))
        guard let window = controller.window else { Issue.record("no window"); return }
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        window.orderFrontRegardless()
        defer { MiniLinkWake.release(); window.orderOut(nil); window.close() }
        try body(controller, window)
    }

    /// Unlocking the screen gives the front back to Zigzag: its windows show at once, never held unseen, which left a
    /// full-screen window black and showed the window behind a windowed one.
    @MainActor @Test func unlockingNeverHoldsTheWindows() {
        ScreenLock.shared.reset()
        defer { ScreenLock.shared.reset() }
        inWindow { _, window in
            // What a link's wake does: the window waits unseen.
            MiniLinkWake.wake([window], reason: nil)
            #expect(MiniLinkWake.isHolding && window.alphaValue == 0)
            MiniLinkWake.release()
            #expect(!MiniLinkWake.isHolding && window.alphaValue == 1)
            // Unlocked, and Zigzag hears it woke after the unlock.
            ScreenLock.shared.screenDidLock()
            ScreenLock.shared.screenDidUnlock()
            MiniLinkWake.wake([window], reason: MiniLinkWake.reasonNotToWait())
            #expect(!MiniLinkWake.isHolding && window.alphaValue == 1)
            // Zigzag hears it woke before the unlock does.
            ScreenLock.shared.screenDidLock()
            MiniLinkWake.wake([window], reason: MiniLinkWake.reasonNotToWait())
            #expect(!MiniLinkWake.isHolding && window.alphaValue == 1)
            ScreenLock.shared.screenDidUnlock()
            // Back from another user's session.
            ScreenLock.shared.sessionDidResign()
            ScreenLock.shared.sessionDidBecomeActive()
            MiniLinkWake.wake([window], reason: MiniLinkWake.reasonNotToWait())
            #expect(!MiniLinkWake.isHolding && window.alphaValue == 1)
        }
    }

    /// Only the unlock's own wake is passed over: after it, or after another app took the front back, a link's wake
    /// holds the windows again.
    @MainActor @Test func theUnlockWakeIsTakenOnce() {
        let lock = ScreenLock()
        lock.screenDidLock()
        #expect(lock.isLocked && lock.wakeIsUnlock)
        // Woken while still locked: still the unlock's, for when it comes.
        #expect(lock.takeUnlockWake())
        lock.screenDidUnlock()
        #expect(!lock.isLocked && lock.takeUnlockWake())
        #expect(!lock.takeUnlockWake())
        lock.screenDidLock()
        lock.screenDidUnlock()
        lock.appActivated(isZigzag: false, isLoginWindow: true)
        #expect(lock.wakeIsUnlock)
        lock.appActivated(isZigzag: false, isLoginWindow: false)
        #expect(!lock.wakeIsUnlock && !lock.takeUnlockWake())
    }

    /// The lock is heard from macOS's own notifications: the screen locking and unlocking, and the session switching.
    @MainActor @Test func theLockIsHeardFromItsNotifications() {
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        let lock = ScreenLock()
        lock.start(workspace: workspace, distributed: distributed)
        defer { lock.stop() }
        var changes = 0
        let token = NotificationCenter.default.addObserver(forName: ScreenLock.changedNotification, object: lock, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        distributed.post(name: ScreenLock.lockedNotification, object: nil)
        #expect(lock.isLocked && changes == 1)
        distributed.post(name: ScreenLock.unlockedNotification, object: nil)
        #expect(!lock.isLocked && changes == 2 && lock.wakeIsUnlock)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(lock.isLocked)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(!lock.isLocked && changes == 4)
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(!lock.wakeIsUnlock)
    }

    /// A see-through space's glass, which goes while its window can't be seen, stays through a locked screen, so the
    /// window shows with it on unlocking rather than clear (black behind it in full screen) until macOS says it's seen.
    @MainActor @Test func theGlassStaysThroughALock() {
        ScreenLock.shared.reset()
        defer { ScreenLock.shared.reset() }
        // Never ordered in: out of sight, as behind the lock screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let frame = SpaceFrameView()
        frame.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = frame
        frame.setGlass(true)
        #expect(window.occlusionState.contains(.visible) == false)
        #expect(frame.debugGlass["frostedAlpha"] as? CGFloat == 0)
        ScreenLock.shared.screenDidLock()
        #expect(frame.debugGlass["frostedAlpha"] as? CGFloat == 1)
        ScreenLock.shared.screenDidUnlock()
        // Still there for the unlock, until the window is seen again.
        #expect(frame.debugGlass["frostedAlpha"] as? CGFloat == 1)
    }

    /// Behind the lock screen a window can't be seen, but its front page is still the one shown: it never sleeps for
    /// being out of sight (tab sleep and the energy watch keep what `shownTabs` lists), so unlocking reloads nothing.
    @MainActor @Test func theFrontTabStaysShownWhileLocked() {
        ScreenLock.shared.reset()
        defer { ScreenLock.shared.reset() }
        inWindow { controller, window in
            window.orderOut(nil)
            ScreenLock.shared.screenDidLock()
            #expect(window.occlusionState.contains(.visible) == false)
            #expect(controller.tabManager.shownTabs.map(\.id) == controller.tabManager.selectedTab.map { [$0.id] })
        }
    }
}

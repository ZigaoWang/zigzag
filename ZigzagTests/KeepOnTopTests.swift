import AppKit
import Testing
@testable import Zigzag

/// Window › Keep on Top: a window floats above the rest, a small one on every desktop too, and turning it off gives
/// the window back exactly as it was.
@MainActor
struct KeepOnTopTests {
    private func window(_ behavior: NSWindow.CollectionBehavior = []) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = behavior
        return window
    }

    @Test func aSmallWindowFollowsYouToEveryDesktop() {
        let on = KeepOnTop.behavior(from: [.moveToActiveSpace, .fullScreenNone], on: true)
        #expect(on.contains(.canJoinAllSpaces))
        #expect(on.contains(.fullScreenAuxiliary))
        // The two can't both be on.
        #expect(!on.contains(.moveToActiveSpace))
        #expect(on.contains(.fullScreenNone))
        #expect(KeepOnTop.behavior(from: [.moveToActiveSpace], on: false) == [.moveToActiveSpace])
    }

    @Test func aBrowserWindowOnlyFloats() {
        // One that goes full screen itself stays on its own desktop.
        #expect(KeepOnTop.behavior(from: [.fullScreenPrimary], on: true) == [.fullScreenPrimary])
    }

    @Test func turningItOffGivesTheWindowBackAsItWas() {
        let window = window([.fullScreenNone])
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let token = NotificationCenter.default.addObserver(forName: KeepOnTop.changed, object: window, queue: nil) { _ in count.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(!KeepOnTop.isOn(window))
        KeepOnTop.toggle(window)
        #expect(KeepOnTop.isOn(window))
        #expect(window.level == .floating)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        // Again on: nothing changes, nothing is said.
        KeepOnTop.set(true, for: window)
        #expect(count.value == 1)
        KeepOnTop.toggle(window)
        #expect(!KeepOnTop.isOn(window))
        #expect(window.level == .normal)
        #expect(window.collectionBehavior == [.fullScreenNone])
        #expect(count.value == 2)
    }

    @Test func onlyOrdinaryWindowsCanBeKeptOnTop() {
        #expect(KeepOnTop.applies(to: window()))
        #expect(!KeepOnTop.applies(to: nil))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!KeepOnTop.applies(to: panel))
        let borderless = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!KeepOnTop.applies(to: borderless))
    }
}

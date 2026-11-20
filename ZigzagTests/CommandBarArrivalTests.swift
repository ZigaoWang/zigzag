import AppKit
import Foundation
import Testing
@testable import Zigzag

/// The empty-window bar closes when a page arrives another way (Open in from Mini); a bar opened over a page stays.
@MainActor struct CommandBarArrivalTests {
    private final class Host: CommandBarHost {
        let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        var tab: Tab?
        init() { window?.isReleasedWhenClosed = false; window?.contentView = overlay }
        var commandBarOverlay: NSView { overlay }
        var commandBarPageFrame: NSRect { overlay.bounds }
        func commandBarAnchor(asked: NSView?) -> NSView? { asked }
        var commandBarTabs: TabManager? { nil }
        var commandBarProfile: Profile { Profiles.shared.default }
        var commandBarTab: Tab? { tab }
        var commandBarSpace: SpaceInfo? { nil }
        var commandBarIsPrivate: Bool { false }
        func commandBarWillShow() {}
        func commandBarRestoreFocus() {}
        func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool { true }
        func commandBarDidHide() {}
    }

    @Test func theEmptyWindowsBarGoesWhenAPageArrives() {
        let host = Host()
        let bar = CommandBarController(host: host)
        bar.show(mode: .newTab)
        #expect(bar.isForEmptyWindow)
        bar.pageArrived()
        #expect(!bar.isVisible)
    }

    @Test func aBarOpenedOverAPageStays() {
        let host = Host()
        let tab = Tab(url: URL(string: "https://example.com")!, spaceID: Library.shared.spaces[0].id)
        defer { tab.close() }
        host.tab = tab
        let bar = CommandBarController(host: host)
        // ⌘T and ⌘L over a page aren't the empty-window bar.
        bar.show(mode: .newTab)
        #expect(!bar.isForEmptyWindow)
        bar.pageArrived()
        #expect(bar.isVisible)
        bar.dismiss(restoringFocus: false)
        bar.show(mode: .editCurrent)
        bar.pageArrived()
        #expect(bar.isVisible)
        bar.dismiss(restoringFocus: false)
    }

    /// A split pane's address opens at its own size, in its strip's light or dark, never past its pane.
    @Test func aPanesAddressOpensInItsStrip() throws {
        let host = Host()
        let tab = Tab(url: URL(string: "https://example.com/a/long/address/that/needs/room")!, spaceID: Library.shared.spaces[0].id)
        defer { tab.close() }
        host.tab = tab
        let strip = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 420, height: PaneHeaderView.height))
        strip.appearance = NSAppearance(named: .darkAqua)
        host.overlay.addSubview(strip)
        strip.address.text = "example.com"
        strip.layoutSubtreeIfNeeded()
        let bar = CommandBarController(host: host)
        bar.show(mode: .editCurrent, anchor: strip.address)
        let panel = bar.panelView
        #expect(panel.frame.height == strip.address.frame.height)
        #expect(panel.frame.minX >= strip.addressRoom.lowerBound && panel.frame.maxX <= strip.addressRoom.upperBound)
        #expect(panel.effectiveAppearance.isDark)
        bar.dismiss(restoringFocus: false)
    }
}

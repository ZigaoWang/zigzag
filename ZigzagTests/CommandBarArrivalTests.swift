import AppKit
import Foundation
import Testing
@testable import Zigzag

/// The bar an empty window opens with goes when a page arrives some other way (Open in from Zigzag Mini), and a bar
/// you opened over a page stays.
@MainActor struct CommandBarArrivalTests {
    private final class Host: CommandBarHost {
        let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        var tab: Tab?
        init() { window?.isReleasedWhenClosed = false; window?.contentView = overlay }
        var commandBarOverlay: NSView { overlay }
        var commandBarPageFrame: NSRect { overlay.bounds }
        func commandBarAnchor(asked: NSView?) -> NSView? { nil }
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
        // ⌘T over a page, and ⌘L: neither was the empty window's.
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
}

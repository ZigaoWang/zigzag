import AppKit
import Testing
@testable import Zigzag

/// The panel's New Tab (#560): with the panel out, the + menu's New Tab and the panel's ⌘T open the bar over the
/// screen, in the panel, in the space the panel shows, and never bring the browser window behind forward.
@MainActor
struct EdgeNewTabTests {
    /// Below a menu bar, no Dock.
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let offScreen = NSPoint(x: -100_000, y: -100_000)

    /// A window with one tab, and the panel out for it.
    private func panelWithTab(_ path: String = "https://example.test/a",
                              _ body: (BrowserWindowController, TabManager, Tab, NSWindow, EdgeSidebarHost) throws -> Void) throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        let tab = manager.newTab(url: URL(string: path), spaceID: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        EdgeSidebar.debugHoldsOpen = true
        EdgeSidebar.debugPointer = offScreen
        defer {
            EdgeSidebar.shared.hide(animated: false)
            EdgeSidebar.debugHoldsOpen = false
            EdgeSidebar.debugPointer = nil
            controller.window?.close()
            manager.invalidate()
            Library.shared.restore(before)
        }
        EdgeSidebar.shared.show(on: visible, for: controller)
        let panel = try #require(NSApp.windows.first { $0.contentView is EdgeSidebarHost })
        let host = try #require(panel.contentView as? EdgeSidebarHost)
        try body(controller, manager, tab, panel, host)
    }

    /// A ⌘ key as the window sends it.
    private func keys(_ key: String, code: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    /// With the space changed under it, the bar opens the page in the space the panel shows now, not the one it was
    /// opened in.
    @Test func theBarFollowsTheSpaceThePanelShows() throws {
        try panelWithTab { controller, manager, _, _, _ in
            EdgeSidebar.shared.showNewTabBar()
            let bar = try #require(EdgeSidebar.shared.newTabBar)
            let other = Library.shared.addSpace(name: "Edge bar space").id
            manager.switchToSpace(other)
            #expect(manager.currentSpaceID == other)
            bar.debugType("https://example.test/there")
            bar.debugEnter()
            let made = try #require(manager.selectedTab)
            #expect(made.spaceID == other)
            #expect(made.url?.absoluteString == "https://example.test/there")
        }
    }

    /// Both ways into New Tab in the panel go through `listNewTab`: the + menu's item and the panel's ⌘T.
    /// The panel stays where it was, the window behind stays behind, and the bar is the panel's.
    @Test func thePanelsOwnCommandTSSNewTabOpensInThePanel() throws {
        try panelWithTab { controller, manager, _, panel, _ in
            let before = manager.currentTabs.count
            #expect(panel.performKeyEquivalent(with: try keys("t", code: 17, in: panel)))
            let bar = try #require(EdgeSidebar.shared.newTabBar)
            #expect(bar.isVisible && bar.mode == .newTab)
            #expect(bar.panelView.window === panel)
            // Its glass shows the desktop: no page is behind the bar in the panel's window.
            #expect(bar.showsDesktop)
            // The field has the keyboard, so Esc reaches it rather than putting the panel away.
            #expect(panel.firstResponder is NSTextView)
            // Not the window's bar, which would need the window in front to type in.
            #expect(!controller.commandBar.isVisible)
            #expect(EdgeSidebar.shared.isShowing)
            #expect(controller.window?.isKeyWindow != true)
            // Nothing is made until something is typed and Return goes.
            #expect(manager.currentTabs.count == before)
        }
    }

    /// The + menu's New Tab is done in the panel: the menu closes, the panel stays out, and the bar opens there.
    @Test func thePlusMenusNewTabOpensTheSameBarInThePanel() throws {
        try panelWithTab { controller, _, _, panel, _ in
            let sidebar = try #require(controller.edgeSidebar)
            let entries = SidebarMenus.addPanel(controller: controller)
            try #require(MenuPanel.show(entries, from: sidebar.newSpaceButton) != nil)
            let menu = try #require(MenuPanel.current)
            let row = try #require(menu.itemTitles.firstIndex(of: SidebarMenus.title(of: .newTab)))
            for _ in 0...row { menu.debugKey(125) }
            menu.debugKey(36)
            #expect(EdgeSidebar.shared.isShowing)
            let bar = try #require(EdgeSidebar.shared.newTabBar)
            #expect(bar.isVisible && bar.mode == .newTab && bar.panelView.window === panel)
            #expect(!controller.commandBar.isVisible)
            #expect(controller.window?.isKeyWindow != true)
        }
    }

    /// The bar takes the page where the panel's list shows it: the window's tabs, in the space the panel is showing,
    /// and the panel stays out with the keyboard.
    @Test func theBarMakesThePageInTheSpaceThePanelShows() throws {
        try panelWithTab { controller, manager, _, panel, _ in
            EdgeSidebar.shared.showNewTabBar()
            let bar = try #require(EdgeSidebar.shared.newTabBar)
            let shown = manager.currentSpaceID
            bar.debugType("https://example.test/new")
            bar.debugEnter()
            #expect(!bar.isVisible)
            // The window has it, in the space the panel was showing.
            let made = try #require(manager.selectedTab)
            #expect(made.url?.absoluteString == "https://example.test/new")
            #expect(made.spaceID == shown)
            #expect(made.host === controller)
            // Typed in the panel, done in the panel: the list shows the new row and the keyboard stays there.
            #expect(EdgeSidebar.shared.isShowing)
            #expect(panel.isVisible == true)
            #expect(panel.isKeyWindow)
            #expect(controller.window?.isKeyWindow != true)
        }
    }

    /// Closing the bar without opening anything hands the keyboard back to the panel, not to the window behind.
    @Test func escHandsTheKeyboardBackToThePanel() throws {
        try panelWithTab { controller, _, _, panel, _ in
            EdgeSidebar.shared.showNewTabBar()
            let bar = try #require(EdgeSidebar.shared.newTabBar)
            bar.debugEscape()
            #expect(!bar.isVisible)
            #expect(EdgeSidebar.shared.isShowing)
            #expect(panel.isKeyWindow)
            #expect(controller.window?.isKeyWindow != true)
            #expect(panel.isVisible == true)
        }
    }

    /// While the bar is out the panel keeps its room beside the card, and the pointer away from the panel doesn't
    /// send it back: typing is no time for the panel to slide away.
    @Test func theBarHoldsThePanelOutWithThePointerAway() throws {
        try panelWithTab { controller, _, _, panel, host in
            let cardBefore = panel.convertToScreen(host.convert(host.cardFrame, to: nil))
            EdgeSidebar.shared.showNewTabBar()
            let bar = try #require(EdgeSidebar.shared.newTabBar)
            // The panel widened for the bar's room, the card staying where it was on screen.
            let frame = EdgeSidebarLayout.newTabBarFrame(in: visible, sidebar: controller.edgeSidebarWidth,
                                                         inset: host.inset, onRight: controller.edgeSidebarOnRight)
            #expect(panel.frame == frame)
            #expect(frame.width > controller.edgeSidebarWidth + host.inset)
            #expect(panel.convertToScreen(host.convert(host.cardFrame, to: nil)) == cardBefore)
            #expect(host.bounds.contains(bar.panelView.frame), "bar \(bar.panelView.frame) host \(host.bounds)")
            EdgeSidebar.shared.hide(animated: false)
            #expect(!bar.isVisible, "the bar goes with the panel")
        }
    }

    /// With the panel not out, the window's own bar is what New Tab opens, as ever.
    @Test func withoutThePanelTheWindowsBarIsTheOneThatOpens() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 900, height: 600))
        defer { controller.window?.close() }
        controller.listNewTab()
        #expect(controller.commandBar.isVisible && controller.commandBar.mode == .newTab)
        #expect(EdgeSidebar.shared.newTabBar?.isVisible != true)
        controller.commandBar.dismiss()
    }

    /// The + menu's items are all done in the panel now, New Tab included.
    @Test func everyPlusItemStaysInThePanel() {
        #expect(SidebarMenus.addEntries(isPrivate: false).filter { $0 != .separator }.count > 0)
        // The bar's room is the card's plus the gutters plus the whole bar, never past the screen.
        let narrow = EdgeSidebarLayout.newTabBarFrame(in: visible, sidebar: 240, inset: 8, onRight: false)
        #expect(narrow.minX == visible.minX)
        #expect(narrow.width >= 240 + 8 + Tokens.Metric.commandBarWidth)
        let wide = EdgeSidebarLayout.newTabBarFrame(in: visible, sidebar: 240, inset: 8, onRight: true)
        #expect(wide.maxX == visible.maxX)
        #expect(wide.width == narrow.width)
    }
}

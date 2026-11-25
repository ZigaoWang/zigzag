import AppKit
import Testing
@testable import Zigzag

/// A mouse's side buttons go back and forward in every window that shows a page, Zigzag Mini and installed apps too,
/// not only the browser window (#345).
@MainActor
struct SideButtonTests {
    private final class Controller: NSWindowController, SideButtonHistory {
        var actions: [String] = []
        @objc func goBack(_ sender: Any?) { actions.append("back") }
        @objc func goForward(_ sender: Any?) { actions.append("forward") }

        /// Three pages each way, the way `BrowserWindowController.historyMenu` lists them.
        func sideButtonHistory(back: Bool) -> NSMenu? {
            let menu = NSMenu()
            for title in ["One", "Two", "Three"] {
                let page = (back ? "back " : "forward ") + title
                menu.addItem(SidebarMenus.Item(page) { [weak self] in self?.actions.append(page) })
            }
            return menu
        }
    }

    private func press(_ button: Int64, in window: NSWindow) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center) else { continue }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        }
    }

    /// One side button event at `point` in the window's own coordinates.
    private func side(_ type: NSEvent.EventType, _ button: Int64, at point: NSPoint, in window: NSWindow) {
        guard let cg = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)?.cgEvent
        else { return }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
        if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
    }

    private func pageWindow() -> (BrowserWindow, Controller) {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        return (window, Controller(window: window))
    }

    @Test func buttonsThreeAndFourAreBackAndForwardOnRelease() {
        #expect(BrowserWindow.SideButton(.otherMouseDown, button: 3) == .press)
        #expect(BrowserWindow.SideButton(.otherMouseDown, button: 4) == .press)
        #expect(BrowserWindow.SideButton(.otherMouseUp, button: 3) == .back)
        #expect(BrowserWindow.SideButton(.otherMouseUp, button: 4) == .forward)
        #expect(BrowserWindow.SideButton(.otherMouseUp, button: 2) == nil)
        #expect(BrowserWindow.SideButton(.leftMouseUp, button: 3) == nil)
        #expect(BrowserWindow.SideButton.press.action == nil)
    }

    @Test func anyWindowsControllerGoesBackAndForward() {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        let controller = Controller(window: window)
        press(3, in: window)
        press(4, in: window)
        // The middle button is the page's.
        press(2, in: window)
        #expect(controller.actions == ["back", "forward"])
    }

    // MARK: Holding a side button (#515)

    @Test func holdingBackOpensItsListAtThePointerAfterTheDelay() async throws {
        let (window, controller) = pageWindow()
        defer { window.close() }
        let point = NSPoint(x: 300, y: 400)
        side(.otherMouseDown, 3, at: point, in: window)
        #expect(MenuPanel.current == nil)
        try await Task.sleep(for: .seconds(InteractiveView.holdMenuDelay + 0.2))
        let menu = try #require(MenuPanel.current)
        defer { menu.close(animated: false) }
        #expect(menu.itemTitles == ["back One", "back Two", "back Three"])
        // At the pointer, as a right-click's list opens.
        let frame = menu.convert(menu.bounds, to: nil)
        #expect(abs(frame.minX - point.x) < 1 && abs(frame.maxY - point.y) < 1)
        // Let go off the list: it stays open to click, and doesn't go back a step.
        side(.otherMouseUp, 3, at: point, in: window)
        #expect(MenuPanel.current === menu)
        #expect(controller.actions.isEmpty)
    }

    @Test func aQuickSideButtonPressGoesOneStepWithNoList() {
        let (window, controller) = pageWindow()
        defer { window.close() }
        side(.otherMouseDown, 4, at: NSPoint(x: 300, y: 400), in: window)
        side(.otherMouseUp, 4, at: NSPoint(x: 300, y: 400), in: window)
        #expect(controller.actions == ["forward"])
        // The hold that never came stays away.
        window.sideHoldElapsed()
        #expect(MenuPanel.current == nil)
    }

    @Test func holdSlideAndReleaseOnAPageGoesThere() throws {
        let (window, controller) = pageWindow()
        defer { window.close() }
        side(.otherMouseDown, 4, at: NSPoint(x: 300, y: 400), in: window)
        window.sideHoldElapsed()
        let menu = try #require(MenuPanel.current)
        #expect(menu.itemTitles.first == "forward One")
        side(.otherMouseDragged, 4, at: menu.debugItemPoint(1), in: window)
        #expect(menu.highlightedIndex == 1)
        side(.otherMouseUp, 4, at: menu.debugItemPoint(1), in: window)
        #expect(controller.actions == ["forward Two"])
        #expect(MenuPanel.current == nil)
    }

    @Test func aHeldSideButtonWithNoPagesThatWayOpensNothing() {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        let controller = PlainController(window: window)
        side(.otherMouseDown, 3, at: NSPoint(x: 300, y: 400), in: window)
        window.sideHoldElapsed()
        #expect(MenuPanel.current == nil)
        side(.otherMouseUp, 3, at: NSPoint(x: 300, y: 400), in: window)
        #expect(controller.actions == ["back"])
    }

    private final class PlainController: NSWindowController, SideButtonHistory {
        var actions: [String] = []
        @objc func goBack(_ sender: Any?) { actions.append("back") }
        func sideButtonHistory(back: Bool) -> NSMenu? { nil }
    }

    @Test func everyPageWindowListsItsPagesForASideButton() {
        let windows: [AnyClass] = [BrowserWindowController.self, MiniWindowController.self, WebAppWindowController.self]
        for window in windows { #expect(window is SideButtonHistory.Type) }
    }
}

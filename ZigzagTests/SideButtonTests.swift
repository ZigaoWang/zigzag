import AppKit
import Testing
@testable import Zigzag

/// A mouse's side buttons go back and forward in every window that shows a page, Zigzag Mini and installed apps too,
/// not only the browser window (#345).
@MainActor
struct SideButtonTests {
    private final class Controller: NSWindowController {
        var actions: [String] = []
        @objc func goBack(_ sender: Any?) { actions.append("back") }
        @objc func goForward(_ sender: Any?) { actions.append("forward") }
    }

    private func press(_ button: Int64, in window: NSWindow) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center) else { continue }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        }
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
}

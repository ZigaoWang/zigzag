import AppKit
import Testing
@testable import Zigzag

/// Where the window's traffic lights go, and that they stay there when AppKit lays the title bar out again.
@MainActor
struct TrafficLightTests {
    @Test func buttonsSitInARowFromTheOrigin() {
        let origins = NSWindow.trafficLightOrigins(at: NSPoint(x: 12, y: 15), step: 23, buttonHeight: 14, titlebarHeight: 33)
        #expect(origins == [NSPoint(x: 12, y: 4), NSPoint(x: 35, y: 4), NSPoint(x: 58, y: 4)])
    }

    @Test func titleBarLeavesRoomBelowTheButtons() {
        #expect(NSWindow.titlebarHeight(forTrafficLightsAt: NSPoint(x: 12, y: 15), buttonHeight: 14) == 15 + 14 + Tokens.Space.x1)
    }

    /// AppKit puts the buttons back in its own spot each time it lays the title bar out again (a title, a document
    /// URL, a key change). They must be back in ours by the layout pass that comes before the frame is drawn, the green
    /// one too: put back only on the next turn of the run loop, it showed in AppKit's spot for a frame.
    @Test func buttonsAreBackBeforeTheFrameIsDrawn() {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        let origin = NSPoint(x: 40, y: 15)
        window.trafficLightOrigin = origin
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        #expect(buttons.count == 3)
        func topLefts() -> [NSPoint] {
            buttons.map { b in
                let r = b.convert(b.bounds, to: nil)
                return NSPoint(x: r.minX, y: (window.contentView?.frame.height ?? 0) - r.maxY)
            }
        }
        let placed = topLefts()
        #expect(placed.first == origin)
        for change in 0..<4 {
            // Each of these makes AppKit lay the title bar out again; the subtitle isn't one Zigzag watches.
            switch change {
            case 0: window.subtitle = "Moved"
            case 1: window.representedURL = nil
            case 2: window.title = "Another page"
            default: window.subtitle = ""
            }
            window.layoutIfNeeded()
            #expect(topLefts() == placed, "change \(change)")
        }
    }
}

import AppKit
import Testing
@testable import Zigzag

/// WebKit's Picture in Picture window comes up in Zigzag as an ordinary window; it's lifted to float over every app
/// and on every desktop, as Safari's does (#210).
@MainActor struct PictureInPictureFloatTests {
    @Test func findsWebKitsWindowOnly() {
        #expect(PictureInPicture.isPanel(className: "PIPPanel"))
        #expect(!PictureInPicture.isPanel(className: "BrowserWindow"))
        #expect(!PictureInPicture.isPanel(className: "MiniPlayerPanel"))
    }

    @Test func joinsEveryDesktop() {
        let behavior = PictureInPicture.floatingBehavior(from: [.moveToActiveSpace, .managed, .ignoresCycle])
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(!behavior.contains(.moveToActiveSpace))
        #expect(!behavior.contains(.managed))
        // What else it had stays.
        #expect(behavior.contains(.ignoresCycle))
    }

    @Test func floatsAndStaysWhenZigzagIsntInFront() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: true)
        panel.hidesOnDeactivate = true
        PictureInPicture.float(panel)
        #expect(panel.level == .floating)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        // Already higher (a full screen video's own level) is left as it is.
        panel.level = .statusBar
        PictureInPicture.float(panel)
        #expect(panel.level == .statusBar)
    }
}

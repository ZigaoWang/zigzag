import AppKit
import Testing
@testable import Zigzag

/// In a split, a click, a mouse's side button or a swipe acts on the page under the pointer: that pane becomes the
/// one you're in first (#170).
struct PaneFocusTests {
    let ids = [UUID(), UUID(), UUID(), UUID()]
    let four = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        .frames(in: CGRect(x: 0, y: 0, width: 1200, height: 800), gap: 8)

    private func pane(_ x: CGFloat, _ y: CGFloat, current: Int = 0, frames: [NSRect]? = nil) -> UUID? {
        BrowserWindowController.pane(at: NSPoint(x: x, y: y), frames: frames ?? four, ids: ids, current: ids[current])
    }

    @Test func thePaneUnderThePointerIsTheOneToGoTo() {
        let centers = four.map { NSPoint(x: $0.midX, y: $0.midY) }
        for (i, center) in centers.enumerated() where i != 0 {
            #expect(pane(center.x, center.y) == ids[i])
        }
    }

    @Test func thePaneYouAreInStaysAsItIs() {
        let center = NSPoint(x: four[2].midX, y: four[2].midY)
        #expect(pane(center.x, center.y, current: 2) == nil)
    }

    @Test func betweenOrOutsideThePanesNothingChanges() {
        // The gap between the left and right columns, and a point off the page.
        #expect(pane(600, 200) == nil)
        #expect(pane(-20, 200) == nil)
        #expect(pane(600, 900) == nil)
    }

    @Test func aPaneWithNoTabIsSkipped() {
        // More frames than pages (a group closing up): a point over the extra frame picks nothing.
        let frames = four
        let center = NSPoint(x: frames[3].midX, y: frames[3].midY)
        #expect(BrowserWindowController.pane(at: center, frames: frames, ids: Array(ids.prefix(3)), current: ids[0]) == nil)
    }
}

import AppKit
import Testing
@testable import Zigzag

/// #592: the link address pill sits in the page's bottom-left corner, where a link may be. It must never take the
/// press meant for that link: a click goes through to the page under it, as does the pointer that hovers the link.
@MainActor
struct LinkStatusHitTests {
    /// Runs `body` as on a new install, with the setting put back afterwards.
    private func fresh(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: LinkStatusController.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: LinkStatusController.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: LinkStatusController.defaultsKey)
        try body()
    }

    @Test func aPressOnThePillReachesThePageUnderIt() throws {
        try fresh {
            // As a window lays them out: the page, and the overlay above it carrying the pill.
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let overlay = PassthroughView(frame: page.bounds)
            let host = NSView(frame: page.bounds)
            host.addSubview(page)
            host.addSubview(overlay)
            let status = LinkStatusController(overlay: overlay)
            status.show(try #require(URL(string: "https://example.com/a/link")), in: overlay.bounds)
            let pill = try #require(overlay.subviews.first)
            let point = NSPoint(x: pill.frame.midX, y: pill.frame.midY)
            #expect(pill.frame.contains(point))
            // The pill answers nothing…
            #expect(pill.hitTest(point) == nil)
            // …the overlay has nothing there either, so the page under it takes the press.
            #expect(host.hitTest(point) === page)
        }
    }

    @Test func thePillStepsAsideWhileThePointerIsOverIt() throws {
        try fresh {
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            status.show(try #require(URL(string: "https://example.com/a/link")), in: overlay.bounds)
            let pill = try #require(overlay.subviews.first)
            #expect(pill.alphaValue == 1)
            // Over it the pill steps back, so the link under it reads; off it, back whole.
            status.pointerMoved(over: true)
            #expect(pill.alphaValue == LinkStatusController.steppedAside)
            status.pointerMoved(over: false)
            #expect(pill.alphaValue == 1)
        }
    }

    /// The two go together: where the pill fades back, the press at that same point reaches the page. A fade that
    /// still ate the click would leave the bug in place with the pill merely harder to see.
    @Test func whereThePillStepsAsideThePressStillReachesThePage() throws {
        try fresh {
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let overlay = PassthroughView(frame: page.bounds)
            let host = NSView(frame: page.bounds)
            host.addSubview(page)
            host.addSubview(overlay)
            let status = LinkStatusController(overlay: overlay)
            status.show(try #require(URL(string: "https://example.com/a/link")), in: overlay.bounds)
            let pill = try #require(overlay.subviews.first)
            let point = NSPoint(x: pill.frame.midX, y: pill.frame.midY)
            status.pointerMoved(over: true)
            #expect(pill.alphaValue == LinkStatusController.steppedAside)
            #expect(host.hitTest(point) === page)
        }
    }

    /// Pointing from one link to the next, both under the pill: it stays stepped aside, never flashing back whole
    /// between them. Leaving it brings it back whole.
    @Test func aStepAsideHoldsWhileThePointerStaysOnIt() throws {
        try fresh {
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            let first = try #require(URL(string: "https://example.com/a/long/address"))
            let second = try #require(URL(string: "https://other.example/b"))
            status.show(first, in: overlay.bounds)
            let pill = try #require(overlay.subviews.first)
            status.pointerMoved(over: true)
            #expect(pill.alphaValue == LinkStatusController.steppedAside)
            // The link under the still pointer changes: the pill keeps out of the way.
            #expect(status.pointerOver)
            status.show(second, in: overlay.bounds)
            #expect(status.pointerOver)
            #expect(pill.alphaValue == LinkStatusController.steppedAside)
            status.pointerMoved(over: false)
            #expect(pill.alphaValue == 1)
        }
    }

    /// A pill put away while stepped aside comes back whole when a link shows it again, whenever its tracking area
    /// sends its next move.
    @Test func aPillPutAwayComesBackWhole() throws {
        try fresh {
            let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let status = LinkStatusController(overlay: overlay)
            let url = try #require(URL(string: "https://example.com/a/link"))
            status.show(url, in: overlay.bounds)
            let pill = try #require(overlay.subviews.first)
            status.pointerMoved(over: true)
            #expect(pill.alphaValue == LinkStatusController.steppedAside)
            status.hide()
            #expect(!status.pointerOver)
            status.show(url, in: overlay.bounds)
            #expect(pill.alphaValue == 1)
        }
    }
}

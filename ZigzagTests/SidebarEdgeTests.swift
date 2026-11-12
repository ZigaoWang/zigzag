import AppKit
import Testing
@testable import Zigzag

/// The sidebar's edge of the window while the sidebar is hidden: where the pointer brings the sidebar out, and where
/// it keeps it out. Top-down; left of the window is negative.
@MainActor
struct SidebarEdgeTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width: CGFloat = 240
    let strip = Tokens.Metric.edgeRevealWidth
    let reach = Tokens.Metric.edgeRevealReach

    func zone(onRight: Bool = false, reservedTop: CGFloat = 0) -> SidebarEdgeZone {
        let out = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: true, onRight: onRight)
        return SidebarEdgeZone(bounds: window, sidebar: out, onRight: onRight, reservedTop: reservedTop)
    }

    @Test func theStripInsideTheEdgeOpensIt() {
        #expect(zone().opens(at: NSPoint(x: 0, y: 400)))
        #expect(zone().opens(at: NSPoint(x: strip, y: 400)))
        #expect(!zone().opens(at: NSPoint(x: strip + 1, y: 400)))
        #expect(!zone().opens(at: NSPoint(x: 640, y: 400)))
    }

    @Test func justPastTheEdgeOpensItAndFurtherOutDoesNot() {
        #expect(zone().opens(at: NSPoint(x: -1, y: 400)))
        #expect(zone().opens(at: NSPoint(x: -reach, y: 400)))
        #expect(!zone().opens(at: NSPoint(x: -reach - 1, y: 400)))
        // On the display beside this one.
        #expect(!zone().opens(at: NSPoint(x: -1500, y: 400)))
    }

    @Test func aboveAndBelowTheWindowNothingOpens() {
        #expect(zone().opens(at: NSPoint(x: 2, y: 0)))
        #expect(zone().opens(at: NSPoint(x: 2, y: 800)))
        #expect(!zone().opens(at: NSPoint(x: 2, y: -1)))
        #expect(!zone().opens(at: NSPoint(x: 2, y: 801)))
    }

    @Test func theBarsStripAtTheTopLeavesTheSidebarBe() {
        let zone = zone(reservedTop: TopBarView.height)
        #expect(!zone.opens(at: NSPoint(x: 2, y: 10)))
        #expect(!zone.opens(at: NSPoint(x: -4, y: TopBarView.height - 1)))
        #expect(zone.opens(at: NSPoint(x: 2, y: TopBarView.height)))
        // Once it's out, the pointer on its top row keeps it.
        #expect(zone.keeps(at: NSPoint(x: 100, y: 20)))
    }

    @Test func theSidebarAndWhatLiesPastItKeepIt() {
        #expect(zone().keeps(at: NSPoint(x: 120, y: 400)))
        #expect(zone().keeps(at: NSPoint(x: 2, y: 400)))
        #expect(zone().keeps(at: NSPoint(x: -reach, y: 400)))
        // A little around it, so a pointer on its edge doesn't lose it.
        #expect(zone().keeps(at: NSPoint(x: zone().sidebar.maxX + Tokens.Space.x1 - 1, y: 400)))
    }

    @Test func awayFromItLetsItGo() {
        #expect(!zone().keeps(at: NSPoint(x: zone().sidebar.maxX + Tokens.Space.x1 + 1, y: 400)))
        #expect(!zone().keeps(at: NSPoint(x: -reach - 1, y: 400)))
        #expect(!zone().keeps(at: NSPoint(x: -1500, y: 400)))
        #expect(!zone().keeps(at: NSPoint(x: -10, y: -1)))
        #expect(!zone().keeps(at: NSPoint(x: -10, y: 801)))
    }

    @Test func onTheRightItIsTheSameTurnedOver() {
        let right = zone(onRight: true), edge = window.maxX
        #expect(right.opens(at: NSPoint(x: edge, y: 400)))
        #expect(right.opens(at: NSPoint(x: edge - strip, y: 400)))
        #expect(!right.opens(at: NSPoint(x: edge - strip - 1, y: 400)))
        #expect(right.opens(at: NSPoint(x: edge + reach, y: 400)))
        #expect(!right.opens(at: NSPoint(x: edge + reach + 1, y: 400)))
        #expect(!right.opens(at: NSPoint(x: 2, y: 400)))
        #expect(right.keeps(at: NSPoint(x: edge - 120, y: 400)))
        #expect(right.keeps(at: NSPoint(x: edge + reach, y: 400)))
        #expect(!right.keeps(at: NSPoint(x: edge + 1500, y: 400)))
        #expect(!right.keeps(at: NSPoint(x: right.sidebar.minX - Tokens.Space.x1 - 1, y: 400)))
        #expect(!right.keeps(at: NSPoint(x: -10, y: 400)))
    }

    /// Or it would open and slide straight back.
    @Test func whereverItOpensItStays() {
        for onRight in [false, true] {
            for reserved in [0, TopBarView.height] {
                let zone = zone(onRight: onRight, reservedTop: reserved)
                for x in stride(from: -reach - 8, through: window.maxX + reach + 8, by: 1) where x <= strip + 8 || x >= window.maxX - strip - 8 {
                    for y in stride(from: CGFloat(-8), through: window.height + 8, by: 4) {
                        let point = NSPoint(x: x, y: y)
                        if zone.opens(at: point) { #expect(zone.keeps(at: point), "opens but lets go at \(point), on the right: \(onRight)") }
                    }
                }
            }
        }
    }
}

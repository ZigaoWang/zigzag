import AppKit
import Testing
@testable import Zigzag

/// The hidden sidebar sliding out at the window's edge and back: its curve, and Reduce Motion's fade.
@MainActor
struct SidebarSlideTests {
    private func points(_ timing: CAMediaTimingFunction) -> (CGPoint, CGPoint) {
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &c1)
        timing.getControlPoint(at: 2, values: &c2)
        return (CGPoint(x: CGFloat(c1[0]), y: CGFloat(c1[1])), CGPoint(x: CGFloat(c2[0]), y: CGFloat(c2[1])))
    }

    @Test func itSlidesOnTheDrawerCurve() {
        let (c1, c2) = points(Tokens.Motion.edgeSlide.timing)
        #expect(abs(c1.x - 0.32) < 0.001 && abs(c1.y - 0.72) < 0.001)
        #expect(abs(c2.x) < 0.001 && abs(c2.y - 1) < 0.001)
        #expect(Tokens.Motion.edgeTuck.timing === Tokens.Motion.edgeSlide.timing)
        #expect(Tokens.Motion.edgeSlide.bounce == nil)
    }

    @Test func itStartsGentlerThanTheHouseEaseOut() {
        // How many times its average speed each starts at: the house ease-out covered half the sidebar's width in
        // the first frame or two.
        let (drawer, _) = points(Tokens.Motion.drawer)
        let (house, _) = points(Tokens.Motion.easeOut)
        #expect(drawer.y / drawer.x < 2.5)
        #expect(house.y / house.x > 4)
    }

    @Test func goingBackIsQuickerThanComingOutAndBothStayUnderTheCeiling() {
        #expect(Tokens.Motion.edgeTuck.duration < Tokens.Motion.edgeSlide.duration)
        #expect(Tokens.Motion.edgeSlide.duration <= Tokens.Motion.large)
        #expect(Tokens.Motion.edgeSlide.duration > Tokens.Motion.slideDuration)
    }

    @Test func otherCurvesKeepTheHouseEaseOut() {
        #expect(Tokens.Motion.slide.timing === Tokens.Motion.easeOut)
        #expect(Tokens.Motion.gentle.timing === Tokens.Motion.easeOut)
    }

    @Test func reduceMotionFadesInWhereItLands() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.wantsLayer = true
        BrowserRootView.crossfadeReveal(view, show: true, from: -300)
        let group = try #require(view.layer?.animation(forKey: BrowserRootView.revealFadeKey) as? CAAnimationGroup)
        let parts = group.animations as? [CABasicAnimation] ?? []
        #expect(parts.map(\.keyPath) == ["opacity"])
        #expect(parts.first?.fromValue as? Float == 0)
        #expect(parts.first?.toValue as? Float == 1)
        #expect(group.duration == Tokens.Motion.crossfade * Tokens.Motion.debugSlowdown)
        #expect(view.layer?.opacity == 1)
    }

    @Test func reduceMotionFadesOutWhereItWasWithoutTraveling() throws {
        let view = NSView(frame: NSRect(x: -300, y: 0, width: 240, height: 600))
        view.wantsLayer = true
        BrowserRootView.crossfadeReveal(view, show: false, from: 308)
        let group = try #require(view.layer?.animation(forKey: BrowserRootView.revealFadeKey) as? CAAnimationGroup)
        let parts = group.animations as? [CABasicAnimation] ?? []
        let fade = try #require(parts.first { $0.keyPath == "opacity" })
        let stay = try #require(parts.first { $0.keyPath == "transform.translation.x" })
        #expect(fade.fromValue as? Float == 1 && fade.toValue as? Float == 0)
        #expect(stay.fromValue as? CGFloat == 308 && stay.toValue as? CGFloat == 308)
        // Its own opacity stays whole, for the next time it comes out.
        #expect(view.layer?.opacity == 1)
    }
}

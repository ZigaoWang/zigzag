import AppKit
import Testing
@testable import Zigzag

/// How things show up and go (`Tokens.Motion.present`): how long, from where, and how a quick turn around carries on
/// from what's on screen.
struct MotionTests {
    typealias Motion = Tokens.Motion

    /// Where a point of a layer (0 to 1 from its top left, in a flipped superview) lands under `t`.
    private func land(_ point: CGPoint, of size: CGSize, anchor: CGPoint, under t: CATransform3D) -> CGPoint {
        let p = CGPoint(x: (point.x - anchor.x) * size.width, y: (point.y - anchor.y) * size.height)
        return CGPoint(x: p.x * t.m11 + p.y * t.m21 + t.m41, y: p.x * t.m12 + p.y * t.m22 + t.m42)
    }

    @Test func exitsAreQuickerThanEntrances() {
        for origin: Motion.Origin in [.point(.zero), .offstage(.minY, 80), .inPlace] {
            let enter = Motion.presenceDuration(origin, entering: true, reduceMotion: false)
            let exit = Motion.presenceDuration(origin, entering: false, reduceMotion: false)
            #expect(exit < enter)
            // About two thirds, and nothing past the ceiling for UI.
            #expect(exit / enter > 0.6 && exit / enter < 0.72)
            #expect(enter <= 0.25)
        }
        #expect(Motion.presenceDuration(.point(.zero), entering: true, reduceMotion: false) == Motion.enter)
        // What hangs from an edge (a toast, the find bar) lifts back at the pace it dropped in.
        #expect(Motion.presenceDuration(.edge(.minY), entering: false, reduceMotion: false) == Motion.presenceDuration(.edge(.minY), entering: true, reduceMotion: false))
        #expect(Motion.presenceDuration(.offstage(.minY, 80), entering: true, reduceMotion: false) == Motion.noticeIn)
    }

    @Test func reduceMotionOnlyCrossfades() {
        for origin: Motion.Origin in [.point(.zero), .edge(.minY), .offstage(.minY, 80)] {
            #expect(Motion.presenceDuration(origin, entering: true, reduceMotion: true) == Motion.crossfade)
            #expect(Motion.presenceDuration(origin, entering: false, reduceMotion: true) == Motion.crossfade)
        }
    }

    @Test func growsAroundTheControlThatOpenedIt() {
        let size = CGSize(width: 200, height: 120)
        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5)] {
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.5, y: 0.7)] {
                let t = Motion.hiddenTransform(.point(point), entering: true, size: size, anchor: anchor, flipped: true)
                #expect(abs(t.m11 - Motion.enterScale) < 0.0001)
                // The control's point stays put; everything else draws in toward it.
                let at = land(point, of: size, anchor: anchor, under: t)
                let expected = CGPoint(x: (point.x - anchor.x) * size.width, y: (point.y - anchor.y) * size.height)
                #expect(abs(at.x - expected.x) < 0.001 && abs(at.y - expected.y) < 0.001)
            }
        }
        // Leaving, it shrinks less than it grew.
        let out = Motion.hiddenTransform(.point(.zero), entering: false, size: size, anchor: .zero, flipped: true)
        #expect(abs(out.m11 - Motion.exitScale) < 0.0001)
        #expect(Motion.exitScale > Motion.enterScale && Motion.enterScale >= 0.96)
    }

    @Test func slidesFromTheEdgeItHangsFrom() {
        let size = CGSize(width: 300, height: 36)
        // The top as you look at it: up in a flipped superview (y runs down), down the axis in an unflipped one.
        let flipped = Motion.hiddenTransform(.edge(.minY), entering: true, size: size, anchor: .zero, flipped: true)
        #expect(flipped.m42 == -Motion.edgeOffset && flipped.m41 == 0 && flipped.m11 == 1)
        let unflipped = Motion.hiddenTransform(.edge(.minY), entering: true, size: size, anchor: .zero, flipped: false)
        #expect(unflipped.m42 == Motion.edgeOffset)
        let bottom = Motion.hiddenTransform(.edge(.maxY), entering: true, size: size, anchor: .zero, flipped: true)
        #expect(bottom.m42 == Motion.edgeOffset)
        // It leaves back the way it came, as far as it dropped.
        let leaving = Motion.hiddenTransform(.edge(.minY), entering: false, size: size, anchor: .zero, flipped: true)
        #expect(leaving.m42 == -Motion.edgeOffset)
        #expect(Motion.edgeOffset >= 4 && Motion.edgeOffset <= 8)
        // A notice goes all the way back out past the window's edge.
        let notice = Motion.hiddenTransform(.offstage(.minY, 90), entering: false, size: size, anchor: .zero, flipped: true)
        #expect(notice.m42 == -90)
        #expect(CATransform3DIsIdentity(Motion.hiddenTransform(.inPlace, entering: true, size: size, anchor: .zero, flipped: true)))
    }

    @Test func turningAroundTakesOnlyWhatsLeft() {
        let full = Motion.enter
        // Closed when it had just begun to show: reopening takes nearly the whole way; nearly shown, almost nothing.
        #expect(abs(Motion.remainingDuration(full, shownOpacity: 0.1, entering: true) - full * 0.9) < 0.0001)
        #expect(abs(Motion.remainingDuration(full, shownOpacity: 0.75, entering: true) - full * 0.25) < 0.0001)
        // Leaving while half shown: half the exit.
        #expect(abs(Motion.remainingDuration(Motion.exit, shownOpacity: 0.5, entering: false) - Motion.exit * 0.5) < 0.0001)
        // Already there: nothing left to animate.
        #expect(Motion.remainingDuration(full, shownOpacity: 1, entering: true) == 0)
        #expect(Motion.remainingDuration(Motion.exit, shownOpacity: 0, entering: false) == 0)
        // A sliver left still moves for a frame or two instead of snapping.
        #expect(Motion.remainingDuration(full, shownOpacity: 0.95, entering: true) >= 0.04)
        // Never longer than the full change.
        #expect(Motion.remainingDuration(full, shownOpacity: -1, entering: true) <= full)
    }

    @MainActor @Test func aPanelOpenedTwiceFastTurnsAroundFromWhereItIs() {
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.wantsLayer = true
        let panel = FloatingPanelView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        host.addSubview(panel)
        panel.attachedEdge = .minY
        panel.present()
        #expect(panel.layer?.animation(forKey: "presence.opacity") != nil)
        #expect(panel.layer?.opacity == 1)
        panel.dismiss()
        #expect(panel.dismissing)
        #expect(panel.layer?.opacity == 0)
        // Shown again before the exit finished: it stays, and is on its way back in.
        panel.present()
        #expect(!panel.dismissing)
        #expect(panel.superview === host)
        #expect(panel.layer?.opacity == 1)
        // Shown at once: nothing left moving.
        panel.present(arrival: .instant)
        #expect(panel.layer?.animation(forKey: "presence.opacity") == nil)
        #expect(panel.layer?.animation(forKey: "presence.transform") == nil)
        // Sent off at once: gone.
        panel.dismiss(instantly: true)
        #expect(panel.superview == nil)
        #expect(panel.layer?.opacity == 1)
    }
}

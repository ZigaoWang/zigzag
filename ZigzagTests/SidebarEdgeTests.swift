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

    /// A quick move is out past the reach already when the window hears it leave: that still met the edge (#206).
    @Test func leavingStraightPastTheReachMeetsTheEdge() {
        for onRight in [false, true] {
            let zone = zone(onRight: onRight, reservedTop: TopBarView.height), edge = onRight ? window.maxX : 0
            func at(_ out: CGFloat, _ y: CGFloat = 400) -> NSPoint { NSPoint(x: onRight ? edge + out : edge - out, y: y) }
            #expect(zone.meetsLeaving(at: at(1)))
            #expect(zone.meetsLeaving(at: at(reach + 60)))
            // Not leaving above or below the window, nor through the bar's strip that holds the traffic lights.
            #expect(!zone.meetsLeaving(at: at(reach + 60, -1)))
            #expect(!zone.meetsLeaving(at: at(reach + 60, 801)))
            #expect(!zone.meetsLeaving(at: at(reach + 60, TopBarView.height - 1)))
            // Nor through the window's other edge.
            #expect(!zone.meetsLeaving(at: NSPoint(x: onRight ? -60 : window.maxX + 60, y: 400)))
        }
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

/// The pointer meeting the hidden sidebar's edge over time (#206): whether it meant to bring the sidebar out, decided
/// once, then one slide. Each path is where the pointer is from each moment on, looked at every frame as the window
/// does. Before, a quick move that ran on past the edge brought the sidebar out, sent it back as the pointer went past
/// the reach, and brought it out again as the hand came back: a stutter.
@MainActor
struct SidebarEdgeRevealTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let slide = Tokens.Motion.edgeSlideDuration

    func zone(width: CGFloat = Tokens.Metric.sidebarWidth, onRight: Bool = false) -> SidebarEdgeZone {
        let out = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: true, onRight: onRight)
        return SidebarEdgeZone(bounds: window, sidebar: out, onRight: onRight)
    }

    /// Every side and size of sidebar.
    var zones: [SidebarEdgeZone] {
        [false, true].flatMap { onRight in
            [Tokens.Metric.sidebarMinWidth, Tokens.Metric.sidebarWidth, Tokens.Metric.sidebarMaxWidth].map { zone(width: $0, onRight: onRight) }
        }
    }

    /// What the sidebar did along a path, and when: "out" or "in". `x` is from the sidebar's edge of the window
    /// (negative: out past it); `speed` is how fast the pointer met the edge.
    func run(_ path: [(time: TimeInterval, x: CGFloat)], speed: CGFloat, zone: SidebarEdgeZone, until end: TimeInterval = 1.5) -> [(String, TimeInterval)] {
        var edge = SidebarEdgeReveal()
        var log: [(String, TimeInterval)] = []
        var lastX: CGFloat?
        for frame in 0...Int(end * 60) {
            let time = Double(frame) / 60
            guard let x = path.last(where: { $0.time <= time })?.x else { continue }
            let point = NSPoint(x: zone.onRight ? window.maxX - x : x, y: 400)
            // An event comes as the pointer moves into the edge while the sidebar is hidden.
            if x != lastX, zone.opens(at: point), edge.phase == .hidden { edge.met(at: time, speed: speed) }
            lastX = x
            switch edge.phase {
            case .hidden: break
            case .deciding:
                switch edge.decide(at: point, time: time, in: zone) {
                case true?: edge.shown(true, at: time, settling: slide); log.append(("out", time))
                case false?: edge.dismiss()
                case nil: break
                }
            case .out:
                if edge.follow(at: point, time: time, in: zone, held: false) { edge.shown(false, at: time, settling: 0); log.append(("in", time)) }
            }
        }
        return log
    }

    @Test func aSlowAndAQuickMoveToTheEdgeBothBringItOutOnceAtTheSameMoment() {
        for zone in zones {
            // Slow: it creeps into the strip and rests there.
            let slow = run([(0, 40), (0.2, 6)], speed: 150, zone: zone)
            // Quick, in full screen or against the screen's edge: it stops dead there.
            let quick = run([(0, 600), (0.2, 0)], speed: 4000, zone: zone)
            #expect(slow.map(\.0) == ["out"])
            #expect(quick.map(\.0) == ["out"])
            #expect(abs((slow.first?.1 ?? 0) - (quick.first?.1 ?? 9)) < 0.02)
        }
    }

    @Test func runningOnPastTheEdgeAndComingBackBringsItOutOnce() {
        for zone in zones {
            // Out of the window onto the desktop or the next display, past the reach, and back while deciding.
            #expect(run([(0, 300), (0.2, -4), (0.22, -90), (0.4, -12)], speed: 3000, zone: zone).map(\.0) == ["out"])
            // Past the reach just as it comes out, and back: this was the stutter, out, in and out again.
            #expect(run([(0, 300), (0.2, -20), (0.32, -70), (0.55, -10)], speed: 3000, zone: zone).map(\.0) == ["out"])
        }
    }

    @Test func aQuickMoveThatBouncesBackOffTheScreensEdgeStillBringsItOut() {
        for zone in zones {
            // Stopped by the screen's edge, the hand eases back onto where the sidebar lands.
            #expect(run([(0, 600), (0.2, 0), (0.25, 30)], speed: 4000, zone: zone).map(\.0) == ["out"])
        }
    }

    @Test func touchingTheEdgeAndComingStraightBackLeavesItHidden() {
        for zone in zones {
            // Slowly, onto a web app's own list along that side.
            #expect(run([(0, 40), (0.2, 4), (0.25, 30)], speed: 150, zone: zone).isEmpty)
            // Even quickly, back past where the sidebar would be.
            #expect(run([(0, 600), (0.2, 0), (0.25, 600)], speed: 4000, zone: zone).isEmpty)
        }
    }

    @Test func goingOnToTheNextDisplayLeavesItHidden() {
        for zone in zones {
            #expect(run([(0, 300), (0.2, -4), (0.22, -600)], speed: 3000, zone: zone).isEmpty)
            #expect(run([(0, 300), (0.2, -4), (0.22, -600)], speed: 300, zone: zone).isEmpty)
        }
    }

    @Test func itSlidesAllTheWayOutBeforeThePointerCanSendItBack() {
        let log = run([(0, 600), (0.2, 0), (0.35, 900)], speed: 4000, zone: zone())
        #expect(log.map(\.0) == ["out", "in"])
        if log.count == 2 { #expect(log[1].1 - log[0].1 >= slide) }
    }

    @Test func leavingItOnceItIsOutSendsItBack() {
        let log = run([(0, 40), (0.2, 6), (0.8, 900)], speed: 150, zone: zone())
        #expect(log.map(\.0) == ["out", "in"])
        if log.count == 2 { #expect(log[1].1 - 0.8 <= Tokens.Motion.edgeHideDelay + 0.04) }
    }

    @Test func eventsWhileDecidingKeepTheFirstMomentAndAQuickArrival() {
        var edge = SidebarEdgeReveal()
        edge.met(at: 1, speed: 3000)
        // Coalesced moves pinned at the edge, slower now that it has stopped.
        edge.met(at: 1.03, speed: 0)
        edge.met(at: 1.06, speed: 0)
        #expect(edge.phase == .deciding(since: 1, flick: true))
        #expect(edge.decide(at: NSPoint(x: 0, y: 400), time: 1.09, in: zone()) == nil)
        #expect(edge.decide(at: NSPoint(x: 0, y: 400), time: 1.1, in: zone()) == true)
    }
}

/// The pointer meeting the hidden sidebar's edge as the window hears it (#206): moved events only while the pointer is
/// inside the window, one exited event as it leaves and one entered as it comes back, and nothing at all while it's out
/// past the window's edge, where only the edge's own timers look at it. A quick move to a window with the desktop or
/// another display beside it runs on past the edge's reach and comes back: it brings the sidebar out once.
@MainActor
struct SidebarEdgeEventTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let slide = Tokens.Motion.edgeSlideDuration

    func zone(width: CGFloat, onRight: Bool) -> SidebarEdgeZone {
        let out = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: true, onRight: onRight)
        return SidebarEdgeZone(bounds: window, sidebar: out, onRight: onRight)
    }

    /// Every side and size of sidebar.
    var zones: [SidebarEdgeZone] {
        [false, true].flatMap { onRight in
            [Tokens.Metric.sidebarMinWidth, Tokens.Metric.sidebarWidth, Tokens.Metric.sidebarMaxWidth].map { zone(width: $0, onRight: onRight) }
        }
    }

    /// Where the pointer is at `time`, moving straight between `keys`: from the sidebar's edge of the window
    /// (negative: out past it).
    func position(_ keys: [(time: TimeInterval, x: CGFloat)], at time: TimeInterval) -> CGFloat {
        guard let next = keys.firstIndex(where: { $0.time > time }) else { return keys.last!.x }
        guard next > 0 else { return keys[0].x }
        let a = keys[next - 1], b = keys[next]
        return a.x + (b.x - a.x) * CGFloat((time - a.time) / (b.time - a.time))
    }

    /// What the sidebar did, "out" or "in", and when: the pointer sampled 120 times a second as the Mac sends moved
    /// events, the events as `BrowserRootView` hears and handles them, and its timers as it runs them.
    func replay(_ keys: [(time: TimeInterval, x: CGFloat)], zone: SidebarEdgeZone, until end: TimeInterval = 2) -> [(String, TimeInterval)] {
        var edge = SidebarEdgeReveal()
        var log: [(String, TimeInterval)] = []
        var revealed = false
        var last: (x: CGFloat, inside: Bool)?
        var lastMoveTime: TimeInterval = -1, lastMoveSpeed: CGFloat = 0
        var nextFollow = TimeInterval.infinity
        for sample in 0...Int(end * 120) {
            let time = Double(sample) / 120
            let x = position(keys, at: time)
            let point = NSPoint(x: zone.onRight ? window.maxX - x : x, y: 400)
            let inside = x >= 0 && x < window.width
            func meet(_ speed: CGFloat) { if !revealed { edge.met(at: time, speed: speed) } }
            let recent = time - lastMoveTime < 0.05 ? lastMoveSpeed : 0
            if let last {
                // mouseEntered and mouseExited: the speed of the last moved event, if it came just now.
                if inside, !last.inside, zone.opens(at: point) { meet(recent) }
                if !inside, last.inside, zone.meetsLeaving(at: point) { meet(recent) }
                // mouseMoved, inside the window only.
                if inside, x != last.x {
                    let elapsed = time - lastMoveTime
                    lastMoveSpeed = elapsed < 0.1 ? (last.x - x) / max(elapsed, 1.0 / 240) : 0
                    lastMoveTime = time
                    if zone.opens(at: point) { meet(lastMoveSpeed) }
                }
            }
            last = (x, inside)
            switch edge.phase {
            case .hidden: break
            case .deciding:
                switch edge.decide(at: point, time: time, in: zone) {
                case true?:
                    revealed = true
                    edge.shown(true, at: time, settling: slide)
                    nextFollow = time + 0.1
                    log.append(("out", time))
                case false?: edge.dismiss()
                case nil: break
                }
            case .out:
                // Every tenth of a second while the pointer is on it, every frame once it has left.
                guard time >= nextFollow else { break }
                let wasLeaving = edge.isLeaving
                if edge.follow(at: point, time: time, in: zone, held: false) {
                    revealed = false
                    edge.shown(false, at: time, settling: 0)
                    nextFollow = .infinity
                    log.append(("in", time))
                } else {
                    let interval = edge.isLeaving ? 1.0 / 60 : 0.1
                    nextFollow = (edge.isLeaving != wasLeaving ? time : nextFollow) + interval
                }
            }
        }
        return log
    }

    @Test func aQuickMoveThatRunsOnPastTheReachAndComesBackAfterTheSlideBringsItOutOnce() {
        for zone in zones {
            // Out past the edge just as the sidebar comes out, a beat out on the desktop, and back onto the sidebar.
            let onto = replay([(0, 400), (0.12, -5), (0.24, -30), (0.4, -100), (0.55, -100), (0.7, 30)], zone: zone)
            #expect(onto.map(\.0) == ["out"], "\(onto)")
            // Or back to the edge itself.
            let edge = replay([(0, 400), (0.12, -5), (0.24, -30), (0.4, -100), (0.55, -100), (0.7, 4)], zone: zone)
            #expect(edge.map(\.0) == ["out"], "\(edge)")
        }
    }

    @Test func aMoveThatLeavesStraightPastTheReachAndComesBackBringsItOut() {
        for zone in zones {
            // So quick the window hears it leave already further out than the edge reaches.
            let log = replay([(0, 700), (0.1, -50), (0.25, -70), (0.4, 30)], zone: zone)
            #expect(log.map(\.0) == ["out"], "\(log)")
        }
    }

    @Test func aSlowMoveAndAQuickOneAgainstTheScreensEdgeBothBringItOutOnce() {
        for zone in zones {
            let slow = replay([(0, 40), (0.3, 4)], zone: zone)
            // Full screen, or a window against the screen's edge: the pointer stops dead there.
            let quick = replay([(0, 600), (0.15, 0)], zone: zone)
            #expect(slow.map(\.0) == ["out"])
            #expect(quick.map(\.0) == ["out"])
        }
    }

    @Test func brushingTheEdgeOrGoingOnToTheNextDisplayLeavesItHidden() {
        for zone in zones {
            #expect(replay([(0, 40), (0.2, 4), (0.25, 30)], zone: zone).isEmpty)
            #expect(replay([(0, 600), (0.2, 0), (0.25, 600)], zone: zone).isEmpty)
            #expect(replay([(0, 300), (0.1, -30), (0.3, -600)], zone: zone).isEmpty)
            #expect(replay([(0, 700), (0.1, -50), (0.2, -600)], zone: zone).isEmpty)
        }
    }

    @Test func onceOutLeavingForThePageOrTheNextDisplaySendsItBack() {
        for zone in zones {
            // To the page: at once.
            let page = replay([(0, 40), (0.3, 4), (1, 4), (1.05, 600)], zone: zone)
            #expect(page.map(\.0) == ["out", "in"])
            if page.count == 2 { #expect(page[1].1 - 1 < 0.15) }
            // On to the next display: a moment later, as long as a quick move has to come back.
            let display = replay([(0, 40), (0.3, 4), (1, 4), (1.05, -600)], zone: zone)
            #expect(display.map(\.0) == ["out", "in"])
            if display.count == 2 { #expect(display[1].1 - 1 < SidebarEdgeReveal.comeBack + 0.15) }
        }
    }
}

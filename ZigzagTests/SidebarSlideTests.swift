import AppKit
import Testing
@testable import Zigzag

/// The hidden sidebar sliding out at the window's edge and back: its curve, Reduce Motion's fade, and the glass and
/// color it floats in, which match the docked sidebar's.
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
        #expect(Tokens.Motion.edgeSlide.duration == Tokens.Motion.drawerIn)
    }

    @Test func whatTravelsRidesTheDrawerCurveAndTheRestTheHouseEaseOut() {
        #expect(Tokens.Motion.snappy.timing === Tokens.Motion.drawer)
        #expect(Tokens.Motion.gentle.timing === Tokens.Motion.drawer)
        #expect(Tokens.Motion.spaceSwitch.timing === Tokens.Motion.drawer)
        #expect(Tokens.Motion.feedback.timing === Tokens.Motion.easeOut)
        #expect(Tokens.Motion.change.timing === Tokens.Motion.easeOut)
        #expect(Tokens.Motion.entering.timing === Tokens.Motion.easeOut)
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

    @Test func overGlassTheColorLiesAtTheCoverHoweverThinTheSpace() {
        let cover = Tokens.Frame.floatingCoverDark
        #expect(SidebarContainer.floatingAlpha(of: 1, cover: cover) == cover)
        // A see-through space's wash, thin over the desktop, is as thick as a solid one's over the page.
        #expect(SidebarContainer.floatingAlpha(of: 0.55, cover: cover) == cover)
        #expect(SidebarContainer.floatingAlpha(of: 0, cover: cover) == 0)
    }

    @Test func itFloatsInTheWindowsOwnKindOfGlass() {
        let clear = WindowGlass(isClear: true, tint: .systemBlue)
        let frosted = WindowGlass(isClear: false, tint: nil)
        #expect(SidebarContainer.usesLiquidGlass(isGlass: true, windowGlass: clear, hasClearGlass: true))
        // A solid space has no window glass: the frosting, never Liquid Glass, which would hold the window to 80 frames
        // a second on a ProMotion display even while the sidebar is tucked away (#394).
        #expect(!SidebarContainer.usesLiquidGlass(isGlass: true, windowGlass: nil, hasClearGlass: true))
        #expect(!SidebarContainer.usesLiquidGlass(isGlass: true, windowGlass: frosted, hasClearGlass: true))
        #expect(!SidebarContainer.usesLiquidGlass(isGlass: true, windowGlass: clear, hasClearGlass: false))
        #expect(!SidebarContainer.usesLiquidGlass(isGlass: false, windowGlass: clear, hasClearGlass: true))
    }

    @Test func onlyClearGlassMakesTheWindowSeeThrough() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let frame = SpaceFrameView()
        window.contentView = frame
        var space = SpaceInfo(name: "See-through", color: .sky)
        space.translucency = 0.6
        let showsDesktop = SpaceFrameView.frameColors(of: space, isPrivate: false).clear
        space.clearGlass = false
        frame.paint(space, isPrivate: false, animated: false)
        #expect(window.isOpaque)
        space.clearGlass = nil
        frame.paint(space, isPrivate: false, animated: false)
        #expect(window.isOpaque == !(showsDesktop && space.usesClearGlass))
        space.translucency = nil
        frame.paint(space, isPrivate: false, animated: false)
        #expect(window.isOpaque)
    }

    @Test func theEditorSaysWhenClearShowsAsFrosted() {
        #expect(SpaceLookEditor.glassNote(clearChosen: true, onBattery: false, lowPowerMode: false) == nil)
        #expect(SpaceLookEditor.glassNote(clearChosen: false, onBattery: true, lowPowerMode: true) == nil)
        let battery = SpaceLookEditor.glassNote(clearChosen: true, onBattery: true, lowPowerMode: false)
        let lowPower = SpaceLookEditor.glassNote(clearChosen: true, onBattery: false, lowPowerMode: true)
        #expect(battery != nil && lowPower != nil && battery != lowPower)
        #expect(SpaceLookEditor.glassNote(clearChosen: true, onBattery: true, lowPowerMode: true) == battery)
    }

    @Test func theWindowKeepsTheGlassItShows() {
        let frame = SpaceFrameView()
        frame.setGlass(true, clear: true, tint: .systemPink)
        #expect(frame.windowGlass == WindowGlass(isClear: SpaceInfo.hasClearGlass, tint: SpaceInfo.hasClearGlass ? .systemPink : nil))
        frame.setGlass(true, clear: false, tint: .systemPink)
        #expect(frame.windowGlass == WindowGlass(isClear: false, tint: nil))
        frame.setGlass(false)
        #expect(frame.windowGlass == nil)
    }

    /// A browser window with one page open, laid out at 1200 × 700 with the bar above the page.
    private func inWindow(_ body: (BrowserWindowController) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/idle-glass")!, title: "A", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: -6000, y: 200, width: 1200, height: 700))
        defer { controller.window?.close() }
        let root = controller.root
        root.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        root.showsTopBar = true
        root.setSidebarVisible(true, animated: false)
        root.layoutSubtreeIfNeeded()
        try body(controller)
    }

    /// A see-through window is never wholly clear: with a shadow, a wholly clear window made the window server redraw
    /// it every frame while nothing in it moved. Its background stays too faint to see.
    @Test func aSeeThroughWindowIsNeverWhollyClear() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let frame = SpaceFrameView()
        window.contentView = frame
        var space = SpaceInfo(name: "See-through", color: .sky)
        space.translucency = 0.6
        let faint = SpaceFrameView.seeThroughBackground.alphaComponent
        #expect(faint > 0 && faint <= 1.0 / 255 + 0.0001)
        frame.paint(space, isPrivate: false, animated: false)
        // On battery or before macOS 26 the glass is frosted and the window opaque.
        guard !window.isOpaque else { return }
        #expect(window.hasShadow)
        #expect(window.backgroundColor.alphaComponent == faint)
    }

    /// A window that sits still gives the window server nothing to redraw: no animation that never ends, and no layer
    /// asking for HDR, which an HDR display composites the whole window in.
    @Test func anIdleWindowHasNoEndlessAnimationsAndNoHDR() throws {
        try inWindow { controller in
            guard let window = controller.window else { return }
            SettingsPage.open(in: controller)
            controller.root.layoutSubtreeIfNeeded()
            #expect(IdleWork.animations(in: window, longerThan: 1).isEmpty, "hidden layers included")
            #expect(IdleWork.extendedRangeLayers(in: window).isEmpty)
        }
    }

    /// The update card's bar slides only while it shows, waiting for a size; hidden, as it is in every window until
    /// an update downloads, it holds still.
    @Test func theUpdateBarSlidesOnlyWhileItShows() {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 300, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = UpdateBar(frame: NSRect(x: 0, y: 0, width: 200, height: UpdateBar.height))
        bar.isHidden = true
        window.contentView?.addSubview(bar)
        bar.share = nil
        #expect(!bar.isSliding)
        bar.isHidden = false
        #expect(bar.isSliding)
        bar.share = 0.5
        #expect(!bar.isSliding)
        bar.share = nil
        #expect(bar.isSliding)
        window.contentView?.isHidden = true
        #expect(!bar.isSliding, "a hidden card hides its bar")
        window.contentView?.isHidden = false
        bar.removeFromSuperview()
        #expect(!bar.isSliding)
    }
}

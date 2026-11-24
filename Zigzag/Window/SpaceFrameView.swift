import AppKit

/// The window's frame, behind everything: the space's color, its gradient, its grain, and the frosted desktop for a
/// see-through space. A browser window draws it behind its sidebar and page, Zigzag Mini behind its page, so the
/// two are the same space's color down to the grain.
class SpaceFrameView: ColorView {
    /// Paints the window for a space: its mode, color, gradient, how see-through it is, and grain. Private windows are
    /// always dark graphite, with no effects. Returns the color and gradient end it used, for what floats on it.
    @discardableResult
    func paint(_ space: SpaceInfo, isPrivate: Bool, animated: Bool, crossFadesMode: Bool = true) -> (color: NSColor, end: NSColor?) {
        if !isPrivate {
            let mode = space.readableAppearance
            let name: NSAppearance.Name? = mode == "light" ? .aqua : mode == "dark" ? .darkAqua : nil
            if window?.appearance?.name != name {
                // Light to dark and back cross-fades with the color, rather than snapping.
                if animated, crossFadesMode, !Tokens.Motion.reduceMotion, let frameLayer = window?.contentView?.superview?.layer {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = Tokens.Motion.large
                    fade.timingFunction = Tokens.Motion.easeOut
                    frameLayer.add(fade, forKey: "appearance")
                }
                window?.appearance = name.flatMap(NSAppearance.init(named:))
            }
        }
        let (color, end, clear) = Self.frameColors(of: space, isPrivate: isPrivate)
        // See-through: the frosted desktop shows through, and the space's color washes over it, thinner the more shows.
        // Only clear glass needs a see-through window, which macOS shows at 80 Hz on a 120 Hz display (#394).
        let (seeThroughWindow, liquid) = Self.glassKind(clear: clear, space)
        window?.isOpaque = !seeThroughWindow
        window?.backgroundColor = seeThroughWindow ? .clear : .windowBackgroundColor
        setGlass(clear, clear: liquid, tint: space.frameColor)
        // See-through, the wash goes in the gradient layer, the one above the frosted desktop (the frame's own color
        // sits under it and would be hidden); a single color washes as a gradient of itself.
        setColor(clear ? .clear : color, animated: animated, duration: Tokens.Motion.large)
        setGradient(from: color, to: clear ? end ?? color : end, angle: space.gradientAngle, animated: animated)
        setGrain(isPrivate ? 0 : space.grain ?? 0, texture: space.texture, animated: animated)
        return (color, end)
    }

    /// What a space lays on the frame: its color, where its gradient ends, and whether the desktop shows through.
    static func frameColors(of space: SpaceInfo, isPrivate: Bool) -> (color: NSColor, end: NSColor?, clear: Bool) {
        // Reduce Transparency in System Settings: a see-through space shows its color solid instead.
        let clear = !isPrivate && space.isSeeThrough && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Solid, the space's own color at full strength; see-through, thinned over the frosting.
        let reduced = space.isSeeThrough && !clear
        let color = isPrivate ? SpaceColor.graphite.background : reduced ? space.background : space.frameColor
        let end = isPrivate ? nil : reduced ? space.background2 : space.frameColor2
        return (color, end, clear)
    }

    /// Partway through a swipe: `space`'s color, gradient and grain `share` of the way to `next`'s, following the
    /// fingers. The mode and the glass stay `space`'s until the switch lands, so nothing restyles mid-swipe.
    @discardableResult
    func paint(_ space: SpaceInfo, toward next: SpaceInfo, share: CGFloat) -> (color: NSColor, end: NSColor?) {
        let a = Self.frameColors(of: space, isPrivate: false), b = Self.frameColors(of: next, isPrivate: false)
        let color = SpaceInfo.mix(a.color, b.color, by: share)
        let end = a.end == nil && b.end == nil ? nil : SpaceInfo.mix(a.end ?? a.color, b.end ?? b.color, by: share)
        // A fade still running from the last switch would hold its color over this one.
        layer?.removeAnimation(forKey: "backgroundColor")
        gradientLayer.removeAllAnimations()
        grainLayer.removeAllAnimations()
        if a.clear { setGlass(true, clear: Self.glassKind(clear: true, space).liquid, tint: SpaceInfo.mix(space.frameColor, next.frameColor, by: share)) }
        setColor(a.clear ? .clear : color, animated: false)
        setGradient(from: color, to: a.clear ? end ?? color : end, angle: share < 0.5 ? space.gradientAngle : next.gradientAngle, animated: false)
        let t = Double(min(max(share, 0), 1))
        setGrain((space.grain ?? 0) * (1 - t) + (next.grain ?? 0) * t, texture: t < 0.5 ? space.texture : next.texture, animated: false)
        return (color, end)
    }

    // MARK: Glass

    /// Whether the window is see-through and the glass is Liquid Glass, for a space that shows the desktop (`clear`).
    private static func glassKind(clear: Bool, _ space: SpaceInfo) -> (seeThrough: Bool, liquid: Bool) {
        let shipped = (seeThrough: clear && space.usesClearGlass, liquid: space.usesClearGlass)
        #if DEBUG
        return shipped.seeThrough ? GlassVariant.now.window : shipped
        #else
        return shipped
        #endif
    }

    /// Frosted glass behind the frame, for spaces that want the desktop to show through: blurred, so what's behind
    /// reads as soft shapes and never as text under the sidebar's own. The sidebar's material, the clearest there is.
    private lazy var glassView: NSVisualEffectView = {
        let glass = NSVisualEffectView()
        glass.blendingMode = .behindWindow
        glass.material = .sidebar
        // Live while the window is in front; a still frosting behind other apps' windows, as macOS's own sidebars.
        glass.state = .followsWindowActiveState
        glass.isHidden = true
        addSubview(glass, positioned: .below, relativeTo: nil)
        glass.wantsLayer = true
        glass.layer?.zPosition = -3
        return glass
    }()

    /// The frosting always covers all of what's behind: anything thinner lets it through sharp, and its text then
    /// reads under the sidebar's own. See-through spaces thin their color over the blur instead.
    /// `clear`: Liquid Glass, really transparent and still blurred, tinted with `tint` (it draws over the frame's own
    /// wash, so the color goes in the glass). Before macOS 26 the frosted glass stands in.
    func setGlass(_ on: Bool, clear: Bool = false, tint: NSColor? = nil) {
        glassWanted = on
        let liquid = clear && SpaceInfo.hasClearGlass
        windowGlass = on ? WindowGlass(isClear: liquid, tint: liquid ? tint : nil) : nil
        defer { refreshGlassOcclusion() }
        if #available(macOS 26.0, *), clear {
            glassView.isHidden = true
            let glass = clearGlass as? NSGlassEffectView ?? {
                let made = NSGlassEffectView()
                // Regular, not the clear style: still plainly see-through, but blurred enough that what's behind reads
                // as color and shape, never as text under the sidebar's own.
                made.style = .regular
                made.cornerRadius = 0
                made.wantsLayer = true
                made.layer?.zPosition = -3
                addSubview(made, positioned: .below, relativeTo: nil)
                clearGlass = made
                return made
            }()
            glass.isHidden = !on
            glass.tintColor = tint
            if on { glass.frame = glassFrame }
            // The glass draws over the frame's own grain, so it carries its own, kept in step by `setGrain`.
            if glass.contentView == nil {
                let content = NSView()
                content.wantsLayer = true
                content.layer?.addSublayer(glassGrain)
                glass.contentView = content
            }
            Tokens.Motion.withoutAnimation { glassGrain.frame = glassGrainBounds }
            return
        }
        clearGlass?.isHidden = true
        glassView.isHidden = !on
        glassView.material = .sidebar
        #if DEBUG
        if let material = GlassVariant.now.material { glassView.material = material }
        #endif
        if on { glassView.frame = glassFrame }
    }

    /// The glass the window shows through now, nil while it's solid: what the floating sidebar's glass matches.
    private(set) var windowGlass: WindowGlass?

    /// Where the glass needs to be: only what you can see through. The whole frame, unless something opaque covers
    /// part of it for good.
    var glassFrame: NSRect { bounds }
    private var glassGrainBounds: NSRect { NSRect(origin: .zero, size: glassFrame.size) }

    /// Nothing to see through right now, so the glass rests.
    var glassIsCovered: Bool { false }

    /// Puts the glass where it needs to be now (after what covers it changes).
    func refreshGlassFrame() {
        if !glassView.isHidden { glassView.frame = glassFrame }
        if let clearGlass, !clearGlass.isHidden {
            clearGlass.frame = glassFrame
            Tokens.Motion.withoutAnimation { glassGrain.frame = glassGrainBounds }
        }
    }

    /// Whether the space wants glass; `refreshGlassOcclusion` keeps it off while the window can't be seen.
    private var glassWanted = false
    /// Follows the window's visibility for as long as the view is in one, so the glass comes back the moment the
    /// window shows (at launch, from behind another window, back from the Dock).
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGlassOcclusion() }
        }
        refreshGlassOcclusion()
    }

    isolated deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// A window you can't see (behind others, minimized, on another desktop) needs no live blur: the glass goes
    /// until it shows again, so the window server isn't re-blurring a window nobody is looking at.
    func refreshGlassOcclusion() {
        let visible = window?.occlusionState.contains(.visible) ?? true
        let on = glassWanted && visible && !glassIsCovered
        if let clearGlass, !clearGlass.isHidden || on { clearGlass.alphaValue = on ? 1 : 0 }
        glassView.alphaValue = on ? 1 : 0
    }

    #if DEBUG
    var debugGlass: [String: Any] {
        ["opaque": window?.isOpaque ?? false, "wanted": glassWanted, "frosted": !glassView.isHidden, "frostedAlpha": glassView.alphaValue,
         "clear": clearGlass.map { !$0.isHidden } ?? false, "clearAlpha": clearGlass?.alphaValue ?? -1,
         "clearFrame": NSStringFromRect(clearGlass?.frame ?? .zero), "occlusionVisible": window?.occlusionState.contains(.visible) ?? false,
         "background": window?.backgroundColor.description ?? ""]
    }
    #endif

    /// The clear glass, once a clear space has asked for it.
    private var clearGlass: NSView?
    /// Grain inside the clear glass, matching the frame's.
    private lazy var glassGrain: CALayer = {
        let grain = CALayer()
        grain.backgroundColor = MaterialImages.grain.cgColor
        grain.opacity = 0
        return grain
    }()

    // MARK: Gradient and grain

    /// A second color the frame fades into, corner to corner, under the grain.
    private lazy var gradientLayer: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.zPosition = -2
        gradient.opacity = 0
        layer?.insertSublayer(gradient, at: 0)
        return gradient
    }()
    private var gradientColors: (NSColor, NSColor)?

    func setGradient(from start: NSColor, to end: NSColor?, angle: Double = 45, animated: Bool) {
        gradientColors = end.map { (start, $0) }
        // The angle as two points on the unit square, through its middle (0° runs left to right, 90° top to bottom;
        // the view is flipped, so y grows downward here too).
        let r = angle * .pi / 180
        let dx = cos(r) / 2, dy = sin(r) / 2
        Tokens.Motion.withoutAnimation {
            gradientLayer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            gradientLayer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        }
        applyGradient(animated: animated)
    }

    private func applyGradient(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.large)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        if let (start, end) = gradientColors {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                gradientLayer.colors = [start.cgColor, end.cgColor]
            }
            gradientLayer.opacity = 1
        } else {
            gradientLayer.opacity = 0
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGradient(animated: false)
    }

    /// The frame's grain, under everything else: the same fine noise as Zigzag's own branded screens.
    private lazy var grainLayer: CALayer = {
        let grain = CALayer()
        grain.backgroundColor = MaterialImages.grain.cgColor
        grain.opacity = 0
        grain.zPosition = -1
        layer?.insertSublayer(grain, at: 0)
        return grain
    }()

    /// The grain's texture now (`SpaceInfo.texture`).
    private var grainTexture: String?

    /// 0 is smooth; 1 is as much as reads as texture without becoming noise.
    func setGrain(_ amount: Double, texture: String? = nil, animated: Bool) {
        #if DEBUG
        let amount = GlassVariant.now.dropsGrain ? 0 : amount
        #endif
        let target = Float(min(max(amount, 0), 1) * 0.18)
        if texture != grainTexture {
            grainTexture = texture
            Tokens.Motion.withoutAnimation {
                grainLayer.backgroundColor = MaterialImages.texture(texture).cgColor
                glassGrain.backgroundColor = MaterialImages.texture(texture).cgColor
            }
        }
        guard grainLayer.opacity != target || glassGrain.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.large)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        grainLayer.opacity = target
        glassGrain.opacity = target
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation { grainLayer.frame = bounds; gradientLayer.frame = bounds }
        refreshGlassFrame()
    }
}

/// The glass a see-through window shows the desktop through: Liquid Glass tinted with the space's color, or the
/// frosting (no tint: the color washes over it).
struct WindowGlass: Equatable {
    var isClear: Bool
    var tint: NSColor?
}

#if DEBUG
/// Debug only: other ways to build a clear glass window, to compare frame rates on a 120 Hz display (#394). Set with
/// `-ZZGlassVariant <name>` at launch, `glassvariant <name>` or Debug › Glass Variant; never saved.
enum GlassVariant: String, CaseIterable {
    /// As shipped.
    case current
    /// No grain in the frame, the clear glass or the sidebar.
    case noGrain
    /// No shadows under the page cards.
    case noCardShadow
    case noGrainNoShadow
    /// See-through window and Liquid Glass as shipped, with an opaque layer under each page card.
    case opaqueUnderPage
    /// Opaque window, Liquid Glass kept.
    case opaqueGlass
    /// See-through window, frosted glass instead of Liquid Glass.
    case frostedSeeThrough
    /// Opaque window, `NSVisualEffectView` behind the window (`-ZZGlassMaterial`, under-window background by default).
    case visualEffect

    static var now: GlassVariant = {
        let args = ProcessInfo.processInfo.arguments
        let name = args.firstIndex(of: "-ZZGlassVariant").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        return name.flatMap(GlassVariant.init(rawValue:)) ?? .current
    }()

    /// For a clear glass space: whether the window stays see-through, and whether the glass is Liquid Glass.
    var window: (seeThrough: Bool, liquid: Bool) {
        switch self {
        case .opaqueGlass: (false, true)
        case .frostedSeeThrough: (true, false)
        case .visualEffect: (false, false)
        default: (true, true)
        }
    }

    var dropsGrain: Bool { self == .noGrain || self == .noGrainNoShadow }
    var dropsCardShadow: Bool { self == .noCardShadow || self == .noGrainNoShadow }
    var backsPageOpaque: Bool { self == .opaqueUnderPage }

    /// The frosting's material, when this variant picks one.
    var material: NSVisualEffectView.Material? {
        guard self == .visualEffect else { return nil }
        let args = ProcessInfo.processInfo.arguments
        let name = args.firstIndex(of: "-ZZGlassMaterial").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let materials: [String: NSVisualEffectView.Material] = [
            "sidebar": .sidebar, "underWindowBackground": .underWindowBackground, "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI,
            "headerView": .headerView, "windowBackground": .windowBackground, "menu": .menu, "popover": .popover, "titlebar": .titlebar,
            "contentBackground": .contentBackground, "sheet": .sheet, "toolTip": .toolTip, "underPageBackground": .underPageBackground,
        ]
        return name.flatMap { materials[$0] } ?? .underWindowBackground
    }
}
#endif

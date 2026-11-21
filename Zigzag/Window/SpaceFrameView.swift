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
        // The window stays opaque: macOS shows a see-through one at 80 Hz on a 120 Hz display (#394).
        window?.isOpaque = true
        window?.backgroundColor = .windowBackgroundColor
        setGlass(clear, clear: space.usesClearGlass, tint: space.frameColor)
        // See-through, the wash goes in the gradient layer, the one above the frosted desktop (the frame's own color
        // sits under it and would be hidden); a single color washes as a gradient of itself.
        setColor(clear ? .clear : color, animated: animated, duration: Tokens.Motion.large)
        setGradient(from: color, to: clear ? end ?? color : end, angle: space.gradientAngle, animated: animated)
        setGrain(isPrivate ? 0 : space.grain ?? 0, animated: animated)
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
        if a.clear { setGlass(true, clear: space.usesClearGlass, tint: SpaceInfo.mix(space.frameColor, next.frameColor, by: share)) }
        setColor(a.clear ? .clear : color, animated: false)
        setGradient(from: color, to: a.clear ? end ?? color : end, angle: share < 0.5 ? space.gradientAngle : next.gradientAngle, animated: false)
        let t = Double(min(max(share, 0), 1))
        setGrain((space.grain ?? 0) * (1 - t) + (next.grain ?? 0) * t, animated: false)
        return (color, end)
    }

    // MARK: Glass

    /// Frosted glass behind the frame, for spaces that want the desktop to show through: blurred, so what's behind
    /// reads as soft shapes and never as text under the sidebar's own. The sidebar's material, the clearest there is.
    private lazy var glassView: WindowFrosting = {
        let glass = WindowFrosting()
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
    /// `clear`: clear glass, lightly blurred and tinted with `tint`. It is the frosting with its milk taken out, not
    /// Liquid Glass: that needs a see-through window, which macOS shows at 80 Hz on a 120 Hz display (#394).
    /// Before macOS 26 the frosted glass stands in.
    func setGlass(_ on: Bool, clear: Bool = false, tint: NSColor? = nil) {
        glassWanted = on
        let liquid = clear && SpaceInfo.hasClearGlass
        windowGlass = on ? WindowGlass(isClear: liquid, tint: liquid ? tint : nil) : nil
        defer { refreshGlassOcclusion() }
        glassView.isHidden = !on
        glassView.material = .sidebar
        glassView.clearTint = liquid ? tint : nil
        // Clear glass stays live, as Liquid Glass did; the frosting rests to a still one behind other apps' windows.
        glassView.state = liquid ? .active : .followsWindowActiveState
        if on { glassView.frame = glassFrame }
    }

    /// The glass the window shows through now, nil while it's solid: what the floating sidebar's glass matches.
    private(set) var windowGlass: WindowGlass?

    /// Where the glass needs to be: only what you can see through. The whole frame, unless something opaque covers
    /// part of it for good.
    var glassFrame: NSRect { bounds }

    /// Nothing to see through right now, so the glass rests.
    var glassIsCovered: Bool { false }

    /// Puts the glass where it needs to be now (after what covers it changes).
    func refreshGlassFrame() {
        if !glassView.isHidden { glassView.frame = glassFrame }
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
        glassView.alphaValue = on ? 1 : 0
    }

    #if DEBUG
    var debugGlass: [String: Any] {
        ["opaque": window?.isOpaque ?? false, "wanted": glassWanted, "frosted": !glassView.isHidden, "frostedAlpha": glassView.alphaValue,
         "clear": glassView.clearTint != nil, "occlusionVisible": window?.occlusionState.contains(.visible) ?? false,
         "background": window?.backgroundColor.description ?? ""]
    }
    #endif

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

    /// 0 is smooth; 1 is as much as reads as texture without becoming noise.
    func setGrain(_ amount: Double, animated: Bool) {
        let target = Float(min(max(amount, 0), 1) * 0.18)
        guard grainLayer.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.large)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        grainLayer.opacity = target
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

/// The window's frosting, which can also be clear glass: the same behind-window blur, which the window server draws
/// at the display's full rate in an opaque window, with most of its milk taken out, a lighter blur, and the space's
/// color laid into it as Liquid Glass lays its tint. Where the material's layers aren't the ones expected, it stays
/// the frosting.
final class WindowFrosting: NSVisualEffectView {
    /// The color clear glass takes on; nil for the frosting.
    var clearTint: NSColor? { didSet { if clearTint != oldValue { tune() } } }

    /// How much of the material's milk clear glass keeps, how far it blurs, and how much of the tint's hue it takes:
    /// matched to Liquid Glass over light and dark desktops.
    static let clearMilk: Float = 0.6
    static let clearBlur = 6.0
    static let clearHue: Float = 0.6

    private let hueLayer: CALayer = {
        let layer = CALayer()
        layer.compositingFilter = "colorBlendMode"
        layer.isHidden = true
        return layer
    }()
    private var frostedBlur: [ObjectIdentifier: Any] = [:]

    override func updateLayer() { super.updateLayer(); tune() }
    override func layout() { super.layout(); tune() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); tune() }

    /// AppKit rebuilds the material's layers when the appearance, state or material changes, so this runs after.
    private func tune() {
        guard let root = layer else { return }
        let clear = clearTint != nil
        var material: [CALayer] = []
        var pending = (root.sublayers ?? []).filter { $0 !== hueLayer }
        while let next = pending.popLast() {
            material.append(next)
            pending += next.sublayers ?? []
        }
        Tokens.Motion.withoutAnimation {
            for layer in material {
                switch layer.name {
                case "fill": layer.opacity = clear ? Self.clearMilk : 1
                case "tone": layer.opacity = clear ? 0 : 1
                case "Backdrop": blur(layer, clear: clear)
                default: break
                }
            }
            if hueLayer.superlayer !== root { root.addSublayer(hueLayer) }
            hueLayer.zPosition = 1
            hueLayer.frame = root.bounds
            hueLayer.isHidden = !clear
            hueLayer.opacity = Self.clearHue
            if let clearTint {
                effectiveAppearance.performAsCurrentDrawingAppearance { hueLayer.backgroundColor = clearTint.withAlphaComponent(1).cgColor }
            }
        }
    }

    /// The backdrop's blur, lighter for clear glass, back to the material's own for the frosting.
    private func blur(_ backdrop: CALayer, clear: Bool) {
        guard let filters = backdrop.filters as? [NSObject] else { return }
        for filter in filters {
            guard let name = filter.value(forKey: "name") as? String, name.hasPrefix("gaussianBlur") else { continue }
            let id = ObjectIdentifier(backdrop)
            if frostedBlur[id] == nil { frostedBlur[id] = filter.value(forKey: "inputRadius") }
            guard let radius = clear ? Self.clearBlur : frostedBlur[id] else { continue }
            backdrop.setValue(radius, forKeyPath: "filters.\(name).inputRadius")
        }
    }
}
